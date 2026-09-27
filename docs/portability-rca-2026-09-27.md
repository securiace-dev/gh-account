# Portability RCA — why the first CI run failed on both platforms (2026-09-27)

The initial release's CI failed on `ubuntu-latest` (63 of 122 behavioural tests) and on
`macos-26-arm64` (61 of 122). The tool had passed its full suite on the developer's Mac. This
document records what was actually wrong — five independent defects, three of them in the
product — and how each was proven, because most of the first hypotheses were wrong and it matters
which evidence finally settled each one.

Method throughout: reproduce in a clean `ubuntu:24.04` container and on the Mac under both
`umask 022` and `umask 002`, change one variable at a time, and only accept a root cause once a
targeted experiment flips a failing test to passing. Every "fix" below is paired with the
experiment that confirmed it.

## Summary

| # | Defect | Where | Platform it bit | Kind |
|---|---|---|---|---|
| 1 | Sticky-bit directories (`/tmp`, mode `1777`) rejected as "not owner-controlled" during ancestor walks | `config_origin_file_is_safe`, `config_origin_path_is_safe_or_absent` | Linux (`mktemp -d` defaults to `/tmp`) | product |
| 2 | Group-writable files rejected even when the group is the owner's private group | `path_mode_is_owner_controlled` (and an inline copy in `audit_directory_is_safe`) | every user-private-group Linux (Debian/Ubuntu default, umask 002) | product |
| 3 | System-scope git config under a group-writable package prefix rejected | `git_config_origins_are_safe` / `config_origin_file_is_safe` | macOS CI (Homebrew git, `/opt/homebrew` is `runner:admin 775`) | product |
| 4 | The routed-command supervisor cannot run under dash (`set -m` fails without a tty; builtin `kill` rejects `-- -pgid`) | `run_tracked` supervisor spawn; script shebang | every Linux where `/bin/sh` is dash | product |
| 5 | Liveness checks are zombie-blind (`kill -0` succeeds on an unreaped exited process) | `lease_process_matches`, supervisor group scan; harness `kill -0` sites | any container without an init (PID 1 does not reap) | product + tests |
| 7 | procps reports a process that exits mid-query as success with empty output; the supervisor failed closed on it and turned a successful command into exit 137 | supervisor member query | Linux, ~50% of runs of one test | product |

Plus one test-only race (#6) exposed by Linux being faster than macOS. Numbering follows the order
each defect was found; #7 surfaced only after #1–#6 were fixed.

## 1. Sticky-bit ancestors

**Symptom.** Linux CI, test 1 onward: `CONFIG.UNSAFE_PERMISSIONS: Git configuration ownership,
permissions, or ACLs are unsafe`.

**Cause.** `config_origin_file_is_safe` walks a config file's ancestors to `/` and requires each
root-owned directory to be free of group/other write bits. Linux `mktemp -d` puts the test home
under `/tmp` (`1777`), which failed that test. macOS never showed it because its `mktemp -d` uses
the private per-user `$TMPDIR` (`0700`).

**Proof.** Instrumented ancestor walk in the container printed the exact directory and mode
(`/tmp … mode=1777 owner_ctrl=1`). Adding a sticky-bit exception for root-owned directories made
the same test pass.

**Fix.** `dir_mode_has_sticky_bit`; a root-owned world-writable directory *with* the sticky bit is
accepted in the two ancestor walks only. File-level checks are unchanged.

## 2. Private groups

**Symptom.** In a clean Ubuntu container as a normal user (`umask 002`, primary group `runner`
containing only `runner`), 107 of 122 tests failed with `CONFIG.UNSAFE_PERMISSIONS`; the identical
tree passed under `umask 022`. So the tool was unusable on a stock Debian/Ubuntu account: every
`git init` repository is `775/664` there.

**Cause.** `path_mode_is_owner_controlled` decided from mode bits alone. A group-write bit only
widens who can write if the group has members other than the owner; on user-private-group systems
it never does.

**Proof.** Same container, same tree: `umask 022 → ok`, `umask 002 → not ok` on the same test.
After the fix, both pass.

**Fix.** `group_is_private_to_owner`: a group-write bit is accepted only when the file's group is
named after the owner, is the owner's primary group, and has no other explicit members
(`getent group`, falling back to `/etc/group`; `dscl` on Darwin). Anything unresolvable fails
closed. Memoised per gid. macOS is deliberately unaffected: its primary group `staff` contains
every local user, so group-writable there really is shared-writable — the tool still refuses
under `umask 002` on a Mac, correctly. An inline copy of the old bit test in
`audit_directory_is_safe` was routed through the same function (it had silently left the audit
spool unwritable on private-group hosts). Test 50, which asserted "a group-writable include
parent is refused", now makes the directory writable by a *non-owner* group (or other-writable)
so it keeps asserting the invariant it meant.

## 3. System config under a package prefix

**Symptom.** macOS CI: tests 1–20 pass, tests 21+ fail with `repository Git configuration …
unsafe`. Test 21 is the first that runs `git -C <repo> config --show-origin --list`, which — unlike
`--global` — also lists the **system** config.

**Cause.** The runner's git is Homebrew's; its prefix `/opt/homebrew` is `runner:admin 775`. Only
Apple Git's toolchain path had an "admin-managed ancestry" tolerance.

**Proof.** Reproduced the *class* locally (any group-writable ancestor of a system-scope origin);
final confirmation is the CI run itself — this was the one cause I could not reproduce on the
Mac, and it is stated as such.

**Fix.** `--show-scope` is added to the origin listing; `system`-scope origins get the same
"not world-writable" ancestry tolerance as Apple Git's config, in both the root-owned and
owner-owned branches. Apple Git reports its bundled config with scope `unknown`; that value is
accepted but gets no tolerance (the exec-path check already covers it). A strict scope allowlist
without `unknown` regressed test 21 on macOS during development — caught locally.

## 4. dash

**Symptom.** After 1–3, Linux at `umask 022` still failed 78 tests with `AUTH.SWITCH_FAILED` /
"could not select the requested account". The same test passed the moment the binary was run
with `bash` instead of `sh`.

**Cause, in two parts.** The script is `#!/bin/sh`, and on Debian/Ubuntu that is dash; on macOS
it is bash, so bash was the only shell the tool had ever been validated under.
`run_tracked` supervises routed commands through a job-control process group: `set -m`, then
`kill -SIG -- -$$` to address the group. Under dash without a tty, `set -m` fails ("can't access
tty; job control turned off") so no separate group exists at all, and dash's builtin `kill`
rejects `-- -pgid` with `kill: Illegal number: -` (seen verbatim in a supervisor trace). The
supervisor is spawned as a literal `/bin/sh -c`, so it stayed dash even after the router itself
re-executed under bash — which is why fixing the shebang alone left test 88 failing.

**Proof.** `TEST_FILTER=<test> sh tests/test-gh-account.sh` fails; the same with the under-test
binary's shebang rewritten to bash passes. Supervisor trace shows the `Illegal number` error at
the group-kill. A direct experiment: `dash -c 'set -m; (sleep&…)'` prints the tty warning and the
job stays in the caller's group.

**Fix.** The router re-executes under `bash` when the **pinned** `PATH` provides one (never the
caller's `PATH` — that would be an injection route); `GH_ACCOUNT_SH=posix` opts out for
diagnosis. The supervisor is spawned with `${BASH:-/bin/sh}`, so it runs under the router's
shell — identical on macOS, bash on Linux. `bash` was added to the test harness's explicit tool
allowlist so Linux tests exercise the real runtime. dash remains a documented-unsupported
fallback for the supervised paths.

## 5. Zombie-blind liveness

**Symptom.** Five tests still failed in the container after 1–4: crash-recovery reported
`LOCK.BUSY`, and signal-cleanup tests reported descendants "still alive" after the router had
restored the account.

**Cause.** A process that has exited but not been reaped still answers `kill -0` and still
reports its original `lstart`. Its parent here was the deliberately-crashed router, so it
reparented to the container's PID 1 — `sleep`, in my repro container — which never reaps.
`lease_process_matches` (lease liveness) and the supervisor's group scan therefore saw dead
processes as live. On a host with a real init this is invisible; inside `docker run` without
`--init` — where agents commonly run this tool — it is not.

**Proof.** Correlated trace: the supervisor logs `EXIT status=0`, and the very next `preflight`
still finds the lease's `child.owner` pid "alive" — only a zombie satisfies both.

**Fix.** The supervisor snapshot includes `stat=` and ignores `Z*` members; `lease_process_matches`
treats `Z*` as gone. The harness gained the same `process_is_live` helper for its own
`kill -0` assertions.

## 7. procps: `ps -p <dying pid>` succeeds with no output

**Symptom.** With 1–6 in place, one test (114, "process-group cleanup rescans after an empty
snapshot") still failed on Linux in roughly half its runs, with the routed command's exit
reported as 137 and the router logging `tracked process-group inspection failed safely
(member-query)`. Instrumenting the supervisor loop made it disappear — a timing race.

**Cause.** The supervisor's group scan takes a `ps -axo` snapshot, then queries each candidate's
pgid with `ps -o pgid= -p <pid>`. A member that exits between the two is reported by procps as
**exit 0 with empty output** (found in the `/proc` scan, gone before its stat was read); BSD `ps`
on macOS exits non-zero instead. The code read an empty pgid as "cannot classify" and failed
closed — killing its own process group and returning `EXIT_TEMPFAIL`, so a command that had
already *succeeded* came back as 137.

**Proof.** A trace on that single statement (no other perturbation) caught it: snapshot row
`<pid> <pgid> S`, query result `[]`, `kill -0` → dead. Reproduced 7 of 10 runs.

**Fix.** An empty pgid triggers a `kill -0` re-check: a vanished process is dropped as no longer a
member; a still-live one is queried once more and only then fails closed. Non-numeric output is
still treated as an inspection failure.

## 6. A test race Linux exposed

Test 69 waited for the fake git *transport* to exit but not for the crashed router's supervisor,
which needs two empty snapshots 100 ms apart. macOS starts the next router slowly enough to lose
that race by accident; Linux won it and correctly saw a live tracked child (`LOCK.BUSY`,
`retryable: true`). The test now waits for the supervisor explicitly. The product's behaviour was
right.

## What was wrong in the first analysis, for the record

- "umask 002 on the CI runner" — plausible, reproduced the symptom class locally, but standard
  hosted runners use 022; it explains stock Ubuntu desktops, not CI. Kept as #2 because it is real.
- "`ps -axo` hides group members on procps" — falsified by a direct experiment (3 rows both ways).
- "the fixtures use `setsid`" — falsified by reading them.
- "running the supervisor under bash fixes test 69" — falsified; the cause was #5/#6, not #4.

## Verification

Full `tests/run.sh` (122 behavioural tests + insights suite + shellcheck): clean on macOS
(`umask 022`), and in a clean `ubuntu:24.04` container as a normal user under both `umask 002`
and `umask 022`, with an init-less PID 1 (the harsher environment). CI is the oracle for #3.

**CI confirmation.** Run `36292687593` (`b39d10c`): both Linux legs green; the hosted macOS
runner failed exactly one test of 122 — #84, a whole-second timing assertion (`< 2 s` against a
3 s grace) that a slow runner reads as 2 — and passed every test from 21 onward, which is what
confirms #3. The assertion was corrected to the discriminating value (`< 3 s`) in `3a571ed`;
run `36293820124` is green on all three legs (macOS 21m45s, Linux 5m44s, Linux-umask-002 5m45s).
