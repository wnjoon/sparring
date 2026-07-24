#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/plugins/spar/commands/spar-queue-pending.sh"
# Substring match — for free-text content assertions.
chk() { if printf '%s' "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
# Exact match — for exit codes and counts (never accept "13" for "3").
chk_eq() { if [ "$3" = "$2" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }
# Run the writer and echo its exact numeric exit code (for code-contract asserts).
rc() { bash "$W" "$@" >/dev/null 2>&1; echo "$?"; }

fresh() { d=$(mktemp -d); cd "$d" || exit 1; mkdir -p reviews; }

# 1. first append creates the queue and records the keyed heading + finding text
fresh
printf '### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n' > finding.txt
bash "$W" 20260721-120000-abc123 'mod.py | split the module' finding.txt
Q=reviews/spar-pending.md
chk "queue created" "present" "$([ -f "$Q" ] && echo present || echo absent)"
chk "keyed heading written" "## 20260721-120000-abc123 :: mod.py | split the module" "$(cat "$Q")"
chk "finding text carried" "split the module" "$(cat "$Q")"
chk "full finding body carried (not just heading)" "problem: big" "$(cat "$Q")"

# 2. duplicate key is a no-op (merge, never duplicate)
bash "$W" 20260721-120000-abc123 'mod.py | split the module' finding.txt
chk_eq "duplicate key not duplicated" "1" "$(grep -c '^## 20260721-120000-abc123 :: mod.py | split the module$' "$Q")"

# 3. a second distinct key from another run merges in
printf '### F1-1 [DESIGN] rename thing\n' > finding2.txt
bash "$W" 20260722-090000-def456 'x.py | rename thing' finding2.txt
chk_eq "second run merged" "2" "$(grep -c '^## ' "$Q")"

# 4. a symlinked queue path is rejected (exit 3), target untouched
fresh
outside=$(mktemp)
ln -s "$outside" reviews/spar-pending.md
printf 'x\n' > finding.txt
chk_eq "symlinked queue → exit 3" "3" "$(rc 20260721-120000-abc123 'a | b' finding.txt)"
chk_eq "symlink target untouched" "0" "$(wc -c < "$outside" | tr -d ' ')"

# 5. a symlinked ANCESTOR directory is rejected (exit 3), nothing written through it
fresh
realdir=$(mktemp -d)
ln -s "$realdir" linkdir
printf 'x\n' > finding.txt
chk_eq "symlinked ancestor dir → exit 3" "3" "$(rc 20260721-120000-abc123 'a | b' finding.txt linkdir/sub/queue.md)"
chk_eq "symlink target dir untouched" "0" "$(find "$realdir" -type f | wc -l | tr -d ' ')"

# 6. a queue path that exists as a non-regular file (directory) is rejected (exit 3)
fresh
printf 'x\n' > finding.txt
mkdir -p reviews/spar-pending.md
chk_eq "non-regular queue path → exit 3" "3" "$(rc 20260721-120000-abc123 'a | b' finding.txt)"

# 7. missing finding-text file is a usage error (exit 2)
fresh
chk_eq "missing finding file → exit 2" "2" "$(rc 20260721-120000-abc123 'a | b' /nonexistent.txt)"

# 8. missing positional args are usage errors (exit 2)
fresh
printf 'x\n' > finding.txt
chk_eq "missing fingerprint → exit 2" "2" "$(rc 20260721-120000-abc123 '' finding.txt)"

# 9. F1-1 regression: an unreadable body (exists, passes -f, but cat fails) must
# abort with exit 3 and leave NO heading behind — otherwise a retry no-ops.
fresh
printf '### F1-1 body\n' > finding.txt
chmod 000 finding.txt
if cat finding.txt >/dev/null 2>&1; then
  echo "SKIP: cannot make file unreadable in this environment (running as root?)"
else
  chk_eq "unreadable body → exit 3" "3" "$(rc 20260721-120000-abc123 'a | b' finding.txt)"
  chk_eq "unreadable body → no poisoned heading" "gone" "$([ -f reviews/spar-pending.md ] && echo present || echo gone)"
fi
chmod 644 finding.txt 2>/dev/null || true

# 10. F2-1 regression: publish is atomic — after a normal write no staging temp
# is left behind (the entry is built in .spar-pending.* and renamed into place).
fresh
printf 'body\n' > finding.txt
bash "$W" 20260721-120000-abc123 'a | b' finding.txt
chk_eq "atomic publish leaves no staging temp" "0" "$(find reviews -name '.spar-pending*' | wc -l | tr -d ' ')"
chk_eq "published queue is a regular file" "regular" "$([ -f reviews/spar-pending.md ] && [ ! -L reviews/spar-pending.md ] && echo regular || echo no)"

# 11. F2-2 regression: the queue is swapped to a symlink WHILE the writer waits
# on the lock. The under-lock re-check must reject it (exit 3), target untouched.
fresh
outside=$(mktemp)
printf 'body\n' > finding.txt
mkdir reviews/spar-pending.md.lock          # pre-hold the lock so the writer waits
( sleep 0.6; ln -s "$outside" reviews/spar-pending.md; rmdir reviews/spar-pending.md.lock ) &
CODE=$(rc 20260721-120000-abc123 'a | b' finding.txt)
wait
chk_eq "symlink-to-file swap during lock wait → exit 3" "3" "$CODE"
chk_eq "swapped-symlink (file) target untouched" "0" "$(wc -c < "$outside" | tr -d ' ')"

# 11b. F4-1 regression: swap the queue to a symlink-to-DIRECTORY during the lock
# wait. `mv` onto such a target would otherwise move the staged file into the
# external dir and exit 0; the recheck must reject with exit 3, dir untouched.
fresh
extdir=$(mktemp -d)
printf 'body\n' > finding.txt
mkdir reviews/spar-pending.md.lock
( sleep 0.6; ln -s "$extdir" reviews/spar-pending.md; rmdir reviews/spar-pending.md.lock ) &
CODE=$(rc 20260721-120000-abc123 'a | b' finding.txt)
wait
chk_eq "symlink-to-dir swap during lock wait → exit 3" "3" "$CODE"
chk_eq "swapped-symlink (dir) target untouched" "0" "$(find "$extdir" -type f | wc -l | tr -d ' ')"

# 12. F3-1 regression: a pre-existing queue with NO trailing newline must not
# break dedup — the same key twice stays a single entry.
fresh
printf 'body\n' > finding.txt
printf '# hdr\n\n## 20260721-120000-abc123 :: a | b' > reviews/spar-pending.md  # no trailing newline
bash "$W" 20260721-120000-abc123 'a | b' finding.txt   # heading already present → no-op
chk_eq "no-trailing-newline dedup: key not duplicated" "1" "$(grep -c '^## 20260721-120000-abc123 :: a | b$' reviews/spar-pending.md)"
# a DIFFERENT key appended onto a non-terminated file lands on its own line
printf '# hdr\n\n## 20260721-120000-abc123 :: a | b' > reviews/spar-pending.md
bash "$W" 20260722-090000-def456 'c | d' finding.txt
chk_eq "appended heading starts its own line" "1" "$(grep -c '^## 20260722-090000-def456 :: c | d$' reviews/spar-pending.md)"
chk_eq "prior heading still matchable after fixup" "1" "$(grep -c '^## 20260721-120000-abc123 :: a | b$' reviews/spar-pending.md)"

# 13. F3-2 regression: argument count is exactly 3 or 4.
fresh
printf 'body\n' > finding.txt
chk_eq "too few args (2) → exit 2" "2" "$(rc 20260721-120000-abc123 'a | b')"
chk_eq "too many args (5) → exit 2" "2" "$(rc 20260721-120000-abc123 'a | b' finding.txt reviews/spar-pending.md extra)"

# 14. F5-1 regression: leading-dash paths are treated as files, not options.
# A finding file literally named "-n" must be READ (not turn cat into line-
# numbering + stdin), so its body reaches the queue.
fresh
printf 'body-content-xyz\n' > -n
bash "$W" 20260721-120000-abc123 'a | b' -n   # bare -n as $3 exercises the script's own normalization
chk "leading-dash finding path read as a file" "body-content-xyz" "$(cat reviews/spar-pending.md)"
# A queue path beginning with '-' must be created, not parsed as an option.
fresh
printf 'body\n' > finding.txt
bash "$W" 20260721-120000-abc123 'a | b' finding.txt -q.md
chk "leading-dash queue path created" "present" "$([ -f ./-q.md ] && echo present || echo absent)"
chk "leading-dash queue carries the heading" "## 20260721-120000-abc123 :: a | b" "$(cat ./-q.md)"

# 15. queue-directory creation: with NO pre-existing reviews/ dir the writer
# creates the parent and the queue (every other fixture pre-creates reviews/).
bare() { d=$(mktemp -d); cd "$d" || exit 1; }   # like fresh() but WITHOUT mkdir reviews
bare
printf 'body\n' > finding.txt
chk_eq "missing parent dir → created (exit 0)" "0" "$(rc 20260721-120000-abc123 'a | b' finding.txt)"
chk "missing parent dir → queue created" "present" "$([ -f reviews/spar-pending.md ] && echo present || echo absent)"

# 16. mkdir-failure contract: a regular file blocking an ancestor makes mkdir -p
# fail → exit 3 with no queue written anywhere.
bare
printf 'body\n' > finding.txt
printf 'x\n' > block                     # regular file where a directory is needed
chk_eq "mkdir failure (file blocks ancestor) → exit 3" "3" "$(rc 20260721-120000-abc123 'a | b' finding.txt block/sub/queue.md)"
chk_eq "mkdir failure → no queue created" "0" "$(find . -name queue.md | wc -l | tr -d ' ')"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
