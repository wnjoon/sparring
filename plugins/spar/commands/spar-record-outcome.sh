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
  not-run|not-triggered|clean|findings|error) ;;
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

mkdir -p reviews || exit 3
out="reviews/spar-${safe_id}-outcome.md"
[ -e "$out" ] && exit 0

tmp="${out}.tmp.$$"
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

mv "$tmp" "$out" || exit 3
trap - EXIT
exit 0
