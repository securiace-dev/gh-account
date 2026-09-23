# gh-account

A fail-closed multi-account router for the GitHub CLI, built for anyone — human
or AI agent — who works across more than one GitHub identity from the same
machine.

## The problem

If you have a personal account, a work/org account, and maybe a client
account all authenticated in `gh` on the same box, it is very easy for
*something* — a script, an AI coding agent, a stale `PATH`, an unset env var —
to run `gh pr create` or `git push` under the wrong identity. The damage
ranges from an embarrassing commit author to a real credential/data leak
across an account boundary.

This gets sharply worse once an AI agent is the one driving `gh`/`git`
unattended: it won't notice a wrong-account mistake the way a human glancing
at a terminal prompt might, and a broken mid-operation state (partial auth
switch, a crashed process holding a stale identity) can silently persist
into the *next* unrelated task.

`gh-account` exists to make "wrong identity" and "stuck mid-switch" both
structurally hard to hit, rather than something you have to remember to
check for.

## What makes it different

Compared to other multi-account `gh` tools, `gh-account` is built around a
few non-negotiable guarantees rather than convenience UX:

- **Fail-closed, not fail-open.** Every check defaults to refusing the
  operation on ambiguity — ownership mismatches, symlinked config paths,
  unsafe permissions/ACLs, an unexpected `XDG_CONFIG_HOME`/`GH_CONFIG_DIR` —
  rather than proceeding and hoping.
- **Guaranteed restore.** `exec`/`git-exec` switch the active account under a
  per-UID lock, run the requested command, and restore the prior account
  afterward — including on crash or signal, verified, not assumed.
- **Atomic config mutation.** Git identity/config changes go through a
  whole-file transaction journal, so an interrupted write can be recovered or
  cleanly refused on the next run instead of leaving a half-written config.
- **Secret-free, agent-safe diagnostics.** `doctor` is read-only and reports
  findings (misconfiguration, unsafe permissions, auth state) without ever
  emitting a token, credential, or anything else unsafe for an AI agent to
  read back into its own context.
- **A real audit trail.** Every mutating operation can emit a structured,
  secret-scrubbed JSONL event, with an optional analyzer (`insights`) for
  post-hoc pattern review.
- **Actually tested.** A ~3,200-line hermetic test suite (500+ assertions)
  drives the tool against faked `gh`/`git`/`ps`/`stat`/`lockf` binaries in an
  isolated `HOME` for every case — no test ever touches a real account.

## Installation

### As a standalone script

```bash
curl -fsSL https://raw.githubusercontent.com/securiace-dev/gh-account/main/gh-account \
  -o ~/.local/bin/gh-account
chmod +x ~/.local/bin/gh-account
```

### As a `gh` extension

```bash
gh extension install securiace-dev/gh-account
# then: gh account <subcommand> ...
```

**Requirements:** POSIX `/bin/sh`, the GitHub CLI (`gh`), Git, and `jq`.
Tested on macOS and Linux.

## Usage

```
gh-account list
gh-account current [REPO]
gh-account doctor [REPO] [--account USER] [--deep] [--json]
gh-account preflight USER [REPO] [--required-scopes LIST] [--json]
gh-account repair USER [REPO] [--dry-run] [--interactive]
gh-account reauth USER [--scopes LIST] [--json]
gh-account onboard USER [REPO] [--scopes LIST]
gh-account insights [ANALYZER_OPTIONS]
gh-account bind USER [REPO]
gh-account use USER [REPO]
gh-account auto [REPO]
gh-account exec USER [--] GH_ARGUMENTS...
gh-account git-exec USER REPO -- {fetch|push|ls-remote} origin [GIT_ARGUMENTS...]
```

- `doctor` is read-only and emits secret-free findings for humans or agents.
- `preflight` proves the routed account identity and restores the prior
  account afterward.
- `repair` applies deterministic Git configuration fixes; `--interactive` may
  trigger a reauth.
- `reauth`/`onboard` use native GitHub CLI browser/device authorization
  explicitly — this tool never handles credentials directly.
- `exec` temporarily switches under a per-user lock, runs `gh`, and verifies
  restore before returning.
- `git-exec` does the same for an HTTPS origin Git transport operation
  (`fetch`/`push`/`ls-remote`).

### Typical agent-facing pattern

```bash
# Read-only, safe to run unattended for diagnosis:
gh-account doctor --json

# Route a specific mutating action through the right identity, with a
# guaranteed restore of whatever was active before:
gh-account exec work-account -- pr create --title "..." --body-file notes.md
```

## Audit trail

Mutating commands append structured JSONL events to
`~/.local/state/gh-account/events.jsonl` by default (rotated automatically
past 5 MiB). Run `gh-account insights` for a pattern-matched summary of
recent events; `gh-account insights --json` for machine-readable output.

If you keep a broader personal audit log (e.g. `~/.ai-audit`), set
`AIAUDIT_HOME` to point `insights` at that root instead of the bundled
analyzer's own event spool.

## Security model

- Distrusts inherited environment for anything security-relevant:
  `XDG_CONFIG_HOME`/`GH_CONFIG_DIR` overrides are detected and reported, but
  never trusted for the actual config path used.
- Every filesystem location it writes to is validated end-to-end from `$HOME`
  down — ownership, symlink status, permission bits, ACLs — before use, not
  just at creation time.
- `list`, `current`, `doctor`, and `insights` are the only commands that
  don't require a fully validated GitHub CLI context; everything else fails
  closed on an unsafe posture (`EXIT_CONFIG`, `EXIT_NOPERM`) before touching
  any account state.

## Running the test suite

```bash
tests/run.sh
```

Requires `bash`, `jq`; `shellcheck` is used opportunistically if installed.
Every test runs against an isolated `HOME` with faked `gh`/`git`/system
binaries — nothing touches your real GitHub accounts or Git config.

## License

MIT — see [LICENSE](LICENSE).
