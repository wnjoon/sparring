---
name: spar-ready
description: Turn a spec into a checkbox implementation plan on a dedicated branch, then stop — spar-fight executes it task by task.
---

# spar-ready

Turns a spec into a plan and stops. It never runs the review loop; `spar-fight`
does that. This skill mirrors the Claude-hosted `/spar:ready` command.

## 1. Setup

**Before running the block below**, write whatever the user passed — flags and
the spec path or description, byte for byte — to `.claude/spar-args.txt` with your
file-writing tool, creating `.claude` if it does not exist. Never paste their text
into the shell block; the block reads the file as data.

```bash
set -e
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-}"
[ -n "$SPAR_ROOT" ] || SPAR_ROOT=@@SPAR_PLUGIN_ROOT@@
[ -d "$SPAR_ROOT" ] || { echo "Error: set SPAR_PLUGIN_ROOT to sparring's plugins/spar." >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Error: spar-ready must run inside a git repository." >&2; exit 1; }
if [ -f .claude/spar-plan.local.md ]; then echo "Error: a plan is already ready. Run spar-fight, or spar-cancel first." >&2; exit 1; fi
if [ -f .claude/spar.local.md ]; then echo "Error: a fight loop is already active. Use spar-cancel first." >&2; exit 1; fi
# Arguments arrive in a FILE, never pasted into this block — a spec description is
# arbitrary prose, and a line matching a heredoc delimiter would close the heredoc
# early and hand the rest to the shell. Read once, then removed.
RDY_ARGS_FILE=".claude/spar-args.txt"
RDY_RAW="$(cat "$RDY_ARGS_FILE" 2>/dev/null || true)"
rm -f "$RDY_ARGS_FILE"
RESOLVED="$("$SPAR_ROOT/commands/spar-ready-resolve.sh" "$RDY_RAW")" || { printf '%s\n' "$RESOLVED" >&2; exit 1; }
RDY_MODE="${RESOLVED%%$'\t'*}"
RDY_REST="${RESOLVED#*$'\t'}"
RDY_REVIEWER="${RDY_REST%%$'\t'*}"
RDY_REST2="${RDY_REST#*$'\t'}"
RDY_UNATTENDED="${RDY_REST2%%$'\t'*}"
RDY_SPEC="${RDY_REST2#*$'\t'}"
# Mirror of the Claude seat's auto-detect: Codex authors here, so claude reviews
# when it is installed and only a machine without it falls back to same-family.
if [ -z "$RDY_REVIEWER" ]; then
  if command -v claude >/dev/null 2>&1; then RDY_REVIEWER=claude; else RDY_REVIEWER=codex; fi
fi
command -v "$RDY_REVIEWER" >/dev/null 2>&1 || { echo "Error: '$RDY_REVIEWER' CLI not on PATH." >&2; exit 1; }
# Planning is not an enforced loop, so a missing liveness marker is not fatal here
# — but spar-fight WILL refuse without one, and finding that out only after a plan
# has been written wastes the work. Warn now.
RDY_LIVE="$(git rev-parse --git-dir)/spar-hook-live"
if [ "$(head -1 "$RDY_LIVE" 2>/dev/null || true)" != "${CODEX_THREAD_ID:-}" ]; then
  echo "warning: sparring's hooks have not proven themselves live in this session." >&2
  echo "         spar-fight will refuse to start until they do (install them, then" >&2
  echo "         start a new session and accept the trust prompt)." >&2
fi
# Isolate this run on a dedicated branch in the CURRENT directory. No separate
# worktree, so the working directory — and thus every state path the Stop hook
# reads — never changes mid-run. All task commits land on this branch.
RDY_SLUG="$(printf '%s' "$RDY_SPEC" | sed 's#.*/##; s/\.[A-Za-z0-9]*$//' | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed 's/^-*//; s/-*$//' | cut -c1-40)"
[ -n "$RDY_SLUG" ] || RDY_SLUG=run
RDY_BRANCH="spar/${RDY_SLUG}-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$RDY_BRANCH" || { echo "Error: could not create branch $RDY_BRANCH." >&2; exit 1; }
for D in .claude reviews docs/superpowers/plans; do mkdir -p "$D"; done
# Reuse spar's git-excludes so fight's own commits never stage loop artifacts.
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
for pat in 'reviews/spar-*' '.claude/spar*'; do
  grep -qxF "$pat" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$pat" >> "$EXCLUDE"
done
# 'author: codex' is the seat — it decides which family runs the final sweep for
# every task of this plan. Recorded here so the prepared plan is self-describing;
# spar-fight re-stamps it (and the owning session, which is only knowable once the
# plan is actually being fought, possibly from a later session) at launch.
TMP="$(mktemp .claude/spar-plan.local.md.tmp.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<STATE_EOF
---
active: true
phase: planned
mode: ${RDY_MODE}
author: codex
reviewer: ${RDY_REVIEWER}
owner_session:
unattended: ${RDY_UNATTENDED}
plan_path:
branch: ${RDY_BRANCH}
tasks: 0
current: 1
current_review_id:
---
STATE_EOF
mv "$TMP" .claude/spar-plan.local.md
trap - EXIT
printf 'Ready — plan branch %s (author=codex, reviewer=%s, unattended=%s).\nSPEC=%s\n' \
  "$RDY_BRANCH" "$RDY_REVIEWER" "$RDY_UNATTENDED" "$RDY_SPEC"
```

## 2. Write the plan

Read the spec (the `SPEC=` value printed above — a path or an inline
description; if it is a path, read that file). If it is empty or missing, stop
and say so.

Write the implementation plan to `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`:
bite-sized tasks, each with its own failing test → implementation → verification
→ commit steps, and exact file paths. No placeholders — every step must carry the
content an implementer needs, because each task is handed to the loop on its own.

**Watch out:** no line inside a task body may start with `### ` unless it is the
next task heading — the extractor stops there, silently truncating what the
implementer receives. Write fixtures as `printf '### F1-1 …\n'` one-liners.

## 3. Record and ingest

```bash
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-}"
[ -n "$SPAR_ROOT" ] || SPAR_ROOT=@@SPAR_PLUGIN_ROOT@@
. "$SPAR_ROOT/commands/spar-plan-lib.sh"
plan_set_field plan_path "<the plan path you just wrote>"
MODE="$(sed -n 's/^mode: //p' .claude/spar-plan.local.md | head -1)"
bash "$SPAR_ROOT/commands/spar-ready-ingest.sh" "<the plan path>" "$MODE" .claude/spar-plan.local.md
```

## 4. Stop

Tell the user the plan path and branch, and that `spar-fight` with no task will
drive the plan to convergence task by task. Do not start it — the checkpoint here
is deliberate, so the plan can be reviewed or edited first.

## Hard rules

- Never edit `.claude/spar-plan.local.md` by hand after setup. To abort, run the
  `spar-cancel` skill.
- `spar-ready` never runs the review loop. Do not launch a task or write a
  sparring outcome yourself.
