#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/plugins/spar/commands/spar-classify-change.sh"

chk() {
  if printf '%s' "$3" | grep -qF "$2"; then
    echo "PASS: $1"; PASS=$((PASS+1))
  else
    echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1))
  fi
}
fresh() {
  d=$(mktemp -d); cd "$d" || exit 1
  git init -q
  git config user.email sparring@example.invalid
  git config user.name sparring-test
  printf 'base\n' > base.txt
  git add . && git commit -qm base
  BASE=$(git rev-parse HEAD)
}

fresh
OUT=$(bash "$C" "$BASE")
chk "clean surface has no changes" "has_changes: false" "$OUT"

fresh
printf 'one\ntwo\n' >> base.txt
OUT=$(bash "$C" "$BASE")
chk "tracked lines counted" "lines: 2" "$OUT"
chk "tracked path counted" "paths: 1" "$OUT"
chk "small tracked change" "small: true" "$OUT"

fresh
printf 'new\n' > added.txt
git add added.txt
OUT=$(bash "$C" "$BASE")
chk "staged regular add is not a mode change" "unsafe_kind: false" "$OUT"
chk "staged regular add remains skip-size eligible" "small: true" "$OUT"

fresh
printf 'tracked\n' >> base.txt
i=1; : > large.txt
while [ "$i" -le 20 ]; do printf 'line %s\n' "$i" >> large.txt; i=$((i+1)); done
OUT=$(bash "$C" "$BASE")
chk "mixed surface counts untracked lines" "lines: 21" "$OUT"
chk "mixed surface not small" "small: false" "$OUT"

fresh
mkdir -p src/auth
printf 'x\n' > src/auth/session.sh
OUT=$(bash "$C" "$BASE")
chk "auth touched risk" "touched_risk: true" "$OUT"
chk "auth risk reason" "auth-security" "$OUT"

fresh
mkdir -p auth
printf 'base\n' > auth/session.sh
git add . && git commit -qm auth
BASE=$(git rev-parse HEAD)
printf 'docs\n' > README.md
OUT=$(bash "$C" "$BASE")
chk "risky repo detected" "repo_risk: true" "$OUT"
chk "unrelated docs path not touched-risky" "touched_risk: false" "$OUT"

fresh
git mv base.txt renamed.txt
OUT=$(bash "$C" "$BASE")
chk "rename unsafe" "unsafe_kind: true" "$OUT"

fresh
git rm -q base.txt
OUT=$(bash "$C" "$BASE")
chk "delete unsafe" "unsafe_kind: true" "$OUT"

fresh
printf '\000\001\002' > binary.dat
OUT=$(bash "$C" "$BASE")
chk "untracked binary unsafe" "unsafe_kind: true" "$OUT"

fresh
ln -s base.txt link.txt
OUT=$(bash "$C" "$BASE")
chk "untracked symlink unsafe" "unsafe_kind: true" "$OUT"

fresh
chmod +x base.txt
OUT=$(bash "$C" "$BASE")
chk "mode-only change unsafe" "unsafe_kind: true" "$OUT"

fresh
printf 'odd\n' > $'space and\nnewline.txt'
OUT=$(bash "$C" "$BASE")
chk "NUL-safe unusual path counted once" "paths: 1" "$OUT"
chk "NUL-safe unusual path line counted" "lines: 1" "$OUT"

d=$(mktemp -d); cd "$d" || exit 1; git init -q
printf 'new\n' > new.txt
OUT=$(bash "$C" none)
chk "unborn repo has changes" "has_changes: true" "$OUT"
chk "unborn repo never skip-safe" "unsafe_kind: true" "$OUT"

echo
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
