#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/spar/commands/spar-ready-resolve.sh"
chk(){ if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }

# Output is: <mode>\t<reviewer|empty>\t<unattended>\t<spec>
chk "plain spec path" "$(printf 'per-task\t\tfalse\ttrue\tdocs/superpowers/specs/x.md')" "$(bash "$R" "docs/superpowers/specs/x.md")"
chk "whole flag" "$(printf 'whole\t\tfalse\ttrue\tbuild the thing')" "$(bash "$R" "--whole -- build the thing")"
chk "reviewer passthrough" "$(printf 'per-task\tclaude\tfalse\ttrue\tfix it')" "$(bash "$R" "--reviewer claude -- fix it")"
chk "whole + reviewer either order" "$(printf 'whole\tcodex\tfalse\ttrue\tgo')" "$(bash "$R" "--reviewer codex --whole -- go")"
chk "bad reviewer errors" "error" "$(bash "$R" "--reviewer bogus -- x" 2>&1; echo)"
chk "empty spec errors" "error" "$(bash "$R" "" 2>&1; echo)"
chk "dashed spec after --" "$(printf 'per-task\t\tfalse\ttrue\t--weird-spec-name')" "$(bash "$R" "-- --weird-spec-name")"

# Phase 5: --unattended threads through the ready resolver.
chk "unattended default false" "$(printf 'per-task\t\tfalse\ttrue\tspec.md')" "$(bash "$R" "spec.md")"
chk "unattended alone" "$(printf 'per-task\t\ttrue\ttrue\tspec.md')" "$(bash "$R" "--unattended -- spec.md")"
chk "unattended with whole + reviewer" "$(printf 'whole\tcodex\ttrue\ttrue\tspec.md')" "$(bash "$R" "--whole --unattended --reviewer codex -- spec.md")"
chk "unattended after reviewer" "$(printf 'per-task\tclaude\ttrue\ttrue\tspec.md')" "$(bash "$R" "--reviewer claude --unattended -- spec.md")"
chk "duplicate unattended errors" "error" "$(bash "$R" "--unattended --unattended spec.md" 2>&1; echo)"

# ── Phase 9: --no-plan-review threads through ───────────────────────────────
# Output is: <mode>\t<reviewer|empty>\t<unattended>\t<plan_review>\t<spec>
chk "plan review is on by default" \
  "$(printf 'per-task\t\tfalse\ttrue\tdocs/x.md')" "$(bash "$R" "docs/x.md")"
chk "--no-plan-review turns it off" \
  "$(printf 'per-task\t\tfalse\tfalse\tdocs/x.md')" "$(bash "$R" "--no-plan-review -- docs/x.md")"
chk "it composes with the other flags in any order" \
  "$(printf 'whole\tcodex\ttrue\tfalse\tgo')" \
  "$(bash "$R" "--no-plan-review --whole --reviewer codex --unattended -- go")"
chk "and in the reverse order" \
  "$(printf 'whole\tcodex\ttrue\tfalse\tgo')" \
  "$(bash "$R" "--unattended --reviewer codex --whole --no-plan-review -- go")"
chk "twice is an error" "error" "$(bash "$R" "--no-plan-review --no-plan-review -- x" 2>&1; echo)"
chk "the flag does not survive into the spec text" "absent" \
  "$(bash "$R" "--no-plan-review -- build it" | cut -f5 | grep -qF -- '--no-plan-review' && echo present || echo absent)"
chk "the spec is still the last field" "build it" \
  "$(bash "$R" "--no-plan-review -- build it" | cut -f5)"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
