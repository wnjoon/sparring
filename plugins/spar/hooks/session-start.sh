#!/usr/bin/env bash
# sparring — SessionStart hook. Best-effort: announce how many unattended
# design decisions are pending. Never blocks, never errors out a session.
set -uo pipefail
QUEUE="reviews/spar-pending.md"

trap 'exit 0' ERR      # any failure → stay silent, fail open
IN=$(cat 2>/dev/null || true)  # consume the hook JSON on stdin

# Liveness marker: the only way an activation step can prove that THIS session's
# hooks actually run. Codex makes hook trust a per-session choice ("Continue
# without trusting (hooks won't run)") and exposes no CLI that reports hook state,
# so no amount of inspecting configuration can answer it — only the hook having
# fired can.
#
# It lives in the git directory, not under reviews/. Activation must consult the
# marker BEFORE it creates anything, so the marker has to sit somewhere that
# already exists on a clean checkout; reviews/ is untracked, and writing it here
# to break that ordering would leave a trace in every repository the user happens
# to open. The git directory always exists for a run sparring can host (both seats
# require a repository), is never committed, and is already where the loop keeps
# its per-repo exclude rules. Outside a repository nothing is written — a session
# that cannot start a loop must leave nothing behind.
#
# --git-dir, not --git-common-dir: the marker names one SESSION, and linked
# worktrees are how a single repository hosts several at once. The common
# directory is shared between them, so a session started in worktree B would
# overwrite worktree A's marker and leave A refusing to activate even though its
# own hooks ran. (The loop's git-excludes keep using the common directory — those
# really are repository-wide.)
#
# Written through a temp file and renamed rather than redirected onto the path.
# A plain redirect follows a symlink, and this marker is exactly the file an
# attacker would want pointed elsewhere: it is written on every session start
# with content they do not control but a path they might. Renaming replaces
# whatever sits there — including a planted link — without ever writing through
# it, and keeps the marker readable atomically by an activation step.
SESSION_ID=$(printf '%s' "$IN" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$SESSION_ID" ]; then
  GITDIR=$(git rev-parse --git-dir 2>/dev/null || true)
  if [ -n "$GITDIR" ] && [ -d "$GITDIR" ]; then
    MTMP=$(mktemp "$GITDIR/spar-hook-live.XXXXXX" 2>/dev/null || true)
    if [ -n "$MTMP" ]; then
      if printf '%s\n' "$SESSION_ID" > "$MTMP" 2>/dev/null; then
        mv -f "$MTMP" "$GITDIR/spar-hook-live" 2>/dev/null || rm -f "$MTMP"
      else
        rm -f "$MTMP"
      fi
    fi
  fi
fi

# Only read a real regular file (never follow a symlink).
[ -f "$QUEUE" ] && [ ! -L "$QUEUE" ] || exit 0

n=$(grep -c '^## ' "$QUEUE" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) exit 0 ;; esac
[ "$n" -gt 0 ] || exit 0

msg="sparring: ${n} design decision(s) are pending from unattended run(s). See ${QUEUE} (and the matching reviews/spar-*-report.md) to resolve them."
jq -nc --arg c "$msg" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null \
  || printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s design decisions pending — see %s"}}\n' "$n" "$QUEUE"
exit 0
