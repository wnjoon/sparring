#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
J="$ROOT/plugins/spar/hooks/hooks.json"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }
jq -e . "$J" >/dev/null && { echo "PASS: valid json"; PASS=$((PASS+1)); } || { echo "FAIL: valid json"; FAIL=$((FAIL+1)); }
CMDS="$(jq -r '.hooks.Stop[].hooks[].command' "$J")"
chk "exactly one Stop command" "1" "$(echo "$CMDS" | grep -c .)"
chk "the Stop command is the dispatcher" "stop-weighin.sh" "$(echo "$CMDS" | sed -n '1p' | sed 's#.*/##')"
# the dispatcher must call spar's real hook by its default path
grep -q 'hooks/stop-hook.sh' "$ROOT/plugins/spar/hooks/stop-weighin.sh" && { echo "PASS: dispatcher references stop-hook.sh"; PASS=$((PASS+1)); } || { echo "FAIL: dispatcher references stop-hook.sh"; FAIL=$((FAIL+1)); }
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
