#!/usr/bin/env bash
# Every test. No network. Linux only (on Windows: wsl.exe bash tests/run-all.sh).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
rc=0
for t in "$HERE"/test-*.sh; do
  echo "== $(basename "$t")"
  bash "$t" || rc=1
done
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck"
  shellcheck "$HERE"/../templates/stale-check.sh "$HERE"/*.sh && echo "  ok   shellcheck clean" || rc=1
else
  echo "  skip shellcheck not installed"
fi
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "SOMETHING FAILED"
exit "$rc"
