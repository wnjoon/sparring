#!/usr/bin/env bash
# Guards the CI wiring: every tests/test_*.sh suite must actually be run by the
# workflow. A suite that exists but is never executed is worse than no CI.
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/tests.yml"

chk() { # $1=desc $2=expected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$WF" ]; then
  echo "FAIL: workflow missing ($WF)"; echo; echo "PASS=0 FAIL=1"; exit 1
fi
WF_TEXT="$(cat "$WF")"

chk "runs on push" "push:" "$WF_TEXT"
chk "runs on pull requests" "pull_request:" "$WF_TEXT"
chk "runs on linux" "ubuntu-latest" "$WF_TEXT"
chk "runs on macos" "macos-latest" "$WF_TEXT"
chk "does not install a reviewer CLI" "no-reviewer-cli" "$WF_TEXT"

# Every suite must be reachable from the workflow's runner loop. The loop globs
# tests/test_*.sh, so assert the glob is there rather than listing each file.
chk "iterates every suite by glob" 'tests/test_*.sh' "$WF_TEXT"
chk "fails the job when a suite fails" "exit 1" "$WF_TEXT"

# The workflow must not silently swallow failures.
if printf '%s' "$WF_TEXT" | grep -q 'continue-on-error: *true'; then
  echo "FAIL: workflow tolerates failing suites"; FAIL=$((FAIL+1))
else
  echo "PASS: workflow does not tolerate failing suites"; PASS=$((PASS+1))
fi

# Sanity: the suites the workflow will pick up are all executable-by-bash files.
COUNT=$(ls "$ROOT"/tests/test_*.sh 2>/dev/null | wc -l | tr -d ' ')
chk "at least the suites known today are present" "1" \
  "$([ "$COUNT" -ge 19 ] && echo 1 || echo "only $COUNT")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
