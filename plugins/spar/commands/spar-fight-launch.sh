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

# Author seat and owning session travel with the PLAN, not with one task: the
# hook launches every task after the first, so a value carried only by the seat's
# activation step would be lost from task 2 onward. Both are absent from a
# Claude-hosted plan state, and absent means "the historical default" — author
# claude, no session gating — so those state files stay byte-identical.
author="$(plan_field author "$state")"
case "$author" in '' | codex | claude) ;;
  *) echo "error: bad author in plan state: $author" >&2; exit 2 ;;
esac
owner_session="$(plan_field owner_session "$state")"
# A newline in the session id would inject an arbitrary field into the state file.
case "$owner_session" in *[!A-Za-z0-9_.-]*)
  echo "error: owner_session in plan state has unexpected characters" >&2; exit 2 ;;
esac

# Propagate the plan's unattended flag into each task's fight state. A missing
# or malformed value defaults to false (attended) — older plan states that
# predate the flag keep working unchanged.
unattended="$(plan_field unattended "$state")"
case "$unattended" in true) ;; ''|false) unattended=false ;; *) unattended=false ;; esac

id="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
base="$(git rev-parse HEAD 2>/dev/null || echo none)"

# Best-effort and one call per run: a CLI that will not report a version must not
# stop a run, and this is the version the run STARTED with — a CLI that updates
# mid-run will have done some rounds under a build this does not name. Normalised
# to one bounded printable line so it cannot forge a frontmatter field.
reviewer_version="$("$reviewer" --version 2>/dev/null | head -1 \
  | tr -d '\000-\037\177' | LC_ALL=C tr -cd '\040-\176' | cut -c1-120)"
[ -n "$reviewer_version" ] || reviewer_version=unknown

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
STATE_EOF
  [ -n "$author" ] && printf 'author: %s\n' "$author"
  cat <<STATE_EOF
reviewer: ${reviewer}
reviewer_version: ${reviewer_version}
STATE_EOF
  [ -n "$owner_session" ] && printf 'owner_session: %s\n' "$owner_session"
  cat <<STATE_EOF
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
