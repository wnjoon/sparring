#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/plugins/spar/commands/spar-check-worktree.sh"

chk_status() {
  desc="$1"; want="$2"; shift 2
  "$@" >/tmp/spar-check-out.$$ 2>&1
  got=$?
  rm -f /tmp/spar-check-out.$$
  if [ "$got" -eq "$want" ]; then
    echo "PASS: $desc"; PASS=$((PASS+1))
  else
    echo "FAIL: $desc (want=$want got=$got)"; FAIL=$((FAIL+1))
  fi
}

fresh_repo() {
  d=$(mktemp -d)
  cd "$d" || exit 1
  git init -q
  git config user.email sparring@example.invalid
  git config user.name sparring-test
  printf 'base\n' > tracked.txt
  git add tracked.txt
  git commit -q -m base
}

fresh_repo
chk_status "clean worktree accepted" 0 bash "$CHECK" false

printf 'changed\n' >> tracked.txt
chk_status "unstaged tracked change refused" 4 bash "$CHECK" false
chk_status "unstaged tracked change accepted by opt-in" 0 bash "$CHECK" true

fresh_repo
printf 'staged\n' >> tracked.txt
git add tracked.txt
chk_status "staged change refused" 4 bash "$CHECK" false

fresh_repo
printf 'new\n' > untracked.txt
chk_status "untracked file refused" 4 bash "$CHECK" false
chk_status "untracked file accepted by opt-in" 0 bash "$CHECK" true

fresh_repo
printf 'ignored.txt\n' > .gitignore
git add .gitignore
git commit -q -m ignore
printf 'ignored\n' > ignored.txt
chk_status "ignored-only change accepted" 0 bash "$CHECK" false

d=$(mktemp -d)
cd "$d" || exit 1
chk_status "non-git directory refused" 3 bash "$CHECK" false
chk_status "invalid include-dirty state refused" 2 bash "$CHECK" maybe

echo
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
