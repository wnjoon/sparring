---
description: "Weigh-in: turn a spec into a checkbox plan, set up the ring, and run the enforced spar loop task-by-task to convergence"
argument-hint: "[--whole] [--reviewer codex|claude] [--] <spec path or description>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

First, activate the weigh-in by running this setup command:

```bash
set -e
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Error: /spar-weighin must run inside a git repository."; exit 1; }
if [ -f .claude/spar-weighin.local.md ]; then echo "Error: a weigh-in is already active. Finish it or run /spar-cancel."; exit 1; fi
if [ -f .claude/spar.local.md ]; then echo "Error: a sparring loop is already active. Use /spar-cancel first."; exit 1; fi
WGN_RAW="$(cat <<'WGN_ARGS_EOF'
$ARGUMENTS
WGN_ARGS_EOF
)"
RESOLVED="$("${CLAUDE_PLUGIN_ROOT}/commands/spar-weighin-resolve.sh" "$WGN_RAW")" || { printf '%s\n' "$RESOLVED" >&2; exit 1; }
WGN_MODE="${RESOLVED%%$'\t'*}"
WGN_REST="${RESOLVED#*$'\t'}"
WGN_REVIEWER="${WGN_REST%%$'\t'*}"
WGN_SPEC="${WGN_REST#*$'\t'}"
# Reviewer: empty means auto-detect (codex if present, else claude), matching /spar.
if [ -z "$WGN_REVIEWER" ]; then
  if command -v codex >/dev/null 2>&1; then WGN_REVIEWER=codex; else WGN_REVIEWER=claude; fi
fi
command -v "$WGN_REVIEWER" >/dev/null 2>&1 || { echo "Error: '$WGN_REVIEWER' CLI not on PATH."; exit 1; }
# Isolate this run on a dedicated branch in the CURRENT directory. No separate
# worktree, so the working directory — and thus every state path the Stop hook
# reads — never changes mid-run. All task commits land on this branch.
WGN_SLUG="$(printf '%s' "$WGN_SPEC" | sed 's#.*/##; s/\.[A-Za-z0-9]*$//' | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed 's/^-*//; s/-*$//' | cut -c1-40)"
[ -n "$WGN_SLUG" ] || WGN_SLUG=run
WGN_BRANCH="weighin/${WGN_SLUG}-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$WGN_BRANCH" || { echo "Error: could not create branch $WGN_BRANCH."; exit 1; }
for D in .claude reviews docs/superpowers/plans; do mkdir -p "$D"; done
# Reuse spar's git-excludes so weighin's own commits never stage loop artifacts.
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
for pat in 'reviews/spar-*' '.claude/spar*'; do
  grep -qxF "$pat" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$pat" >> "$EXCLUDE"
done
TMP="$(mktemp .claude/spar-weighin.local.md.tmp.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<STATE_EOF
---
active: true
phase: plan
mode: ${WGN_MODE}
reviewer: ${WGN_REVIEWER}
plan_path:
worktree: ${WGN_BRANCH}
tasks: 0
current: 1
current_review_id:
---
STATE_EOF
mv "$TMP" .claude/spar-weighin.local.md
trap - EXIT
printf 'Weigh-in activated (mode=%s, reviewer=%s, branch=%s)\nSPEC=%s\n' "$WGN_MODE" "$WGN_REVIEWER" "$WGN_BRANCH" "$WGN_SPEC"
```

Then run these steps in order. Do NOT stop until task 1's sparring loop is
launched — from that point the weigh-in Stop hook drives the rest.

1. **Produce the plan.** Read the spec (the `SPEC=` value printed above — a path
   or an inline description; if it is a path, read that file). Use the
   `superpowers:writing-plans` skill to write the implementation plan to
   `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`. **Do NOT run writing-plans'
   execution handoff (do not offer subagent/inline execution) — the weigh-in is
   the executor.** If the spec is empty or missing, stop and tell the user to run
   `superpowers:brainstorming` first.

2. **Record the plan path.** The dedicated branch was already created at setup
   (shown as `branch=` above), so there is no worktree to make — just record the
   plan path into state:

   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/commands/spar-weighin-lib.sh"
   wgn_set_field plan_path "<the plan path you just wrote>"
   ```

3. **Ingest the plan into the task table:**

   ```bash
   MODE="$(sed -n 's/^mode: //p' .claude/spar-weighin.local.md | head -1)"
   bash "${CLAUDE_PLUGIN_ROOT}/commands/spar-weighin-ingest.sh" "<the plan path>" "$MODE" .claude/spar-weighin.local.md
   ```

4. **Launch task 1.** Write task 1's text to a file and activate its sparring
   loop, then implement it:

   ```bash
   PLAN="$(sed -n 's/^plan_path: //p' .claude/spar-weighin.local.md | head -1)"
   MODE="$(sed -n 's/^mode: //p' .claude/spar-weighin.local.md | head -1)"
   H1="$(awk -F'\t' 'c>=2 && $1==1{print $3; exit}' <(awk '/^---$/{c++}{print}' .claude/spar-weighin.local.md))"
   if [ "$MODE" = "whole" ]; then cp "$PLAN" .claude/spar-weighin-task.txt
   else awk -v h="### ${H1}" '$0==h{f=1} f&&/^### /&&$0!=h&&seen{exit} $0==h{seen=1} f{print}' "$PLAN" > .claude/spar-weighin-task.txt; fi
   bash "${CLAUDE_PLUGIN_ROOT}/commands/spar-weighin-launch.sh" .claude/spar-weighin.local.md .claude/spar-weighin-task.txt
   ```

   Then implement task 1 following its steps in the plan. When you believe it is
   done, stop — the sparring reviewer engages automatically, and on convergence
   the weigh-in advances to the next task on its own.

## Hard rules

- Never edit `.claude/spar-weighin.local.md` or `.claude/spar.local.md` by hand
  after setup. To abort, run `/spar-cancel`.
- Never write a sparring outcome or convergence marker yourself.
- If a task's loop ends unconverged, the weigh-in stops and asks you to report
  honestly — do not present the work as finished.
