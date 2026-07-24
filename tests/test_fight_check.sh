#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/plugins/spar/commands/spar-fight-check.sh"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); PLAN="$TMP/plan.md"
cat > "$PLAN" <<'EOF'
### Task 1: A
- [ ] step a1
- [ ] step a2
### Task 2: B
- [ ] step b1
EOF
bash "$C" "$PLAN" 1
chk "task1 line1 checked" "- [x] step a1" "$(sed -n '2p' "$PLAN")"
chk "task1 line2 checked" "- [x] step a2" "$(sed -n '3p' "$PLAN")"
chk "task2 untouched" "- [ ] step b1" "$(sed -n '5p' "$PLAN")"

# whole (index 0) flips everything
cat > "$PLAN" <<'EOF'
### Task 1: A
- [ ] step a1
### Task 2: B
- [ ] step b1
EOF
bash "$C" "$PLAN" 0
chk "whole flips a1" "- [x] step a1" "$(sed -n '2p' "$PLAN")"
chk "whole flips b1" "- [x] step b1" "$(sed -n '4p' "$PLAN")"

rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
