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

# 7. clean removes exactly the workspace
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
bash "$V" clean --dir ./ws >/dev/null 2>&1
chk "clean → workspace gone" "absent" "$([ -e ./ws ] && echo present || echo absent)"
mkdir -p ./notours
OUT=$(bash "$V" clean --dir ./notours 2>&1); RC=$?
chk "clean refuses a directory that is not ours" "3" "$RC"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
