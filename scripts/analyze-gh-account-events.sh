#!/usr/bin/env bash

set -euo pipefail
LC_ALL=C
export LC_ALL

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
format=text
audit_root="${AIAUDIT_ROOT:-${HOME:-}/.ai-audit}"
events_path=""
events_explicit=false
patterns_path="$script_root/config/gh-account-incident-patterns.tsv"
history_enabled=true
max_events=10000
max_event_bytes=8388608
max_line_bytes=16384
max_history_files=2000
max_history_file_bytes=262144
since_days=""
unknown_threshold=2

usage() {
  cat <<'EOF'
Usage: analyze-gh-account-events.sh [OPTIONS]

Analyze secret-safe gh-account JSONL events and reviewed historical incident
signals without executing or echoing any logged content.

Options:
  --json                         Emit deterministic JSON (default: text)
  --text                         Emit deterministic human-readable text
  --events PATH                  JSONL spool path
  --audit-root DIR               Audit root containing ledger/
  --patterns PATH                Reviewed fixed-string incident mappings
  --no-history                   Do not scan historical ledger prose
  --max-events N                 Analyze only the newest N lines (default: 10000)
  --max-event-bytes N            Reject a larger event spool (default: 8388608)
  --max-line-bytes N             Ignore and count larger JSONL lines (default: 16384)
  --max-history-files N          Scan at most N ledger files (default: 2000)
  --max-history-file-bytes N     Skip larger ledger files (default: 262144)
  --since-days N                 Window events relative to their newest timestamp
  --unknown-threshold N          Recurrence threshold for unclassified failures
  -h, --help                     Show this help
EOF
}

usage_error() {
  printf 'gh-account-insights: %s\n' "$1" >&2
  exit 64
}

input_error() {
  printf 'gh-account-insights: %s\n' "$1" >&2
  exit 78
}

require_uint() {
  local option="$1"
  local value="$2"
  local maximum="$3"
  case "$value" in
    ''|*[!0-9]*) usage_error "$option requires an integer" ;;
    0|0[0-9]*) usage_error "$option requires a canonical positive integer" ;;
  esac
  if [ "${#value}" -gt "${#maximum}" ] \
    || { [ "${#value}" -eq "${#maximum}" ] && [[ "$value" > "$maximum" ]]; }; then
    usage_error "$option must be between 1 and $maximum"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      format=json
      shift
      ;;
    --text)
      format=text
      shift
      ;;
    --events)
      [ "$#" -ge 2 ] || usage_error "--events requires PATH"
      events_path=$2
      events_explicit=true
      shift 2
      ;;
    --audit-root)
      [ "$#" -ge 2 ] || usage_error "--audit-root requires DIR"
      audit_root=$2
      shift 2
      ;;
    --patterns)
      [ "$#" -ge 2 ] || usage_error "--patterns requires PATH"
      patterns_path=$2
      shift 2
      ;;
    --no-history)
      history_enabled=false
      shift
      ;;
    --max-events)
      [ "$#" -ge 2 ] || usage_error "--max-events requires N"
      max_events=$2
      shift 2
      ;;
    --max-event-bytes)
      [ "$#" -ge 2 ] || usage_error "--max-event-bytes requires N"
      max_event_bytes=$2
      shift 2
      ;;
    --max-line-bytes)
      [ "$#" -ge 2 ] || usage_error "--max-line-bytes requires N"
      max_line_bytes=$2
      shift 2
      ;;
    --max-history-files)
      [ "$#" -ge 2 ] || usage_error "--max-history-files requires N"
      max_history_files=$2
      shift 2
      ;;
    --max-history-file-bytes)
      [ "$#" -ge 2 ] || usage_error "--max-history-file-bytes requires N"
      max_history_file_bytes=$2
      shift 2
      ;;
    --since-days)
      [ "$#" -ge 2 ] || usage_error "--since-days requires N"
      since_days=$2
      shift 2
      ;;
    --unknown-threshold)
      [ "$#" -ge 2 ] || usage_error "--unknown-threshold requires N"
      unknown_threshold=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown option"
      ;;
  esac
done

require_uint --max-events "$max_events" 100000
require_uint --max-event-bytes "$max_event_bytes" 67108864
require_uint --max-line-bytes "$max_line_bytes" 1048576
require_uint --max-history-files "$max_history_files" 10000
require_uint --max-history-file-bytes "$max_history_file_bytes" 1048576
[ -z "$since_days" ] || require_uint --since-days "$since_days" 36500
require_uint --unknown-threshold "$unknown_threshold" 1000

since_days_json=null
[ -z "$since_days" ] || since_days_json=$since_days

if [ "$events_explicit" = false ]; then
  events_path="$audit_root/runtime/gh-account/events.jsonl"
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'gh-account-insights: jq is required\n' >&2
  exit 69
fi
if ! command -v perl >/dev/null 2>&1; then
  printf 'gh-account-insights: perl is required for safe bounded snapshots\n' >&2
  exit 69
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/gh-account-insights.XXXXXX")" || exit 69
cleanup() {
  trap - EXIT HUP INT TERM
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Copy an untrusted input into a private, bounded regular-file snapshot without
# ever blocking on a FIFO. The source is read twice through one descriptor and
# its identity/metadata are revalidated so a symlink swap, growth, or in-place
# mutation is rejected before downstream parsers see any bytes.
bounded_snapshot_file() {
  local source="$1"
  local destination="$2"
  local maximum="$3"
  local allowed_root="${4:-}"
  perl -MFcntl=:DEFAULT,:mode -MCwd=abs_path -e '
    use strict;
    use warnings;

    my ($source, $destination, $maximum, $allowed_root) = @ARGV;
    my $complete = 0;
    END {
      unlink $destination if !$complete && defined($destination) && -e $destination;
    }

    exit 24 unless defined($maximum) && $maximum =~ /^[1-9][0-9]*$/;
    my @path_before = lstat($source);
    exit 20 unless @path_before && S_ISREG($path_before[2]);
    exit 20 unless $path_before[4] == $<;

    my $resolved_before = abs_path($source);
    exit 20 unless defined($resolved_before);
    if (defined($allowed_root) && length($allowed_root)) {
      my $root_real = abs_path($allowed_root);
      exit 20 unless defined($root_real) && -d $root_real;
      my $prefix = $root_real eq q{/} ? q{/} : "$root_real/";
      exit 20 unless index($resolved_before, $prefix) == 0;
    }

    sysopen(my $input, $source, O_RDONLY | O_NONBLOCK) or exit 20;
    binmode($input);
    my @before = stat($input);
    exit 20 unless @before && S_ISREG($before[2]);
    exit 20 unless $before[0] == $path_before[0] && $before[1] == $path_before[1];
    exit 20 unless $before[4] == $<;
    exit 21 if $before[7] > $maximum;

    sysopen(my $output, $destination, O_WRONLY | O_CREAT | O_EXCL, 0600) or exit 24;
    binmode($output);
    my $total = 0;
    while (1) {
      my $chunk = q{};
      my $read = sysread($input, $chunk, 65536);
      exit 22 unless defined($read);
      last if $read == 0;
      $total += $read;
      exit 21 if $total > $maximum;
      my $offset = 0;
      while ($offset < $read) {
        my $written = syswrite($output, $chunk, $read - $offset, $offset);
        exit 24 unless defined($written) && $written > 0;
        $offset += $written;
      }
    }
    close($output) or exit 24;

    seek($input, 0, 0) or exit 22;
    open(my $verify, q{<}, $destination) or exit 24;
    binmode($verify);
    while (1) {
      my ($source_chunk, $snapshot_chunk) = (q{}, q{});
      my $source_read = sysread($input, $source_chunk, 65536);
      my $snapshot_read = sysread($verify, $snapshot_chunk, 65536);
      exit 22 unless defined($source_read) && defined($snapshot_read);
      exit 22 unless $source_read == $snapshot_read && $source_chunk eq $snapshot_chunk;
      last if $source_read == 0;
    }
    close($verify) or exit 24;

    my @after = stat($input);
    exit 22 unless @after;
    for my $field (0, 1, 2, 4, 7, 9, 10) {
      exit 22 unless $after[$field] == $before[$field];
    }
    my @path_after = lstat($source);
    exit 22 unless @path_after && S_ISREG($path_after[2]);
    exit 22 unless $path_after[0] == $before[0] && $path_after[1] == $before[1];
    exit 22 unless $path_after[4] == $<;
    my $resolved_after = abs_path($source);
    exit 22 unless defined($resolved_after) && $resolved_after eq $resolved_before;
    close($input) or exit 22;

    $complete = 1;
    exit 0;
  ' -- "$source" "$destination" "$maximum" "$allowed_root" 2>/dev/null
}

event_snapshot="$scratch/events.snapshot"
event_tail="$scratch/events.tail"
event_filtered="$scratch/events.filtered"
oversize_count_path="$scratch/oversize.count"
event_json="$scratch/events.json"
history_json="$scratch/history.json"
result_json="$scratch/result.json"
known_events_path="$scratch/known-events.txt"
known_findings_path="$scratch/known-findings.txt"

cat >"$known_events_path" <<'EOF'
account.restore.completed
account.restore.failed
account.restore.requested
account.switch.completed
account.switch.failed
account.switch.requested
auth.onboard.awaiting_user
auth.onboard.cancelled
auth.onboard.completed
auth.onboard.failed
auth.onboard.requested
auth.reauth.awaiting_user
auth.reauth.cancelled
auth.reauth.completed
auth.reauth.failed
auth.reauth.requested
auth.repair.awaiting_user
auth.repair.cancelled
auth.repair.completed
auth.repair.failed
auth.repair.requested
doctor.completed
doctor.failed
doctor.started
gh.exec.completed
gh.exec.failed
gh.exec.started
git.exec.completed
lock.acquired
lock.failed
lock.stale_recovered
lock.waited
preflight.completed
preflight.failed
preflight.started
repo.binding.failed
repo.binding.mismatch
repo.binding.repaired
safety.refused
selection.failed
selection.resolved
EOF

cat >"$known_findings_path" <<'EOF'
ACCOUNT.IDENTITY_MISMATCH
ACCOUNT.INVALID
ACCOUNT.NOT_STORED
ACCOUNT.NO_ACTIVE
AUTH.ACTIVE_COUNT
AUTH.CACHED_INVENTORY_ONLY
AUTH.DEEP_CHECK_SKIPPED
AUTH.ENV_OVERRIDE
AUTH.IDENTITY_MISMATCH
AUTH.INVALID
AUTH.KEYCHAIN_CONTEXT_UNAVAILABLE
AUTH.PLAINTEXT_STORAGE
AUTH.REPAIR_CANCELLED
AUTH.REPAIR_FAILED
AUTH.SCOPE_MISSING
AUTH.SSO_REQUIRED
AUTH.STATUS_FAILED
AUTH.STATUS_MALFORMED
AUTH.STORAGE_UNSAFE
AUTH.SWITCH_FAILED
AUTH.UNRELATED_INVALID
CONFIG.INVALID_HOST
CONFIG.RECOVERY_PENDING
CONFIG.UNSAFE_PERMISSIONS
CONTEXT.CUSTOM_GH_CONFIG
CONTEXT.GH_CONFIG_OVERRIDE
CONTEXT.GH_HOST_OVERRIDE
CONTEXT.GH_TRANSPORT_OVERRIDE
CONTEXT.GIT_ENV_OVERRIDE
DEPENDENCY.MISSING
GIT.CREDENTIAL_HELPER
GIT.CREDENTIAL_OVERRIDE
GIT.EXTRA_HEADER
GIT.HTTPS_FAILED
GIT.INSECURE_REMOTE
GIT.SSH_FAILED
GIT.SSH_UNVERIFIED
GIT.TLS_OVERRIDE
GIT.URL_REWRITE
GIT.URL_REWRITE_TRANSPORT
GIT.USE_CONFIG_ONLY
GIT.USE_HTTP_PATH
IDENTITY.MISMATCH
LIFECYCLE.RESTORATION_LOCKING
LOCK.BUSY
LOCK.RELEASE_FAILED
LOCK.STALE
LOCK.UNSAFE
NETWORK.DNS
NETWORK.PROXY
NETWORK.PROXY_CONFIGURED
NETWORK.RATE_LIMIT
NETWORK.SERVICE_UNAVAILABLE
NETWORK.TIMEOUT
NETWORK.TLS
NETWORK.TRANSPORT
OPERATION.IN_PROGRESS
REPO.AMBIGUOUS_ACCOUNT
REPO.BINDING_MISMATCH
REPO.CREDENTIAL_URL
REPO.FORBIDDEN
REPO.INVALID_BINDING
REPO.NOT_GIT
REPO.NO_ORIGIN
REPO.REMOTE_MISMATCH
REPO.UNBOUND
REPO.UNSUPPORTED_REMOTE
RESTORE.FAILED
RESTORE.QUARANTINED
SAFETY.REFUSED
EOF

total_lines=0
lines_considered=0
events_truncated=false
oversize_lines=0

if [ -L "$events_path" ]; then
  input_error "event spool symlinks are not accepted"
fi
if [ -e "$events_path" ]; then
  [ -f "$events_path" ] || input_error "event spool is not a regular file"
  [ -r "$events_path" ] || input_error "event spool is not readable"
  if bounded_snapshot_file "$events_path" "$event_snapshot" "$max_event_bytes"; then
    :
  else
    event_snapshot_status=$?
    case "$event_snapshot_status" in
      21) input_error "event spool exceeds --max-event-bytes; rotate it before analysis" ;;
      20|22) input_error "event spool changed or became unsafe while being read" ;;
      *) input_error "event spool snapshot could not be created" ;;
    esac
  fi
  event_size="$(wc -c <"$event_snapshot" | tr -d '[:space:]')"
  case "$event_size" in
    ''|*[!0-9]*) input_error "could not measure event spool" ;;
  esac
  [ "$event_size" -le "$max_event_bytes" ] || input_error "event spool exceeds --max-event-bytes; rotate it before analysis"

  total_lines="$(awk 'END { print NR + 0 }' "$event_snapshot")"
  if [ "$total_lines" -gt "$max_events" ]; then
    events_truncated=true
  fi
  tail -n "$max_events" "$event_snapshot" >"$event_tail"
else
  : >"$event_snapshot"
  : >"$event_tail"
fi

lines_considered="$(awk 'END { print NR + 0 }' "$event_tail")"
awk -v maximum="$max_line_bytes" -v count_path="$oversize_count_path" '
  length($0) <= maximum { print }
  length($0) > maximum { rejected++ }
  END { print rejected + 0 > count_path }
' "$event_tail" >"$event_filtered"
oversize_lines="$(tr -d '[:space:]' <"$oversize_count_path")"

jq -Rn \
  --rawfile known_events "$known_events_path" \
  --rawfile known_findings "$known_findings_path" \
  --argjson total_lines "$total_lines" \
  --argjson lines_considered "$lines_considered" \
  --argjson events_truncated "$events_truncated" \
  --argjson oversize_lines "$oversize_lines" \
  --argjson since_days "$since_days_json" \
  --argjson unknown_threshold "$unknown_threshold" '
  def valid_event:
    type == "object" and .schema == "gh-account.audit.v1";

  def registry_contains($registry; $candidate):
    ($registry | split("\n") | index($candidate)) != null;

  def event_epoch:
    .timestamp? as $candidate
    | if (($candidate | type) == "string")
         and ($candidate | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      then try (
        ($candidate | fromdateiso8601) as $epoch
        | if ($epoch | todateiso8601) == $candidate then $epoch else null end
      ) catch null
      else null
      end;

  def safe_event_name:
    .event? as $candidate
    | if (($candidate | type) != "string")
         or (($candidate | length) > 64)
         or (($candidate | test("^[a-z][a-z0-9]*(\\.[a-z][a-z0-9_-]*)+$")) | not)
      then "invalid.event"
      elif registry_contains($known_events; $candidate)
      then $candidate
      else "unknown.event"
      end;

  def finding_values:
    ((.finding_ids? // []) as $ids
      | if ($ids | type) == "array" then $ids[] else empty end),
    ((.findings? // []) as $findings
      | if ($findings | type) == "array"
        then $findings[] | if type == "object" then .id? else empty end
        else empty
        end);

  def safe_findings:
    [finding_values
      | select(type == "string")
      | select(length <= 96)
      | select(test("^[A-Z][A-Z0-9_]*(\\.[A-Z0-9_]+)+$"))
      | . as $candidate
      | if registry_contains($known_findings; $candidate) then $candidate else "UNKNOWN.FINDING" end]
    | unique;

  def normalized_outcome:
    (.outcome? // .remediation_outcome? // .status? // "") as $value
    | if (((.exit_code? | type) == "number") and .exit_code == 2) then "cancelled"
      elif (((.exit_code? | type) == "number") and .exit_code != 0) then "failed"
      elif (.status? == "error" or .status? == "failed" or .status? == "failure") then "failed"
      elif ($value | type) != "string" then "other"
      elif $value == "success" or $value == "succeeded" or $value == "completed" or $value == "ok" then "success"
      elif $value == "failed" or $value == "failure" or $value == "error" then "failed"
      elif $value == "action_required" then "action_required"
      elif $value == "cancelled" or $value == "canceled" then "cancelled"
      elif $value == "skipped" then "skipped"
      elif $value == "no_change" then "no_change"
      else "other"
      end;

  def failure_event:
    normalized_outcome as $outcome
    | if $outcome == "cancelled"
      then false
      else ($outcome == "failed")
        or (.status? == "error" or .status? == "failed" or .status? == "failure")
        or (safe_event_name | endswith(".failed"))
        or (((.exit_code? | type) == "number") and (.exit_code != 0))
      end;

  def remediation_event:
    safe_event_name | test("^(auth\\.(repair|reauth|onboard)|repair)\\.");

  [inputs | try fromjson catch {"__parse_error": true}] as $rows
  | [$rows[] | select(valid_event)] as $schema_events
  | [$schema_events[]
      | . as $event
      | (event_epoch) as $epoch
      | select($epoch != null)
      | {event: $event, epoch: $epoch}] as $timestamped_events
  | ($timestamped_events | map(.epoch) | max // null) as $window_reference_epoch
  | (if $since_days == null
     then $schema_events
     elif $window_reference_epoch == null
     then []
     else [$timestamped_events[]
       | select(.epoch >= ($window_reference_epoch - ($since_days * 86400)))
       | .event]
     end) as $events
  | {
      schema: "gh-account.insights.v1",
      source: {
        total_lines: $total_lines,
        lines_considered: $lines_considered,
        events_truncated: $events_truncated,
        oversize_lines: $oversize_lines,
        schema_valid_events: ($schema_events | length),
        valid_events: ($events | length),
        invalid_lines: (($rows | length) - ($schema_events | length)),
        since_days: $since_days,
        window_reference_timestamp: (
          if $since_days == null or $window_reference_epoch == null
          then null
          else ($window_reference_epoch | todateiso8601)
          end
        ),
        timestamp_excluded_events: (
          if $since_days == null
          then 0
          else (($schema_events | length) - ($timestamped_events | length))
          end
        ),
        outside_window_events: (
          if $since_days == null
          then 0
          else (($timestamped_events | length) - ($events | length))
          end
        )
      },
      event_counts: (
        [$events[] | safe_event_name]
        | sort
        | group_by(.)
        | map({event: .[0], count: length})
      ),
      finding_counts: (
        [$events[] | safe_findings[]]
        | sort
        | group_by(.)
        | map({finding_id: .[0], count: length})
      ),
      outcome_counts: (
        [$events[] | normalized_outcome]
        | sort
        | group_by(.)
        | map({outcome: .[0], count: length})
      ),
      remediation_outcomes: (
        [$events[] | select(remediation_event) | normalized_outcome]
        | sort
        | group_by(.)
        | map({outcome: .[0], count: length})
      ),
      unknown_recurring_failures: (
        [$events[]
          | select(failure_event)
          | select((safe_findings | map(select(. != "UNKNOWN.FINDING")) | length) == 0)
          | safe_event_name]
        | sort
        | group_by(.)
        | map(select(length >= $unknown_threshold) | {event: .[0], count: length})
      )
    }
' <"$event_filtered" >"$event_json"

history_files_discovered=0
history_files_considered=0
history_files_skipped_oversize=0
history_files_unreadable=0
history_files_changed_or_unsafe=0
history_files_truncated=false

if [ "$history_enabled" = true ]; then
  [ -f "$patterns_path" ] || input_error "reviewed historical incident mappings are unavailable"
  [ -r "$patterns_path" ] || input_error "reviewed historical incident mappings are unreadable"

  sanitized_patterns="$scratch/patterns.tsv"
  : >"$sanitized_patterns"
  tab=$'\t'
  while IFS="$tab" read -r incident_id finding_id severity needle extra; do
    case "$incident_id" in
      ''|'#'*) continue ;;
    esac
    [ -z "${extra:-}" ] || input_error "incident mapping must contain exactly four tab-separated fields"
    [[ "$incident_id" =~ ^[A-Z][A-Z0-9_]{2,63}$ ]] || input_error "incident mapping contains an invalid incident ID"
    [[ "$finding_id" =~ ^[A-Z][A-Z0-9_]*(\.[A-Z0-9_]+)+$ ]] || input_error "incident mapping contains an invalid finding ID"
    LC_ALL=C grep -Fqx -- "$finding_id" "$known_findings_path" \
      || input_error "incident mapping contains an unallowlisted finding ID"
    case "$severity" in
      info|warning|error) ;;
      *) input_error "incident mapping contains an invalid severity" ;;
    esac
    [ -n "$needle" ] || input_error "incident mapping contains an empty fixed-string pattern"
    [ "${#needle}" -le 256 ] || input_error "incident mapping pattern exceeds 256 characters"
    printf '%s\t%s\t%s\t%s\n' "$incident_id" "$finding_id" "$severity" "$needle" >>"$sanitized_patterns"
  done <"$patterns_path"

  [ -s "$sanitized_patterns" ] || input_error "incident mapping contains no usable patterns"
  if ! awk -F '\t' '
    {
      if (seen[$1] && (finding[$1] != $2 || severity[$1] != $3)) exit 1
      seen[$1] = 1
      finding[$1] = $2
      severity[$1] = $3
    }
  ' "$sanitized_patterns"; then
    input_error "incident mapping reuses an incident ID inconsistently"
  fi

  ledger_root="$audit_root/ledger"
  history_all_nul="$scratch/history.all-nul"
  history_all_unsorted="$scratch/history.all-unsorted"
  history_all="$scratch/history.all"
  history_files="$scratch/history.files"
  history_oversize_nul="$scratch/history.oversize-nul"
  history_oversize_unsorted="$scratch/history.oversize-unsorted"
  history_oversize="$scratch/history.oversize"
  history_skipped_oversize="$scratch/history.skipped-oversize"
  history_eligible="$scratch/history.eligible"
  history_matches="$scratch/history.matches"
  history_unique="$scratch/history.unique"
  history_counts="$scratch/history.counts"
  : >"$history_matches"
  : >"$history_all_unsorted"
  : >"$history_oversize_unsorted"

  if [ -d "$ledger_root" ]; then
    find "$ledger_root" -type f -name '*.md' -print0 >"$history_all_nul" 2>/dev/null \
      || input_error "ledger discovery failed"
    while IFS= read -r -d '' history_candidate; do
      case "$history_candidate" in
        *$'\n'*) input_error "ledger paths containing line breaks are not accepted" ;;
      esac
      printf '%s\n' "$history_candidate" >>"$history_all_unsorted"
    done <"$history_all_nul"
    find "$ledger_root" -type f -name '*.md' -size +"${max_history_file_bytes}"c -print0 >"$history_oversize_nul" 2>/dev/null \
      || input_error "ledger discovery failed"
    while IFS= read -r -d '' history_candidate; do
      case "$history_candidate" in
        *$'\n'*) input_error "ledger paths containing line breaks are not accepted" ;;
      esac
      printf '%s\n' "$history_candidate" >>"$history_oversize_unsorted"
    done <"$history_oversize_nul"
  fi
  LC_ALL=C sort "$history_all_unsorted" >"$history_all"
  LC_ALL=C sort "$history_oversize_unsorted" >"$history_oversize"
  history_files_discovered="$(awk 'END { print NR + 0 }' "$history_all")"
  awk -v maximum="$max_history_files" 'NR <= maximum { print }' "$history_all" >"$history_files"
  if [ "$history_files_discovered" -gt "$max_history_files" ]; then
    history_files_truncated=true
  fi
  LC_ALL=C comm -12 "$history_files" "$history_oversize" >"$history_skipped_oversize"
  LC_ALL=C comm -23 "$history_files" "$history_oversize" >"$history_eligible"
  history_files_skipped_oversize="$(awk 'END { print NR + 0 }' "$history_skipped_oversize")"

  scan_history_batch() {
    local batch_offset="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    awk -F '\t' -v batch_offset="$batch_offset" '
      function clear_matches(  i) {
        for (i in matched) delete matched[i]
      }
      function emit_matches(  i) {
        if (current_file == "") return
        for (i = 1; i <= pattern_count; i++) {
          if (matched[i]) print ids[i] "\t" (batch_offset + file_number)
        }
      }
      NR == FNR {
        ids[++pattern_count] = $1
        patterns[pattern_count] = tolower($4)
        next
      }
      FILENAME != current_file {
        emit_matches()
        clear_matches()
        current_file = FILENAME
        file_number++
      }
      {
        line = tolower($0)
        for (i = 1; i <= pattern_count; i++) {
          if (!matched[i] && index(line, patterns[i]) != 0) matched[i] = 1
        }
      }
      END { emit_matches() }
    ' "$sanitized_patterns" "$@"
  }

  scan_files=()
  scan_batch_offset=0
  history_snapshot_index=0
  while IFS= read -r history_file; do
    case "$history_file" in
      "$ledger_root"/*) ;;
      *)
        history_files_changed_or_unsafe=$((history_files_changed_or_unsafe + 1))
        continue
        ;;
    esac
    if [ ! -r "$history_file" ]; then
      history_files_unreadable=$((history_files_unreadable + 1))
      continue
    fi
    history_snapshot_index=$((history_snapshot_index + 1))
    history_snapshot="$scratch/history.snapshot.$history_snapshot_index"
    if bounded_snapshot_file "$history_file" "$history_snapshot" \
      "$max_history_file_bytes" "$ledger_root"; then
      :
    else
      history_snapshot_status=$?
      case "$history_snapshot_status" in
        20|21|22)
          history_files_changed_or_unsafe=$((history_files_changed_or_unsafe + 1))
          continue
          ;;
        *) input_error "bounded ledger snapshot could not be created" ;;
      esac
    fi
    history_files_considered=$((history_files_considered + 1))
    scan_files+=("$history_snapshot")
    if [ "${#scan_files[@]}" -ge 100 ]; then
      scan_history_batch "$scan_batch_offset" "${scan_files[@]}" >>"$history_matches"
      scan_batch_offset=$((scan_batch_offset + ${#scan_files[@]}))
      scan_files=()
    fi
  done <"$history_eligible"
  if [ "${#scan_files[@]}" -gt 0 ]; then
    scan_history_batch "$scan_batch_offset" "${scan_files[@]}" >>"$history_matches"
  fi

  LC_ALL=C sort -u "$history_matches" >"$history_unique"
  awk -F '\t' '!seen[$1]++ { print $1 "\t" $2 "\t" $3 }' "$sanitized_patterns" | LC_ALL=C sort >"$scratch/history.meta"
  : >"$history_counts"
  while IFS="$tab" read -r incident_id finding_id severity; do
    match_count="$(awk -F '\t' -v wanted="$incident_id" '$1 == wanted { count++ } END { print count + 0 }' "$history_unique")"
    if [ "$match_count" -gt 0 ]; then
      printf '%s\t%s\t%s\t%s\n' "$incident_id" "$finding_id" "$severity" "$match_count" >>"$history_counts"
    fi
  done <"$scratch/history.meta"

  jq -Rn '
    [inputs
      | split("\t")
      | {
          incident_id: .[0],
          finding_id: .[1],
          severity: .[2],
          matching_files: (.[3] | tonumber)
        }]
    | sort_by(.incident_id)
  ' <"$history_counts" >"$history_json"
else
  printf '[]\n' >"$history_json"
fi

jq -S \
  --slurpfile history "$history_json" \
  --argjson history_files_discovered "$history_files_discovered" \
  --argjson history_files_considered "$history_files_considered" \
  --argjson history_files_skipped_oversize "$history_files_skipped_oversize" \
  --argjson history_files_unreadable "$history_files_unreadable" \
  --argjson history_files_changed_or_unsafe "$history_files_changed_or_unsafe" \
  --argjson history_files_truncated "$history_files_truncated" '
  .historical_incidents = $history[0]
  | .source.history_files_discovered = $history_files_discovered
  | .source.history_files_considered = $history_files_considered
  | .source.history_files_skipped_oversize = $history_files_skipped_oversize
  | .source.history_files_unreadable = $history_files_unreadable
  | .source.history_files_changed_or_unsafe = $history_files_changed_or_unsafe
  | .source.history_files_truncated = $history_files_truncated
' "$event_json" >"$result_json"

if [ "$format" = json ]; then
  sed -n '1,$p' "$result_json"
else
  jq -r '
    "gh-account insights",
    "events: valid=\(.source.valid_events) invalid=\(.source.invalid_lines) oversize=\(.source.oversize_lines) considered=\(.source.lines_considered)/\(.source.total_lines)",
    (if .source.since_days == null then empty else
      "window: since_days=\(.source.since_days) reference=\(.source.window_reference_timestamp // "none") timestamp_excluded=\(.source.timestamp_excluded_events) outside_window=\(.source.outside_window_events)"
    end),
    "history: considered=\(.source.history_files_considered)/\(.source.history_files_discovered) oversize=\(.source.history_files_skipped_oversize) unreadable=\(.source.history_files_unreadable) changed_or_unsafe=\(.source.history_files_changed_or_unsafe) truncated=\(.source.history_files_truncated)",
    "event counts:",
    (if (.event_counts | length) == 0 then "  none" else .event_counts[] | "  \(.event): \(.count)" end),
    "finding counts:",
    (if (.finding_counts | length) == 0 then "  none" else .finding_counts[] | "  \(.finding_id): \(.count)" end),
    "outcome counts:",
    (if (.outcome_counts | length) == 0 then "  none" else .outcome_counts[] | "  \(.outcome): \(.count)" end),
    "remediation outcomes:",
    (if (.remediation_outcomes | length) == 0 then "  none" else .remediation_outcomes[] | "  \(.outcome): \(.count)" end),
    "unknown recurring failures:",
    (if (.unknown_recurring_failures | length) == 0 then "  none" else .unknown_recurring_failures[] | "  \(.event): \(.count)" end),
    "historical signals (untrusted prose; review required):",
    (if (.historical_incidents | length) == 0 then "  none" else .historical_incidents[] | "  \(.incident_id) -> \(.finding_id): \(.matching_files) file(s)" end)
  ' "$result_json"
fi
