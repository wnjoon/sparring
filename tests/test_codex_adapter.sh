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

# Every case runs in its own temp tree AND its own HOME/CODEX_HOME. Skills follow
# --scope, so a case that passes only --target still resolves a user-scope skills
# directory; without this the suite would write into the developer's real
# ~/.codex on every run. Individual cases still override these inline.
fresh() {
  d=$(mktemp -d); cd "$d" || exit 1; cd "$(pwd -P)" || exit 1
  export HOME="$PWD/.testhome" CODEX_HOME="$PWD/.testcodex"
}

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

# 19. the skills exist and carry the load-bearing loop rules
for sk in spar-fight spar-ready spar-cancel spar-report; do
  F="$ROOT/adapters/codex/skills/$sk/SKILL.md"
  chk "$sk skill exists" "present" "$([ -f "$F" ] && echo present || echo absent)"
done
FIGHT="$(cat "$ROOT/adapters/codex/skills/spar-fight/SKILL.md" 2>/dev/null)"
chk "fight skill forbids self-declared convergence" "Never write" "$FIGHT"
chk "fight skill states the response format" "FIXED" "$FIGHT"
chk "fight skill requires the liveness check" "spar-hook-live" "$FIGHT"
chk "fight skill claims the session" "owner_session" "$FIGHT"
chk "fight skill sets the author seat" "author: codex" "$FIGHT"
# The resolver grew a fifth field; a mirror that does not peel it silently
# receives the flag where the task text belongs.
chk "fight skill destructures plan_review" "SPAR_PLAN_REVIEW=" "$FIGHT"
chk "ready skill destructures plan_review" "RDY_PLAN_REVIEW=" \
  "$(cat "$ROOT/adapters/codex/skills/spar-ready/SKILL.md")"
READY="$(cat "$ROOT/adapters/codex/skills/spar-ready/SKILL.md")"
chk "ready skill captures the spec" "spar-plan-spec.txt" "$READY"
chk "ready skill records plan_review" "plan_review:" "$READY"
chk "ready skill records plan_review_id" "plan_review_id:" "$READY"
# Scoped to the authoring section: the path is in section 1's setup block either
# way, so a whole-document check would pass while section 2 still sent the author
# back to the mutable original and put the plan and the review on different specs.
chk "ready skill's authoring section reads the captured spec" ".claude/spar-plan-spec.txt" \
  "$(awk '/^## 2\. Write the plan/{f=1} f&&/^## 3\./{exit} f' \
       "$ROOT/adapters/codex/skills/spar-ready/SKILL.md")"
# Provenance is written at activation, so the direct Codex seat needs it too —
# the shared launcher covers only the plan path.
chk "fight skill records the reviewer build" "reviewer_version:" "$FIGHT"
chk "fight skill gates on the plan review" "spar-plan-review-check.sh" "$FIGHT"
# Presence is not order. The gate must precede the phase flip, or a refused plan
# is already `running` and the cancel skill is the only way out of it.
chk "and does so before flipping the phase" "yes" \
  "$(awk '/spar-plan-review-check\.sh/{c=NR} /plan_set_field phase running/{p=NR} END{print (c && p && c < p) ? "yes" : "no"}' \
     "$ROOT/adapters/codex/skills/spar-fight/SKILL.md")"
# plan_put_field, not plan_set_field: a plan prepared before this phase has no
# plan_review line, and a pure replace would silently record nothing.
chk "fight skill appends the override" "plan_put_field plan_review overridden" "$FIGHT"
chk "fight skill refuses when enforcement is unproven" "NOT be enforced" "$FIGHT"

# The marker must be checked for IDENTITY, not mere existence: one left by an
# earlier session outlives it, and adopting it would start an unenforced loop.
chk "fight skill compares the marker to this session" 'CODEX_THREAD_ID' "$FIGHT"
chk "fight skill rejects a stale marker" "is stale" "$FIGHT"

# It is the mirror of fight.md, not a sketch of it: the same dispatch, the same
# guards, the same helper scripts. A skill missing these silently drops a
# prepared plan on the floor, or reviews a dirty tree while claiming otherwise.
chk "fight skill dispatches a prepared plan" "spar-plan.local.md" "$FIGHT"
chk "fight skill refuses a task arg with a plan pending" "run spar-fight with no task" "$FIGHT"
chk "fight skill launches through the shared launcher" "spar-fight-launch.sh" "$FIGHT"
chk "fight skill runs the clean-worktree guard" "spar-check-worktree.sh" "$FIGHT"
# A plan prepared by the Claude command has neither key, and plan_set_field is a
# pure replace — stamping with it would leave the run ungated and mis-attributed.
chk "fight skill stamps the author with an inserting write" "plan_put_field author codex" "$FIGHT"
chk "fight skill stamps the session with an inserting write" "plan_put_field owner_session" "$FIGHT"
chk_absent "fight skill never stamps the seat with a replace-only write" \
  "plan_set_field owner_session" "$FIGHT"
chk "fight skill resolves flags instead of hardcoding them" "spar-fight-resolve.sh" "$FIGHT"
chk_absent "fight skill has no placeholder task" "TASK_DESCRIPTION_GOES_HERE" "$FIGHT"

# Falling back to same-family review is supported, but it is not what this seat
# is for. A real session degraded to codex-reviews-codex because claude lives in
# ~/.local/bin, which a non-interactive shell does not have on PATH — and nothing
# said so until the run was over and the report read "same-model".
for sk in spar-fight spar-ready; do
  S="$(cat "$ROOT/adapters/codex/skills/$sk/SKILL.md" 2>/dev/null)"
  chk "$sk warns when the cross-model default is unavailable" \
    "'claude' is not on PATH" "$S"
  chk "$sk names what the fallback actually is" "single-agent mode" "$S"
  chk "$sk says where claude usually lives" ".local/bin" "$S"
done

READY="$(cat "$ROOT/adapters/codex/skills/spar-ready/SKILL.md" 2>/dev/null)"
chk "ready skill creates the dedicated branch" "git checkout -b" "$READY"
chk "ready skill resolves its flags" "spar-ready-resolve.sh" "$READY"
chk "ready skill initialises the plan state it later edits" "spar-plan.local.md.tmp" "$READY"
chk "ready skill records the author seat on the plan" "author: codex" "$READY"
chk "ready skill leaves owner_session for fight to stamp" "owner_session:" "$READY"
chk "ready skill still ingests the task table" "spar-ready-ingest.sh" "$READY"

# 19b. every skill reaches its helpers through a path the installer resolves —
# a guessed default points at a directory nothing is ever installed into.
for sk in spar-fight spar-ready spar-cancel spar-report; do
  S="$(cat "$ROOT/adapters/codex/skills/$sk/SKILL.md" 2>/dev/null)"
  case "$S" in
    *'SPAR_PLUGIN_ROOT:-'*)
      chk "$sk defaults to the substituted root" '@@SPAR_PLUGIN_ROOT@@' "$S" ;;
  esac
done

# 20. the installer places the skills, idempotently
fresh
HOME="$PWD/fakehome" CODEX_HOME="$PWD/fakecodex" bash "$INSTALL" >/dev/null 2>&1
chk "installer places the fight skill" "present" \
  "$([ -f "$PWD/fakecodex/skills/spar-fight/SKILL.md" ] && echo present || echo absent)"
chk "installer places the report skill" "present" \
  "$([ -f "$PWD/fakecodex/skills/spar-report/SKILL.md" ] && echo present || echo absent)"
BEFORE="$(cat "$PWD/fakecodex/skills/spar-fight/SKILL.md")"
HOME="$PWD/fakehome" CODEX_HOME="$PWD/fakecodex" bash "$INSTALL" >/dev/null 2>&1
chk "re-install leaves skills byte-identical" "$BEFORE" \
  "$(cat "$PWD/fakecodex/skills/spar-fight/SKILL.md")"

# 21. the installed skill carries the REAL plugin path, so it works with
# SPAR_PLUGIN_ROOT unset — which is the normal case after a plain install.
INSTALLED="$(cat "$PWD/fakecodex/skills/spar-fight/SKILL.md")"
chk_absent "installed skill keeps no placeholder" '@@SPAR_PLUGIN_ROOT@@' "$INSTALLED"
chk "installed skill points at this checkout's plugin" "$ROOT/plugins/spar" "$INSTALLED"
for sk in spar-ready spar-cancel spar-report; do
  S="$(cat "$PWD/fakecodex/skills/$sk/SKILL.md")"
  chk_absent "installed $sk keeps no placeholder" '@@' "$S"
  chk "installed $sk points at this checkout's plugin" "$ROOT/plugins/spar" "$S"
done
# The resolved default must actually resolve — evaluated the way the skill's own
# shell evaluates it, not string-matched, so the quoting is under test too.
skill_root() {   # skill_root <skill text>  → the SPAR_ROOT the block would use
  local assign
  assign="$(printf '%s\n' "$1" | grep -m1 '|| SPAR_ROOT=')"
  env -u SPAR_PLUGIN_ROOT bash -c \
    "SPAR_ROOT=\"\${SPAR_PLUGIN_ROOT:-}\"; $assign; printf '%s' \"\$SPAR_ROOT\""
}
RESOLVED_ROOT="$(skill_root "$INSTALLED")"
chk "installed skill's default root exists" "present" \
  "$([ -d "$RESOLVED_ROOT" ] && [ -f "$RESOLVED_ROOT/commands/spar-plan-lib.sh" ] && echo present || echo absent)"

# 22. project scope: a repository that symlinks .codex/skills must not redirect
# the installed skills out of the tree. Unsafe is fatal — an installer reporting
# success while writing nothing (or writing elsewhere) is the worse failure.
fresh
outside=$(mktemp -d)
mkdir -p .codex; ln -s "$outside" .codex/skills
bash "$INSTALL" --scope project >/dev/null 2>&1
chk "symlinked project skills dir → exit 3" "3" "$?"
chk "symlinked project skills dir → nothing written outside the tree" "empty" \
  "$([ -z "$(ls -A "$outside" 2>/dev/null)" ] && echo empty || echo "wrote: $(ls -A "$outside")")"
rm -rf "$outside"

# The exact destination file being a symlink is refused the same way.
fresh
outside=$(mktemp -d)
mkdir -p .codex/skills/spar-fight; ln -s "$outside/planted" .codex/skills/spar-fight/SKILL.md
bash "$INSTALL" --scope project >/dev/null 2>&1
chk "symlinked destination file → exit 3" "3" "$?"
chk "symlinked destination file → link target never created" "absent" \
  "$([ -e "$outside/planted" ] && echo present || echo absent)"
rm -rf "$outside"

# A real project tree still installs.
fresh
bash "$INSTALL" --scope project >/dev/null 2>&1
chk "clean project scope → skills installed" "present" \
  "$([ -f .codex/skills/spar-fight/SKILL.md ] && echo present || echo absent)"

# 23. --target relocates the hooks file only. Codex discovers skills at fixed
# paths, so a copy beside an arbitrary hooks.json is a copy nothing ever loads.
fresh
mkdir -p elsewhere
bash "$INSTALL" --target ./elsewhere/hooks.json >/dev/null 2>&1
chk "--target → hooks land at the given path" "stop-fight.sh" \
  "$(cat ./elsewhere/hooks.json 2>/dev/null)"
chk "--target → skills stay in the user-scope directory" "present" \
  "$([ -f "$CODEX_HOME/skills/spar-fight/SKILL.md" ] && echo present || echo absent)"
chk "--target → no skills orphaned beside the hooks file" "absent" \
  "$([ -e ./elsewhere/skills ] && echo present || echo absent)"

fresh
mkdir -p elsewhere
bash "$INSTALL" --scope project --target ./elsewhere/hooks.json >/dev/null 2>&1
chk "--target with project scope → skills in .codex/skills" "present" \
  "$([ -f .codex/skills/spar-fight/SKILL.md ] && echo present || echo absent)"
chk "--target with project scope → none beside the hooks file" "absent" \
  "$([ -e ./elsewhere/skills ] && echo present || echo absent)"

# 24. a checkout path carrying shell metacharacters must not execute when the
# installed skill's activation block runs. The path goes into a script the user
# runs without reading, so quoting it is not cosmetic.
fresh
EVIL="$PWD/we\"ird \$(touch pwned) \`touch pwned2\` dir"
mkdir -p "$EVIL"
cp -R "$ROOT/adapters" "$EVIL/"
cp -R "$ROOT/plugins" "$EVIL/"
bash "$EVIL/adapters/codex/install.sh" >/dev/null 2>&1
S="$(cat "$CODEX_HOME/skills/spar-fight/SKILL.md" 2>/dev/null)"
chk "metacharacter path → skill resolves to the real plugin root" \
  "$EVIL/plugins/spar" "$(skill_root "$S")"
chk "metacharacter path → command substitution did not run" "absent" \
  "$({ [ -e pwned ] || [ -e pwned2 ] || [ -e "$EVIL/pwned" ] || [ -e "$EVIL/pwned2" ]; } && echo present || echo absent)"
for sk in spar-ready spar-cancel spar-report; do
  S2="$(cat "$CODEX_HOME/skills/$sk/SKILL.md" 2>/dev/null)"
  chk "metacharacter path → $sk resolves too" "$EVIL/plugins/spar" "$(skill_root "$S2")"
done
# SPAR_PLUGIN_ROOT still wins, which is the whole point of keeping the default.
chk "SPAR_PLUGIN_ROOT overrides the baked-in default" "/somewhere/else" \
  "$(SPAR_PLUGIN_ROOT=/somewhere/else bash -c "$(printf '%s\n' "$S" | grep -m1 '|| SPAR_ROOT=' | sed 's/^/SPAR_ROOT="${SPAR_PLUGIN_ROOT:-}"; /'); printf '%s' \"\$SPAR_ROOT\"")"

# 25. arguments must not be pasted into the activation block. Task text is
# arbitrary prose; a line matching a heredoc delimiter would end the heredoc and
# hand the rest to the shell.
for sk in spar-fight spar-ready; do
  S="$(cat "$ROOT/adapters/codex/skills/$sk/SKILL.md" 2>/dev/null)"
  chk_absent "$sk does not paste arguments into a heredoc" "ARGS_EOF" "$S"
  chk "$sk reads arguments from a file" ".claude/spar-args.txt" "$S"
  chk "$sk tells the model to write that file verbatim" "byte for byte" "$S"
  chk "$sk consumes the file so a re-run cannot inherit it" 'rm -f "$SPAR_ARGS_FILE"' \
    "$(printf '%s' "$S" | sed 's/RDY_ARGS_FILE/SPAR_ARGS_FILE/g')"
done
# The args path is already covered by the loop's git-exclude patterns.
chk "the args file is hidden from the review surface" ".claude/spar*" \
  "$(cat "$ROOT/adapters/codex/skills/spar-fight/SKILL.md")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
