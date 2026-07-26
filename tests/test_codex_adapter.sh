#!/usr/bin/env bash
# Pure-bash tests for adapters/codex/install.sh and its hooks.json output.
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/adapters/codex/install.sh"

chk() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent() { if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }

fresh() { d=$(mktemp -d); cd "$d" || exit 1; cd "$(pwd -P)" || exit 1; }

# 1. fresh install registers both events at absolute paths
fresh
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
OUT="$(cat hooks.json 2>/dev/null)"
chk "valid json" "hooks" "$OUT"
python3 -c "import json;json.load(open('hooks.json'))" 2>/dev/null \
  && { echo "PASS: parses as json"; PASS=$((PASS+1)); } \
  || { echo "FAIL: parses as json"; FAIL=$((FAIL+1)); }
chk "Stop registered" '"Stop"' "$OUT"
chk "Stop runs the dispatcher, not the engine" "stop-fight.sh" "$OUT"
chk_absent "Stop does not run the inner engine directly" "hooks/stop-hook.sh" "$OUT"
chk "SessionStart registered" "session-start.sh" "$OUT"
chk "absolute plugin path" "$ROOT/plugins/spar" "$OUT"

# 2. idempotent — a second run must not change a byte (hook trust would reset)
BEFORE=$(cat hooks.json)
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
chk "second run changes nothing" "$BEFORE" "$(cat hooks.json)"

# 3. merges into an existing hooks.json without dropping other events
fresh
cat > hooks.json <<'EOF'
{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }
EOF
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
OUT="$(cat hooks.json)"
chk "pre-existing event preserved" "echo mine" "$OUT"
chk "our Stop added alongside" "stop-fight.sh" "$OUT"

# 4. refuses to write through a symlink
fresh
outside=$(mktemp); printf '{}\n' > "$outside"
ln -s "$outside" hooks.json
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
chk "symlink target → exit 3" "3" "$?"
chk "symlink target untouched" "{}" "$(cat "$outside")"

# 5. the installer tells the user about the one-time trust prompt
fresh
OUT="$(bash "$INSTALL" --target ./hooks.json 2>&1)"
chk "mentions the trust prompt" "trust" "$OUT"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
