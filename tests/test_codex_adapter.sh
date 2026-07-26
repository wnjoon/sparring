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

# 6. a planted symlink at the temp path must not be followed
# A predictable "<target>.tmp" lets an untrusted project point it at another file
# and have the installer truncate it.
fresh
outside=$(mktemp); printf 'PRECIOUS\n' > "$outside"
ln -s "$outside" ./hooks.json.tmp
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
chk "planted .tmp symlink → outside file untouched" "PRECIOUS" "$(cat "$outside")"
chk "planted .tmp symlink → target still written" "stop-fight.sh" "$(cat hooks.json 2>/dev/null)"
# the installer's own temp files must not survive either
chk_absent "no installer temp left behind" ".hooks.json." "$(ls -a . | tr '\n' ' ')"
rm -f "$outside"

# 7. our entries are removed surgically; a user's command in the same group stays
fresh
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
python3 - <<'PY'
import json
d = json.load(open('hooks.json'))
d['hooks']['Stop'][0]['hooks'].append({"type": "command", "command": "echo my-own-hook"})
json.dump(d, open('hooks.json', 'w'), indent=2)
PY
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
OUT="$(cat hooks.json)"
chk "reinstall keeps the user's command in our group" "my-own-hook" "$OUT"
chk "reinstall still registers our hook" "stop-fight.sh" "$OUT"
chk "our hook is registered exactly once" "1" \
  "$(grep -c 'stop-fight.sh' hooks.json | tr -d ' ')"

# 8. an unrelated group on the same event is preserved verbatim
fresh
cat > hooks.json <<'EOF'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo theirs" } ] } ] } }
EOF
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
chk "unrelated Stop group preserved" "echo theirs" "$(cat hooks.json)"

# 9. an invalid scope is a usage error even when --target is explicit
fresh
bash "$INSTALL" --scope bogus --target ./hooks.json >/dev/null 2>&1
chk "invalid scope with explicit target → exit 2" "2" "$?"
chk "invalid scope → nothing written" "absent" \
  "$([ -f hooks.json ] && echo present || echo absent)"

# 10. a plugin path containing a single quote produces valid, non-injecting shell
fresh
QROOT="$PWD/it's-here"
mkdir -p "$QROOT"
cp -R "$ROOT/adapters" "$QROOT/"
cp -R "$ROOT/plugins" "$QROOT/"
bash "$QROOT/adapters/codex/install.sh" --target ./hooks.json >/dev/null 2>&1
CMD="$(python3 -c "import json;print(json.load(open('hooks.json'))['hooks']['Stop'][0]['hooks'][0]['command'])" 2>/dev/null)"
# The literal path does NOT appear verbatim — shlex.quote escapes the apostrophe —
# so assert what actually matters: the shell's own word-splitting recovers the real
# script path, and the command parses.
ROUNDTRIP="$(CMD="$CMD" QROOT="$QROOT" python3 - <<'PY' 2>/dev/null
import os, shlex
want = os.path.join(os.environ["QROOT"], "plugins", "spar", "hooks", "stop-fight.sh")
parts = shlex.split(os.environ["CMD"])
print("yes" if parts and parts[-1] == want else "no: %r" % (parts[-1:],))
PY
)"
chk "apostrophe path → script path round-trips through shell quoting" "yes" "$ROUNDTRIP"
printf '%s\n' "$CMD" > ./cmd.sh
if bash -n ./cmd.sh 2>/dev/null; then echo "PASS: apostrophe path → command is valid shell"; PASS=$((PASS+1))
else echo "FAIL: apostrophe path → command is not valid shell"; echo "  cmd:$CMD"; FAIL=$((FAIL+1)); fi

# 11. a user command that merely lives under the plugin tree must survive
# Ownership is by resolved script path, not by "the plugin root appears somewhere",
# which would also claim a neighbour's command or a path sharing the prefix.
fresh
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
python3 - "$ROOT" <<'PY'
import json, os, sys
root = os.path.join(sys.argv[1], "plugins", "spar")
d = json.load(open('hooks.json'))
d['hooks']['Stop'].append({"hooks": [
    {"type": "command", "command": f"echo {root}/hooks/not-ours.sh"},
]})
d['hooks']['Stop'].append({"hooks": [
    {"type": "command", "command": f"{root}-other/hooks/stop-fight.sh"},
]})
json.dump(d, open('hooks.json', 'w'), indent=2)
PY
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
OUT="$(cat hooks.json)"
chk "neighbour command under the plugin tree survives" "not-ours.sh" "$OUT"
chk "same-prefix path is not claimed as ours" "spar-other/hooks/stop-fight.sh" "$OUT"

# 12. an explicitly empty --target is a usage error, never the user default
fresh
HOME="$PWD/fakehome" CODEX_HOME="$PWD/fakecodex" bash "$INSTALL" --target "" >/dev/null 2>&1
chk "empty --target → exit 2" "2" "$?"
chk "empty --target → user config untouched" "absent" \
  "$([ -f "$PWD/fakecodex/hooks.json" ] && echo present || echo absent)"

# 13. default user scope resolves to CODEX_HOME, else \$HOME/.codex
fresh
HOME="$PWD/fakehome" CODEX_HOME="$PWD/fakecodex" bash "$INSTALL" >/dev/null 2>&1
chk "default scope → CODEX_HOME/hooks.json" "present" \
  "$([ -f "$PWD/fakecodex/hooks.json" ] && echo present || echo absent)"
chk "default scope → registers our hook" "stop-fight.sh" \
  "$(cat "$PWD/fakecodex/hooks.json" 2>/dev/null)"

fresh
HOME="$PWD/fakehome" env -u CODEX_HOME bash "$INSTALL" >/dev/null 2>&1
chk "no CODEX_HOME → \$HOME/.codex/hooks.json" "present" \
  "$([ -f "$PWD/fakehome/.codex/hooks.json" ] && echo present || echo absent)"

# 14. project scope writes .codex/hooks.json in the working directory
fresh
HOME="$PWD/fakehome" CODEX_HOME="$PWD/fakecodex" bash "$INSTALL" --scope project >/dev/null 2>&1
chk "project scope → ./.codex/hooks.json" "present" \
  "$([ -f .codex/hooks.json ] && echo present || echo absent)"
chk "project scope → user config untouched" "absent" \
  "$([ -f "$PWD/fakecodex/hooks.json" ] && echo present || echo absent)"

# 15. mentioning our script is not invoking it
fresh
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
python3 - "$ROOT" <<'MENTION'
import json, os, sys
script = os.path.join(sys.argv[1], "plugins", "spar", "hooks", "stop-fight.sh")
d = json.load(open("hooks.json"))
d["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": f"echo {script}"}]})
json.dump(d, open("hooks.json", "w"), indent=2)
MENTION
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
chk "a command that only NAMES our script survives" "echo /" "$(cat hooks.json)"
chk "our hook still registered exactly once" "1" \
  "$(grep -c 'CLAUDE_PLUGIN_ROOT=.*stop-fight.sh' hooks.json | tr -d ' ')"

# 16. a symlinked PARENT must be refused, not written through
fresh
outside=$(mktemp -d)
ln -s "$outside" ./link
bash "$INSTALL" --target ./link/hooks.json >/dev/null 2>&1
chk "symlinked parent → exit 3" "3" "$?"
chk "symlinked parent → nothing written outside" "absent" \
  "$([ -f "$outside/hooks.json" ] && echo present || echo absent)"
rm -rf "$outside"

# 17. shapes we cannot merge are refused, never mangled
fresh
printf '{"hooks": "oops"}\n' > hooks.json
B="$(cat hooks.json)"
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
chk "non-object hooks → exit 3" "3" "$?"
chk "non-object hooks → file byte-identical" "$B" "$(cat hooks.json)"

fresh
printf '{"hooks": {"Stop": "echo x"}}\n' > hooks.json
B="$(cat hooks.json)"
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
chk "non-array event → exit 3" "3" "$?"
chk "non-array event → file byte-identical" "$B" "$(cat hooks.json)"
chk_absent "non-array event → never exploded into characters" '"e",' "$(cat hooks.json)"

# 18. an absolute target under a symlinked parent is the user's own choice
# (the ancestor rule guards the untrusted project tree, i.e. relative paths)
fresh
real=$(mktemp -d); ln -s "$real" ./link
bash "$INSTALL" --target "$PWD/link/hooks.json" >/dev/null 2>&1
chk "absolute target under a symlinked parent → installs" "stop-fight.sh" \
  "$(cat "$real/hooks.json" 2>/dev/null)"
rm -rf "$real"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
