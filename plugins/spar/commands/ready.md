---
description: "Ready: turn a spec into a checkbox plan on a dedicated branch, then stop — run /spar:fight to execute it"
argument-hint: "[--whole] [--reviewer codex|claude] [--unattended] [--] <spec path or description>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

First, prepare the plan by running this setup command:

```bash
set -e
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Error: /spar:ready must run inside a git repository."; exit 1; }
if [ -f .claude/spar-plan.local.md ]; then echo "Error: a plan is already ready. Run /spar:fight, or /spar:cancel first."; exit 1; fi
if [ -f .claude/spar.local.md ]; then echo "Error: a fight loop is already active. Use /spar:cancel first."; exit 1; fi
RDY_RAW="$(cat <<'RDY_ARGS_EOF'
$ARGUMENTS
RDY_ARGS_EOF
)"
RESOLVED="$("${CLAUDE_PLUGIN_ROOT}/commands/spar-ready-resolve.sh" "$RDY_RAW")" || { printf '%s\n' "$RESOLVED" >&2; exit 1; }
RDY_MODE="${RESOLVED%%$'\t'*}"
RDY_REST="${RESOLVED#*$'\t'}"
RDY_REVIEWER="${RDY_REST%%$'\t'*}"
RDY_REST2="${RDY_REST#*$'\t'}"
RDY_UNATTENDED="${RDY_REST2%%$'\t'*}"
RDY_SPEC="${RDY_REST2#*$'\t'}"
# Reviewer: empty means auto-detect (codex if present, else claude), matching /spar:fight.
if [ -z "$RDY_REVIEWER" ]; then
  if command -v codex >/dev/null 2>&1; then RDY_REVIEWER=codex; else RDY_REVIEWER=claude; fi
fi
command -v "$RDY_REVIEWER" >/dev/null 2>&1 || { echo "Error: '$RDY_REVIEWER' CLI not on PATH."; exit 1; }
# Isolate this run on a dedicated branch in the CURRENT directory. No separate
# worktree, so the working directory — and thus every state path the Stop hook
# reads — never changes mid-run. All task commits land on this branch.
RDY_SLUG="$(printf '%s' "$RDY_SPEC" | sed 's#.*/##; s/\.[A-Za-z0-9]*$//' | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed 's/^-*//; s/-*$//' | cut -c1-40)"
[ -n "$RDY_SLUG" ] || RDY_SLUG=run
RDY_BRANCH="spar/${RDY_SLUG}-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$RDY_BRANCH" || { echo "Error: could not create branch $RDY_BRANCH."; exit 1; }
for D in .claude reviews docs/superpowers/plans; do mkdir -p "$D"; done
# Reuse spar's git-excludes so fight's own commits never stage loop artifacts.
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
for pat in 'reviews/spar-*' '.claude/spar*'; do
  grep -qxF "$pat" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$pat" >> "$EXCLUDE"
done
# The 'branch' state field holds the dedicated branch name (there is no separate
# worktree; the working directory stays put so the Stop hook's paths never move).
TMP="$(mktemp .claude/spar-plan.local.md.tmp.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<STATE_EOF
---
active: true
phase: planned
mode: ${RDY_MODE}
reviewer: ${RDY_REVIEWER}
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
printf 'Ready — plan branch %s (reviewer=%s, unattended=%s). Review the plan, then run /spar:fight to execute.\nSPEC=%s\n' "$RDY_BRANCH" "$RDY_REVIEWER" "$RDY_UNATTENDED" "$RDY_SPEC"
```

Then run these steps in order, and **stop after ingest** — `/spar:ready` prepares
the plan but does NOT execute it. Execution is `/spar:fight`.

1. **Produce the plan.** Read the spec (the `SPEC=` value printed above — a path
   or an inline description; if it is a path, read that file). Use the
   `superpowers:writing-plans` skill to write the implementation plan to
   `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`. **Do NOT run writing-plans'
   execution handoff (do not offer subagent/inline execution) — `/spar:fight` is
   the executor.** If the spec is empty or missing, stop and tell the user to run
   `superpowers:brainstorming` first.

2. **Record the plan path** into the plan state:

   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/commands/spar-plan-lib.sh"
   plan_set_field plan_path "<the plan path you just wrote>"
   ```

3. **Ingest the plan into the task table:**

   ```bash
   MODE="$(sed -n 's/^mode: //p' .claude/spar-plan.local.md | head -1)"
   bash "${CLAUDE_PLUGIN_ROOT}/commands/spar-ready-ingest.sh" "<the plan path>" "$MODE" .claude/spar-plan.local.md
   ```

4. **Stop.** The plan is written and ingested; `/spar:ready` does not execute.
   Tell the user the plan path and branch, and that running `/spar:fight` (with no
   arguments) will drive the plan task-by-task to convergence — with a natural
   checkpoint here to review or edit the plan first.

## Hard rules

- Never edit `.claude/spar-plan.local.md` by hand after setup. To abort, run
  `/spar:cancel`.
- `/spar:ready` never runs the review loop — it only plans. Do not launch a
  task or write a sparring outcome yourself.
