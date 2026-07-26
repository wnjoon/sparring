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
# A real repository, because the liveness marker lives in the git directory.
fresh() { d=$(mktemp -d); cd "$d" || exit 1; git init -q .; mkdir -p reviews; }
marker() { cat "$(git rev-parse --git-dir)/spar-hook-live" 2>/dev/null; }
marker_state() {
  [ -f "$(git rev-parse --git-dir)/spar-hook-live" ] 2>/dev/null \
    && echo present || echo absent
}

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
chk "Stop hook untouched" "stop-fight.sh" "$(jq -r '.hooks.Stop[].hooks[].command' "$J")"

# 6. the hook leaves a liveness marker so activation can prove it ran
fresh
run '{"source":"startup","session_id":"sess-live-1"}' >/dev/null
chk "marker written" "sess-live-1" "$(marker)"

# 7. a second session overwrites it — the marker names the CURRENT session only
run '{"source":"startup","session_id":"sess-live-2"}' >/dev/null
chk "marker names the current session" "sess-live-2" "$(marker)"

# 8. no session id → no marker, and still silent
fresh
OUT="$(run '{"source":"startup"}')"
chk_empty "no session id → still silent" "" "$OUT"
chk "no session id → no marker" "absent" "$(marker_state)"

# 9. a CLEAN CHECKOUT can bootstrap: reviews/ does not exist yet, and activation
#    reads the marker before anything creates it. The git directory always does.
fresh
rm -rf reviews
run '{"source":"startup","session_id":"sess-live-3"}' >/dev/null
chk "clean checkout → marker still written" "sess-live-3" "$(marker)"
chk "clean checkout → reviews/ NOT created as a side effect" "absent" \
  "$([ -e reviews ] && echo present || echo absent)"

# 10. outside a repository nothing is written and nothing is created
d=$(mktemp -d); cd "$d" || exit 1
run '{"source":"startup","session_id":"sess-live-4"}' >/dev/null
chk_empty "no repository → no marker anywhere" "" \
  "$(find . -name 'spar-hook-live*' 2>/dev/null)"

# 11. a symlinked marker path is overwritten in place, never followed out of the
#     git directory (the file is ours; a link there is not something we honour)
fresh
outside=$(mktemp -d)
ln -s "$outside/planted" "$(git rev-parse --git-dir)/spar-hook-live"
run '{"source":"startup","session_id":"sess-live-5"}' >/dev/null
chk "symlinked marker → target outside the repo untouched" "absent" \
  "$([ -f "$outside/planted" ] && echo present || echo absent)"
rm -rf "$outside"

# 12. linked worktrees keep independent markers. The marker names one SESSION,
#     and a shared common directory would let a session started in worktree B
#     invalidate worktree A, which refuses to activate despite its hooks running.
fresh
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
WT="$d/../wt-$$"; git worktree add -q "$WT" -b wt-branch 2>/dev/null
run '{"source":"startup","session_id":"sess-main"}' >/dev/null
cd "$WT" || exit 1
run '{"source":"startup","session_id":"sess-worktree"}' >/dev/null
chk "worktree marker names the worktree's session" "sess-worktree" "$(marker)"
cd "$d" || exit 1
chk "main worktree's marker survives the other session" "sess-main" "$(marker)"
git worktree remove --force "$WT" 2>/dev/null

# 13. the marker does not disturb the pending-queue announcement
fresh
printf '# sparring — pending\n\n## id-a :: f | one\ntext\n' > reviews/spar-pending.md
OUT="$(run '{"source":"startup","session_id":"sess-live-6"}')"
chk "queue still announced alongside the marker" "1 design decision" "$OUT"
chk "marker still written" "sess-live-6" "$(marker)"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
