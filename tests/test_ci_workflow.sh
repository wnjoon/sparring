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

# Assert the EXECUTION step specifically, not the whole file: the
# `tests/test_*.sh` glob also appears in the syntax-check step, and `exit 1`
# appears in two earlier steps, so whole-file checks would stay green even if
# the "Run every suite" step were deleted and CI stopped at `bash -n`.
RUN_STEP="$(awk '/name: Run every suite/,0' "$WF")"
chk "the run step exists" "Run every suite" "$RUN_STEP"
chk "the run step iterates every suite by glob" 'tests/test_*.sh' "$RUN_STEP"
chk "the run step actually executes each suite" 'if bash "$t"; then' "$RUN_STEP"
chk "the run step records a suite failure" "rc=1" "$RUN_STEP"
chk "the run step fails the job" "exit 1" "$RUN_STEP"

# The workflow must not silently swallow failures.
if printf '%s' "$WF_TEXT" | grep -q 'continue-on-error: *true'; then
  echo "FAIL: workflow tolerates failing suites"; FAIL=$((FAIL+1))
else
  echo "PASS: workflow does not tolerate failing suites"; PASS=$((PASS+1))
fi

# Sanity: no suite silently disappeared. Asserted directly rather than through
# `chk` — a sentinel compared with `grep -qF` is a trap here, since a failure
# message like "only 18" contains the digits of most sentinels.
COUNT=$(ls "$ROOT"/tests/test_*.sh 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT" -ge 19 ]; then
  echo "PASS: no suite went missing (found $COUNT)"; PASS=$((PASS+1))
else
  echo "FAIL: suites went missing (found $COUNT, expected at least 19)"; FAIL=$((FAIL+1))
fi

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
