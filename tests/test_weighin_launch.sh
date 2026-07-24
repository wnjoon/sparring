#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/plugins/spar/commands/spar-weighin-launch.sh"
LIB="$ROOT/plugins/spar/commands/spar-weighin-lib.sh"; . "$LIB"
chk(){ if echo "$3" | grep -qE "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want~:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
eqchk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); cd "$TMP"; git init -q; git commit -q --allow-empty -m init
mkdir -p .claude
ST=".claude/spar-weighin.local.md"
printf -- '---\nactive: true\nphase: running\nmode: per-task\nreviewer: codex\nplan_path: p.md\nworktree: %s\ntasks: 2\ncurrent: 1\ncurrent_review_id:\n---\n1\tpending\tTask 1: Alpha\n' "$TMP" > "$ST"
printf 'Implement Task 1: Alpha\nDo the alpha thing.\n' > .claude/task.txt

bash "$L" "$ST" .claude/task.txt

SPAR=".claude/spar.local.md"
[ -f "$SPAR" ] && echo "PASS: spar state written" && PASS=$((PASS+1)) || { echo "FAIL: spar state written"; FAIL=$((FAIL+1)); }
chk "review_id format" '^review_id: [0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' "$(grep '^review_id:' "$SPAR")"
eqchk "phase task" "task" "$(sed -n 's/^phase: //p' "$SPAR" | head -1)"
eqchk "round 0" "0" "$(sed -n 's/^round: //p' "$SPAR" | head -1)"
eqchk "reviewer codex" "codex" "$(sed -n 's/^reviewer: //p' "$SPAR" | head -1)"
chk "task body carried" "Do the alpha thing" "$(cat "$SPAR")"
# weighin recorded the id
RID="$(grep '^review_id:' "$SPAR" | sed 's/^review_id: //')"
eqchk "weighin current_review_id set" "$RID" "$(wgn_field current_review_id "$ST")"

# Phase 5: default (no unattended field in weighin state) → task state false.
eqchk "task state unattended defaults false" "false" "$(sed -n 's/^unattended: //p' "$SPAR" | head -1)"

# Phase 5: unattended: true in weighin state propagates into the launched task.
# (wgn_set_field only replaces an existing key, so insert the field explicitly.)
sed -i '' 's/^reviewer: codex/reviewer: codex\nunattended: true/' "$ST" 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: codex\nunattended: true/' "$ST"
rm -f "$SPAR"
bash "$L" "$ST" .claude/task.txt
eqchk "task state marked unattended true" "true" "$(sed -n 's/^unattended: //p' "$SPAR" | head -1)"

# Phase 5: a malformed unattended value in weighin state defaults to false.
sed -i '' 's/^unattended: true/unattended: invalid/' "$ST" 2>/dev/null \
  || sed -i 's/^unattended: true/unattended: invalid/' "$ST"
rm -f "$SPAR"
bash "$L" "$ST" .claude/task.txt
eqchk "malformed unattended → task state false" "false" "$(sed -n 's/^unattended: //p' "$SPAR" | head -1)"

cd /; rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
