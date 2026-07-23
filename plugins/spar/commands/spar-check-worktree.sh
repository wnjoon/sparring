#!/usr/bin/env bash
# Guard the Phase 1 frozen-baseline gap: without a content snapshot, changes
# present before /spar cannot be separated from changes made during the loop.
# Usage: spar-check-worktree.sh <true|false>  (include dirty opt-in)
set -uo pipefail

include_dirty="${1-false}"
case "$include_dirty" in
  true|false) ;;
  *) echo "error: invalid include-dirty state" >&2; exit 2 ;;
esac

tmp=$(mktemp) || { echo "error: cannot inspect worktree" >&2; exit 3; }
trap 'rm -f "$tmp"' EXIT

if ! git status --porcelain=v1 --untracked-files=all > "$tmp" 2>/dev/null; then
  echo "error: /spar requires a Git worktree" >&2
  exit 3
fi

if [ -s "$tmp" ] && [ "$include_dirty" != true ]; then
  echo "error: worktree already has tracked, staged, or untracked changes." >&2
  echo "Commit/stash them first, or use --include-dirty to review the entire dirty surface (automatic skip will be disabled)." >&2
  exit 4
fi

exit 0
