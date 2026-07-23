#!/usr/bin/env bash
# Persist one immutable, machine-readable terminal outcome before loop cleanup.
# Usage: spar-record-outcome.sh <reason> <state-file> [sweep-result]
set -uo pipefail

reason="${1-}"
state_file="${2-.claude/spar.local.md}"
sweep_result="${3-not-run}"

case "$reason" in
  converged|cap|error-bypass|cancelled|skipped|blocked-pending-user|sweep-findings-at-cap) ;;
  *) echo "error: invalid sparring outcome reason: $reason" >&2; exit 2 ;;
esac
case "$sweep_result" in
  not-run|not-triggered|pending|clean|findings|error) ;;
  *) echo "error: invalid sweep result: $sweep_result" >&2; exit 2 ;;
esac

field() { sed -n "s/^${1}: *//p" "$state_file" 2>/dev/null | head -1; }

review_id=$(field review_id)
round=$(field round)
reviewer=$(field reviewer)

safe_id="$review_id"
if ! printf '%s' "$safe_id" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  safe_id="invalid-$(date -u +%Y%m%d-%H%M%S)-$$"
  review_id="invalid"
fi
case "$round" in ''|*[!0-9]*) round=0;; esac
case "$reviewer" in codex|claude) ;; *) reviewer=unknown;; esac

if [ -e reviews ] || [ -L reviews ]; then
  [ -d reviews ] && [ ! -L reviews ] \
    || { echo "error: reviews must be a real directory" >&2; exit 3; }
else
  mkdir reviews || exit 3
fi
out="reviews/spar-${safe_id}-outcome.md"
if [ -e "$out" ] || [ -L "$out" ]; then
  [ -f "$out" ] && [ ! -L "$out" ] && exit 0
  echo "error: outcome path is not a regular file" >&2
  exit 3
fi

tmp=$(mktemp "reviews/.spar-outcome-${safe_id}.XXXXXX") || exit 3
trap 'rm -f "$tmp"' EXIT
{
  echo "---"
  echo "reason: ${reason}"
  echo "review_id: ${review_id}"
  echo "rounds: ${round}"
  echo "reviewer: ${reviewer}"
  echo "sweep: ${sweep_result}"
  echo "recorded_at: $(date -u +%FT%TZ)"
  echo "---"
} > "$tmp" || exit 3

# A hard-link publish is atomic and never replaces an existing path. If a
# concurrent writer won the race, accept only its regular, non-symlink file.
if ! ln "$tmp" "$out" 2>/dev/null; then
  if [ -f "$out" ] && [ ! -L "$out" ]; then
    exit 0
  fi
  echo "error: could not publish outcome immutably" >&2
  exit 3
fi
rm -f "$tmp"
trap - EXIT
exit 0
