#!/usr/bin/env bash
# sparring — SessionStart hook. Best-effort: announce how many unattended
# design decisions are pending. Never blocks, never errors out a session.
set -uo pipefail
QUEUE="reviews/spar-pending.md"

trap 'exit 0' ERR      # any failure → stay silent, fail open
cat >/dev/null 2>&1 || true   # consume the hook JSON on stdin

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
