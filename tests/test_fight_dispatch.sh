#!/usr/bin/env bash
# Verifies /spar:fight's plan-vs-single-task dispatch is encoded in the command
# body. The dispatch lives inside fight.md (a slash-command body, not a
# standalone script), so this asserts each route's guard is present.
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/plugins/spar/commands/fight.md"
# Activation moved into a helper both seats call, so the guards that used to be
# in the command body are asserted there. Left pointed at fight.md they would
# assert that the duplicate is back.
A="$ROOT/plugins/spar/commands/spar-plan-activate.sh"
chk(){ if grep -qF "$2" "$F"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  missing: $2"; FAIL=$((FAIL+1)); fi; }
chka(){ if grep -qF "$2" "$A"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  missing: $2"; FAIL=$((FAIL+1)); fi; }

chk "detects a pending plan state" '.claude/spar-plan.local.md'
chk "refuses plan + task arg (safety rule)" 'a plan is ready — run /spar:fight with no task'
chk "hands a pending plan to the shared activator" 'spar-plan-activate.sh'
chka "refuses when already running" 'already being fought'
chka "requires phase planned before launch" 'not ready to fight (phase:'
chka "launches task 1 via fight-launch" 'spar-fight-launch.sh'
chk "errors on no plan and no task" 'nothing to fight'
chk "single-task path still guarded" 'a fight loop is already active'
chk "single-task worktree gate only after dispatch" 'No pending plan + a task arg'

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
