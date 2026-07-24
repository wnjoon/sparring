#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/spar/commands/spar-weighin-lib.sh"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }
. "$LIB"

TMP=$(mktemp -d); ST="$TMP/state.md"
cat > "$ST" <<'EOF'
---
active: true
phase: running
mode: per-task
reviewer: codex
plan_path: docs/superpowers/plans/x.md
worktree: /tmp/wt
tasks: 2
current: 1
current_review_id:
---
1	pending	Task 1: Alpha
2	pending	Task 2: Beta
EOF

chk "field phase" "running" "$(wgn_field phase "$ST")"
chk "field tasks" "2" "$(wgn_field tasks "$ST")"
chk "empty review_id" "" "$(wgn_field current_review_id "$ST")"
chk "task line 2 heading" "Task 2: Beta" "$(wgn_task_line 2 "$ST" | cut -f3)"

wgn_set_field current 2 "$ST"
chk "set current" "2" "$(wgn_field current "$ST")"
wgn_set_field current_review_id 20260724-101010-abc123 "$ST"
chk "set review_id" "20260724-101010-abc123" "$(wgn_field current_review_id "$ST")"

wgn_set_task_status 1 done "$ST"
chk "task 1 done" "done" "$(wgn_task_line 1 "$ST" | cut -f2)"
chk "task 2 untouched" "pending" "$(wgn_task_line 2 "$ST" | cut -f2)"

rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
