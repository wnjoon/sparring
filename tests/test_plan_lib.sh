#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/spar/commands/spar-plan-lib.sh"
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
branch: /tmp/wt
tasks: 2
current: 1
current_review_id:
---
1	pending	Task 1: Alpha
2	pending	Task 2: Beta
EOF

chk "field phase" "running" "$(plan_field phase "$ST")"
chk "field tasks" "2" "$(plan_field tasks "$ST")"
chk "empty review_id" "" "$(plan_field current_review_id "$ST")"
chk "task line 2 heading" "Task 2: Beta" "$(plan_task_line 2 "$ST" | cut -f3)"

plan_set_field current 2 "$ST"
chk "set current" "2" "$(plan_field current "$ST")"
plan_set_field current_review_id 20260724-101010-abc123 "$ST"
chk "set review_id" "20260724-101010-abc123" "$(plan_field current_review_id "$ST")"

plan_set_task_status 1 done "$ST"
chk "task 1 done" "done" "$(plan_task_line 1 "$ST" | cut -f2)"
chk "task 2 untouched" "pending" "$(plan_task_line 2 "$ST" | cut -f2)"

# plan_set_field is a pure replace: a key that is not already there stays absent.
plan_set_field author codex "$ST"
chk "set_field does not create a missing key" "" "$(plan_field author "$ST")"

# plan_put_field is insert-or-replace, for fields whose absence means "unguarded"
# rather than "the default" — the Codex seat's author and owning session.
plan_put_field author codex "$ST"
chk "put_field inserts a missing key" "codex" "$(plan_field author "$ST")"
plan_put_field author claude "$ST"
chk "put_field replaces an existing key" "claude" "$(plan_field author "$ST")"
chk "put_field inserted only once" "1" "$(grep -c '^author: ' "$ST")"

# The task table below the frontmatter must survive both paths.
chk "task table intact after put_field" "Task 2: Beta" "$(plan_task_line 2 "$ST" | cut -f3)"
chk "task 1 status intact after put_field" "done" "$(plan_task_line 1 "$ST" | cut -f2)"
chk "frontmatter still closed exactly twice" "2" "$(grep -c '^---$' "$ST")"
chk "existing fields untouched" "claude" "$(plan_field author "$ST")"
chk "put_field kept phase" "running" "$(plan_field phase "$ST")"

# The inserted key must land INSIDE the frontmatter, not after the table — the
# readers stop at the second '---'.
plan_put_field owner_session 019f-abc "$ST"
chk "put_field inserts inside the frontmatter" "019f-abc" "$(plan_field owner_session "$ST")"
chk "put_field did not append below the table" "" \
  "$(awk '/^---$/{c++} c>=2 && /^owner_session: /{print "leaked"}' "$ST")"

# A state file with frontmatter and no task table yet (spar-ready writes one).
ST2="$TMP/fresh.md"
printf -- '---\nactive: true\nphase: planned\n---\n' > "$ST2"
plan_put_field owner_session sess-1 "$ST2"
chk "put_field works with no task table" "sess-1" "$(plan_field owner_session "$ST2")"
chk "no-table state still closed twice" "2" "$(grep -c '^---$' "$ST2")"

rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
