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
# fired can. Written under reviews/, which already exists for a real run, and
# never created here: an unrelated session must leave no trace.
SESSION_ID=$(printf '%s' "$IN" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$SESSION_ID" ] && [ -d reviews ] && [ ! -L reviews ]; then
  printf '%s\n' "$SESSION_ID" > reviews/.spar-hook-live 2>/dev/null || true
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
