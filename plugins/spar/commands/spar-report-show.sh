#!/usr/bin/env bash
# Print one sparring run's frozen final report. With no id, the most recently
# modified report in the reviews directory. Read-only: it never re-derives a
# report (the loop state it would need is deleted at cleanup) and never writes.
# Usage: spar-report-show.sh [review-id] [reviews-dir]
# Exit: 0 printed; 1 nothing readable to show; 2 invalid review id.
set -uo pipefail

id="${1-}"; rev_dir="${2:-reviews}"
case "$rev_dir" in -*) rev_dir="./$rev_dir" ;; esac

if [ -n "$id" ]; then
  printf '%s' "$id" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' \
    || { echo "error: invalid review id: $id" >&2; exit 2; }
  f="${rev_dir}/spar-${id}-report.md"
else
  # Report names are fixed-format (no spaces), so this listing is safe.
  f=$(ls -t "${rev_dir}"/spar-*-report.md 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "No sparring report found in ${rev_dir}/."; exit 1; }
fi

# Only ever read a real regular file — never follow a symlink.
[ -f "$f" ] && [ ! -L "$f" ] \
  || { echo "No readable report at ${f} (missing, a symlink, or not a regular file)."; exit 1; }

echo "# report file: ${f}"
cat "$f"
