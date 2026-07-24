#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/plugins/spar/hooks/session-start.sh"
J="$ROOT/plugins/spar/hooks/hooks.json"
chk() { if printf '%s' "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_empty() { if [ -z "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1"; echo "  want:(empty)"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
run() { printf '%s' "$1" | bash "$H"; }
fresh() { d=$(mktemp -d); cd "$d" || exit 1; mkdir -p reviews; }

# 1. no queue → silent, exit 0
fresh
OUT="$(run '{"source":"startup"}')"; RC=$?
chk_empty "no queue → no output" "" "$OUT"
chk "no queue → exit 0" "0" "$RC"

# 2. queue with two entries → announces the count and the path
fresh
printf '# sparring — pending\n\n## id-a :: f | one\ntext\n\n## id-b :: g | two\ntext\n' > reviews/spar-pending.md
OUT="$(run '{"source":"startup"}')"
chk "announces additionalContext" "additionalContext" "$OUT"
chk "announces count 2" "2 design decision" "$OUT"
chk "points to the queue file" "reviews/spar-pending.md" "$OUT"
chk "valid json emitted" "hookSpecificOutput" "$OUT"

# 3. empty queue (no ## headings) → silent
fresh
printf '# sparring — pending\n\n(nothing pending)\n' > reviews/spar-pending.md
chk_empty "empty queue → no output" "" "$(run '{"source":"resume"}')"

# 4. symlinked queue → silent, never followed
fresh
outside=$(mktemp); printf '## x :: y\n' > "$outside"
ln -s "$outside" reviews/spar-pending.md
chk_empty "symlinked queue → no output" "" "$(run '{"source":"startup"}')"

# 5. hooks.json registers the SessionStart hook and stays valid json
jq -e . "$J" >/dev/null && { echo "PASS: hooks.json valid"; PASS=$((PASS+1)); } \
  || { echo "FAIL: hooks.json valid"; FAIL=$((FAIL+1)); }
chk "SessionStart command registered" "session-start.sh" "$(jq -r '.hooks.SessionStart[].hooks[].command' "$J")"
chk "Stop hook untouched" "stop-weighin.sh" "$(jq -r '.hooks.Stop[].hooks[].command' "$J")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
