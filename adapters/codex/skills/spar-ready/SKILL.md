---
name: spar-ready
description: Turn a spec into a checkbox implementation plan on a dedicated branch, then stop — spar-fight executes it task by task.
---

# spar-ready

Turns a spec into a plan and stops. It never runs the review loop; `spar-fight`
does that.

1. Refuse if `.claude/spar-plan.local.md` or `.claude/spar.local.md` already
   exists — a plan is pending or a loop is live. Clear with `spar-cancel`.
2. Create a dedicated branch `spar/<slug>-<timestamp>` from the current one, so
   every task commit lands off to the side.
3. Write the plan to `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`: bite-sized
   tasks, each with its own failing test → implementation → verification → commit
   steps, and exact file paths. No placeholders.
4. Record the plan and ingest its `### Task N:` headings into the task table:

```bash
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-$HOME/.codex/sparring/plugins/spar}"
. "$SPAR_ROOT/commands/spar-plan-lib.sh"
plan_set_field plan_path "<the plan path>"
MODE="$(sed -n 's/^mode: //p' .claude/spar-plan.local.md | head -1)"
bash "$SPAR_ROOT/commands/spar-ready-ingest.sh" "<the plan path>" "$MODE" .claude/spar-plan.local.md
```

5. Stop. Tell the user the plan path and branch, and that `spar-fight` with no
   task will drive it to convergence.

**Watch out:** no line inside a task body may start with `### ` unless it is the
next task heading — the extractor stops there, silently truncating what the
implementer receives. Write fixtures as `printf '### F1-1 …\n'` one-liners.
