#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/spar/commands/spar-weighin-resolve.sh"
chk(){ if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }

chk "plain spec path" "per-task		docs/superpowers/specs/x.md" "$(bash "$R" "docs/superpowers/specs/x.md")"
chk "whole flag" "whole		build the thing" "$(bash "$R" "--whole -- build the thing")"
chk "reviewer passthrough" "per-task	claude	fix it" "$(bash "$R" "--reviewer claude -- fix it")"
chk "whole + reviewer either order" "whole	codex	go" "$(bash "$R" "--reviewer codex --whole -- go")"
chk "bad reviewer errors" "error" "$(bash "$R" "--reviewer bogus -- x" 2>&1; echo)"
chk "empty spec errors" "error" "$(bash "$R" "" 2>&1; echo)"
chk "dashed spec after --" "per-task		--weird-spec-name" "$(bash "$R" "-- --weird-spec-name")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
