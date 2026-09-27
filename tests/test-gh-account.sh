#!/bin/sh

# Behavioral contract for the gh-account router. The suite targets macOS 11+
# and maintained Linux userlands with /bin/sh plus the production tool's
# declared git/jq and advisory-lock dependencies.
# Every test gets an isolated HOME, gh config, Git config, PATH, repository,
# lock directory, fake gh state, and audit event file.
set -u

script_dir=$(unset CDPATH; cd "$(dirname "$0")" && pwd)
repo_root=$(unset CDPATH; cd "$script_dir/.." && pwd)
gh_account_bin=${GH_ACCOUNT_BIN:-$repo_root/gh-account}
fake_gh_source=$script_dir/fixtures/gh-account/gh
fake_git_source=$script_dir/fixtures/gh-account/git
fake_ln_source=$script_dir/fixtures/gh-account/ln
fake_mv_source=$script_dir/fixtures/gh-account/mv
fake_rm_source=$script_dir/fixtures/gh-account/rm
fake_lockf_source=$script_dir/fixtures/gh-account/lockf
fake_ps_source=$script_dir/fixtures/gh-account/ps
fake_stat_source=$script_dir/fixtures/gh-account/stat

host_git=$(command -v git 2>/dev/null || true)
host_jq=$(command -v jq 2>/dev/null || true)
host_lockf=$(command -v lockf 2>/dev/null || true)
host_flock=$(command -v flock 2>/dev/null || true)
host_ln=$(command -v ln 2>/dev/null || true)
host_mv=$(command -v mv 2>/dev/null || true)
host_rm=$(command -v rm 2>/dev/null || true)
host_ps=$(command -v ps 2>/dev/null || true)
host_stat=$(command -v stat 2>/dev/null || true)
host_script=$(command -v script 2>/dev/null || true)
host_expect=$(command -v expect 2>/dev/null || true)

if [ ! -x "$gh_account_bin" ]; then
  printf 'Bail out! gh-account executable not found: %s\n' "$gh_account_bin" >&2
  exit 1
fi
if [ ! -x "$fake_gh_source" ]; then
  printf 'Bail out! fake gh fixture is not executable: %s\n' "$fake_gh_source" >&2
  exit 1
fi
if [ ! -x "$fake_git_source" ]; then
  printf 'Bail out! fake git fixture is not executable: %s\n' "$fake_git_source" >&2
  exit 1
fi
if [ ! -f "$fake_ln_source" ]; then
  printf 'Bail out! fake ln fixture not found: %s\n' "$fake_ln_source" >&2
  exit 1
fi
if [ ! -f "$fake_mv_source" ]; then
  printf 'Bail out! fake mv fixture not found: %s\n' "$fake_mv_source" >&2
  exit 1
fi
if [ ! -f "$fake_rm_source" ]; then
  printf 'Bail out! fake rm fixture not found: %s\n' "$fake_rm_source" >&2
  exit 1
fi
if [ ! -f "$fake_lockf_source" ]; then
  printf 'Bail out! fake lockf fixture not found: %s\n' "$fake_lockf_source" >&2
  exit 1
fi
if [ ! -f "$fake_ps_source" ]; then
  printf 'Bail out! fake ps fixture not found: %s\n' "$fake_ps_source" >&2
  exit 1
fi
if [ ! -f "$fake_stat_source" ]; then
  printf 'Bail out! fake stat fixture not found: %s\n' "$fake_stat_source" >&2
  exit 1
fi
if [ -z "$host_git" ] || [ -z "$host_jq" ] || [ -z "$host_ln" ] || \
   [ -z "$host_mv" ] || [ -z "$host_rm" ] || [ -z "$host_ps" ] || \
   [ -z "$host_stat" ] || { [ -z "$host_lockf" ] && [ -z "$host_flock" ]; }; then
  printf 'Bail out! the test host requires git, jq, ln, mv, rm, ps, stat, and lockf or flock\n' >&2
  exit 1
fi

suite_tmp=$(mktemp -d)
cleanup_suite_tmp() {
  if [ "${KEEP_TEST_TMP:-0}" = 1 ]; then
    printf '# preserved test workspace: %s\n' "$suite_tmp" >&2
  else
    rm -rf "$suite_tmp"
  fi
}
trap cleanup_suite_tmp EXIT HUP INT TERM
test_count=0
failure_count=0

diagnose() {
  printf '%s\n' "$*" >&2
  return 1
}

assert_status() {
  expected_status=$1
  [ "$cli_status" -eq "$expected_status" ] || \
    diagnose "expected exit $expected_status, got $cli_status; diagnostic: $("$host_jq" -c '{status,findings:[.findings[]?|{id,summary}]}' "$cli_stdout" 2>/dev/null || sed -n '1p' "$cli_stderr")"
}

assert_nonzero_status() {
  [ "$cli_status" -ne 0 ] || diagnose 'expected a non-zero exit status'
}

assert_stdout_json() {
  "$host_jq" -e . "$cli_stdout" >/dev/null 2>&1 || \
    diagnose "stdout is not one valid JSON document: $(sed -n '1,3p' "$cli_stdout")"
}

assert_json() {
  json_filter=$1
  "$host_jq" -e "$json_filter" "$cli_stdout" >/dev/null 2>&1 || \
    diagnose "JSON contract failed: $json_filter"
}

assert_finding() {
  finding_id=$1
  # shellcheck disable=SC2016 # $id is a jq variable supplied by --arg.
  "$host_jq" -e --arg id "$finding_id" \
    '.findings | any(.id == $id)' "$cli_stdout" >/dev/null 2>&1 || \
    diagnose "expected finding $finding_id"
}

assert_file_contains() {
  searched_file=$1
  literal=$2
  [ -f "$searched_file" ] || diagnose "missing expected file: $searched_file"
  grep -F -- "$literal" "$searched_file" >/dev/null 2>&1 || \
    diagnose "expected '$literal' in $searched_file"
}

assert_file_not_contains() {
  searched_file=$1
  literal=$2
  if [ -f "$searched_file" ] && grep -F -- "$literal" "$searched_file" >/dev/null 2>&1; then
    diagnose "sensitive/unexpected text appeared in $searched_file"
  fi
}

assert_combined_contains() {
  literal=$1
  if ! grep -F -- "$literal" "$cli_stdout" >/dev/null 2>&1 && \
     ! grep -F -- "$literal" "$cli_stderr" >/dev/null 2>&1; then
    diagnose "expected diagnostic text '$literal'"
  fi
}

assert_output_not_contains() {
  literal=$1
  assert_file_not_contains "$cli_stdout" "$literal" || return 1
  assert_file_not_contains "$cli_stderr" "$literal"
}

link_host_tool() {
  link_name=$1
  link_path=$(command -v "$link_name" 2>/dev/null || true)
  case "$link_path" in
    /*) ln -s "$link_path" "$case_bin/$link_name" ;;
  esac
}

setup_case() {
  include_gh=${1:-yes}
  include_jq=${2:-yes}
  include_git=${3:-yes}

  case_root=$(mktemp -d "$suite_tmp/case.XXXXXX")
  case_bin=$case_root/bin
  fake_state=$case_root/fake-gh
  cli_stdout=$case_root/stdout
  cli_stderr=$case_root/stderr
  mkdir -p "$case_bin" "$fake_state" "$case_root/home/.config/gh" \
    "$case_root/runtime" "$case_root/audit"

  # Supply only explicit tools. This lets dependency tests prove that the
  # production CLI handles an actually absent gh, jq, or git executable.
  # bash is listed because the router re-execs under it from its pinned PATH:
  # without it, Linux hosts whose /bin/sh is dash run the job-control
  # supervisor under a shell it was never validated on and every routed
  # command fails — exactly the runtime this suite must exercise.
  for case_tool in awk basename bash cat chmod cmp cp cut date dirname env grep head id \
    mkdir mktemp printf ps rmdir sed sleep sort tail touch tr uname wc; do
    link_host_tool "$case_tool"
  done
  cp "$fake_ln_source" "$case_bin/ln"
  chmod 755 "$case_bin/ln"
  cp "$fake_mv_source" "$case_bin/mv"
  chmod 755 "$case_bin/mv"
  cp "$fake_rm_source" "$case_bin/rm"
  chmod 755 "$case_bin/rm"
  cp "$fake_stat_source" "$case_bin/stat"
  chmod 755 "$case_bin/stat"
  if [ "$include_git" = yes ]; then
    cp "$fake_git_source" "$case_bin/git"
    chmod 755 "$case_bin/git"
  fi
  [ "$include_jq" = yes ] && ln -s "$host_jq" "$case_bin/jq"
  [ -z "$host_lockf" ] || ln -s "$host_lockf" "$case_bin/lockf"
  [ -z "$host_flock" ] || ln -s "$host_flock" "$case_bin/flock"
  if [ "$include_gh" = yes ]; then
    cp "$fake_gh_source" "$case_bin/gh"
    chmod 755 "$case_bin/gh"
  fi

  printf '%s\n' alice bob >"$fake_state/accounts"
  printf 'alice\n' >"$fake_state/active"
  printf 'success\n' >"$fake_state/account.alice.state"
  printf 'success\n' >"$fake_state/account.bob.state"
  printf 'repo,read:org\n' >"$fake_state/account.alice.scopes"
  printf 'repo,read:org\n' >"$fake_state/account.bob.scopes"
  printf '1001\n' >"$fake_state/account.alice.id"
  printf '1002\n' >"$fake_state/account.bob.id"
  printf 'Alice Example\n' >"$fake_state/account.alice.name"
  printf 'Bob Example\n' >"$fake_state/account.bob.name"
  printf 'GH_ACCOUNT_TEST_TOKEN_CANARY_91e4\n' >"$fake_state/token_canary"
  : >"$fake_state/calls.log"

  HOME=$case_root/home
  GH_CONFIG_DIR=$HOME/.config/gh
  case_git_config=$HOME/.gitconfig
  XDG_CONFIG_HOME=$HOME/.config
  XDG_CACHE_HOME=$case_root/cache
  XDG_RUNTIME_DIR=$case_root/runtime
  FAKE_GH_STATE_DIR=$fake_state
  FAKE_GH_LOG=$fake_state/calls.log
  FAKE_GIT_REAL=$host_git
  FAKE_LN_REAL=$host_ln
  FAKE_MV_REAL=$host_mv
  FAKE_RM_REAL=$host_rm
  FAKE_LOCKF_REAL=$host_lockf
  FAKE_PS_REAL=$host_ps
  FAKE_STAT_REAL=$host_stat
  case_audit_file=$HOME/.local/state/gh-account/events.jsonl
  gh_account_lock_dir=$case_root/runtime/operation.lock
  gh_account_state_dir=$case_root/runtime/github.com
  gh_account_transaction_journal=$case_root/runtime/config.pending.json
  "$host_git" config --file "$case_git_config" \
    credential.https://github.com.useHttpPath true
  "$host_git" config --file "$case_git_config" user.useConfigOnly true
  "$host_git" config --file "$case_git_config" --add \
    credential.https://github.com.helper ''
  "$host_git" config --file "$case_git_config" --add \
    credential.https://github.com.helper '!gh auth git-credential'
  case_gh_account_bin=$case_bin/gh-account-under-test
  sed \
    -e "s|^PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin$|PATH=$case_bin|" \
    -e 's|^lock_root=/tmp/gh-account-$account_uid$|lock_root='"$case_root"'/runtime|' \
    -e "s|^audit_file=.*$|audit_file=$case_audit_file|" \
    -e 's/^lock_attempts=100$/lock_attempts=1/' \
    -e 's/^lock_sleep=0.1$/lock_sleep=0/' \
    -e 's/^signal_grace=5$/signal_grace=1/' \
    "$gh_account_bin" >"$case_gh_account_bin"
  chmod 755 "$case_gh_account_bin"
  PATH=$case_bin
  export HOME GH_CONFIG_DIR XDG_CONFIG_HOME
  export XDG_CACHE_HOME XDG_RUNTIME_DIR FAKE_GH_STATE_DIR FAKE_GH_LOG FAKE_GIT_REAL
  export FAKE_LN_REAL FAKE_MV_REAL FAKE_RM_REAL
  export FAKE_LOCKF_REAL
  export FAKE_PS_REAL FAKE_STAT_REAL
  export PATH
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_DIR GIT_WORK_TREE GIT_CONFIG
  unset GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GH_ACCOUNT_TEST_MODE
  unset GH_ACCOUNT_TEST_ALLOW_GIT_ENV GH_ACCOUNT_RUNTIME_DIR GH_ACCOUNT_AUDIT_FILE
  GIT_CONFIG_GLOBAL=$case_git_config
  GH_ACCOUNT_AUDIT_FILE=$case_audit_file
  unset GH_TOKEN GITHUB_TOKEN
}

start_lock_holder() {
  mkdir "$gh_account_lock_dir" || return 1
  chmod 700 "$gh_account_lock_dir"
  /bin/sleep 30 &
  lock_holder_pid=$!
  printf '%s\n' "$lock_holder_pid" >"$gh_account_lock_dir/owner.pid"
  printf 'test-live-owner\n' >"$gh_account_lock_dir/owner.nonce"
  LC_ALL=C TZ=UTC /bin/ps -o lstart= -p "$lock_holder_pid" |
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' >"$gh_account_lock_dir/owner.birth"
}

lock_is_available() {
  [ ! -e "$gh_account_lock_dir" ]
}

wait_for_file() {
  waited_file=$1
  waited_attempts=${2:-1000}
  waited_count=0
  while [ ! -e "$waited_file" ] && [ "$waited_count" -lt "$waited_attempts" ]; do
    sleep 0.01
    waited_count=$((waited_count + 1))
  done
  [ -e "$waited_file" ]
}

process_is_live() {
  # kill -0 alone is zombie-blind: a KILLed child whose parent is gone stays
  # signalable when PID 1 does not reap orphans (containers without --init).
  # The router uses the same state check in lease_process_matches.
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(LC_ALL=C ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]
}

wait_for_process_exit() {
  waited_pid=$1
  waited_attempts=${2:-500}
  waited_count=0
  while process_is_live "$waited_pid" && [ "$waited_count" -lt "$waited_attempts" ]; do
    sleep 0.01
    waited_count=$((waited_count + 1))
  done
  ! process_is_live "$waited_pid"
}

terminate_case_router() {
  if [ -f "$gh_account_lock_dir/owner.pid" ]; then
    cleanup_router_pid=$(sed -n '1p' "$gh_account_lock_dir/owner.pid" 2>/dev/null || true)
    case "$cleanup_router_pid" in
      ''|*[!0-9]*) ;;
      *)
        kill -TERM "$cleanup_router_pid" 2>/dev/null || true
        sleep 0.1
        kill -KILL "$cleanup_router_pid" 2>/dev/null || true
        ;;
    esac
  fi
}

run_cli() {
  : >"$cli_stdout"
  : >"$cli_stderr"
  "$case_gh_account_bin" "$@" >"$cli_stdout" 2>"$cli_stderr"
  cli_status=$?
}

make_repo() {
  remote_owner=${1:-}
  case_repo=$case_root/repo
  mkdir -p "$case_repo"
  "$host_git" -C "$case_repo" init -q
  if [ -n "$remote_owner" ]; then
    "$host_git" -C "$case_repo" remote add origin \
      "https://github.com/$remote_owner/example.git"
  fi
}

bind_repo_to_bob() {
  "$host_git" -C "$case_repo" config --local github.account bob
  "$host_git" -C "$case_repo" config --local credential.username bob
  "$host_git" -C "$case_repo" config --local user.name 'Bob Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1002+bob@users.noreply.github.com'
}

test_doctor_healthy_json() {
  setup_case
  run_cli doctor --json
  assert_status 0 || return 1
  assert_stdout_json || return 1
  assert_json '.schema == "gh-account.diagnostic.v1" and
    .status == "healthy" and
    .mutation_performed == false and
    (.findings | type == "array") and
    .channels.gh_keyring == "healthy" and
    .channels.api == "healthy"' || return 1
  assert_file_contains "$fake_state/calls.log" 'api user'
}

test_stat_selection_is_cwd_independent() {
  setup_case
  magic_cwd=$case_root/stat-magic
  mkdir "$magic_cwd"
  for magic_name in '%u' '%l' '%d' '%i' '%Lp'; do
    : >"$magic_cwd/$magic_name"
  done
  original_cwd=$PWD
  cd "$magic_cwd" || return 1
  run_cli doctor --json
  cd "$original_cwd" || return 1
  assert_status 0 || return 1
  assert_stdout_json
}

test_doctor_rejects_error_state_with_zero_native_exit() {
  setup_case
  printf 'error\n' >"$fake_state/account.alice.state"
  run_cli doctor --json
  assert_status 1 || return 1
  assert_stdout_json || return 1
  assert_json '.status == "action_required" and .mutation_performed == false' || return 1
  assert_finding AUTH.STATUS_FAILED
}

test_doctor_classifies_native_timeout_without_reauth_advice() {
  setup_case
  printf 'timeout\n' >"$fake_state/account.alice.state"
  run_cli doctor --json
  assert_status 1 || return 1
  assert_stdout_json || return 1
  assert_finding NETWORK.TIMEOUT || return 1
  assert_json '[.findings[].remediation_argv[]? | select(. == "reauth")] | length == 0'
}

test_preflight_classifies_native_timeout_as_temporary_failure() {
  setup_case
  printf 'timeout\n' >"$fake_state/account.alice.state"
  run_cli preflight alice --json
  assert_status 75 || return 1
  assert_stdout_json || return 1
  assert_finding NETWORK.TIMEOUT || return 1
  assert_json '[.findings[].remediation_argv[]? | select(. == "reauth")] | length == 0'
}

test_doctor_classifies_malformed_native_json() {
  setup_case
  : >"$fake_state/status_malformed"
  run_cli doctor --json
  assert_nonzero_status || return 1
  assert_stdout_json || return 1
  assert_finding AUTH.STATUS_MALFORMED
}

test_doctor_handles_empty_native_host_inventory() {
  setup_case
  : >"$fake_state/status_empty_hosts"
  run_cli doctor --json
  assert_status 4 || return 1
  assert_stdout_json || return 1
  assert_finding ACCOUNT.NO_ACTIVE
}

test_doctor_reports_missing_gh() {
  setup_case no yes yes
  run_cli doctor
  assert_status 69 || return 1
  assert_combined_contains DEPENDENCY.MISSING || return 1
  assert_combined_contains gh
}

test_doctor_reports_missing_jq() {
  setup_case yes no yes
  GH_ACCOUNT_HOST=enterprise.example
  export GH_ACCOUNT_HOST
  run_cli doctor --json
  assert_status 69 || return 1
  assert_combined_contains DEPENDENCY.MISSING || return 1
  assert_combined_contains jq || return 1
  "$host_jq" -e '.host == "enterprise.example"' "$cli_stdout" >/dev/null 2>&1 || \
    diagnose 'no-jq fallback misreported the configured GitHub host'
}

test_doctor_reports_missing_git() {
  setup_case yes yes no
  run_cli doctor
  assert_status 69 || return 1
  assert_combined_contains DEPENDENCY.MISSING || return 1
  assert_combined_contains git
}

test_doctor_detects_gh_token_override_without_leakage() {
  setup_case
  GH_TOKEN='GH_TOKEN_CANARY_f20c9a'
  export GH_TOKEN
  run_cli doctor --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding AUTH.ENV_OVERRIDE || return 1
  assert_output_not_contains "$GH_TOKEN" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$GH_TOKEN" || return 1
  [ ! -s "$fake_state/calls.log" ] || diagnose 'doctor invoked gh while GH_TOKEN overrode keyring authority'
}

test_doctor_detects_github_token_override_without_leakage() {
  setup_case
  GITHUB_TOKEN='GITHUB_TOKEN_CANARY_7b8d13'
  export GITHUB_TOKEN
  run_cli doctor --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding AUTH.ENV_OVERRIDE || return 1
  assert_output_not_contains "$GITHUB_TOKEN" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$GITHUB_TOKEN"
}

test_doctor_redacts_invalid_account_argument() {
  setup_case
  invalid_account='INVALID_ACCOUNT_SECRET_CANARY_4c10/unsafe'
  run_cli doctor --account "$invalid_account" --json
  assert_nonzero_status || return 1
  assert_stdout_json || return 1
  assert_finding ACCOUNT.INVALID || return 1
  assert_output_not_contains "$invalid_account" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$invalid_account"
}

test_doctor_structures_and_redacts_invalid_host() {
  setup_case
  host_canary='INVALID_HOST_TOKEN_CANARY_8f7a/..'
  GH_ACCOUNT_HOST=$host_canary
  export GH_ACCOUNT_HOST
  run_cli doctor --json
  assert_status 78 || return 1
  assert_stdout_json || return 1
  assert_finding CONFIG.INVALID_HOST || return 1
  assert_json '.host == "invalid-redacted"' || return 1
  assert_output_not_contains "$host_canary" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$host_canary"
}

test_host_validation_normalizes_case_and_rejects_invalid_dns_labels() {
  setup_case
  GH_ACCOUNT_HOST=GitHub.COM
  export GH_ACCOUNT_HOST
  run_cli doctor --json
  assert_status 0 || return 1
  assert_json '.host == "github.com"' || return 1
  long_label=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  for invalid_host in -github.com github-.com "$long_label.example" github.com.; do
    GH_ACCOUNT_HOST=$invalid_host
    export GH_ACCOUNT_HOST
    run_cli doctor --json
    assert_status 78 || return 1
    assert_finding CONFIG.INVALID_HOST || return 1
    assert_json '.host == "invalid-redacted"' || return 1
  done
}

test_doctor_refuses_git_context_override_without_leakage() {
  setup_case
  GIT_DIR="$case_root/GIT_CONTEXT_CANARY_5c71"
  export GIT_DIR
  run_cli doctor --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding CONTEXT.GIT_ENV_OVERRIDE || return 1
  assert_output_not_contains "$GIT_DIR" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$GIT_DIR"
}

test_commands_reject_alternate_github_cli_state_roots() {
  setup_case
  alternate_root=$case_root/alternate-gh-state
  mkdir -p "$alternate_root"
  GH_CONFIG_DIR=$alternate_root
  export GH_CONFIG_DIR
  # Regenerate the test copy so startup observes the hostile override instead
  # of the trusted path captured by setup_case.
  run_cli doctor --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding CONTEXT.GH_CONFIG_OVERRIDE || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth status' || return 1
  run_cli exec bob -- pr view 1
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'pr view'
}

test_commands_reject_github_transport_and_debug_overrides() {
  setup_case
  transport_canary=$case_root/GH_TRANSPORT_CANARY.sock
  GH_HTTP_UNIX_SOCKET=$transport_canary
  export GH_HTTP_UNIX_SOCKET
  run_cli doctor --json
  assert_status 77 || return 1
  assert_finding CONTEXT.GH_TRANSPORT_OVERRIDE || return 1
  assert_output_not_contains "$transport_canary" || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth status' || return 1
  run_cli exec bob -- pr view 1
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'pr view' || return 1

  unset GH_HTTP_UNIX_SOCKET
  GODEBUG=http2debug=2
  export GODEBUG
  : >"$fake_state/calls.log"
  run_cli exec bob -- pr view 1
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth status' || return 1
  assert_file_not_contains "$fake_state/calls.log" 'pr view' || return 1

  unset GODEBUG
  SSLKEYLOGFILE=$case_root/TLS_KEY_LOG_CANARY
  export SSLKEYLOGFILE
  run_cli exec bob -- pr view 1
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth status' || return 1
  [ ! -e "$SSLKEYLOGFILE" ] || diagnose 'unsafe TLS key logging was started'
}

test_git_config_permissions_fail_closed() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  chmod 666 "$case_git_config"
  run_cli doctor "$case_repo" --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding CONFIG.UNSAFE_PERMISSIONS || return 1

  : >"$fake_state/calls.log"
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding CONFIG.UNSAFE_PERMISSIONS || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth switch' || return 1

  chmod 600 "$case_git_config"
  common_raw=$("$host_git" -C "$case_repo" rev-parse --git-common-dir)
  case "$common_raw" in
    /*) common_dir=$common_raw ;;
    *) common_dir=$(cd "$case_repo/$common_raw" && pwd -P) ;;
  esac
  chmod 666 "$common_dir/config"
  : >"$fake_state/calls.log"
  run_cli repair bob "$case_repo"
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth setup-git' || return 1
  run_cli git-exec bob "$case_repo" -- fetch origin
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'git fetch'
}

test_gh_config_permissions_and_links_fail_closed() {
  setup_case
  printf 'fixture: true\n' >"$GH_CONFIG_DIR/hosts.yml"
  chmod 666 "$GH_CONFIG_DIR/hosts.yml"
  run_cli doctor --json
  assert_status 77 || return 1
  assert_finding CONFIG.UNSAFE_PERMISSIONS || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth status' || return 1
  run_cli exec bob -- pr view 1
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'pr view' || return 1

  setup_case
  gh_config_outside=$case_root/hosts-outside.yml
  printf 'fixture: true\n' >"$gh_config_outside"
  ln -s "$gh_config_outside" "$GH_CONFIG_DIR/hosts.yml"
  run_cli doctor --json
  assert_status 77 || return 1
  assert_finding CONFIG.UNSAFE_PERMISSIONS || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth status'
}

test_git_config_includes_require_safe_origins() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  included_parent=$case_root/included-parent
  mkdir "$included_parent"
  # The invariant is "a parent writable by a principal other than the owner is
  # refused". Plain `chmod 770` no longer expresses that on user-private-group
  # systems (Debian/Ubuntu: the owner's primary group is a same-named group
  # with no other members, so 770 is owner-only and the router now accepts it).
  # Hand the directory to a group the owner belongs to but which is NOT their
  # private group when one exists; otherwise fall back to other-writable.
  shared_gid=
  for candidate_gid in $(id -G); do
    [ "$candidate_gid" != "$(id -g)" ] || continue
    if chgrp "$candidate_gid" "$included_parent" 2>/dev/null; then
      shared_gid=$candidate_gid
      break
    fi
  done
  if [ -n "$shared_gid" ]; then
    chmod 770 "$included_parent"
  else
    chmod 707 "$included_parent"
  fi
  included_config=$included_parent/included.gitconfig
  "$host_git" config --file "$included_config" safe.fixture true
  chmod 600 "$included_config"
  "$host_git" config --file "$case_git_config" include.path "$included_config"
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding CONFIG.UNSAFE_PERMISSIONS || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth switch' || return 1
  run_cli git-exec bob "$case_repo" -- fetch origin
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'git fetch'
}

test_absent_global_git_config_is_safe_for_first_use() {
  setup_case
  rm "$case_git_config"
  run_cli doctor --json
  [ "$cli_status" -ne 77 ] || return 1
  assert_stdout_json || return 1
  assert_json '.findings | all(.id != "CONFIG.UNSAFE_PERMISSIONS")'
}

test_preflight_refuses_git_author_identity_override() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  GIT_AUTHOR_EMAIL='wrong-author@example.invalid'
  export GIT_AUTHOR_EMAIL
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding CONTEXT.GIT_ENV_OVERRIDE || return 1
  assert_output_not_contains "$GIT_AUTHOR_EMAIL"
}

test_doctor_reports_repository_binding_mismatch() {
  setup_case
  make_repo alice
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username bob
  run_cli doctor "$case_repo" --json
  assert_status 78 || return 1
  assert_stdout_json || return 1
  assert_finding REPO.BINDING_MISMATCH || return 1
  assert_json '[.findings[] | select(.remediation_argv[1] == "repair") |
    (.safe_to_automate == false and .requires_operator == true)] | all'
}

test_doctor_redacts_invalid_repository_binding() {
  setup_case
  make_repo example-org
  binding_canary='ghp_CONFIG_CANARY_7d31'
  "$host_git" -C "$case_repo" config --local github.account "$binding_canary"
  "$host_git" -C "$case_repo" config --local credential.username bob
  run_cli doctor "$case_repo" --account bob --json
  assert_nonzero_status || return 1
  assert_finding REPO.INVALID_BINDING || return 1
  assert_output_not_contains "$binding_canary" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$binding_canary" || return 1
  run_cli current "$case_repo"
  assert_output_not_contains "$binding_canary" || return 1
  assert_combined_contains 'invalid-redacted'
}

test_doctor_redacts_embedded_remote_credentials() {
  setup_case
  make_repo example-org
  remote_canary='REMOTE_CREDENTIAL_CANARY_8a31'
  "$host_git" -C "$case_repo" remote set-url origin \
    "https://$remote_canary@github.com/example-org/example.git"
  run_cli doctor "$case_repo" --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding REPO.CREDENTIAL_URL || return 1
  assert_output_not_contains "$remote_canary" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$remote_canary"
}

test_doctor_requires_explicit_account_for_org_remote() {
  setup_case
  make_repo example-org
  run_cli doctor "$case_repo" --json
  assert_status 78 || return 1
  assert_stdout_json || return 1
  assert_finding REPO.AMBIGUOUS_ACCOUNT
}

test_doctor_requires_explicit_account_without_remote() {
  setup_case
  make_repo
  run_cli doctor "$case_repo" --json
  assert_status 78 || return 1
  assert_stdout_json || return 1
  assert_finding REPO.AMBIGUOUS_ACCOUNT
}

test_preflight_verifies_identity_and_restores_active_account() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  run_cli preflight bob "$case_repo" --json
  assert_status 0 || return 1
  assert_stdout_json || return 1
  assert_json '.status == "healthy" and .account == "bob" and
    .mutation_performed == false' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'preflight did not restore alice'
  assert_file_contains "$fake_state/calls.log" 'auth switch bob' || return 1
  assert_file_contains "$fake_state/calls.log" 'api user' || return 1
  assert_file_contains "$fake_state/calls.log" 'auth switch alice'
}

test_preflight_classifies_api_network_failures_without_reauth() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  printf '1\n' >"$fake_state/api_exit"
  printf 'request timed out while contacting GitHub\n' >"$fake_state/api_error"
  run_cli preflight bob "$case_repo" --json
  assert_status 75 || { sed 's/^/network stdout: /' "$cli_stdout" >&2; sed 's/^/network stderr: /' "$cli_stderr" >&2; return 1; }
  assert_stdout_json || return 1
  assert_finding NETWORK.TIMEOUT || return 1
  assert_file_not_contains "$cli_stdout" 'gh-account reauth' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'network failure preflight did not restore alice'
}

test_preflight_classifies_repository_dns_failure() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  printf '1\n' >"$fake_state/repo_exit"
  printf 'Could not resolve host: github.com\n' >"$fake_state/repo_error"
  run_cli preflight bob "$case_repo" --json
  assert_status 75 || return 1
  assert_stdout_json || return 1
  assert_finding NETWORK.DNS || return 1
  assert_file_not_contains "$cli_stdout" 'gh-account reauth'
}

test_preflight_classifies_rate_limit_and_service_failures_as_temporary() {
  setup_case
  printf '1\n' >"$fake_state/status_exit"
  printf 'HTTP 503 service unavailable\n' >"$fake_state/status_error"
  run_cli preflight bob --json
  assert_status 75 || return 1
  assert_stdout_json || return 1
  assert_finding NETWORK.SERVICE_UNAVAILABLE || return 1
  assert_file_not_contains "$cli_stdout" 'gh-account reauth' || return 1

  setup_case
  make_repo example-org
  bind_repo_to_bob
  printf '1\n' >"$fake_state/api_exit"
  printf 'HTTP 429 secondary rate limit\n' >"$fake_state/api_error"
  run_cli preflight bob "$case_repo" --json
  assert_status 75 || return 1
  assert_stdout_json || return 1
  assert_finding NETWORK.RATE_LIMIT || return 1
  assert_file_not_contains "$cli_stdout" 'gh-account reauth' || return 1

  setup_case
  make_repo example-org
  bind_repo_to_bob
  printf '1\n' >"$fake_state/repo_exit"
  printf 'HTTP 407 Proxy Authentication Required\n' >"$fake_state/repo_error"
  run_cli preflight bob "$case_repo" --json
  assert_status 75 || return 1
  assert_finding NETWORK.PROXY || return 1
  assert_file_not_contains "$cli_stdout" 'gh-account reauth'
}

test_preflight_refuses_environment_token_override() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  GH_TOKEN='PREFLIGHT_TOKEN_CANARY_b937'
  export GH_TOKEN
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding AUTH.ENV_OVERRIDE || return 1
  assert_output_not_contains "$GH_TOKEN" || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth switch bob'
}

test_preflight_rejects_non_keyring_credential_storage() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  printf 'plaintext-file\n' >"$fake_state/account.bob.source"
  run_cli preflight bob "$case_repo" --json
  assert_status 4 || return 1
  assert_stdout_json || return 1
  assert_finding AUTH.PLAINTEXT_STORAGE || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth switch bob'
}

test_preflight_classifies_repository_binding_mismatch() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  run_cli preflight bob "$case_repo" --json
  assert_status 78 || return 1
  assert_stdout_json || return 1
  assert_finding REPO.BINDING_MISMATCH || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'mismatch preflight did not restore alice'
}

test_preflight_rejects_divergent_marker_and_credential() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  "$host_git" -C "$case_repo" config --local credential.username alice
  run_cli preflight bob "$case_repo" --json
  assert_status 78 || return 1
  assert_stdout_json || return 1
  assert_finding REPO.BINDING_MISMATCH || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'divergence preflight did not restore alice'
}

test_preflight_rejects_unexpected_credential_helper() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" --add \
    credential.https://github.com.helper '!unexpected-helper'
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding GIT.CREDENTIAL_HELPER || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'helper preflight did not restore alice'
}

test_preflight_rejects_basename_masquerading_helper() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" --replace-all \
    credential.https://github.com.helper ''
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" --add \
    credential.https://github.com.helper '!/tmp/untrusted/gh auth git-credential'
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding GIT.CREDENTIAL_HELPER
}

test_helper_validation_honors_git_reset_semantics() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  xdg_git_config=$HOME/.config/git/config
  mkdir -p "${xdg_git_config%/*}"
  "$host_git" config --file "$xdg_git_config" --add \
    credential.https://github.com.helper '!pre-reset-helper'
  run_cli preflight bob "$case_repo" --json
  assert_status 0 || return 1

  "$host_git" config --file "$case_git_config" --add \
    credential.https://github.com.helper '!post-reset-helper'
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding GIT.CREDENTIAL_HELPER
}

test_preflight_rejects_effective_route_overrides_and_proxy() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  route_key='https://github.com/example-org/example.git'
  "$host_git" -C "$case_repo" config --local \
    "credential.$route_key.useHttpPath" false
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding GIT.USE_HTTP_PATH || return 1

  setup_case
  make_repo example-org
  bind_repo_to_bob
  "$host_git" -C "$case_repo" config --local user.useConfigOnly false
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding GIT.USE_CONFIG_ONLY || return 1

  setup_case
  make_repo example-org
  bind_repo_to_bob
  "$host_git" -C "$case_repo" config --local \
    http.https://github.com/.proxy http://127.0.0.1:9
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding NETWORK.PROXY_CONFIGURED || return 1
  run_cli git-exec bob "$case_repo" -- fetch origin
  assert_status 78 || return 1

  setup_case
  make_repo example-org
  bind_repo_to_bob
  "$host_git" -C "$case_repo" config --local \
    remote.origin.proxy http://127.0.0.1:9
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding NETWORK.PROXY_CONFIGURED || return 1
  run_cli git-exec bob "$case_repo" -- fetch origin
  assert_status 78 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'git fetch'
}

test_preflight_rejects_effective_repository_url_rewrite() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  "$host_git" config --file "$case_git_config" \
    url.https://github.com/attacker/other.insteadOf \
    https://github.com/example-org/example
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding GIT.URL_REWRITE || return 1
  run_cli git-exec bob "$case_repo" -- fetch origin
  assert_status 78 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'git fetch'
}

test_preflight_rejects_mixed_case_host_extra_header() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  header_canary=MIXED_CASE_HEADER_CANARY_a81f
  "$host_git" config --file "$case_git_config" \
    http.https://GitHub.com/.extraHeader "Authorization: $header_canary"
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding GIT.EXTRA_HEADER || return 1
  assert_output_not_contains "$header_canary"
}

test_preflight_refuses_embedded_remote_credentials() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  remote_canary='PREFLIGHT_REMOTE_CANARY_3f24'
  "$host_git" -C "$case_repo" remote set-url origin \
    "https://user:$remote_canary@github.com/example-org/example.git"
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding REPO.CREDENTIAL_URL || return 1
  assert_output_not_contains "$remote_canary" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$remote_canary" || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'credential preflight did not restore alice'
}

test_preflight_rejects_different_push_target() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  "$host_git" -C "$case_repo" remote set-url --push origin \
    'https://github.com/other-owner/other.git'
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding REPO.REMOTE_MISMATCH
}

test_preflight_rejects_local_credential_and_header_overrides() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  override_canary='LOCAL_AUTH_HEADER_CANARY_69ad'
  "$host_git" -C "$case_repo" config --local --add credential.helper '!local-helper'
  "$host_git" -C "$case_repo" config --local \
    http.https://github.com/.extraHeader "Authorization: $override_canary"
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_stdout_json || return 1
  assert_finding GIT.CREDENTIAL_OVERRIDE || return 1
  assert_finding GIT.EXTRA_HEADER || return 1
  assert_output_not_contains "$override_canary" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$override_canary"
}

test_preflight_canonicalizes_account_case() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  run_cli preflight BOB "$case_repo" --json
  assert_status 0 || return 1
  assert_stdout_json || return 1
  assert_json '.account == "bob" and .status == "healthy"'
}

test_preflight_requires_local_binding_and_exact_noreply_identity() {
  setup_case
  make_repo example-org
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" github.account bob
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" credential.username bob
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" user.name 'Bob Example'
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" user.email \
    '1002+bob@users.noreply.github.com'
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding REPO.BINDING_MISMATCH || return 1
  bind_repo_to_bob
  "$host_git" -C "$case_repo" config --local user.email \
    'attacker+bob@users.noreply.github.com'
  run_cli preflight bob "$case_repo" --json
  assert_status 78 || return 1
  assert_finding IDENTITY.MISMATCH
}

test_preflight_rejects_path_specific_transport_and_tls_overrides() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  path_key=https://github.com/example-org/example.git
  "$host_git" -C "$case_repo" config --local \
    "credential.$path_key.helper" '!path-specific-evil'
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding GIT.CREDENTIAL_OVERRIDE || return 1
  "$host_git" -C "$case_repo" config --local --unset-all \
    "credential.$path_key.helper"
  "$host_git" -C "$case_repo" config --local --add \
    "http.$path_key.extraHeader" 'Authorization: REDACTED-CANARY'
  "$host_git" -C "$case_repo" config --local --add \
    "http.$path_key.extraHeader" 'X-Safe: yes'
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding GIT.EXTRA_HEADER || return 1
  "$host_git" -C "$case_repo" config --local --unset-all \
    "http.$path_key.extraHeader"
  multiline_header_canary=HEADER_VALUE_CANARY_7ac1
  "$host_git" -C "$case_repo" config --local --add \
    "http.$path_key.extraHeader" "X-Safe: yes
Authorization: $multiline_header_canary"
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding GIT.EXTRA_HEADER || return 1
  assert_output_not_contains "$multiline_header_canary" || return 1
  "$host_git" -C "$case_repo" config --local --unset-all \
    "http.$path_key.extraHeader"
  "$host_git" -C "$case_repo" config --local \
    "http.$path_key.sslVerify" false
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding GIT.TLS_OVERRIDE
}

test_preflight_refuses_unverified_ssh_transport() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  "$host_git" -C "$case_repo" remote set-url origin \
    git@github.com:example-org/example.git
  run_cli preflight bob "$case_repo" --json
  assert_status 78 || return 1
  assert_stdout_json || return 1
  assert_finding GIT.SSH_UNVERIFIED || return 1
  assert_json '.channels.git_ssh == "unverified"'
}

test_doctor_builds_cwd_independent_remediation_arguments() {
  setup_case
  "$host_git" config --file "$case_git_config" --unset-all \
    credential.https://github.com.useHttpPath
  run_cli doctor --account bob --json
  assert_stdout_json || return 1
  assert_json '.findings[] | select(.id == "GIT.USE_HTTP_PATH") |
    .remediation_argv == ["gh-account","repair","bob"]' || return 1
  assert_json '[.findings[].remediation_argv[]? | select(. == ".")] | length == 0' || return 1

  setup_case
  : >"$fake_state/active"
  "$host_git" config --file "$case_git_config" --unset-all \
    credential.https://github.com.useHttpPath
  run_cli doctor --json
  assert_stdout_json || return 1
  assert_json '.findings[] | select(.id == "GIT.USE_HTTP_PATH") |
    .remediation_argv == []'
}

test_scope_and_git_transport_environment_inputs_fail_closed() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  : >"$case_root/admin:org"
  : >"$cli_stdout"
  : >"$cli_stderr"
  (cd "$case_root" && "$case_gh_account_bin" preflight bob "$case_repo" \
    --required-scopes '*' --json >"$cli_stdout" 2>"$cli_stderr")
  cli_status=$?
  assert_status 64 || return 1
  GIT_TRACE_CURL=1
  GIT_TRACE_REDACT=0
  export GIT_TRACE_CURL GIT_TRACE_REDACT
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding CONTEXT.GIT_ENV_OVERRIDE || return 1
  unset GIT_TRACE_CURL GIT_TRACE_REDACT
  GIT_EXEC_PATH=$case_root/attacker
  export GIT_EXEC_PATH
  run_cli git-exec bob "$case_repo" -- fetch origin
  assert_status 77 || return 1
  assert_combined_contains SAFETY.REFUSED
}

test_preflight_surfaces_restore_failure() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  printf 'alice\n' >"$fake_state/switch_fail_user"
  run_cli preflight bob "$case_repo" --json
  assert_nonzero_status || return 1
  assert_stdout_json || return 1
  assert_json '.status == "failed"' || return 1
  assert_finding RESTORE.FAILED
}

test_preflight_surfaces_lock_release_failure() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  : >"$fake_state/corrupt_lock_before_release"
  run_cli preflight bob "$case_repo" --json
  assert_status 75 || return 1
  assert_stdout_json || return 1
  assert_json '.status == "failed"' || return 1
  assert_finding LOCK.RELEASE_FAILED
}

test_exec_blocks_auth_token() {
  setup_case
  run_cli exec bob -- auth token
  assert_status 77 || return 1
  assert_combined_contains SAFETY.REFUSED || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth token' || return 1
  assert_output_not_contains "$(cat "$fake_state/token_canary")"
}

test_exec_blocks_show_token() {
  setup_case
  for token_flag in --show-token --show-token=true -t -t=true -at; do
    : >"$fake_state/calls.log"
    run_cli exec bob -- auth status "$token_flag"
    assert_status 77 || return 1
    assert_combined_contains SAFETY.REFUSED || return 1
    assert_file_not_contains "$fake_state/calls.log" 'auth status' || return 1
    assert_output_not_contains "$(cat "$fake_state/token_canary")" || return 1
  done
  assert_file_contains "$GH_ACCOUNT_AUDIT_FILE" 'safety.refused'
}

test_exec_blocks_alias_extension_and_unknown_dispatch() {
  setup_case
  for blocked_command in alias extension token-alias; do
    : >"$fake_state/calls.log"
    run_cli exec bob -- "$blocked_command" run
    assert_status 77 || return 1
    assert_combined_contains SAFETY.REFUSED || return 1
    assert_file_not_contains "$fake_state/calls.log" "$blocked_command" || return 1
    assert_output_not_contains "$(cat "$fake_state/token_canary")" || return 1
  done
}

test_exec_blocks_auth_mutations() {
  setup_case
  for mutation in login logout switch refresh; do
    : >"$fake_state/calls.log"
    run_cli exec bob -- auth "$mutation"
    assert_status 77 || return 1
    assert_combined_contains SAFETY.REFUSED || return 1
    assert_file_not_contains "$fake_state/calls.log" "auth $mutation" || return 1
  done
}

test_exec_refuses_cross_host_and_credential_key_operations() {
  setup_case
  for unsafe_args in \
    'api --hostname enterprise.invalid user' \
    'api -X DELETE user/keys/1' \
    'ssh-key delete 1 --yes' \
    'gpg-key delete 1 --yes' \
    'repo view enterprise.invalid/owner/repo' \
    'repo view ghe/owner/repo' \
    'pr -R owner/repo checkout 1' \
    'secret -R owner/repo set NAME' \
    'codespace --repo owner/repo ssh' \
    'repo deploy-key delete 1 --yes' \
    'pr checkout 1' \
    'pr view 1 --web' \
    'browse owner/repo' \
    'secret delete example'; do
    # shellcheck disable=SC2086 # Deliberately split the fixed test vector.
    run_cli exec bob -- $unsafe_args
    assert_status 77 || return 1
    assert_combined_contains SAFETY.REFUSED || return 1
  done
  assert_file_not_contains "$fake_state/calls.log" 'user/keys/1'
}

test_exec_pins_repo_and_neutralizes_local_program_launchers() {
  setup_case
  make_repo example-org
  : >"$cli_stdout"
  : >"$cli_stderr"
  (cd "$case_repo" && "$case_gh_account_bin" exec bob -- pr env-check \
    >"$cli_stdout" 2>"$cli_stderr")
  cli_status=$?
  assert_status 0 || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'environment-hardening exec did not restore alice'
}

test_exec_refuses_gh_repo_environment_override() {
  setup_case
  GH_REPO='enterprise.invalid/owner/repo'
  export GH_REPO
  run_cli exec bob -- pr view 1
  assert_status 77 || return 1
  assert_combined_contains SAFETY.REFUSED || return 1
  assert_file_not_contains "$fake_state/calls.log" 'pr view'
}

test_exec_allows_only_read_only_graphql() {
  setup_case
  # shellcheck disable=SC2016 # GraphQL variables must remain literal.
  read_query='query($owner:String!){repository(owner:$owner){name}}'
  run_cli exec bob -- api graphql -f query="$read_query" -F owner=example-org
  assert_status 0 || return 1
  assert_file_contains "$fake_state/calls.log" 'api graphql' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'read-only GraphQL exec did not restore alice'

  for unsafe_query in \
    'mutation{deleteProjectV2(input:{projectV2Id:"x"}){clientMutationId}}' \
    'subscription{securityAdvisoryUpdated{id}}'; do
    : >"$fake_state/calls.log"
    run_cli exec bob -- api graphql -f query="$unsafe_query"
    assert_status 77 || return 1
    assert_combined_contains SAFETY.REFUSED || return 1
    assert_file_not_contains "$fake_state/calls.log" 'api graphql' || return 1
  done

  : >"$fake_state/calls.log"
  run_cli exec bob -- api graphql -f other=value
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'api graphql' || return 1

  : >"$fake_state/calls.log"
  run_cli exec bob -- api graphql -f query="$read_query" \
    -F 'query=mutation{deleteProjectV2(input:{projectV2Id:"x"}){clientMutationId}}'
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'api graphql'
}

test_exec_preserves_downstream_exit_and_restores() {
  setup_case
  printf '42\n' >"$fake_state/downstream_exit"
  printf 'downstream marker\n' >"$fake_state/downstream_output"
  run_cli exec bob -- pr view 123
  assert_status 42 || return 1
  assert_file_contains "$cli_stdout" 'downstream marker' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'exec did not restore alice'
}

test_exec_cleanup_failure_dominates_downstream_exit() {
  setup_case
  printf '42\n' >"$fake_state/downstream_exit"
  printf 'alice\n' >"$fake_state/switch_fail_user"
  run_cli exec bob -- pr view 123
  assert_status 75 || return 1
  assert_combined_contains 'routed-operation cleanup failed' || return 1
  [ -e "$gh_account_state_dir/restore.pending" ] || \
    diagnose 'cleanup failure did not preserve restore quarantine'
}

test_restore_requires_quarantine_cleanup_before_success() {
  setup_case
  printf 'alice\n' >"$fake_state/corrupt_restore_quarantine_user"
  run_cli exec bob -- pr view 123
  assert_status 75 || return 1
  assert_combined_contains 'routed-operation cleanup failed' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'restore-cleanup failure did not restore the original identity'
  [ -e "$gh_account_state_dir/restore.pending" ] || \
    diagnose 'restore-cleanup failure did not preserve quarantine metadata'
}

test_temporary_routes_refuse_zero_active_account() {
  setup_case
  : >"$fake_state/active"
  run_cli preflight bob --json
  assert_status 4 || return 1
  assert_stdout_json || return 1
  assert_finding ACCOUNT.NO_ACTIVE || return 1
  [ ! -s "$fake_state/active" ] || diagnose 'preflight activated an account without a restore target'

  setup_case
  : >"$fake_state/active"
  run_cli exec bob -- pr view 123
  assert_status 4 || return 1
  [ ! -s "$fake_state/active" ] || diagnose 'exec activated an account without a restore target'

  setup_case
  make_repo example-org
  bind_repo_to_bob
  : >"$fake_state/active"
  run_cli git-exec bob "$case_repo" -- fetch origin
  assert_status 4 || return 1
  [ ! -s "$fake_state/active" ] || diagnose 'git-exec activated an account without a restore target' || return 1

  setup_case
  make_repo example-org
  : >"$fake_state/active"
  run_cli repair bob "$case_repo"
  assert_status 4 || return 1
  [ ! -s "$fake_state/active" ] || diagnose 'repair activated an account without a restore target' || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth setup-git' || return 1

  run_cli bind bob "$case_repo"
  assert_status 4 || return 1
  [ ! -s "$fake_state/active" ] || diagnose 'bind activated an account without a restore target'
}

test_lock_dependency_and_unsafe_state_have_distinct_exits() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  rm -f "$case_bin/lockf" "$case_bin/flock"
  run_cli preflight bob "$case_repo" --json
  assert_status 69 || return 1
  assert_finding DEPENDENCY.MISSING || return 1
  run_cli reauth bob --json
  assert_status 69 || return 1
  assert_finding DEPENDENCY.MISSING || return 1
  run_cli repair bob "$case_repo"
  assert_status 69 || return 1
  run_cli bind bob "$case_repo"
  assert_status 69 || return 1
  run_cli use bob "$case_repo"
  assert_status 69 || return 1
  run_cli exec bob -- pr view 1
  assert_status 69 || return 1
  run_cli git-exec bob "$case_repo" -- fetch origin
  assert_status 69 || return 1
  run_cli onboard charlie
  assert_status 69 || return 1

  setup_case
  make_repo example-org
  bind_repo_to_bob
  outside_gate=$case_root/outside-gate
  : >"$outside_gate"
  ln -s "$outside_gate" "$case_root/runtime/operation.gate"
  run_cli preflight bob "$case_repo" --json
  assert_status 77 || return 1
  assert_finding LOCK.UNSAFE || return 1
  run_cli exec bob -- pr view 1
  assert_status 77

  setup_case
  rm -f "$case_bin/ps"
  printf '#!/bin/sh\nexit 1\n' >"$case_bin/ps"
  chmod 755 "$case_bin/ps"
  run_cli preflight bob --json
  assert_status 69 || return 1
  assert_finding DEPENDENCY.MISSING
}

test_git_exec_routes_transport_and_restores() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  : >"$fake_state/intercept_git_transport"
  : >"$fake_state/require_hooks_disabled"
  run_cli git-exec bob "$case_repo" -- push origin feature/test
  assert_status 0 || { sed 's/^/git-exec stderr: /' "$cli_stderr" >&2; return 1; }
  assert_file_contains "$fake_state/calls.log" 'git push bob' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'git-exec did not restore the previously active account'
  [ ! -e "$fake_state/hook_canary" ] || \
    diagnose 'git-exec allowed a repository hook inside the selected-account window'
  assert_file_contains "$GH_ACCOUNT_AUDIT_FILE" 'git.exec.completed'
}

test_git_exec_holds_config_guards_through_transport() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  missing_include=$HOME/.config/git/routed-missing.gitconfig
  mkdir -p "${missing_include%/*}"
  chmod 700 "${missing_include%/*}"
  "$host_git" config --file "$case_git_config" --add include.path "$missing_include"
  : >"$fake_state/intercept_git_transport"
  : >"$fake_state/block_git_transport"
  "$case_gh_account_bin" git-exec bob "$case_repo" -- fetch origin \
    >"$cli_stdout" 2>"$cli_stderr" &
  router_pid=$!
  if ! wait_for_file "$fake_state/git_transport.ready" 3000; then
    kill -KILL "$router_pid" 2>/dev/null || true
    wait "$router_pid" 2>/dev/null || true
    diagnose 'git-exec did not reach the guarded transport barrier'
    return 1
  fi
  [ -f "$case_repo/.git/config.lock" ] && [ ! -L "$case_repo/.git/config.lock" ] || {
    : >"$fake_state/release_git_transport"
    wait "$router_pid" 2>/dev/null || true
    diagnose 'git-exec did not hold the repository config lock through transport'
    return 1
  }
  [ -f "$case_git_config.lock" ] && [ ! -L "$case_git_config.lock" ] || {
    : >"$fake_state/release_git_transport"
    wait "$router_pid" 2>/dev/null || true
    diagnose 'git-exec did not hold the global config lock through transport'
    return 1
  }
  [ -f "$missing_include.lock" ] && [ ! -L "$missing_include.lock" ] || {
    : >"$fake_state/release_git_transport"
    wait "$router_pid" 2>/dev/null || true
    diagnose 'git-exec did not guard an absent declared include target'
    return 1
  }
  if "$host_git" -C "$case_repo" remote set-url origin \
    https://github.com/attacker/other.git >/dev/null 2>&1; then
    : >"$fake_state/release_git_transport"
    wait "$router_pid" 2>/dev/null || true
    diagnose 'concurrent Git writer changed the guarded repository route'
    return 1
  fi
  if "$host_git" config --global concurrent.guard bypassed >/dev/null 2>&1; then
    : >"$fake_state/release_git_transport"
    wait "$router_pid" 2>/dev/null || true
    diagnose 'concurrent Git writer changed guarded global configuration'
    return 1
  fi
  if "$host_git" config --file "$missing_include" credential.helper '!unexpected' \
    >/dev/null 2>&1; then
    : >"$fake_state/release_git_transport"
    wait "$router_pid" 2>/dev/null || true
    diagnose 'concurrent writer created an unguarded declared include target'
    return 1
  fi
  : >"$fake_state/release_git_transport"
  wait "$router_pid"
  cli_status=$?
  assert_status 0 || { sed 's/^/git-exec guard stderr: /' "$cli_stderr" >&2; return 1; }
  [ ! -e "$case_repo/.git/config.lock" ] && [ ! -e "$case_git_config.lock" ] && \
    [ ! -e "$missing_include.lock" ] && [ ! -e "$missing_include" ] || \
    diagnose 'git-exec left canonical Git config locks after completion' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'guarded git-exec did not restore the previous account'
}

test_git_exec_recovers_owned_config_guards_after_crash() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  : >"$fake_state/intercept_git_transport"
  : >"$fake_state/block_git_transport"
  "$case_gh_account_bin" git-exec bob "$case_repo" -- fetch origin \
    >"$cli_stdout" 2>"$cli_stderr" &
  router_pid=$!
  if ! wait_for_file "$fake_state/git_transport.ready" 3000; then
    kill -KILL "$router_pid" 2>/dev/null || true
    wait "$router_pid" 2>/dev/null || true
    diagnose 'git-exec did not reach the crash-recovery barrier'
    return 1
  fi
  child_pid=$(cat "$fake_state/git_transport.pid")
  kill -KILL "$router_pid" 2>/dev/null || true
  wait "$router_pid" 2>/dev/null || true
  run_cli preflight bob "$case_repo" --json
  assert_status 75 || {
    : >"$fake_state/release_git_transport"
    kill -KILL "$child_pid" 2>/dev/null || true
    return 1
  }
  : >"$fake_state/release_git_transport"
  child_wait=0
  while process_is_live "$child_pid" && [ "$child_wait" -lt 1000 ]; do
    sleep 0.01
    child_wait=$((child_wait + 1))
  done
  if process_is_live "$child_pid"; then
    kill -KILL "$child_pid" 2>/dev/null || true
    diagnose 'orphaned routed Git child did not exit after release'
    return 1
  fi
  # The crashed router's lease also names its supervisor (child.owner). The
  # supervisor only exits after two empty process-group snapshots 100 ms apart,
  # and while it is alive the lease is legitimately busy (LOCK.BUSY, retryable).
  # macOS starts the next router slowly enough to lose that race by accident;
  # Linux wins it. Wait for the supervisor explicitly so the assertion below
  # tests reclaim, not scheduler timing.
  supervisor_pid=$(sed -n '1p' "$gh_account_lock_dir/child.owner" 2>/dev/null || true)
  case "$supervisor_pid" in
    ''|*[!0-9]*) ;;
    *)
      supervisor_wait=0
      # kill -0 alone cannot see that the supervisor has exited when its
      # parent (the crashed router) is gone and PID 1 does not reap orphans
      # (containers without --init): the zombie stays signalable. Consult
      # the process state as the router itself now does.
      while process_is_live "$supervisor_pid" && [ "$supervisor_wait" -lt 1000 ]; do
        sleep 0.01
        supervisor_wait=$((supervisor_wait + 1))
      done
      ;;
  esac
  # Recovery is deliberately restricted to the quarantined prior identity.
  run_cli preflight alice --json
  assert_status 0 || { sed 's/^/guard recovery stderr: /' "$cli_stderr" >&2; return 1; }
  [ ! -e "$case_repo/.git/config.lock" ] && [ ! -e "$case_git_config.lock" ] || \
    diagnose 'stale routed Git guards were not reclaimed safely' || return 1
  lock_is_available || diagnose 'stale routed operation lease was not retired'
}

test_git_exec_refuses_unsafe_or_unbound_routes() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  : >"$fake_state/intercept_git_transport"
  run_cli git-exec bob "$case_repo" -- credential fill
  assert_status 77 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'git credential' || return 1
  run_cli git-exec bob "$case_repo" -- push upstream feature/test
  assert_status 77 || return 1
  run_cli git-exec bob "$case_repo" -- fetch origin --mult upstream
  assert_status 77 || return 1
  run_cli git-exec bob "$case_repo" -- push origin -u feature/test
  assert_status 77 || return 1
  "$host_git" -C "$case_repo" remote set-url origin git@github.com:example-org/example.git
  run_cli git-exec bob "$case_repo" -- fetch origin
  assert_status 78
}

test_use_restores_previous_account_when_identity_verification_fails() {
  setup_case
  printf 'mallory\n' >"$fake_state/api_login_override"
  run_cli use bob
  assert_status 4 || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'failed use left bob active'
  lock_is_available || diagnose 'failed use left the advisory lock held'
}

test_use_commits_account_and_binding_as_one_outcome() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  printf 'bob\n' >"$fake_state/corrupt_restore_quarantine_user"
  run_cli use bob "$case_repo"
  assert_status 75 || { sed 's/^/use commit stderr: /' "$cli_stderr" >&2; return 1; }
  [ "$(cat "$fake_state/active")" = bob ] || \
    diagnose 'committed persistent use restored only the account half' || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = bob ] || \
    diagnose 'committed persistent use restored only the binding half' || return 1
  [ -f "$gh_account_transaction_journal" ] && [ ! -L "$gh_account_transaction_journal" ] || \
    diagnose 'persistent use did not preserve its committed cleanup journal' || return 1
  lock_is_available || diagnose 'persistent-use cleanup failure kept the operation lock held' || return 1
  rmdir "$gh_account_state_dir/restore.pending" || return 1
  run_cli preflight bob "$case_repo" --json
  assert_status 0 || { sed 's/^/committed recovery stderr: /' "$cli_stderr" >&2; return 1; }
  [ ! -e "$gh_account_transaction_journal" ] || \
    diagnose 'next lock owner did not finish committed metadata cleanup'
}

test_use_commit_journal_failure_rolls_back_before_unlock() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  : >"$fake_state/fail_binding_commit_journal"
  : >"$fake_state/require_lock_for_binding_rollback"
  run_cli use bob "$case_repo"
  assert_nonzero_status || return 1
  [ -e "$fake_state/binding_commit_journal_failed" ] || \
    diagnose 'persistent-use commit-journal failure was not injected' || return 1
  [ ! -e "$fake_state/binding_rollback_ran_unlocked" ] || \
    diagnose 'persistent-use rollback ran after releasing the operation lock' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'failed persistent-use commit did not restore the prior account' || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = alice ] || \
    diagnose 'failed persistent-use commit did not restore the prior binding' || return 1
  [ ! -e "$gh_account_transaction_journal" ] || \
    diagnose 'failed persistent-use commit left a completed journal' || return 1
  lock_is_available || diagnose 'failed persistent-use commit left the operation lock held'
}

test_bind_and_use_finalize_install_failure_before_unlock() {
  for failing_command in bind use; do
    setup_case
    make_repo example-org
    "$host_git" -C "$case_repo" config --local github.account alice
    "$host_git" -C "$case_repo" config --local credential.username alice
    "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
    "$host_git" -C "$case_repo" config --local user.email \
      '1001+alice@users.noreply.github.com'
    : >"$fake_state/fail_binding_install"
    : >"$fake_state/require_lock_for_binding_rollback"
    run_cli "$failing_command" bob "$case_repo"
    assert_nonzero_status || return 1
    [ -e "$fake_state/binding_install_failed" ] || \
      diagnose "$failing_command binding-install failure was not injected" || return 1
    [ ! -e "$fake_state/binding_rollback_ran_unlocked" ] || \
      diagnose "$failing_command rollback ran after operation-lock release" || return 1
    [ "$(cat "$fake_state/active")" = alice ] || \
      diagnose "$failing_command failure did not restore the prior account" || return 1
    [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = alice ] || \
      diagnose "$failing_command failure did not preserve the prior binding" || return 1
    [ ! -e "$gh_account_transaction_journal" ] || \
      diagnose "$failing_command failure left a completed journal" || return 1
    lock_is_available || diagnose "$failing_command failure left the operation lock held" || return 1
  done
}

test_bind_preserves_wal_when_locked_rollback_fails() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  : >"$fake_state/fail_binding_install"
  : >"$fake_state/fail_binding_rollback"
  : >"$fake_state/require_lock_for_binding_rollback"
  run_cli bind bob "$case_repo"
  assert_status 75 || return 1
  [ -e "$fake_state/binding_rollback_failed" ] || \
    diagnose 'binding rollback failure was not injected' || return 1
  [ ! -e "$fake_state/binding_rollback_ran_unlocked" ] || \
    diagnose 'failed binding rollback was retried after operation-lock release' || return 1
  [ -f "$gh_account_transaction_journal" ] && [ ! -L "$gh_account_transaction_journal" ] || \
    diagnose 'failed locked rollback did not preserve its recovery journal' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'failed locked rollback did not restore the prior account' || return 1
  rm -f "$fake_state/fail_binding_install" "$fake_state/fail_binding_rollback"
  run_cli preflight alice "$case_repo" --json
  assert_status 0 || { sed 's/^/rollback recovery stderr: /' "$cli_stderr" >&2; return 1; }
  [ ! -e "$gh_account_transaction_journal" ] || \
    diagnose 'next lock owner did not complete binding recovery' || return 1
  lock_is_available || diagnose 'recovered binding transaction left the lock held'
}

test_use_signal_rolls_back_account_and_binding_together() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  : >"$fake_state/signal_after_binding_install"
  run_cli use bob "$case_repo"
  assert_status 2 || { sed 's/^/use signal stderr: /' "$cli_stderr" >&2; return 1; }
  [ -e "$fake_state/binding_install_ready" ] || \
    diagnose 'persistent-use signal barrier was not reached' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'interrupted persistent use left the new account active' || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = alice ] || \
    diagnose 'interrupted persistent use left the new binding committed' || return 1
  [ ! -e "$gh_account_transaction_journal" ] || \
    diagnose 'interrupted persistent use left a completed journal' || return 1
  lock_is_available || diagnose 'interrupted persistent use left the operation lock held'
}

test_auto_revalidates_binding_under_operation_lock() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  : >"$fake_state/pause_bound_read"
  : >"$cli_stdout"
  : >"$cli_stderr"
  "$case_gh_account_bin" auto "$case_repo" >"$cli_stdout" 2>"$cli_stderr" &
  auto_pid=$!
  auto_wait=0
  while [ ! -e "$fake_state/bound_read_ready" ]; do
    auto_wait=$((auto_wait + 1))
    if [ "$auto_wait" -ge 1000 ]; then
      kill "$auto_pid" 2>/dev/null || true
      wait "$auto_pid" 2>/dev/null || true
      diagnose 'auto did not reach the stale-binding barrier'
      return 1
    fi
    sleep 0.01
  done
  bind_repo_to_bob
  : >"$fake_state/release_bound_read"
  wait "$auto_pid"
  cli_status=$?
  assert_status 75 || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = bob ] || \
    diagnose 'auto overwrote a newer serialized repository binding' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'auto left a stale inferred account active'
}

test_preflight_reports_live_lock_contention() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  start_lock_holder || return 1
  run_cli preflight bob "$case_repo" --json
  kill "$lock_holder_pid" 2>/dev/null || true
  wait "$lock_holder_pid" 2>/dev/null || true
  assert_status 75 || return 1
  assert_stdout_json || return 1
  assert_finding LOCK.BUSY
}

test_preflight_reclaims_stale_lock_owner() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  mkdir "$gh_account_lock_dir"
  printf '999999\n' >"$gh_account_lock_dir/owner.pid"
  printf 'test-stale-owner\n' >"$gh_account_lock_dir/owner.nonce"
  printf 'Mon Jan  1 00:00:00 2001\n' >"$gh_account_lock_dir/owner.birth"
  run_cli preflight bob "$case_repo" --json
  assert_status 0 || return 1
  lock_is_available || diagnose 'advisory lock was not released after preflight'
}

test_exec_signal_restores_identity_and_releases_lock() {
  setup_case
  "$case_gh_account_bin" exec bob -- pr test-block >"$cli_stdout" 2>"$cli_stderr" &
  router_pid=$!
  ready_attempts=0
  while [ ! -e "$fake_state/child.ready" ] && [ "$ready_attempts" -lt 500 ]; do
    sleep 0.02
    ready_attempts=$((ready_attempts + 1))
  done
  [ -e "$fake_state/child.ready" ] || {
    kill "$router_pid" 2>/dev/null || true
    diagnose 'fake child did not reach blocking state'
    return 1
  }
  child_pid=$(cat "$fake_state/child.pid")
  kill -TERM "$router_pid" 2>/dev/null || true
  wait "$router_pid"
  cli_status=$?
  assert_status 2 || return 1
  if process_is_live "$child_pid"; then
    kill -TERM "$child_pid" 2>/dev/null || true
    diagnose 'router signal did not terminate its gh child'
    return 1
  fi
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'signal path did not restore alice'
  lock_is_available || diagnose 'signal path left the advisory lock held'
}

test_cooperative_signal_cancels_escalation_promptly() {
  setup_case
  sed 's/^signal_grace=1$/signal_grace=3/' "$case_gh_account_bin" \
    >"$case_gh_account_bin.prompt"
  mv "$case_gh_account_bin.prompt" "$case_gh_account_bin"
  chmod 755 "$case_gh_account_bin"
  "$case_gh_account_bin" exec bob -- pr test-block >"$cli_stdout" 2>"$cli_stderr" &
  router_pid=$!
  if ! wait_for_file "$fake_state/child.ready"; then
    kill -KILL "$router_pid" 2>/dev/null || true
    wait "$router_pid" 2>/dev/null || true
    diagnose 'cooperative fake child did not reach its blocking state'
    return 1
  fi
  signal_started=$(date +%s)
  kill -TERM "$router_pid" 2>/dev/null || true
  wait "$router_pid"
  cli_status=$?
  signal_finished=$(date +%s)
  assert_status 2 || return 1
  signal_elapsed=$((signal_finished - signal_started))
  [ "$signal_elapsed" -lt 2 ] || \
    diagnose "cooperative signal waited ${signal_elapsed}s for the escalation timer" || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'cooperative signal path did not restore alice' || return 1
  lock_is_available || diagnose 'cooperative signal path left the operation lock held'
}

test_repeated_signal_preserves_cleanup() {
  setup_case
  : >"$fake_state/child.signal_delay"
  router_out=$case_root/router.out
  router_err=$case_root/router.err
  "$case_gh_account_bin" exec bob -- pr test-block >"$router_out" 2>"$router_err" &
  router_pid=$!
  ready_attempts=0
  while [ ! -e "$fake_state/child.ready" ] && [ "$ready_attempts" -lt 500 ]; do
    sleep 0.02
    ready_attempts=$((ready_attempts + 1))
  done
  [ -e "$fake_state/child.ready" ] || {
    kill "$router_pid" 2>/dev/null || true
    diagnose 'fake child did not reach blocking state for repeated-signal test'
    return 1
  }
  kill -TERM "$router_pid" 2>/dev/null || true
  signal_attempts=0
  while [ ! -e "$fake_state/child.signal_received" ] && [ "$signal_attempts" -lt 100 ]; do
    sleep 0.02
    signal_attempts=$((signal_attempts + 1))
  done
  [ -e "$fake_state/child.signal_received" ] || {
    kill -KILL "$router_pid" 2>/dev/null || true
    wait "$router_pid" 2>/dev/null || true
    diagnose 'fake child did not enter delayed signal cleanup'
    return 1
  }
  kill -TERM "$router_pid" 2>/dev/null || true
  wait "$router_pid"
  repeated_signal_status=$?
  [ "$repeated_signal_status" -eq 2 ] || \
    diagnose "repeated signal bypassed cleanup with exit $repeated_signal_status" || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'repeated signal path did not restore alice' || return 1
  lock_is_available || diagnose 'repeated signal path left the advisory lock held'
}

test_signal_escalates_for_resistant_child() {
  setup_case
  : >"$fake_state/child.signal_ignore"
  "$case_gh_account_bin" exec bob -- pr test-block >"$cli_stdout" 2>"$cli_stderr" &
  router_pid=$!
  ready_attempts=0
  while [ ! -e "$fake_state/child.ready" ] && [ "$ready_attempts" -lt 500 ]; do
    sleep 0.02
    ready_attempts=$((ready_attempts + 1))
  done
  [ -e "$fake_state/child.ready" ] || {
    kill -KILL "$router_pid" 2>/dev/null || true
    wait "$router_pid" 2>/dev/null || true
    diagnose 'resistant fake child did not reach its blocking state'
    return 1
  }
  child_pid=$(cat "$fake_state/child.pid")
  kill -TERM "$router_pid" 2>/dev/null || true
  wait "$router_pid"
  cli_status=$?
  assert_status 2 || return 1
  if process_is_live "$child_pid"; then
    kill -KILL "$child_pid" 2>/dev/null || true
    diagnose 'signal watchdog did not terminate the resistant child'
    return 1
  fi
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'resistant-child signal path did not restore alice' || return 1
  lock_is_available || diagnose 'resistant-child signal path left the operation lock held'
}

test_signal_terminates_resistant_descendants_before_restore() {
  setup_case
  : >"$fake_state/child.spawn_resistant_descendant"
  "$case_gh_account_bin" exec bob -- pr test-block >"$cli_stdout" 2>"$cli_stderr" &
  router_pid=$!
  if ! wait_for_file "$fake_state/child.ready" || \
     ! wait_for_file "$fake_state/child.descendant.ready"; then
    kill -KILL "$router_pid" 2>/dev/null || true
    wait "$router_pid" 2>/dev/null || true
    diagnose 'resistant descendant did not reach its blocking state'
    return 1
  fi
  descendant_pid=$(cat "$fake_state/child.descendant.pid")
  kill -TERM "$router_pid" 2>/dev/null || true
  wait "$router_pid"
  cli_status=$?
  assert_status 2 || return 1
  if process_is_live "$descendant_pid"; then
    kill -KILL "$descendant_pid" 2>/dev/null || true
    diagnose 'router restored the account while a resistant descendant remained alive'
    return 1
  fi
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'descendant signal path did not restore alice' || return 1
  lock_is_available || diagnose 'descendant signal path left the operation lock held'
}

test_group_enumeration_failure_terminates_descendants() {
  setup_case
  rm -f "$case_bin/ps"
  cp "$fake_ps_source" "$case_bin/ps"
  chmod 755 "$case_bin/ps"
  run_cli exec bob -- pr test-descendant-exit
  assert_nonzero_status || return 1
  [ -e "$fake_state/group_enumeration_failed" ] || \
    diagnose 'process-group enumeration failure was not injected' || return 1
  descendant_pid=$(cat "$fake_state/child.descendant.pid")
  descendant_wait=0
  while process_is_live "$descendant_pid" && [ "$descendant_wait" -lt 100 ]; do
    sleep 0.01
    descendant_wait=$((descendant_wait + 1))
  done
  if process_is_live "$descendant_pid"; then
    kill -KILL "$descendant_pid" 2>/dev/null || true
    diagnose 'enumeration failure released routing with a descendant alive'
    return 1
  fi
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'enumeration-failure path did not restore alice' || return 1
  lock_is_available || diagnose 'enumeration-failure path left the operation lock held'
}

test_command_only_lockf_tracks_live_mutation_children() {
  [ -n "$host_lockf" ] || return 0
  setup_case
  rm -f "$case_bin/lockf"
  cp "$fake_lockf_source" "$case_bin/lockf"
  chmod 755 "$case_bin/lockf"
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  : >"$fake_state/block_before_binding_install"
  "$case_gh_account_bin" use bob "$case_repo" >"$cli_stdout" 2>"$cli_stderr" &
  router_pid=$!
  if ! wait_for_file "$fake_state/binding_move.ready"; then
    kill -KILL "$router_pid" 2>/dev/null || true
    wait "$router_pid" 2>/dev/null || true
    diagnose 'command-only lockf route did not reach the live mutation barrier'
    return 1
  fi
  mutation_pid=$(cat "$fake_state/binding_move.pid")
  kill -KILL "$router_pid" 2>/dev/null || true
  wait "$router_pid" 2>/dev/null || true
  run_cli preflight bob "$case_repo" --json
  assert_status 75 || {
    : >"$fake_state/release_binding_move"
    kill -KILL "$mutation_pid" 2>/dev/null || true
    return 1
  }
  assert_finding LOCK.BUSY || return 1
  : >"$fake_state/release_binding_move"
  mutation_wait=0
  while kill -0 "$mutation_pid" 2>/dev/null && [ "$mutation_wait" -lt 1000 ]; do
    sleep 0.01
    mutation_wait=$((mutation_wait + 1))
  done
  if kill -0 "$mutation_pid" 2>/dev/null; then
    kill -KILL "$mutation_pid" 2>/dev/null || true
    diagnose 'tracked config mutation child did not complete after release'
    return 1
  fi
  run_cli preflight alice "$case_repo" --json
  assert_status 0 || { sed 's/^/command-only recovery stderr: /' "$cli_stderr" >&2; return 1; }
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'command-only recovery did not restore the prior account' || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = alice ] || \
    diagnose 'late mutation escaped command-only transaction recovery' || return 1
  [ ! -e "$gh_account_transaction_journal" ] || \
    diagnose 'command-only recovery left a completed journal' || return 1
  lock_is_available || diagnose 'command-only recovery left the operation lease present'
}

test_read_commands_refuse_transient_account_snapshots() {
  setup_case
  router_out=$case_root/router.out
  router_err=$case_root/router.err
  "$case_gh_account_bin" exec bob -- pr test-block >"$router_out" 2>"$router_err" &
  router_pid=$!
  ready_attempts=0
  while [ ! -e "$fake_state/child.ready" ] && [ "$ready_attempts" -lt 500 ]; do
    sleep 0.02
    ready_attempts=$((ready_attempts + 1))
  done
  [ -e "$fake_state/child.ready" ] || {
    kill "$router_pid" 2>/dev/null || true
    diagnose 'fake child did not reach blocking state for snapshot test'
    return 1
  }
  api_calls_before=$(grep -c '^api user$' "$fake_state/calls.log" 2>/dev/null || true)
  run_cli current
  assert_status 75 || return 1
  assert_output_not_contains 'gh-active: bob' || return 1
  run_cli doctor --json
  assert_status 75 || return 1
  assert_finding LOCK.BUSY || return 1
  api_calls_after=$(grep -c '^api user$' "$fake_state/calls.log" 2>/dev/null || true)
  [ "$api_calls_after" -eq "$api_calls_before" ] || \
    diagnose 'doctor queried the API while another account switch was transiently active'
  kill -TERM "$router_pid" 2>/dev/null || true
  wait "$router_pid" 2>/dev/null || true
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'snapshot contention test did not restore alice'
  lock_is_available || diagnose 'snapshot contention test left the operation lock held'
}

test_reauth_refreshes_and_verifies_native_identity() {
  setup_case
  printf 'error\n' >"$fake_state/account.bob.state"
  run_cli reauth bob --json
  assert_status 0 || return 1
  assert_stdout_json || return 1
  assert_json '.status == "healthy" and .account == "bob" and
    .mutation_performed == true' || return 1
  assert_file_contains "$fake_state/calls.log" 'auth refresh bob' || return 1
  assert_file_contains "$fake_state/calls.log" 'api user' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'reauth did not restore alice'
  assert_file_contains "$GH_ACCOUNT_AUDIT_FILE" 'auth.reauth.completed'
}

test_reauth_preserves_native_cancellation() {
  setup_case
  printf 'error\n' >"$fake_state/account.bob.state"
  printf '2\n' >"$fake_state/refresh_exit"
  run_cli reauth bob --json
  assert_status 2 || return 1
  assert_stdout_json || return 1
  assert_finding AUTH.REPAIR_CANCELLED || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'cancelled reauth did not restore alice'
  assert_file_contains "$GH_ACCOUNT_AUDIT_FILE" 'auth.reauth.cancelled'
}

test_reauth_rejects_wrong_resolved_identity() {
  setup_case
  printf 'error\n' >"$fake_state/account.bob.state"
  printf 'mallory\n' >"$fake_state/api_login_override"
  printf '9999\n' >"$fake_state/account.mallory.id"
  run_cli reauth bob --json
  assert_nonzero_status || return 1
  assert_stdout_json || return 1
  assert_finding ACCOUNT.IDENTITY_MISMATCH || return 1
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'failed reauth did not restore alice'
}

test_onboard_first_account_needs_no_restoration() {
  setup_case
  : >"$fake_state/accounts"
  : >"$fake_state/active"
  printf 'bob\n' >"$fake_state/login_account"
  run_cli onboard bob
  assert_status 0 || return 1
  assert_file_contains "$fake_state/calls.log" 'auth login bob' || return 1
  [ "$(cat "$fake_state/active")" = bob ] || \
    diagnose 'first-account onboarding did not leave the new account active'
  [ ! -e "$gh_account_state_dir/restore.pending" ] || \
    diagnose 'first-account onboarding created an impossible restoration obligation'
}

test_repair_dry_run_never_mutates() {
  setup_case
  make_repo example-org
  printf 'error\n' >"$fake_state/account.bob.state"
  run_cli repair bob "$case_repo" --interactive --dry-run
  assert_status 0 || return 1
  assert_file_contains "$cli_stdout" 'would-run-interactively: gh auth refresh' || return 1
  assert_file_contains "$cli_stdout" 'would-run: gh auth setup-git' || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth refresh' || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth setup-git' || return 1
  [ -z "$("$host_git" -C "$case_repo" config --local --get github.account 2>/dev/null || true)" ] || \
    diagnose 'dry-run unexpectedly bound the repository'
}

test_repair_applies_native_config_and_repository_identity() {
  setup_case
  make_repo example-org
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" --unset-all \
    credential.https://github.com.useHttpPath
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" --unset-all user.useConfigOnly
  run_cli repair bob "$case_repo"
  assert_status 0 || { sed 's/^/repair stderr: /' "$cli_stderr" >&2; return 1; }
  [ "$("$host_git" config --file "$GIT_CONFIG_GLOBAL" --get credential.https://github.com.useHttpPath)" = true ] || \
    diagnose 'repair did not enable credential useHttpPath'
  [ "$("$host_git" config --file "$GIT_CONFIG_GLOBAL" --get user.useConfigOnly)" = true ] || \
    diagnose 'repair did not enable user.useConfigOnly'
  assert_file_contains "$fake_state/calls.log" 'auth setup-git' || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = bob ] || \
    diagnose 'repair did not write the repository account marker'
  [ "$("$host_git" -C "$case_repo" config --local --get credential.username)" = bob ] || \
    diagnose 'repair did not write the credential username'
  [ "$("$host_git" -C "$case_repo" config --local --get user.email)" = \
      '1002+bob@users.noreply.github.com' ] || diagnose 'repair wrote the wrong commit email'
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'repair did not restore alice'
}

test_repair_corrects_existing_repository_identity() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  run_cli repair bob "$case_repo"
  assert_status 0 || { sed 's/^/repair existing stderr: /' "$cli_stderr" >&2; return 1; }
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = bob ] || \
    diagnose 'repair did not replace the existing repository account'
  run_cli preflight bob "$case_repo" --json
  assert_status 0 || diagnose 'corrected repository did not pass the next preflight'
}

test_repair_refuses_local_helper_reset_and_unsafe_remote() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local --add \
    credential.https://github.com.helper ''
  run_cli repair bob "$case_repo"
  assert_status 78 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth setup-git' || return 1
  "$host_git" -C "$case_repo" config --local --unset-all \
    credential.https://github.com.helper
  remote_canary='REPAIR_REMOTE_TOKEN_CANARY_c031'
  "$host_git" -C "$case_repo" remote set-url origin \
    "https://user:$remote_canary@github.com/example-org/example.git"
  run_cli repair bob "$case_repo"
  assert_status 77 || return 1
  assert_output_not_contains "$remote_canary" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$remote_canary" || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth setup-git' || return 1

  "$host_git" -C "$case_repo" remote set-url origin \
    'https://github.com/example-org/example.git'
  "$host_git" -C "$case_repo" config --local \
    http.https://github.com.proxy http://proxy.invalid
  run_cli repair bob "$case_repo"
  assert_status 78 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth setup-git' || return 1
  "$host_git" -C "$case_repo" config --local --unset-all \
    http.https://github.com.proxy
  "$host_git" -C "$case_repo" config --local \
    credential.https://github.com/example-org.useHttpPath false
  run_cli repair bob "$case_repo"
  assert_status 78 || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth setup-git'
}

test_repair_interactive_refreshes_then_repairs() {
  setup_case
  make_repo example-org
  printf 'error\n' >"$fake_state/account.bob.state"
  run_cli repair bob "$case_repo" --interactive
  assert_status 0 || { sed 's/^/repair stderr: /' "$cli_stderr" >&2; return 1; }
  assert_file_contains "$fake_state/calls.log" 'auth refresh bob' || return 1
  assert_file_contains "$fake_state/calls.log" 'auth setup-git' || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = bob ] || \
    diagnose 'interactive repair did not bind bob'
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'interactive repair did not restore alice'
}

test_repair_rolls_back_partial_global_config_failure() {
  setup_case
  make_repo example-org
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" --unset-all \
    credential.https://github.com.helper
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" --add \
    credential.https://github.com.helper '!original-helper'
  : >"$fake_state/setup_git_partial_failure"
  run_cli repair bob "$case_repo"
  assert_status 1 || { sed 's/^/repair stderr: /' "$cli_stderr" >&2; return 1; }
  [ "$("$host_git" config --file "$GIT_CONFIG_GLOBAL" --get-all credential.https://github.com.helper)" = \
      '!original-helper' ] || diagnose 'repair did not restore the prior credential helper'
  [ -z "$("$host_git" -C "$case_repo" config --local --get github.account 2>/dev/null || true)" ] || \
    diagnose 'failed repair unexpectedly bound the repository'
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'failed repair did not restore alice'
}

test_repair_preserves_unrelated_edit_between_stage_and_install() {
  setup_case
  make_repo example-org
  : >"$fake_state/setup_git_edit_live_config"
  run_cli repair bob "$case_repo"
  assert_nonzero_status || return 1
  [ "$("$host_git" config --file "$case_git_config" --get external.concurrent 2>/dev/null || true)" = true ] || \
    diagnose 'repair rollback overwrote an unrelated concurrent Git config edit'
  [ -e "$gh_account_transaction_journal" ] || \
    diagnose 'repair cleared recovery metadata after detecting an unrelated edit'
}

test_repair_signal_rolls_back_durable_transaction() {
  setup_case
  make_repo example-org
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" --unset-all \
    credential.https://github.com.helper
  "$host_git" config --file "$GIT_CONFIG_GLOBAL" --add \
    credential.https://github.com.helper '!original-helper'
  : >"$fake_state/setup_git_signal_parent"
  run_cli repair bob "$case_repo"
  assert_status 2 || { sed 's/^/repair signal stderr: /' "$cli_stderr" >&2; return 1; }
  [ "$("$host_git" config --file "$GIT_CONFIG_GLOBAL" --get-all credential.https://github.com.helper)" = \
      '!original-helper' ] || diagnose 'signal cleanup did not restore the prior credential helper'
  [ -z "$("$host_git" -C "$case_repo" config --local --get github.account 2>/dev/null || true)" ] || \
    diagnose 'signal cleanup unexpectedly committed repository binding'
  [ ! -e "$gh_account_transaction_journal" ] || \
    diagnose 'signal cleanup left a completed recovery journal'
  [ "$(cat "$fake_state/active")" = alice ] || diagnose 'signal cleanup did not restore alice'
  lock_is_available || diagnose 'signal cleanup left the advisory lock held'
}

test_preflight_recovers_interrupted_binding_transaction() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  common_raw=$("$host_git" -C "$case_repo" rev-parse --git-common-dir)
  case "$common_raw" in
    /*) common_dir=$common_raw ;;
    *) common_dir=$(cd "$case_repo/$common_raw" && pwd -P) ;;
  esac
  recovery_root=$(mktemp -d /tmp/gh-account.XXXXXX)
  recovery_snapshot=$recovery_root/item.snapshot
  cp "$common_dir/config" "$recovery_snapshot"
  chmod 600 "$recovery_snapshot"
  "$host_git" -C "$case_repo" config --local github.account bob
  recovery_expected=$recovery_root/item.expected
  cp "$common_dir/config" "$recovery_expected"
  chmod 600 "$recovery_expected"
  mkdir -p "$gh_account_state_dir"
  chmod 700 "$gh_account_state_dir"
  "$host_jq" -n \
    --arg path "$common_dir/config" --arg root "$common_dir" \
    --arg snapshot "$recovery_snapshot" --arg expected "$recovery_expected" '{
      schema:"gh-account.config-transaction.v1",
      mode:"binding",
      binding:{
        path:$path,root:$root,state:"present",snapshot:$snapshot,
        expected_state:"present",expected_snapshot:$expected
      },
      global:{
        home:{path:"",state:"",snapshot:"",expected_state:"",expected_snapshot:""},
        xdg:{path:"",state:"",snapshot:"",expected_state:"",expected_snapshot:""}
      }
    }' >"$gh_account_transaction_journal"
  chmod 600 "$gh_account_transaction_journal"
  run_cli preflight alice "$case_repo" --json
  assert_status 0 || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = alice ] || \
    diagnose 'preflight did not recover the interrupted repository binding'
  [ ! -e "$gh_account_transaction_journal" ] || \
    diagnose 'recovered transaction journal was not cleared'
}

test_recovery_refuses_to_overwrite_unrelated_config_edits() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  common_raw=$("$host_git" -C "$case_repo" rev-parse --git-common-dir)
  case "$common_raw" in
    /*) common_dir=$common_raw ;;
    *) common_dir=$(cd "$case_repo/$common_raw" && pwd -P) ;;
  esac
  recovery_root=$(mktemp -d /tmp/gh-account.XXXXXX)
  recovery_snapshot=$recovery_root/item.snapshot
  recovery_expected=$recovery_root/item.expected
  cp "$common_dir/config" "$recovery_snapshot"
  "$host_git" -C "$case_repo" config --local github.account bob
  cp "$common_dir/config" "$recovery_expected"
  chmod 600 "$recovery_snapshot" "$recovery_expected"
  "$host_git" -C "$case_repo" config --local user.name 'Unrelated Operator Edit'
  "$host_jq" -n \
    --arg path "$common_dir/config" --arg root "$common_dir" \
    --arg snapshot "$recovery_snapshot" --arg expected "$recovery_expected" '{
      schema:"gh-account.config-transaction.v1",
      mode:"binding",
      binding:{
        path:$path,root:$root,state:"present",snapshot:$snapshot,
        expected_state:"present",expected_snapshot:$expected
      },
      global:{
        home:{path:"",state:"",snapshot:"",expected_state:"",expected_snapshot:""},
        xdg:{path:"",state:"",snapshot:"",expected_state:"",expected_snapshot:""}
      }
    }' >"$gh_account_transaction_journal"
  chmod 600 "$gh_account_transaction_journal"
  run_cli preflight alice "$case_repo" --json
  assert_status 75 || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get user.name)" = 'Unrelated Operator Edit' ] || \
    diagnose 'recovery overwrote a config edit that was not in its expected snapshot'
  [ -e "$gh_account_transaction_journal" ] || \
    diagnose 'unsafe recovery unexpectedly cleared its journal'
  run_cli onboard charlie
  assert_status 75 || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get user.name)" = 'Unrelated Operator Edit' ] || \
    diagnose 'onboard recovery overwrote a config edit it had refused' || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth login charlie' || return 1
  rm -f "$gh_account_transaction_journal" "$recovery_snapshot" "$recovery_expected"
  rmdir "$recovery_root"
}

test_doctor_reports_malformed_config_recovery_journal() {
  setup_case
  mkdir -p "$gh_account_state_dir"
  chmod 700 "$gh_account_state_dir"
  printf '{malformed\n' >"$gh_account_transaction_journal"
  chmod 600 "$gh_account_transaction_journal"
  run_cli doctor --json
  assert_status 75 || return 1
  assert_finding CONFIG.RECOVERY_PENDING
}

test_audit_events_never_disclose_token_canary() {
  setup_case
  GH_TOKEN='AUDIT_TOKEN_CANARY_4e9981'
  export GH_TOKEN
  run_cli doctor --json
  assert_nonzero_status || return 1
  assert_file_contains "$GH_ACCOUNT_AUDIT_FILE" 'doctor.completed' || {
    sed 's/^/audit stderr: /' "$cli_stderr" >&2
    return 1
  }
  assert_output_not_contains "$GH_TOKEN" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" "$GH_TOKEN" || return 1
  assert_file_not_contains "$GH_ACCOUNT_AUDIT_FILE" \
    "$(cat "$fake_state/token_canary")"
}

test_audit_spool_serializes_concurrent_writers() {
  setup_case
  audit_pids=
  audit_index=1
  while [ "$audit_index" -le 8 ]; do
    "$case_gh_account_bin" doctor --json >"$case_root/audit.$audit_index.out" \
      2>"$case_root/audit.$audit_index.err" &
    audit_pids="$audit_pids $!"
    audit_index=$((audit_index + 1))
  done
  for audit_pid in $audit_pids; do
    wait "$audit_pid" || true
  done
  [ -f "$GH_ACCOUNT_AUDIT_FILE" ] || diagnose 'concurrent audit spool was not created'
  audit_lines=$(wc -l <"$GH_ACCOUNT_AUDIT_FILE" | tr -d '[:space:]')
  [ "$audit_lines" -eq 8 ] || diagnose "expected 8 serialized events, found $audit_lines"
  "$host_jq" -s -e 'length == 8 and all(.[]; .schema == "gh-account.audit.v1")' \
    "$GH_ACCOUNT_AUDIT_FILE" >/dev/null 2>&1 || diagnose 'concurrent audit spool contains malformed JSONL'
}

test_audit_spool_rotates_without_silent_truncation() {
  setup_case
  audit_dir=${GH_ACCOUNT_AUDIT_FILE%/*}
  mkdir -p "$audit_dir"
  chmod 700 "$HOME/.local" "$HOME/.local/state" "$audit_dir"
  /usr/bin/awk 'BEGIN { for (i = 0; i < 5300; i++) printf "%01023d\n", i }' \
    >"$GH_ACCOUNT_AUDIT_FILE"
  chmod 600 "$GH_ACCOUNT_AUDIT_FILE"
  original_size=$(wc -c <"$GH_ACCOUNT_AUDIT_FILE" | tr -d '[:space:]')
  [ "$original_size" -gt 5242880 ] || diagnose 'rotation fixture did not exceed 5 MiB'
  run_cli doctor --json
  [ -f "$GH_ACCOUNT_AUDIT_FILE.1" ] || diagnose 'audit spool was not rotated'
  rotated_size=$(wc -c <"$GH_ACCOUNT_AUDIT_FILE.1" | tr -d '[:space:]')
  [ "$rotated_size" -eq "$original_size" ] || diagnose 'audit rotation truncated historical evidence'
  "$host_jq" -e '.schema == "gh-account.audit.v1"' "$GH_ACCOUNT_AUDIT_FILE" \
    >/dev/null 2>&1 || diagnose 'new active audit spool does not contain the emitted event'
}

test_audit_spool_refuses_symlink_and_hardlink_targets() {
  setup_case
  run_cli doctor --json
  audit_dir=${GH_ACCOUNT_AUDIT_FILE%/*}
  outside_target=$case_root/outside-audit-target
  printf 'outside-canary\n' >"$outside_target"
  rm -f "$GH_ACCOUNT_AUDIT_FILE"
  ln -s "$outside_target" "$GH_ACCOUNT_AUDIT_FILE"
  run_cli doctor --json
  [ "$(cat "$outside_target")" = outside-canary ] || \
    diagnose 'audit symlink redirected an event write'
  assert_file_contains "$cli_stderr" 'audit event could not be recorded safely' || return 1
  rm -f "$GH_ACCOUNT_AUDIT_FILE"
  printf 'hardlink-canary\n' >"$GH_ACCOUNT_AUDIT_FILE"
  hardlink_peer=$case_root/audit-hardlink-peer
  ln "$GH_ACCOUNT_AUDIT_FILE" "$hardlink_peer"
  run_cli doctor --json
  [ "$(cat "$hardlink_peer")" = hardlink-canary ] || \
    diagnose 'audit hardlink target was modified'
  [ -d "$audit_dir" ] || diagnose 'audit directory was unexpectedly replaced'
}

test_interactive_native_auth_preserves_real_pty_and_stdin() {
  if [ -z "$host_expect" ] && \
     { [ "$(uname -s)" != Linux ] || [ -z "$host_script" ]; }; then
    diagnose 'real-PTY regression requires stock expect or util-linux script'
    return 1
  fi

  for pty_action in refresh login; do
    setup_case
    case "$pty_action" in
      refresh)
        printf 'error\n' >"$fake_state/account.bob.state"
        : >"$fake_state/refresh_require_pty_stdin"
        pty_input=PTY_STDIN_CANARY_4f6b
        pty_marker=$fake_state/refresh_pty_stdin_ok
        pty_args='reauth bob --json'
        ;;
      login)
        : >"$fake_state/accounts"
        : >"$fake_state/active"
        printf 'bob\n' >"$fake_state/login_account"
        : >"$fake_state/login_require_pty_stdin"
        pty_input=PTY_LOGIN_CANARY_7a2d
        pty_marker=$fake_state/login_pty_stdin_ok
        pty_args='onboard bob'
        ;;
    esac
    if [ -n "$host_expect" ]; then
      PTY_ROUTER=$case_gh_account_bin PTY_ACTION=$pty_action PTY_INPUT=$pty_input \
        "$host_expect" -c '
          log_user 1
          set timeout 6
          proc terminate_spawned_router {} {
            global env spawn_id
            set router_pid ""
            catch {set router_pid [exp_pid -i $spawn_id]}
            set supervisor_pid ""
            set owner_path "$env(XDG_RUNTIME_DIR)/operation.lock/child.owner"
            if {[file readable $owner_path]} {
              set owner_file [open $owner_path r]
              set owner_data [read $owner_file]
              close $owner_file
              set supervisor_pid [lindex [split $owner_data "\n"] 0]
            }
            if {[regexp {^[0-9]+$} $supervisor_pid]} {
              catch {exec /bin/kill -TERM -- -$supervisor_pid}
            }
            if {[regexp {^[0-9]+$} $router_pid]} {
              catch {exec /bin/kill -TERM $router_pid}
            }
            after 1500
            if {[regexp {^[0-9]+$} $supervisor_pid]} {
              catch {exec /bin/kill -KILL -- -$supervisor_pid}
            }
            if {[regexp {^[0-9]+$} $router_pid]} {
              catch {exec /bin/kill -KILL $router_pid}
            }
            catch {close -i $spawn_id}
            catch {wait -i $spawn_id}
          }
          if {$env(PTY_ACTION) eq "refresh"} {
            spawn -noecho $env(PTY_ROUTER) reauth bob --json
          } else {
            spawn -noecho $env(PTY_ROUTER) onboard bob
          }
          expect {
            "native-auth-input-ready" {}
            timeout { terminate_spawned_router; exit 90 }
            eof { terminate_spawned_router; exit 91 }
          }
          send -- "$env(PTY_INPUT)\r"
          expect {
            "pty-round-trip:$env(PTY_INPUT)" {}
            timeout { terminate_spawned_router; exit 92 }
            eof { terminate_spawned_router; exit 93 }
          }
          expect {
            eof {}
            timeout { terminate_spawned_router; exit 94 }
          }
          set child_result [wait]
          exit [lindex $child_result 3]
        ' >"$cli_stdout" 2>"$cli_stderr"
      pty_status=$?
    else
      # util-linux script forwards piped input to its PTY slave; BSD script
      # does not, which is why Darwin uses the stock Expect driver above.
      printf '%s\n' "$pty_input" | \
        "$host_script" -q -e -c "$case_gh_account_bin $pty_args" /dev/null \
        >"$cli_stdout" 2>"$cli_stderr"
      pty_status=$?
    fi
    [ "$pty_status" -eq 0 ] || \
      diagnose "$pty_action native auth exited $pty_status under a real PTY" || return 1
    [ -e "$pty_marker" ] || \
      diagnose "$pty_action native auth did not receive its PTY stdin round-trip" || return 1
    assert_file_contains "$cli_stdout" "pty-round-trip:$pty_input" || return 1
    assert_file_not_contains "$cli_stdout" 'gh-account-supervisor' || return 1
    assert_file_not_contains "$cli_stderr" 'gh-account-supervisor' || return 1
    lock_is_available || diagnose "$pty_action native auth left the operation lock held" || return 1
  done
}

test_interactive_ctrl_c_terminates_before_native_auth_mutation() {
  # Darwin ships Expect and is the primary regression host for the native
  # Keychain flow. The existing round-trip test retains a util-linux fallback.
  [ -n "$host_expect" ] || return 0
  setup_case
  printf 'error\n' >"$fake_state/account.bob.state"
  : >"$fake_state/refresh_ctrl_c_mutation_window"
  : >"$fake_state/record_restore_lock_order"
  PTY_ROUTER=$case_gh_account_bin "$host_expect" -c '
    log_user 1
    set timeout 8
    proc terminate_spawned_router {} {
      global env spawn_id
      set router_pid ""
      catch {set router_pid [exp_pid -i $spawn_id]}
      set supervisor_pid ""
      set owner_path "$env(XDG_RUNTIME_DIR)/operation.lock/child.owner"
      if {[file readable $owner_path]} {
        set owner_file [open $owner_path r]
        set owner_data [read $owner_file]
        close $owner_file
        set supervisor_pid [lindex [split $owner_data "\n"] 0]
      }
      if {[regexp {^[0-9]+$} $supervisor_pid]} {
        catch {exec /bin/kill -TERM -- -$supervisor_pid}
      }
      if {[regexp {^[0-9]+$} $router_pid]} {
        catch {exec /bin/kill -TERM $router_pid}
      }
      after 1500
      if {[regexp {^[0-9]+$} $supervisor_pid]} {
        catch {exec /bin/kill -KILL -- -$supervisor_pid}
      }
      if {[regexp {^[0-9]+$} $router_pid]} {
        catch {exec /bin/kill -KILL $router_pid}
      }
      catch {close -i $spawn_id}
      catch {wait -i $spawn_id}
    }
    spawn -noecho $env(PTY_ROUTER) reauth bob --json
    expect {
      "native-auth-cancel-ready" {}
      timeout { terminate_spawned_router; exit 90 }
      eof { terminate_spawned_router; exit 91 }
    }
    send -- "\003"
    expect {
      eof {}
      timeout { terminate_spawned_router; exit 92 }
    }
    set child_result [wait]
    exit [lindex $child_result 3]
  ' >"$cli_stdout" 2>"$cli_stderr"
  ctrl_c_status=$?
  [ "$ctrl_c_status" -eq 2 ] || \
    diagnose "Ctrl-C native auth exited $ctrl_c_status instead of 2" || return 1
  [ -e "$fake_state/ctrl_c.descendant.ready" ] || \
    diagnose 'Ctrl-C resistant descendant was not started' || return 1
  [ ! -e "$fake_state/ctrl_c_completion_mutated" ] || \
    diagnose 'ignored SIGINT allowed native auth to mutate before cancellation' || return 1
  ctrl_c_descendant_pid=$(sed -n '1p' "$fake_state/ctrl_c.descendant.pid")
  wait_for_process_exit "$ctrl_c_descendant_pid" 300 || {
    kill -KILL "$ctrl_c_descendant_pid" 2>/dev/null || true
    diagnose 'Ctrl-C left a resistant native-auth descendant alive'
    return 1
  }
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'Ctrl-C did not restore alice' || return 1
  [ -e "$fake_state/restore_observed_while_locked" ] && \
    [ ! -e "$fake_state/restore_observed_after_unlock" ] || \
    diagnose 'Ctrl-C restored the account after releasing its operation lock' || return 1
  [ ! -e "$gh_account_state_dir/restore.pending" ] && \
    [ ! -L "$gh_account_state_dir/restore.pending" ] || \
    diagnose 'Ctrl-C left restoration quarantine debris' || return 1
  lock_is_available || diagnose 'Ctrl-C left the operation lock held'
}

test_registration_signal_cannot_start_an_unpublished_supervisor() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  rm -f "$case_bin/ps"
  cp "$fake_ps_source" "$case_bin/ps"
  chmod 755 "$case_bin/ps"
  : >"$fake_state/preserve_first_child_ready"
  printf '2\n' >"$fake_state/signal_before_child_publication"
  "$case_gh_account_bin" preflight bob "$case_repo" --json \
    >"$cli_stdout" 2>"$cli_stderr" &
  router_pid=$!
  if ! wait_for_process_exit "$router_pid" 500; then
    terminate_case_router
    kill -KILL "$router_pid" 2>/dev/null || true
    wait "$router_pid" 2>/dev/null || true
    diagnose 'registration-time signal left the router or supervisor hung'
    return 1
  fi
  wait "$router_pid"
  cli_status=$?
  assert_status 2 || return 1
  [ -e "$fake_state/child_ready_preserved" ] || \
    diagnose 'stale-readiness race was not established' || return 1
  [ -e "$fake_state/registration_signal_injected" ] || \
    diagnose 'registration-time signal was not injected' || return 1
  assert_file_not_contains "$fake_state/calls.log" 'auth switch bob' || return 1
  [ ! -e "$gh_account_state_dir/restore.pending" ] || \
    diagnose 'an unpublished supervisor installed restoration state after cancellation' || return 1
  registration_supervisor=$(sed -n '1p' "$fake_state/registration_supervisor.pid" 2>/dev/null || true)
  case "$registration_supervisor" in
    ''|*[!0-9]*) diagnose 'registration supervisor PID was not recorded'; return 1 ;;
  esac
  wait_for_process_exit "$registration_supervisor" 200 || {
    kill -KILL "$registration_supervisor" 2>/dev/null || true
    diagnose 'abandoned registration supervisor survived router cancellation'
    return 1
  }
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'registration-time signal changed the active account' || return 1
  lock_is_available || diagnose 'registration-time signal left the operation lock held'
}

test_lock_held_native_probes_are_lifecycle_tracked() {
  for probe_family in auth-status api-user repo-view; do
    setup_case
    make_repo example-org
    bind_repo_to_bob
    case "$probe_family" in
      auth-status)
        printf '2\n' >"$fake_state/block_auth_status_call"
        probe_ready=$fake_state/probe.auth-status.ready
        probe_pid_file=$fake_state/probe.auth-status.pid
        ;;
      api-user)
        : >"$fake_state/block_api_user"
        probe_ready=$fake_state/probe.api-user.ready
        probe_pid_file=$fake_state/probe.api-user.pid
        ;;
      repo-view)
        : >"$fake_state/block_repo_view"
        probe_ready=$fake_state/probe.repo-view.ready
        probe_pid_file=$fake_state/probe.repo-view.pid
        ;;
    esac
    "$case_gh_account_bin" preflight bob "$case_repo" --json \
      >"$cli_stdout" 2>"$cli_stderr" &
    router_pid=$!
    if ! wait_for_file "$probe_ready" 500; then
      terminate_case_router
      kill -KILL "$router_pid" 2>/dev/null || true
      wait "$router_pid" 2>/dev/null || true
      diagnose "$probe_family did not reach its resistant locked probe"
      return 1
    fi
    probe_pid=$(sed -n '1p' "$probe_pid_file")
    kill -TERM "$router_pid" 2>/dev/null || true
    if ! wait_for_process_exit "$router_pid" 200; then
      kill -KILL "$probe_pid" 2>/dev/null || true
      wait_for_process_exit "$router_pid" 200 || kill -KILL "$router_pid" 2>/dev/null || true
      wait "$router_pid" 2>/dev/null || true
      diagnose "$probe_family was not lifecycle-tracked by the signalled router"
      return 1
    fi
    wait "$router_pid"
    cli_status=$?
    assert_status 2 || return 1
    if process_is_live "$probe_pid"; then
      kill -KILL "$probe_pid" 2>/dev/null || true
      diagnose "$probe_family survived account restoration and lock release"
      return 1
    fi
    [ "$(cat "$fake_state/active")" = alice ] || \
      diagnose "$probe_family signal path did not restore alice" || return 1
    lock_is_available || diagnose "$probe_family signal path left the lock held" || return 1
  done
}

test_group_cleanup_rescans_after_an_empty_snapshot() {
  setup_case
  rm -f "$case_bin/ps"
  cp "$fake_ps_source" "$case_bin/ps"
  chmod 755 "$case_bin/ps"
  : >"$fake_state/fork_after_snapshot"
  run_cli exec bob -- pr test-fork-after-snapshot
  assert_status 0 || return 1
  [ -e "$fake_state/fork_snapshot_hidden" ] || \
    diagnose 'fork-after-snapshot race was not injected' || return 1
  wait_for_file "$fake_state/fork.descendant.ready" 200 || \
    diagnose 'fork-after-snapshot descendant was not created' || return 1
  fork_descendant_pid=$(sed -n '1p' "$fake_state/fork.descendant.pid")
  if process_is_live "$fork_descendant_pid"; then
    kill -KILL "$fork_descendant_pid" 2>/dev/null || true
    diagnose 'supervisor accepted an empty snapshot without a stability rescan'
    return 1
  fi
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'fork-after-snapshot cleanup did not restore alice' || return 1
  lock_is_available || diagnose 'fork-after-snapshot cleanup left the lock held'
}

assert_no_config_guard_debris() {
  debris_root=$1
  [ ! -e "$debris_root/config.lock" ] && [ ! -L "$debris_root/config.lock" ] || \
    diagnose "config guard lock debris remains below $debris_root" || return 1
  for debris_owner in "$debris_root"/.gh-account-owner.*; do
    [ ! -e "$debris_owner" ] && [ ! -L "$debris_owner" ] || \
      diagnose "config guard owner debris remains: $debris_owner" || return 1
  done
}

test_ambiguous_config_guard_mutations_reconcile_exactly() {
  for guard_injection in ambiguous_manifest_move ambiguous_guard_link; do
    setup_case
    make_repo example-org
    rm -f "$case_bin/ps"
    cp "$fake_ps_source" "$case_bin/ps"
    chmod 755 "$case_bin/ps"
    : >"$fake_state/$guard_injection"
    run_cli bind bob "$case_repo"
    assert_status 0 || {
      sed "s/^/$guard_injection stderr: /" "$cli_stderr" >&2
      return 1
    }
    case "$guard_injection" in
      ambiguous_manifest_move) mutation_marker=$fake_state/manifest_move_mutated ;;
      ambiguous_guard_link) mutation_marker=$fake_state/guard_link_mutated ;;
    esac
    [ -e "$mutation_marker" ] || diagnose "$guard_injection was not injected" || return 1
    [ -e "$fake_state/group_enumeration_failed_once" ] || \
      diagnose "$guard_injection did not fail after the real mutation" || return 1
    [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = bob ] || \
      diagnose "$guard_injection lost the committed repository binding" || return 1
    [ "$(cat "$fake_state/active")" = alice ] || \
      diagnose "$guard_injection did not restore alice" || return 1
    [ ! -e "$gh_account_transaction_journal" ] && [ ! -L "$gh_account_transaction_journal" ] || \
      diagnose "$guard_injection left a transaction journal" || return 1
    lock_is_available || diagnose "$guard_injection left the operation lock held" || return 1
    assert_no_config_guard_debris "$case_repo/.git" || return 1
  done
}

test_pre_link_failure_resumes_existing_manifest_row_for_rollback() {
  setup_case
  make_repo example-org
  : >"$fake_state/fail_guard_link_before_mutation"
  run_cli bind bob "$case_repo"
  assert_nonzero_status || return 1
  [ -e "$fake_state/guard_link_pre_mutation_failed" ] || \
    diagnose 'pre-mutation hard-link failure was not injected' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'pre-link failure did not restore alice' || return 1
  [ -z "$("$host_git" -C "$case_repo" config --local --get github.account 2>/dev/null || true)" ] || \
    diagnose 'pre-link failure did not roll back the repository binding' || return 1
  [ ! -e "$gh_account_transaction_journal" ] && [ ! -L "$gh_account_transaction_journal" ] || \
    diagnose 'pre-link failure left transaction WAL debris' || return 1
  lock_is_available || diagnose 'pre-link failure stranded the operation lease' || return 1
  assert_no_config_guard_debris "$case_repo/.git"
}

test_corrupt_ambiguous_manifest_is_not_reconciled() {
  setup_case
  make_repo example-org
  rm -f "$case_bin/ps"
  cp "$fake_ps_source" "$case_bin/ps"
  chmod 755 "$case_bin/ps"
  : >"$fake_state/corrupt_manifest_move"
  run_cli bind bob "$case_repo"
  assert_nonzero_status || return 1
  [ -e "$fake_state/manifest_move_corrupted" ] || \
    diagnose 'wrong-byte manifest outcome was not injected' || return 1
  [ -f "$gh_account_lock_dir/config.guards" ] && \
    grep -F '/unexpected.lock' "$gh_account_lock_dir/config.guards" >/dev/null 2>&1 || \
    diagnose 'wrong-byte manifest evidence was not preserved fail-closed' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'wrong-byte manifest changed the active account' || return 1
  [ -z "$("$host_git" -C "$case_repo" config --local --get github.account 2>/dev/null || true)" ] || \
    diagnose 'wrong-byte manifest unexpectedly committed a repository binding'
}

test_ambiguous_journal_mutations_reconcile_exact_state() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  rm -f "$case_bin/ps"
  cp "$fake_ps_source" "$case_bin/ps"
  chmod 755 "$case_bin/ps"
  : >"$fake_state/ambiguous_binding_committed_journal_move"
  : >"$fake_state/ambiguous_journal_remove"
  run_cli use bob "$case_repo"
  assert_status 0 || { sed 's/^/ambiguous use stderr: /' "$cli_stderr" >&2; return 1; }
  [ -e "$fake_state/journal_move_mutated" ] && [ -e "$fake_state/journal_remove_mutated" ] || \
    diagnose 'persistent use did not exercise both ambiguous journal mutations' || return 1
  [ "$(cat "$fake_state/active")" = bob ] || \
    diagnose 'reconciled persistent use lost its committed account' || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = bob ] || \
    diagnose 'reconciled persistent use lost its committed binding' || return 1
  [ ! -e "$gh_account_transaction_journal" ] && [ ! -L "$gh_account_transaction_journal" ] || \
    diagnose 'reconciled persistent use left journal debris' || return 1
  lock_is_available || diagnose 'reconciled persistent use left the lock held' || return 1
  assert_no_config_guard_debris "$case_repo/.git" || return 1

  setup_case
  make_repo example-org
  rm -f "$case_bin/ps"
  cp "$fake_ps_source" "$case_bin/ps"
  chmod 755 "$case_bin/ps"
  : >"$fake_state/ambiguous_repair_journal_move"
  : >"$fake_state/ambiguous_journal_remove"
  run_cli repair bob "$case_repo"
  assert_status 0 || { sed 's/^/ambiguous repair stderr: /' "$cli_stderr" >&2; return 1; }
  [ -e "$fake_state/journal_move_mutated" ] && [ -e "$fake_state/journal_remove_mutated" ] || \
    diagnose 'repair did not exercise both ambiguous journal mutations' || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = bob ] || \
    diagnose 'reconciled repair lost its binding' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'reconciled repair did not restore alice' || return 1
  [ ! -e "$gh_account_transaction_journal" ] && [ ! -L "$gh_account_transaction_journal" ] || \
    diagnose 'reconciled repair left journal debris' || return 1
  lock_is_available || diagnose 'reconciled repair left the lock held' || return 1
  assert_no_config_guard_debris "$case_repo/.git"
}

test_ambiguous_journal_move_requires_exact_intended_bytes() {
  setup_case
  make_repo example-org
  "$host_git" -C "$case_repo" config --local github.account alice
  "$host_git" -C "$case_repo" config --local credential.username alice
  "$host_git" -C "$case_repo" config --local user.name 'Alice Example'
  "$host_git" -C "$case_repo" config --local user.email \
    '1001+alice@users.noreply.github.com'
  rm -f "$case_bin/ps"
  cp "$fake_ps_source" "$case_bin/ps"
  chmod 755 "$case_bin/ps"
  : >"$fake_state/corrupt_binding_committed_journal_move"
  run_cli use bob "$case_repo"
  assert_nonzero_status || return 1
  [ -e "$fake_state/journal_move_corrupted" ] || \
    diagnose 'valid-schema wrong-byte journal was not injected' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'wrong-byte journal was accepted as a committed account outcome' || return 1
  [ "$("$host_git" -C "$case_repo" config --local --get github.account)" = alice ] || \
    diagnose 'wrong-byte journal was accepted as a committed binding outcome' || return 1
  [ ! -e "$gh_account_transaction_journal" ] && [ ! -L "$gh_account_transaction_journal" ] || \
    diagnose 'wrong-byte journal rollback left WAL debris' || return 1
  lock_is_available || diagnose 'wrong-byte journal failure left the lock held'
}

test_failed_journal_remove_requires_full_absence() {
  setup_case
  make_repo example-org
  : >"$fake_state/fail_journal_remove_before_mutation"
  run_cli repair bob "$case_repo"
  assert_nonzero_status || return 1
  [ -e "$fake_state/journal_remove_pre_mutation_failed" ] || \
    diagnose 'pre-unlink journal failure was not injected' || return 1
  [ -z "$("$host_git" -C "$case_repo" config --local --get github.account 2>/dev/null || true)" ] || \
    diagnose 'repair accepted a failed journal removal while the WAL still existed' || return 1
  [ "$(cat "$fake_state/active")" = alice ] || \
    diagnose 'failed journal removal did not restore alice' || return 1
  [ ! -e "$gh_account_transaction_journal" ] && [ ! -L "$gh_account_transaction_journal" ] || \
    diagnose 'deterministic retry did not clear the retained journal' || return 1
  lock_is_available || diagnose 'deterministic journal-remove retry left the lock held'
}

test_journal_remove_rejects_a_dangling_symlink() {
  setup_case
  make_repo example-org
  rm -f "$case_bin/ps"
  cp "$fake_ps_source" "$case_bin/ps"
  chmod 755 "$case_bin/ps"
  : >"$fake_state/ambiguous_journal_remove_dangling_link"
  run_cli repair bob "$case_repo"
  assert_nonzero_status || return 1
  [ -e "$fake_state/journal_remove_left_dangling_link" ] || \
    diagnose 'dangling-journal unlink outcome was not injected' || return 1
  [ -L "$gh_account_transaction_journal" ] || \
    diagnose 'dangling journal entry was incorrectly accepted as absent' || return 1
  [ -z "$("$host_git" -C "$case_repo" config --local --get github.account 2>/dev/null || true)" ] || \
    diagnose 'dangling journal entry was accepted as a committed repair'
}

test_one_digit_octal_modes_fail_closed() {
  for unsafe_mode in 2 3 6 7; do
    setup_case
    printf '%s\n' "$case_git_config" >"$fake_state/stat_mode_target"
    printf '%s\n' "$unsafe_mode" >"$fake_state/stat_mode_value"
    run_cli doctor --json
    assert_status 77 || return 1
    assert_stdout_json || return 1
    assert_finding CONFIG.UNSAFE_PERMISSIONS || return 1
  done
}

test_bind_writes_usable_commit_name_from_profile() {
  setup_case
  make_repo example-org
  run_cli bind bob "$case_repo"
  assert_status 0 || { sed 's/^/bind stderr: /' "$cli_stderr" >&2; return 1; }
  bound_name=$("$host_git" -C "$case_repo" config --local --get user.name 2>/dev/null || true)
  [ "$bound_name" = 'Bob Example' ] || \
    diagnose "bind wrote an unexpected commit name [$bound_name]" || return 1
  # Guard against the jq-1.7.1-apple regression that rewrote real names to
  # whitespace: the value must contain a non-space character.
  case $bound_name in
    *[![:space:]]*) ;;
    *) diagnose 'bind wrote a whitespace-only commit name' || return 1 ;;
  esac
}

test_bind_falls_back_to_login_when_profile_name_is_null() {
  setup_case
  make_repo example-org
  # GitHub returns a null display name for accounts that never set one.
  : >"$fake_state/account.bob.name_null"
  run_cli bind bob "$case_repo"
  assert_status 0 || { sed 's/^/null-name bind stderr: /' "$cli_stderr" >&2; return 1; }
  bound_name=$("$host_git" -C "$case_repo" config --local --get user.name 2>/dev/null || true)
  [ "$bound_name" = bob ] || \
    diagnose "null profile name did not fall back to login [$bound_name]" || return 1
  # Author name must be non-empty and non-whitespace so git commit succeeds.
  case $bound_name in
    *[![:space:]]*) ;;
    *) diagnose 'null-name fallback produced an unusable commit name' || return 1 ;;
  esac
}

test_current_flags_whitespace_only_commit_name() {
  setup_case
  make_repo example-org
  bind_repo_to_bob
  # Simulate a repository corrupted by the pre-fix router: a whitespace-only
  # user.name. current must report it as unconfigured rather than pass it.
  "$host_git" -C "$case_repo" config --local user.name '   '
  run_cli current "$case_repo"
  assert_status 0 || { sed 's/^/current stderr: /' "$cli_stderr" >&2; return 1; }
  assert_file_contains "$cli_stdout" 'git-author: unconfigured' || return 1
  assert_file_contains "$cli_stdout" 'identity-status: mismatch' || return 1
}

run_test() {
  test_name=$1
  test_function=$2
  if [ -n "${TEST_FILTER:-}" ] && ! printf '%s\n' "$test_name" | grep -F "$TEST_FILTER" >/dev/null 2>&1; then
    return 0
  fi
  test_count=$((test_count + 1))
  test_log=$suite_tmp/test-$test_count.log
  if ( "$test_function" ) >"$test_log" 2>&1; then
    printf 'ok %s - %s\n' "$test_count" "$test_name"
  else
    failure_count=$((failure_count + 1))
    printf 'not ok %s - %s\n' "$test_count" "$test_name"
    sed 's/^/# /' "$test_log"
  fi
}

run_test 'doctor emits healthy agent-readable JSON' test_doctor_healthy_json
run_test 'filesystem metadata selection is independent of cwd filenames' \
  test_stat_selection_is_cwd_independent
run_test 'doctor rejects native state=error even when gh exits zero' \
  test_doctor_rejects_error_state_with_zero_native_exit
run_test 'doctor separates native timeout from invalid credentials' \
  test_doctor_classifies_native_timeout_without_reauth_advice
run_test 'preflight classifies native auth timeout as temporary failure' \
  test_preflight_classifies_native_timeout_as_temporary_failure
run_test 'doctor classifies malformed native auth JSON' \
  test_doctor_classifies_malformed_native_json
run_test 'doctor handles an empty native host inventory' \
  test_doctor_handles_empty_native_host_inventory
run_test 'doctor reports a missing gh dependency' test_doctor_reports_missing_gh
run_test 'doctor reports a missing jq dependency' test_doctor_reports_missing_jq
run_test 'doctor reports a missing git dependency' test_doctor_reports_missing_git
run_test 'doctor detects GH_TOKEN without leaking its value' \
  test_doctor_detects_gh_token_override_without_leakage
run_test 'doctor detects GITHUB_TOKEN without leaking its value' \
  test_doctor_detects_github_token_override_without_leakage
run_test 'doctor redacts invalid account arguments from output and audit' \
  test_doctor_redacts_invalid_account_argument
run_test 'doctor structures and redacts invalid host configuration' \
  test_doctor_structures_and_redacts_invalid_host
run_test 'host validation normalizes case and rejects invalid DNS labels' \
  test_host_validation_normalizes_case_and_rejects_invalid_dns_labels
run_test 'doctor refuses hostile Git context overrides without leakage' \
  test_doctor_refuses_git_context_override_without_leakage
run_test 'commands reject alternate GitHub CLI state roots' \
  test_commands_reject_alternate_github_cli_state_roots
run_test 'commands reject GitHub transport and debug overrides' \
  test_commands_reject_github_transport_and_debug_overrides
run_test 'Git configuration permissions and ACL posture fail closed' \
  test_git_config_permissions_fail_closed
run_test 'preflight refuses Git author identity environment overrides' \
  test_preflight_refuses_git_author_identity_override
run_test 'doctor reports repository binding mismatch' \
  test_doctor_reports_repository_binding_mismatch
run_test 'doctor and current redact invalid repository binding metadata' \
  test_doctor_redacts_invalid_repository_binding
run_test 'doctor redacts credentials embedded in remote URLs' \
  test_doctor_redacts_embedded_remote_credentials
run_test 'doctor refuses ambiguous organization inference' \
  test_doctor_requires_explicit_account_for_org_remote
run_test 'doctor refuses inference when origin is missing' \
  test_doctor_requires_explicit_account_without_remote
run_test 'preflight verifies API identity and restores active account' \
  test_preflight_verifies_identity_and_restores_active_account
run_test 'preflight separates API timeout from credential invalidity' \
  test_preflight_classifies_api_network_failures_without_reauth
run_test 'preflight separates repository DNS failure from authorization' \
  test_preflight_classifies_repository_dns_failure
run_test 'preflight treats API rate limits and service failures as temporary' \
  test_preflight_classifies_rate_limit_and_service_failures_as_temporary
run_test 'preflight refuses environment token overrides' \
  test_preflight_refuses_environment_token_override
run_test 'preflight rejects credentials outside the native keyring' \
  test_preflight_rejects_non_keyring_credential_storage
run_test 'preflight classifies repository binding mismatch' \
  test_preflight_classifies_repository_binding_mismatch
run_test 'preflight rejects divergent account marker and credential username' \
  test_preflight_rejects_divergent_marker_and_credential
run_test 'preflight rejects an unexpected credential helper chain' \
  test_preflight_rejects_unexpected_credential_helper
run_test 'preflight rejects a basename-masquerading credential helper' \
  test_preflight_rejects_basename_masquerading_helper
run_test 'credential-helper validation honors Git reset semantics' \
  test_helper_validation_honors_git_reset_semantics
run_test 'preflight rejects effective route overrides and proxies' \
  test_preflight_rejects_effective_route_overrides_and_proxy
run_test 'preflight rejects effective repository URL rewrites' \
  test_preflight_rejects_effective_repository_url_rewrite
run_test 'preflight rejects mixed-case host extra headers' \
  test_preflight_rejects_mixed_case_host_extra_header
run_test 'preflight refuses credentials embedded in the origin URL' \
  test_preflight_refuses_embedded_remote_credentials
run_test 'preflight rejects a push URL targeting another repository' \
  test_preflight_rejects_different_push_target
run_test 'preflight rejects local helper and authorization-header overrides' \
  test_preflight_rejects_local_credential_and_header_overrides
run_test 'preflight canonicalizes mixed-case account input' \
  test_preflight_canonicalizes_account_case
run_test 'preflight requires local binding and exact canonical noreply identity' \
  test_preflight_requires_local_binding_and_exact_noreply_identity
run_test 'preflight rejects path-specific credential, header, and TLS overrides' \
  test_preflight_rejects_path_specific_transport_and_tls_overrides
run_test 'preflight refuses unverified SSH transport' \
  test_preflight_refuses_unverified_ssh_transport
run_test 'doctor emits cwd-independent remediation arguments' \
  test_doctor_builds_cwd_independent_remediation_arguments
run_test 'scope and Git transport environment inputs fail closed' \
  test_scope_and_git_transport_environment_inputs_fail_closed
run_test 'GitHub CLI state permissions and links fail closed' \
  test_gh_config_permissions_and_links_fail_closed
run_test 'included Git configuration requires trusted origins' \
  test_git_config_includes_require_safe_origins
run_test 'a fresh profile may begin without a global Git config' \
  test_absent_global_git_config_is_safe_for_first_use
run_test 'preflight surfaces restoration failure' test_preflight_surfaces_restore_failure
run_test 'preflight surfaces operation-lock release failure' \
  test_preflight_surfaces_lock_release_failure
run_test 'generic exec blocks auth token' test_exec_blocks_auth_token
run_test 'generic exec blocks auth status --show-token' test_exec_blocks_show_token
run_test 'generic exec blocks aliases, extensions, and unknown dispatch' \
  test_exec_blocks_alias_extension_and_unknown_dispatch
run_test 'generic exec blocks auth mutations' test_exec_blocks_auth_mutations
run_test 'generic exec rejects cross-host and credential-key operations' \
  test_exec_refuses_cross_host_and_credential_key_operations
run_test 'generic exec pins the repository and neutralizes local launchers' \
  test_exec_pins_repo_and_neutralizes_local_program_launchers
run_test 'generic exec rejects GH_REPO environment routing' \
  test_exec_refuses_gh_repo_environment_override
run_test 'generic exec permits only constrained read-only GraphQL' \
  test_exec_allows_only_read_only_graphql
run_test 'generic exec preserves child exit and restores account' \
  test_exec_preserves_downstream_exit_and_restores
run_test 'cleanup failure dominates a downstream command exit' \
  test_exec_cleanup_failure_dominates_downstream_exit
run_test 'restoration requires quarantine cleanup before success' \
  test_restore_requires_quarantine_cleanup_before_success
run_test 'temporary routes refuse a zero-active-account state' \
  test_temporary_routes_refuse_zero_active_account
run_test 'lock dependency and unsafe-state exits remain distinct' \
  test_lock_dependency_and_unsafe_state_have_distinct_exits
run_test 'git-exec routes Git transport under the selected account and restores it' \
  test_git_exec_routes_transport_and_restores
run_test 'git-exec holds reviewed Git configuration through transport' \
  test_git_exec_holds_config_guards_through_transport
run_test 'git-exec reclaims only its owned config guards after a crash' \
  test_git_exec_recovers_owned_config_guards_after_crash
run_test 'git-exec refuses unsafe, non-origin, and SSH routes' \
  test_git_exec_refuses_unsafe_or_unbound_routes
run_test 'persistent use restores identity after verification failure' \
  test_use_restores_previous_account_when_identity_verification_fails
run_test 'persistent use commits account and binding as one outcome' \
  test_use_commits_account_and_binding_as_one_outcome
run_test 'bind writes a usable commit name from the profile' \
  test_bind_writes_usable_commit_name_from_profile
run_test 'bind falls back to the login when the profile name is null' \
  test_bind_falls_back_to_login_when_profile_name_is_null
run_test 'current flags a whitespace-only commit name as unconfigured' \
  test_current_flags_whitespace_only_commit_name
run_test 'persistent use rolls back a failed commit journal before unlock' \
  test_use_commit_journal_failure_rolls_back_before_unlock
run_test 'bind and use finalize install failures before unlock' \
  test_bind_and_use_finalize_install_failure_before_unlock
run_test 'bind preserves recovery metadata when locked rollback fails' \
  test_bind_preserves_wal_when_locked_rollback_fails
run_test 'persistent use rolls back account and binding on interruption' \
  test_use_signal_rolls_back_account_and_binding_together
run_test 'auto revalidates repository binding under the operation lock' \
  test_auto_revalidates_binding_under_operation_lock
run_test 'preflight reports live lock contention' test_preflight_reports_live_lock_contention
run_test 'preflight reclaims a stale lock owner' \
  test_preflight_reclaims_stale_lock_owner
run_test 'signal cleanup restores identity and releases lock' \
  test_exec_signal_restores_identity_and_releases_lock
run_test 'cooperative signal cleanup cancels escalation promptly' \
  test_cooperative_signal_cancels_escalation_promptly
run_test 'repeated signals cannot bypass restoration and lock cleanup' \
  test_repeated_signal_preserves_cleanup
run_test 'signal cleanup escalates for a resistant child' \
  test_signal_escalates_for_resistant_child
run_test 'signal cleanup terminates resistant descendants before restore' \
  test_signal_terminates_resistant_descendants_before_restore
run_test 'group-enumeration failure terminates descendants before restore' \
  test_group_enumeration_failure_terminates_descendants
run_test 'command-only lockf keeps live config mutation children leased' \
  test_command_only_lockf_tracks_live_mutation_children
run_test 'read commands refuse transient account snapshots while routing is active' \
  test_read_commands_refuse_transient_account_snapshots
run_test 'reauth refreshes and verifies native identity' \
  test_reauth_refreshes_and_verifies_native_identity
run_test 'reauth preserves native cancellation' test_reauth_preserves_native_cancellation
run_test 'reauth rejects a wrong resolved identity' test_reauth_rejects_wrong_resolved_identity
run_test 'onboard supports the zero-account first-login case' \
  test_onboard_first_account_needs_no_restoration
run_test 'repair dry-run never mutates even when interactive was requested' \
  test_repair_dry_run_never_mutates
run_test 'repair configures native Git routing and repository identity' \
  test_repair_applies_native_config_and_repository_identity
run_test 'repair corrects an existing repository identity transactionally' \
  test_repair_corrects_existing_repository_identity
run_test 'repair refuses local helper resets and unsafe repository remotes' \
  test_repair_refuses_local_helper_reset_and_unsafe_remote
run_test 'repair interactive performs one-click native refresh and repair' \
  test_repair_interactive_refreshes_then_repairs
run_test 'repair rolls back a partially failed global Git configuration' \
  test_repair_rolls_back_partial_global_config_failure
run_test 'repair preserves unrelated edits detected before live install' \
  test_repair_preserves_unrelated_edit_between_stage_and_install
run_test 'repair signal cleanup rolls back the durable configuration transaction' \
  test_repair_signal_rolls_back_durable_transaction
run_test 'preflight recovers an interrupted repository binding transaction' \
  test_preflight_recovers_interrupted_binding_transaction
run_test 'recovery refuses to overwrite unrelated configuration edits' \
  test_recovery_refuses_to_overwrite_unrelated_config_edits
run_test 'doctor reports malformed configuration recovery metadata' \
  test_doctor_reports_malformed_config_recovery_journal
run_test 'audit events never disclose token canaries' \
  test_audit_events_never_disclose_token_canary
run_test 'audit spool serializes concurrent diagnostic writers' \
  test_audit_spool_serializes_concurrent_writers
run_test 'audit spool rotates without truncating retained evidence' \
  test_audit_spool_rotates_without_silent_truncation
run_test 'audit spool refuses symlink and hardlink targets' \
  test_audit_spool_refuses_symlink_and_hardlink_targets
run_test 'interactive native auth preserves foreground PTY control and stdin' \
  test_interactive_native_auth_preserves_real_pty_and_stdin
run_test 'interactive Ctrl-C terminates before native auth can mutate' \
  test_interactive_ctrl_c_terminates_before_native_auth_mutation
run_test 'registration signals cannot start an unpublished supervisor' \
  test_registration_signal_cannot_start_an_unpublished_supervisor
run_test 'lock-held native probes participate in lifecycle tracking' \
  test_lock_held_native_probes_are_lifecycle_tracked
run_test 'process-group cleanup rescans after an empty snapshot' \
  test_group_cleanup_rescans_after_an_empty_snapshot
run_test 'ambiguous config-guard mutations reconcile exact state' \
  test_ambiguous_config_guard_mutations_reconcile_exactly
run_test 'pre-link failures resume the existing guard row for rollback' \
  test_pre_link_failure_resumes_existing_manifest_row_for_rollback
run_test 'wrong-byte ambiguous manifests are not reconciled' \
  test_corrupt_ambiguous_manifest_is_not_reconciled
run_test 'ambiguous journal mutations reconcile exact state' \
  test_ambiguous_journal_mutations_reconcile_exact_state
run_test 'ambiguous journal moves require exact intended bytes' \
  test_ambiguous_journal_move_requires_exact_intended_bytes
run_test 'journal remove reconciliation requires full absence' \
  test_failed_journal_remove_requires_full_absence
run_test 'journal remove reconciliation rejects dangling symlinks' \
  test_journal_remove_rejects_a_dangling_symlink
run_test 'one-digit unsafe octal modes fail closed' \
  test_one_digit_octal_modes_fail_closed

printf '1..%s\n' "$test_count"
[ "$failure_count" -eq 0 ]
