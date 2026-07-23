#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/plugins/spar/commands/spar-weighin-ingest.sh"
LIB="$ROOT/plugins/spar/commands/spar-weighin-lib.sh"; . "$LIB"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); PLAN="$TMP/plan.md"; ST="$TMP/state.md"
cat > "$PLAN" <<'EOF'
# X Plan
### Task 1: Alpha
- [ ] Step 1
### Task 2: Beta component
- [ ] Step 1
### Task 3: Gamma
EOF
printf -- '---\nactive: true\nphase: plan\nmode: per-task\nreviewer: codex\nplan_path: %s\nworktree: /tmp/wt\ntasks: 0\ncurrent: 1\ncurrent_review_id:\n---\n' "$PLAN" > "$ST"

bash "$I" "$PLAN" per-task "$ST"
chk "counts 3 tasks" "3" "$(wgn_field tasks "$ST")"
chk "phase running" "running" "$(wgn_field phase "$ST")"
chk "task 2 heading" "Task 2: Beta component" "$(wgn_task_line 2 "$ST" | cut -f3)"
chk "task 3 status" "pending" "$(wgn_task_line 3 "$ST" | cut -f2)"

# whole mode → single synthetic task
printf -- '---\nactive: true\nphase: plan\nmode: whole\nreviewer: codex\nplan_path: %s\nworktree: /tmp/wt\ntasks: 0\ncurrent: 1\ncurrent_review_id:\n---\n' "$PLAN" > "$ST"
bash "$I" "$PLAN" whole "$ST"
chk "whole → 1 task" "1" "$(wgn_field tasks "$ST")"
chk "whole heading" "WHOLE PLAN" "$(wgn_task_line 1 "$ST" | cut -f3)"

rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
