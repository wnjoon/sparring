#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/spar/commands/spar-weighin-resolve.sh"
chk(){ if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }

# Output is: <mode>\t<reviewer|empty>\t<unattended>\t<spec>
chk "plain spec path" "$(printf 'per-task\t\tfalse\tdocs/superpowers/specs/x.md')" "$(bash "$R" "docs/superpowers/specs/x.md")"
chk "whole flag" "$(printf 'whole\t\tfalse\tbuild the thing')" "$(bash "$R" "--whole -- build the thing")"
chk "reviewer passthrough" "$(printf 'per-task\tclaude\tfalse\tfix it')" "$(bash "$R" "--reviewer claude -- fix it")"
chk "whole + reviewer either order" "$(printf 'whole\tcodex\tfalse\tgo')" "$(bash "$R" "--reviewer codex --whole -- go")"
chk "bad reviewer errors" "error" "$(bash "$R" "--reviewer bogus -- x" 2>&1; echo)"
chk "empty spec errors" "error" "$(bash "$R" "" 2>&1; echo)"
chk "dashed spec after --" "$(printf 'per-task\t\tfalse\t--weird-spec-name')" "$(bash "$R" "-- --weird-spec-name")"

# Phase 5: --unattended threads through the weigh-in resolver.
chk "unattended default false" "$(printf 'per-task\t\tfalse\tspec.md')" "$(bash "$R" "spec.md")"
chk "unattended alone" "$(printf 'per-task\t\ttrue\tspec.md')" "$(bash "$R" "--unattended -- spec.md")"
chk "unattended with whole + reviewer" "$(printf 'whole\tcodex\ttrue\tspec.md')" "$(bash "$R" "--whole --unattended --reviewer codex -- spec.md")"
chk "unattended after reviewer" "$(printf 'per-task\tclaude\ttrue\tspec.md')" "$(bash "$R" "--reviewer claude --unattended -- spec.md")"
chk "duplicate unattended errors" "error" "$(bash "$R" "--unattended --unattended spec.md" 2>&1; echo)"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
