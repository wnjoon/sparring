#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/plugins/spar/commands/spar-fight-launch.sh"
LIB="$ROOT/plugins/spar/commands/spar-plan-lib.sh"; . "$LIB"
chk(){ if echo "$3" | grep -qE "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want~:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
eqchk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); cd "$TMP"; git init -q; git commit -q --allow-empty -m init
mkdir -p .claude
ST=".claude/spar-plan.local.md"
printf -- '---\nactive: true\nphase: running\nmode: per-task\nreviewer: codex\nplan_path: p.md\nbranch: %s\ntasks: 2\ncurrent: 1\ncurrent_review_id:\n---\n1\tpending\tTask 1: Alpha\n' "$TMP" > "$ST"
printf 'Implement Task 1: Alpha\nDo the alpha thing.\n' > .claude/task.txt

bash "$L" "$ST" .claude/task.txt

SPAR=".claude/spar.local.md"
[ -f "$SPAR" ] && echo "PASS: spar state written" && PASS=$((PASS+1)) || { echo "FAIL: spar state written"; FAIL=$((FAIL+1)); }
chk "review_id format" '^review_id: [0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' "$(grep '^review_id:' "$SPAR")"
eqchk "phase task" "task" "$(sed -n 's/^phase: //p' "$SPAR" | head -1)"
eqchk "round 0" "0" "$(sed -n 's/^round: //p' "$SPAR" | head -1)"
eqchk "reviewer codex" "codex" "$(sed -n 's/^reviewer: //p' "$SPAR" | head -1)"
chk "task body carried" "Do the alpha thing" "$(cat "$SPAR")"
# plan state recorded the id
RID="$(grep '^review_id:' "$SPAR" | sed 's/^review_id: //')"
eqchk "plan current_review_id set" "$RID" "$(plan_field current_review_id "$ST")"

# Phase 5: default (no unattended field in plan state) → task state false.
eqchk "task state unattended defaults false" "false" "$(sed -n 's/^unattended: //p' "$SPAR" | head -1)"

# Phase 5: unattended: true in plan state propagates into the launched task.
# (plan_set_field only replaces an existing key, so insert the field explicitly.)
sed -i '' 's/^reviewer: codex/reviewer: codex\nunattended: true/' "$ST" 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: codex\nunattended: true/' "$ST"
rm -f "$SPAR"
bash "$L" "$ST" .claude/task.txt
eqchk "task state marked unattended true" "true" "$(sed -n 's/^unattended: //p' "$SPAR" | head -1)"

# Phase 5: a malformed unattended value in plan state defaults to false.
sed -i '' 's/^unattended: true/unattended: invalid/' "$ST" 2>/dev/null \
  || sed -i 's/^unattended: true/unattended: invalid/' "$ST"
rm -f "$SPAR"
bash "$L" "$ST" .claude/task.txt
eqchk "malformed unattended → task state false" "false" "$(sed -n 's/^unattended: //p' "$SPAR" | head -1)"

# Phase 6: a Claude-hosted plan state carries neither field, and the launched
# task state must not invent them — absent author means the historical default.
eqchk "no author field in a claude-seat task state" "" "$(sed -n 's/^author: //p' "$SPAR" | head -1)"
eqchk "no owner_session field in a claude-seat task state" "" \
  "$(sed -n 's/^owner_session: //p' "$SPAR" | head -1)"

# Phase 6: the Codex seat's author + owning session travel with the PLAN, so every
# task the hook launches after the first still carries them.
mkfresh_state() { printf -- '---\nactive: true\nphase: running\nmode: per-task\nauthor: %s\nreviewer: claude\nowner_session: %s\nplan_path: p.md\ntasks: 2\ncurrent: 1\ncurrent_review_id:\n---\n1\tpending\tTask 1: Alpha\n' "$1" "$2" > "$ST"; }
mkfresh_state codex 019f9c5c-ea55-7510-b785-41801647fab1
rm -f "$SPAR"; bash "$L" "$ST" .claude/task.txt
eqchk "author propagated" "codex" "$(sed -n 's/^author: //p' "$SPAR" | head -1)"
eqchk "owner_session propagated" "019f9c5c-ea55-7510-b785-41801647fab1" \
  "$(sed -n 's/^owner_session: //p' "$SPAR" | head -1)"
eqchk "reviewer still honoured alongside them" "claude" "$(sed -n 's/^reviewer: //p' "$SPAR" | head -1)"

# An empty owner_session is "no gating", not a malformed field.
mkfresh_state codex ""
rm -f "$SPAR"; bash "$L" "$ST" .claude/task.txt
eqchk "empty owner_session → field omitted" "" "$(sed -n 's/^owner_session: //p' "$SPAR" | head -1)"
eqchk "author still written" "codex" "$(sed -n 's/^author: //p' "$SPAR" | head -1)"

# A bad author is refused rather than written: the hook treats an unknown author
# as an internal error and bypasses the loop, which silently drops enforcement.
mkfresh_state gpt ""
rm -f "$SPAR"; OUT="$(bash "$L" "$ST" .claude/task.txt 2>&1)"; RC=$?
eqchk "bad author → nonzero exit" "2" "$RC"
chk "bad author → says so" "bad author" "$OUT"
eqchk "bad author → no task state written" "absent" \
  "$([ -f "$SPAR" ] && echo present || echo absent)"

# A session id carrying a newline would inject an arbitrary state field.
mkfresh_state codex 'abc'
sed -i '' 's/^owner_session: abc/owner_session: abc def/' "$ST" 2>/dev/null \
  || sed -i 's/^owner_session: abc/owner_session: abc def/' "$ST"
rm -f "$SPAR"; OUT="$(bash "$L" "$ST" .claude/task.txt 2>&1)"; RC=$?
eqchk "malformed owner_session → nonzero exit" "2" "$RC"
chk "malformed owner_session → says so" "owner_session" "$OUT"

cd /; rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
