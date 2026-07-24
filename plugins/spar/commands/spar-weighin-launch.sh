#!/usr/bin/env bash
# Activate a spar loop for the weighin current task by writing a valid
# .claude/spar.local.md, and record the generated review_id in weighin state.
# Usage: spar-weighin-launch.sh <weighin-state-file> <task-text-file>
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/spar-weighin-lib.sh"
state="${1:?weighin state}"; taskfile="${2:?task text file}"
[ -f "$taskfile" ] || { echo "error: task text file not found" >&2; exit 2; }

reviewer="$(wgn_field reviewer "$state")"
case "$reviewer" in codex|claude) ;; *) echo "error: bad reviewer in weighin state" >&2; exit 2 ;; esac

id="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
base="$(git rev-parse HEAD 2>/dev/null || echo none)"

mkdir -p .claude
tmp="$(mktemp .claude/spar.local.md.tmp.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
{
  cat <<STATE_EOF
---
active: true
phase: task
round: 0
review_id: ${id}
base_sha: ${base}
reviewer: ${reviewer}
include_dirty: false
max_rounds: 5
sweep_done: false
sweep_result: not-run
---

STATE_EOF
  cat "$taskfile"
} > "$tmp"
mv "$tmp" .claude/spar.local.md
trap - EXIT
wgn_set_field current_review_id "$id" "$state"
