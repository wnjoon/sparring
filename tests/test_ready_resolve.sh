#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/spar/commands/spar-ready-resolve.sh"
chk(){ if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }

# Output is: <mode>\t<reviewer|empty>\t<unattended>\t<plan_review>\t<verify_spec>\t<spec>
chk "plain spec path" "$(printf 'per-task\t\tfalse\ttrue\tfalse\tdocs/superpowers/specs/x.md')" "$(bash "$R" "docs/superpowers/specs/x.md")"
chk "whole flag" "$(printf 'whole\t\tfalse\ttrue\tfalse\tbuild the thing')" "$(bash "$R" "--whole -- build the thing")"
chk "reviewer passthrough" "$(printf 'per-task\tclaude\tfalse\ttrue\tfalse\tfix it')" "$(bash "$R" "--reviewer claude -- fix it")"
chk "whole + reviewer either order" "$(printf 'whole\tcodex\tfalse\ttrue\tfalse\tgo')" "$(bash "$R" "--reviewer codex --whole -- go")"
chk "bad reviewer errors" "error" "$(bash "$R" "--reviewer bogus -- x" 2>&1; echo)"
chk "empty spec errors" "error" "$(bash "$R" "" 2>&1; echo)"
chk "dashed spec after --" "$(printf 'per-task\t\tfalse\ttrue\tfalse\t--weird-spec-name')" "$(bash "$R" "-- --weird-spec-name")"

# Phase 5: --unattended threads through the ready resolver.
chk "unattended default false" "$(printf 'per-task\t\tfalse\ttrue\tfalse\tspec.md')" "$(bash "$R" "spec.md")"
chk "unattended alone" "$(printf 'per-task\t\ttrue\ttrue\tfalse\tspec.md')" "$(bash "$R" "--unattended -- spec.md")"
chk "unattended with whole + reviewer" "$(printf 'whole\tcodex\ttrue\ttrue\tfalse\tspec.md')" "$(bash "$R" "--whole --unattended --reviewer codex -- spec.md")"
chk "unattended after reviewer" "$(printf 'per-task\tclaude\ttrue\ttrue\tfalse\tspec.md')" "$(bash "$R" "--reviewer claude --unattended -- spec.md")"
chk "duplicate unattended errors" "error" "$(bash "$R" "--unattended --unattended spec.md" 2>&1; echo)"

# ── Phase 9: --no-plan-review threads through ───────────────────────────────
# Output is: <mode>\t<reviewer|empty>\t<unattended>\t<plan_review>\t<verify_spec>\t<spec>
chk "plan review is on by default" \
  "$(printf 'per-task\t\tfalse\ttrue\tfalse\tdocs/x.md')" "$(bash "$R" "docs/x.md")"
chk "--no-plan-review turns it off" \
  "$(printf 'per-task\t\tfalse\tfalse\tfalse\tdocs/x.md')" "$(bash "$R" "--no-plan-review -- docs/x.md")"
chk "it composes with the other flags in any order" \
  "$(printf 'whole\tcodex\ttrue\tfalse\tfalse\tgo')" \
  "$(bash "$R" "--no-plan-review --whole --reviewer codex --unattended -- go")"
chk "and in the reverse order" \
  "$(printf 'whole\tcodex\ttrue\tfalse\tfalse\tgo')" \
  "$(bash "$R" "--unattended --reviewer codex --whole --no-plan-review -- go")"
chk "twice is an error" "error" "$(bash "$R" "--no-plan-review --no-plan-review -- x" 2>&1; echo)"
chk "the flag does not survive into the spec text" "absent" \
  "$(bash "$R" "--no-plan-review -- build it" | cut -f6 | grep -qF -- '--no-plan-review' && echo present || echo absent)"
chk "the spec is still the last field" "build it" \
  "$(bash "$R" "--no-plan-review -- build it" | cut -f6)"

# v0.10.0: optional pre-plan spec verification.
chk "spec verification is off by default" "false" "$(bash "$R" "docs/x.md" | cut -f5)"
chk "--verify-spec turns it on" \
  "$(printf 'per-task\t\tfalse\ttrue\ttrue\tdocs/x.md')" "$(bash "$R" "--verify-spec -- docs/x.md")"
chk "--no-verify-spec is explicit off" \
  "$(printf 'per-task\t\tfalse\ttrue\tfalse\tdocs/x.md')" "$(bash "$R" "--no-verify-spec -- docs/x.md")"
chk "spec verification composes with existing flags" \
  "$(printf 'whole\tclaude\ttrue\tfalse\ttrue\tgo')" \
  "$(bash "$R" "--verify-spec --whole --unattended --no-plan-review --reviewer claude -- go")"
chk "duplicate --verify-spec errors" "error" "$(bash "$R" "--verify-spec --verify-spec -- x" 2>&1; echo)"
chk "conflicting spec verification flags error" "error" "$(bash "$R" "--verify-spec --no-verify-spec -- x" 2>&1; echo)"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
