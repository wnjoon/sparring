#!/usr/bin/env bash
# Activate a fight loop for the plan's current task by writing a valid
# .claude/spar.local.md, and record the generated review_id in the plan state.
# Usage: spar-fight-launch.sh <plan-state-file> <task-text-file>
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/spar-plan-lib.sh"
state="${1:?plan state}"; taskfile="${2:?task text file}"
[ -f "$taskfile" ] || { echo "error: task text file not found" >&2; exit 2; }

reviewer="$(plan_field reviewer "$state")"
case "$reviewer" in codex|claude) ;; *) echo "error: bad reviewer in plan state" >&2; exit 2 ;; esac

# Propagate the plan's unattended flag into each task's fight state. A missing
# or malformed value defaults to false (attended) — older plan states that
# predate the flag keep working unchanged.
unattended="$(plan_field unattended "$state")"
case "$unattended" in true) ;; ''|false) unattended=false ;; *) unattended=false ;; esac

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
unattended: ${unattended}
max_rounds: 5
sweep_done: false
sweep_result: not-run
---

STATE_EOF
  cat "$taskfile"
} > "$tmp"
mv "$tmp" .claude/spar.local.md
trap - EXIT
plan_set_field current_review_id "$id" "$state"
