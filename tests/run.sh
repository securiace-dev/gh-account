#!/usr/bin/env bash
# tests/run.sh — verification baseline for gh-account.
# Covers: shell syntax, shellcheck (opportunistic), and the full behavioral
# contract + insights-analyzer suites. All side effects are scoped to
# mktemp-created HOMEs; nothing outside is touched.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

printf '==> Step 1: shell syntax check\n'
for sh in "$repo_root/gh-account" "$repo_root"/scripts/*.sh "$repo_root"/tests/*.sh; do
  [ -f "$sh" ] || continue
  if ! bash -n "$sh" 2>&1; then
    printf 'FAIL: bash -n failed: %s\n' "$sh" >&2
    failures=$((failures + 1))
  fi
done
printf 'ok: shell syntax\n'

if command -v shellcheck >/dev/null 2>&1; then
  printf '==> Step 1b: shellcheck\n'
  if ! shellcheck -S warning "$repo_root/gh-account" "$repo_root"/scripts/*.sh; then
    printf 'FAIL: shellcheck reported warnings/errors\n' >&2
    failures=$((failures + 1))
  fi
  printf 'ok: shellcheck\n'
else
  printf 'notice: shellcheck not installed; skipping (install with: brew install shellcheck)\n'
fi

printf '==> Step 2: behavioral contract suite (tests/test-gh-account.sh)\n'
if ! sh "$repo_root/tests/test-gh-account.sh"; then
  printf 'FAIL: test-gh-account.sh reported failures\n' >&2
  failures=$((failures + 1))
fi

printf '==> Step 3: insights analyzer suite (tests/test-gh-account-insights.sh)\n'
if ! bash "$repo_root/tests/test-gh-account-insights.sh"; then
  printf 'FAIL: test-gh-account-insights.sh reported failures\n' >&2
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%d step(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nall checks passed\n'
