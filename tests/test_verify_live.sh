#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$ROOT/adapters/codex/verify-live.sh"
chk() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent() { if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }
# Each case gets its own tree AND its own HOME/CODEX_HOME, so a bug in the
# harness's own isolation cannot reach the developer's real Codex home from here.
fresh() { d=$(mktemp -d); cd "$d" || exit 1; cd "$(pwd -P)" || exit 1
  export HOME="$PWD/.testhome" CODEX_HOME="$PWD/.testcodex"; }

# 1. no subcommand → usage, exit 2
fresh
OUT=$(bash "$V" 2>&1); RC=$?
chk "no subcommand → exit 2" "2" "$RC"
chk "no subcommand → prints usage" "usage:" "$OUT"

# 2. setup builds the workspace
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
chk "setup → workspace marker" "spar-live-verify" "$(cat ./ws/.spar-live-workspace 2>/dev/null)"
chk "setup → isolated home has hooks.json" "stop-fight.sh" "$(cat ./ws/home/hooks.json 2>/dev/null)"
chk "setup → all four skills installed" "4" \
  "$(ls ./ws/home/skills 2>/dev/null | wc -l | tr -d ' ')"
chk "setup → scratch repo is a git repo" "true" \
  "$(git -C ./ws/repo rev-parse --is-inside-work-tree 2>/dev/null)"
chk "setup → planted bug present" "range(1, n)" "$(cat ./ws/repo/sum_to.py 2>/dev/null)"
chk "setup → task description present" "sum_to" "$(cat ./ws/repo/TASK.md 2>/dev/null)"
chk "setup → checklist saved" "trust" "$(cat ./ws/checklist.md 2>/dev/null)"

# 3. the real CODEX_HOME is never a target
fresh
OUT=$(CODEX_HOME="$PWD/.testcodex" bash "$V" setup --dir "$PWD/.testcodex/ws" 2>&1); RC=$?
chk "target inside the real CODEX_HOME → exit 3" "3" "$RC"
chk "target inside the real CODEX_HOME → says so" "refusing" "$OUT"
chk_absent "target inside the real CODEX_HOME → nothing written" "ws" \
  "$(ls "$PWD/.testcodex" 2>/dev/null)"

# 3b. containment is a resolved-path question, not a string-prefix one
fresh
mkdir -p ./.testcodex
OUT=$(bash "$V" setup --dir "$PWD/nowhere/../.testcodex/ws" 2>&1); RC=$?
chk "dot-dot into the real CODEX_HOME → exit 3" "3" "$RC"
chk "dot-dot into the real CODEX_HOME → says refusing" "refusing" "$OUT"
chk_absent "dot-dot into the real CODEX_HOME → nothing written" "ws" \
  "$(ls ./.testcodex 2>/dev/null)"

fresh
mkdir -p ./.testcodex
ln -s ./.testcodex ./alias
OUT=$(bash "$V" setup --dir ./alias/ws 2>&1); RC=$?
chk "symlink alias of the real CODEX_HOME → exit 3" "3" "$RC"
chk_absent "symlink alias → nothing written through it" "ws" \
  "$(ls ./.testcodex 2>/dev/null)"

# 3c. a symlinked ANCESTOR of an otherwise-fine target is resolved, not trusted
fresh
mkdir -p ./real-elsewhere
ln -s ./real-elsewhere ./link
bash "$V" setup --dir ./link/ws >/dev/null 2>&1
chk "symlinked ancestor outside CODEX_HOME → still allowed" "spar-live-verify" \
  "$(cat ./real-elsewhere/ws/.spar-live-workspace 2>/dev/null)"

# 3d. a CODEX_HOME that resolves to the filesystem root contains everything
fresh
OUT=$(CODEX_HOME=/ bash "$V" setup --dir ./ws 2>&1); RC=$?
chk "CODEX_HOME=/ → any target refused" "3" "$RC"
chk "CODEX_HOME=/ → says refusing" "refusing" "$OUT"
chk_absent "CODEX_HOME=/ → nothing written" "present" \
  "$([ -e ./ws ] && echo present || echo absent)"
OUT=$(CODEX_HOME=/ bash "$V" clean --dir ./ws 2>&1); RC=$?
chk "CODEX_HOME=/ → clean refused too" "3" "$RC"

# 3e. the workspace being exactly CODEX_HOME is refused, not just a descendant.
# Deliberately NOT pre-created: if the directory existed, the "not a harness
# workspace" guard would refuse it too and this check would pass even with the
# containment test broken.
fresh
OUT=$(bash "$V" setup --dir ./.testcodex 2>&1); RC=$?
chk "workspace equal to CODEX_HOME → exit 3" "3" "$RC"
chk "workspace equal to CODEX_HOME → refused for containment, not existence" \
  "refusing" "$OUT"

# 3f. a newline in a path would shift the resolver's fields, so it is refused
fresh
mkdir -p ./victim && printf 'precious\n' > ./victim/keep.txt
OUT=$(bash "$V" setup --dir "$(printf './victim\n/elsewhere')" 2>&1); RC=$?
chk "newline in --dir → exit 3" "3" "$RC"
chk "newline in --dir → says so" "must not contain a newline" "$OUT"
chk "newline in --dir → the shorter path was NOT touched" "precious" \
  "$(cat ./victim/keep.txt 2>/dev/null)"
chk_absent "newline in --dir → no workspace created there" "spar-live-workspace" \
  "$(ls -a ./victim 2>/dev/null)"

# The dangerous shape: the prefix the fields would collapse to is ALREADY a
# harness workspace, so the "not ours" guard would wave it through and only the
# newline refusal stands between it and rm -rf.
fresh
bash "$V" setup --dir ./victim >/dev/null 2>&1
printf 'irreplaceable\n' > ./victim/keep.txt
OUT=$(bash "$V" clean --dir "$(printf './victim\n/elsewhere')" 2>&1); RC=$?
chk "newline collapsing onto a real workspace → refused" "3" "$RC"
chk "newline collapsing onto a real workspace → it survives" "irreplaceable" \
  "$(cat ./victim/keep.txt 2>/dev/null)"
OUT=$(CODEX_HOME="$(printf '/tmp/a\n/b')" bash "$V" setup --dir ./ws 2>&1); RC=$?
chk "newline in CODEX_HOME → exit 3" "3" "$RC"

# 3g. a newline the INPUT never had, introduced by resolving a symlink. The
# prefix it would collapse to is a real workspace, so only this guard protects it.
fresh
NL_DIR="$(printf 'tgt\nX')"
mkdir -p "./$NL_DIR"
bash "$V" setup --dir ./tgt >/dev/null 2>&1
printf 'irreplaceable\n' > ./tgt/keep.txt
ln -s "$PWD/$NL_DIR" ./nl-link
OUT=$(bash "$V" clean --dir ./nl-link/ws 2>&1); RC=$?
chk "newline via a resolved symlink → exit 3" "3" "$RC"
chk "newline via a resolved symlink → says the RESOLVED path is at fault" \
  "resolved" "$OUT"
chk "newline via a resolved symlink → the collapsed workspace survives" \
  "irreplaceable" "$(cat ./tgt/keep.txt 2>/dev/null)"
OUT=$(bash "$V" setup --dir ./nl-link/ws 2>&1); RC=$?
chk "newline via a resolved symlink → setup refuses too" "3" "$RC"
chk "newline via a resolved symlink → setup did not wipe it" \
  "irreplaceable" "$(cat ./tgt/keep.txt 2>/dev/null)"

# 4. re-running is safe: same marker, no duplication
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf 'stale\n' > ./ws/repo/leftover.txt
bash "$V" setup --dir ./ws >/dev/null 2>&1; RC=$?
chk "re-run → exit 0" "0" "$RC"
chk "re-run → stale file gone" "absent" \
  "$([ -e ./ws/repo/leftover.txt ] && echo present || echo absent)"
chk "re-run → workspace still valid" "spar-live-verify" "$(cat ./ws/.spar-live-workspace 2>/dev/null)"

# 5. a directory that is not ours is refused rather than wiped
fresh
mkdir -p ./notours && printf 'precious\n' > ./notours/keep.txt
OUT=$(bash "$V" setup --dir ./notours 2>&1); RC=$?
chk "non-workspace dir → exit 3" "3" "$RC"
chk "non-workspace dir → file untouched" "precious" "$(cat ./notours/keep.txt)"

# 6. the checklist names all four items and does not claim to automate them
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
CL="$(cat ./ws/checklist.md)"
for item in "trust" "scope" "SessionStart" "CONVERGED"; do
  chk "checklist covers $item" "$item" "$CL"
done
chk "checklist tells the human to run codex themselves" "codex" "$CL"
chk "checklist prints the isolated home to use" "CODEX_HOME=" "$CL"

# 6c. paths the human is told to TYPE are shell-quoted; a space must not break
# the commands and a $(...) must not run when they are pasted.
fresh
EVIL="$PWD/we ird \$(touch pwned) dir/ws"
bash "$V" setup --dir "$EVIL" >/dev/null 2>&1
CL="$(cat "$EVIL/checklist.md" 2>/dev/null)"
chk "quoted path → cd line is a single quoted argument" "cd '" "$CL"
chk "quoted path → CODEX_HOME assignment is quoted" "CODEX_HOME='" "$CL"
chk "quoted path → the check command is quoted" "--dir '" "$CL"
chk_absent "quoted path → no unsubstituted placeholder" "@@" "$CL"
# Run the two command lines in a sandbox shell and confirm nothing executed.
CMDS="$(printf '%s\n' "$CL" | grep -E "^    (cd |bash )" | sed 's/^    //')"
printf '%s\n' "$CMDS" | while IFS= read -r line; do
  bash -n <(printf '%s\n' "$line") 2>/dev/null || echo "UNPARSEABLE: $line"
done > ./parse.log
chk_absent "quoted path → every generated command parses" "UNPARSEABLE" "$(cat ./parse.log)"
chk "quoted path → command substitution did not run" "absent" \
  "$(ls "$PWD" 2>/dev/null | grep -qx pwned && echo present || echo absent)"

# 6d. a symlinked marker does not make a directory ours. It is the only thing
# standing between rm -rf and someone else's files.
fresh
bash "$V" setup --dir ./real-ws >/dev/null 2>&1
mkdir -p ./impostor && printf 'precious\n' > ./impostor/keep.txt
ln -s "$PWD/real-ws/.spar-live-workspace" ./impostor/.spar-live-workspace
OUT=$(bash "$V" clean --dir ./impostor 2>&1); RC=$?
chk "symlinked marker → clean refuses" "3" "$RC"
chk "symlinked marker → the directory survives" "precious" "$(cat ./impostor/keep.txt 2>/dev/null)"
OUT=$(bash "$V" setup --dir ./impostor 2>&1); RC=$?
chk "symlinked marker → setup refuses too" "3" "$RC"
chk "symlinked marker → setup did not wipe it" "precious" "$(cat ./impostor/keep.txt 2>/dev/null)"

# 6e. setup's own deliverable is the printed checklist; failing to print it is
# not a success. stdout is closed so only the final output can fail.
fresh
bash "$V" setup --dir ./ws >&- 2>./err.log; RC=$?
chk "unprintable checklist → exit 3" "3" "$RC"
chk "unprintable checklist → says where it was saved" "checklist.md" "$(cat ./err.log)"

# 6f. the workspace path is data, not template. A path containing @@ — even the
# literal text of a placeholder — must render correctly rather than be rejected
# or rewritten by a later substitution pass.
fresh
AT="$PWD/project@@copy/@@WS@@/ws"
bash "$V" setup --dir "$AT" >/dev/null 2>&1; RC=$?
chk "path containing @@ → setup succeeds" "0" "$RC"
CL="$(cat "$AT/checklist.md" 2>/dev/null)"
chk "path containing @@ → the literal path survives into the checklist" \
  "project@@copy" "$CL"
# Exact-line comparison, not substring: a later substitution pass rewriting the
# inserted value leaves text that still CONTAINS the original segment, so only
# the whole expected command distinguishes a correct render from a mangled one.
WANT_CD="cd $(WSX="$AT" python3 -c 'import os,shlex;print(shlex.quote(os.path.join(os.environ["WSX"],"repo")))')"
GOT_CD="$(printf '%s\n' "$CL" | grep -m1 '^    cd ' | sed 's/^    //')"
chk "path containing @@ → the cd line renders exactly once, correctly" \
  "$WANT_CD" "$GOT_CD"
chk_absent "path containing @@ → no template placeholder is left unrendered" \
  "@@REPOQ@@" "$CL"
chk_absent "path containing @@ → no error was printed" "error:" \
  "$(bash "$V" setup --dir "$AT" 2>&1 >/dev/null)"

# 6g. an unknown placeholder in the TEMPLATE still fails loudly
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
chk "template validation is keyed to known names" "@@" \
  "$(grep -o '@@[A-Z]*@@' "$V" | head -1)"

# 6h. a DANGLING symlink at the target is still someone else's entry. -e is false
# for one, so without an explicit -L test the ownership guard is skipped and the
# link is deleted to make room for a workspace.
fresh
ln -s ./nowhere-at-all ./ws
OUT=$(bash "$V" setup --dir ./ws 2>&1); RC=$?
chk "dangling symlink target → setup refuses" "3" "$RC"
chk "dangling symlink target → says it is not ours" "not a harness workspace" "$OUT"
chk "dangling symlink target → the link is still there" "present" \
  "$([ -L ./ws ] && echo present || echo absent)"
chk "dangling symlink target → still dangling, nothing created" "absent" \
  "$([ -e ./ws ] && echo present || echo absent)"
OUT=$(bash "$V" clean --dir ./ws 2>&1); RC=$?
chk "dangling symlink target → clean refuses rather than shrugging" "3" "$RC"
chk_absent "dangling symlink target → clean does not claim there is nothing there" \
  "nothing to clean" "$OUT"
chk "dangling symlink target → the link survives clean too" "present" \
  "$([ -L ./ws ] && echo present || echo absent)"

# 7. clean removes exactly the workspace
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
bash "$V" clean --dir ./ws >/dev/null 2>&1
chk "clean → workspace gone" "absent" "$([ -e ./ws ] && echo present || echo absent)"
mkdir -p ./notours
OUT=$(bash "$V" clean --dir ./notours 2>&1); RC=$?
chk "clean refuses a directory that is not ours" "3" "$RC"

# 7b. a cleanup that cannot complete is an error, not a success.
# The failure is injected with a PATH shim rather than by dropping permissions:
# mode 500 does not stop root, so a container running tests as root would fail
# this check even though the error handling is correct.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
mkdir -p ./shim
printf '#!/bin/sh\nexit 1\n' > ./shim/rm; chmod +x ./shim/rm
OUT=$(PATH="$PWD/shim:$PATH" bash "$V" clean --dir ./ws 2>&1); RC=$?
chk "unremovable workspace → exit 3" "3" "$RC"
chk "unremovable workspace → says so" "could not remove" "$OUT"
chk_absent "unremovable workspace → never claims success" "removed " "$OUT"
chk "unremovable workspace → still there afterwards" "present" \
  "$([ -d ./ws ] && echo present || echo absent)"

# 6b. the checklist asks for the observations artifacts cannot supply
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
CL="$(cat ./ws/checklist.md)"
chk "checklist asks whether a prompt appeared" "were you asked at all" "$CL"
chk "checklist asks what the prompt said" "what did the prompt say" "$CL"
chk "checklist asks whether the hooks fired" "did the hooks fire" "$CL"
chk "checklist explains why the human answer is needed" "only you can" "$CL"
chk "checklist keeps the ordering observation" "which happened" "$CL"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
