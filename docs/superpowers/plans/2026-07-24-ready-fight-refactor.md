# `ready` / `fight` / `cancel` — Command Re-slice & Rename Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **DO NOT execute this plan by driving it through the sparring loop itself (`/spar-weighin` / the old `/spar`).** This refactor renames and re-slices the very hook scripts that a running loop depends on — renaming them mid-loop is self-modification that breaks the loop. Execute it as plain TDD: adjust/rename tests, edit, and run the **full test suite** (`for t in tests/test_*.sh; do bash "$t"; done`) after every step — the tests run independently of the live hooks and are the real safety net. Only after all five tasks are done and green do we dogfood the finished `/spar:ready` → `/spar:fight` once, in Task 5.

**Goal:** Split today's `/spar-weighin` (which plans *and* executes) into two intuitively-named commands — `/spar:ready` (plan only, then stop) and `/spar:fight` (run the loop) — and rename all "weighin" internals to a coherent `ready` / `fight` / `plan` vocabulary, while keeping the boxing identity at the command surface.

**Architecture:** `ready` does the prep half of today's weigh-in (resolve flags → dedicated branch → write plan doc → ingest into a task table → write a durable handoff state `.claude/spar-plan.local.md` in phase `planned`) and **stops**. `fight` does the execute half: with a task argument and no pending plan it runs a single loop (today's `/spar`); with a pending plan and no argument it launches task 1 and the renamed Stop-hook dispatcher `stop-fight.sh` drives the plan task-by-task to convergence (today's weigh-in orchestration). A pending plan **plus** a task argument is refused (the agreed safety rule). `cancel` clears both states.

**Tech Stack:** POSIX-ish bash (Claude Code plugin commands + hooks), `jq`, `git`, pure-bash `tests/test_*.sh`.

## Global Constraints

- **Scope B — rename thoroughly.** No `weighin` / `wgn` token may remain in `plugins/` scripts, hooks, or `tests/` after this plan. The final Task greps for stragglers.
- **Boxing identity stays at the surface; verbs describe function.** Plugin name stays `spar`; commands are `/spar:ready`, `/spar:fight`, `/spar:cancel`. Internal loop artifacts keep the `spar-` prefix (they belong to the "spar loop").
- **Rename map (authoritative — every task follows it):**
  - Commands: `spar-weighin.md` → `ready.md`; `spar.md` → `fight.md`; `spar-cancel.md` → `cancel.md`.
  - Scripts: `spar-weighin-resolve.sh` → `spar-ready-resolve.sh`; `spar-weighin-ingest.sh` → `spar-ready-ingest.sh`; `spar-weighin-lib.sh` → `spar-plan-lib.sh`; `spar-weighin-launch.sh` → `spar-fight-launch.sh`; `spar-weighin-check.sh` → `spar-fight-check.sh`; `spar-resolve-family.sh` → `spar-fight-resolve.sh`; `stop-weighin.sh` → `stop-fight.sh`.
  - **Unchanged (core/shared):** `stop-hook.sh`, `spar-record-outcome.sh`, `spar-queue-pending.sh`, `spar-classify-change.sh`, `spar-harvest-intent.sh`, `spar-check-worktree.sh`, `session-start.sh`.
  - Lib functions: `wgn_field`→`plan_field`, `wgn_task_line`→`plan_task_line`, `wgn_set_field`→`plan_set_field`, `wgn_set_task_status`→`plan_set_task_status`; default state var `WGN_STATE_DEFAULT`→`PLAN_STATE_DEFAULT`.
  - State file: `.claude/spar-weighin.local.md` → `.claude/spar-plan.local.md`; its `worktree:` key → `branch:`. Log `.claude/spar-weighin.log` → `.claude/spar-fight.log`. Task-text scratch `.claude/spar-weighin-task.txt` → `.claude/spar-fight-task.txt`.
  - **Unchanged loop state:** `.claude/spar.local.md` and all `.claude/spar-*` round artifacts (registry, ledger, judge, matcher, gate, sweep, aliases, diff, intent).
  - Tests: `test_stop_weighin.sh`→`test_stop_fight.sh`; `test_weighin_check.sh`→`test_fight_check.sh`; `test_weighin_ingest.sh`→`test_ready_ingest.sh`; `test_weighin_launch.sh`→`test_fight_launch.sh`; `test_weighin_lib.sh`→`test_plan_lib.sh`; `test_weighin_resolve.sh`→`test_ready_resolve.sh`; `test_weighin_hooks_json.sh`→`test_hooks_json.sh`; `test_resolve_family.sh`→`test_fight_resolve.sh`. New: `test_fight_dispatch.sh`.
- **Behavior parity except the deliberate split:** every capability today's weigh-in has (dedicated branch, per-task checkbox commits, task-by-task auto-advance, honest stop on non-converge, `--whole`, `--reviewer`, `--unattended`) must survive — only the plan/execute boundary moves (`ready` stops after ingest; `fight` starts execution).
- **`git mv` for renames** so history follows. Keep the setup-command shape of the `.md` files intact (they are slash-command bodies executed by Claude Code).
- **Fail-open / style unchanged:** `set -uo pipefail`, atomic `mktemp`+`mv`, symlink guards, `.git/info/exclude` patterns (`.claude/spar*` already covers `spar-plan.local.md`; `reviews/spar-*` unchanged).

---

### Task 1: `ready` — prep-only command

Rename the weigh-in's prep half to `/spar:ready` and **remove execution**: it plans, ingests, writes the handoff state in phase `planned`, and stops. Renames the resolver, ingest, and shared lib it uses.

**Files:**
- Rename: `plugins/spar/commands/spar-weighin.md` → `plugins/spar/commands/ready.md`
- Rename: `plugins/spar/commands/spar-weighin-resolve.sh` → `plugins/spar/commands/spar-ready-resolve.sh`
- Rename: `plugins/spar/commands/spar-weighin-ingest.sh` → `plugins/spar/commands/spar-ready-ingest.sh`
- Rename: `plugins/spar/commands/spar-weighin-lib.sh` → `plugins/spar/commands/spar-plan-lib.sh`
- Rename: `tests/test_weighin_resolve.sh` → `tests/test_ready_resolve.sh`
- Rename: `tests/test_weighin_ingest.sh` → `tests/test_ready_ingest.sh`
- Rename: `tests/test_weighin_lib.sh` → `tests/test_plan_lib.sh`

**Interfaces:**
- Consumes: nothing new (uses the existing plan-doc format `### Task N:`).
- Produces (Task 3's `fight` relies on this exact contract):
  - `.claude/spar-plan.local.md` frontmatter: `active: true`, `phase: planned`, `mode`, `reviewer`, `unattended`, `plan_path`, `branch`, `tasks: N`, `current: 1`, `current_review_id:` (empty), followed by the task table (`index<TAB>status<TAB>heading`).
  - `spar-ready-resolve.sh` prints `<mode>\t<reviewer|empty>\t<unattended>\t<spec>` (unchanged from the old weighin resolver).
  - `spar-plan-lib.sh` exports `plan_field`, `plan_task_line`, `plan_set_field`, `plan_set_task_status`, and `PLAN_STATE_DEFAULT=".claude/spar-plan.local.md"`.

- [ ] **Step 1: Rename the files with git**

```bash
git mv plugins/spar/commands/spar-weighin.md plugins/spar/commands/ready.md
git mv plugins/spar/commands/spar-weighin-resolve.sh plugins/spar/commands/spar-ready-resolve.sh
git mv plugins/spar/commands/spar-weighin-ingest.sh plugins/spar/commands/spar-ready-ingest.sh
git mv plugins/spar/commands/spar-weighin-lib.sh plugins/spar/commands/spar-plan-lib.sh
git mv tests/test_weighin_resolve.sh tests/test_ready_resolve.sh
git mv tests/test_weighin_ingest.sh tests/test_ready_ingest.sh
git mv tests/test_weighin_lib.sh tests/test_plan_lib.sh
```

- [ ] **Step 2: Rewrite `spar-plan-lib.sh` (function + default-path rename)**

Replace the whole file with:

```bash
#!/usr/bin/env bash
# Shared readers/writers for the plan/handoff state file. Sourced, never executed.
# State file layout:
#   ---
#   <frontmatter: name: value>
#   ---
#   <task table: index<TAB>status<TAB>heading  (one row per task)>
PLAN_STATE_DEFAULT=".claude/spar-plan.local.md"

plan_field() { # $1=name [$2=file]
  local f="${2:-$PLAN_STATE_DEFAULT}"
  sed -n "s/^${1}: *//p" "$f" 2>/dev/null | head -1
}

plan_task_line() { # $1=index [$2=file]
  local f="${2:-$PLAN_STATE_DEFAULT}"
  awk -v i="$1" -F'\t' '/^---$/{c++} c>=2 && $1==i {print; exit}' "$f" 2>/dev/null
}

plan_set_field() { # $1=name $2=value [$3=file]
  local f="${3:-$PLAN_STATE_DEFAULT}" tmp
  tmp="${f}.tmp.$$"
  awk -v k="$1" -v v="$2" '
    BEGIN{done=0}
    /^---$/ {marks++}
    marks<2 && $0 ~ "^" k ": *" && !done { print k ": " v; done=1; next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

plan_set_task_status() { # $1=index $2=status [$3=file]
  local f="${3:-$PLAN_STATE_DEFAULT}" tmp
  tmp="${f}.tmp.$$"
  awk -v i="$1" -v s="$2" '
    BEGIN{c=0}
    /^---$/ {c++; print; next}
    c>=2 && $1==i { print $1 "\t" s "\t" substr($0, index($0,$3)); next }
    { print }
  ' FS='\t' OFS='\t' "$f" > "$tmp" && mv "$tmp" "$f"
}
```

- [ ] **Step 3: Update `spar-ready-ingest.sh` to source the renamed lib and use `plan_*`**

In `spar-ready-ingest.sh`, change the source line and the two setter calls. Replace:

```bash
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/spar-weighin-lib.sh"
```
with
```bash
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/spar-plan-lib.sh"
```
and replace the two trailing calls:
```bash
wgn_set_field tasks "$count" "$state"
wgn_set_field phase running "$state"
```
with (note: **`planned`, not `running`** — `ready` no longer launches):
```bash
plan_set_field tasks "$count" "$state"
plan_set_field phase planned "$state"
```

- [ ] **Step 4: Update `test_plan_lib.sh` and `test_ready_ingest.sh` to the new names**

```bash
sed -i '' -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' -e 's/wgn_/plan_/g' -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' tests/test_plan_lib.sh 2>/dev/null \
  || sed -i -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' -e 's/wgn_/plan_/g' -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' tests/test_plan_lib.sh
sed -i '' -e 's/spar-weighin-ingest\.sh/spar-ready-ingest.sh/g' -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' -e 's/wgn_/plan_/g' -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' tests/test_ready_ingest.sh 2>/dev/null \
  || sed -i -e 's/spar-weighin-ingest\.sh/spar-ready-ingest.sh/g' -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' -e 's/wgn_/plan_/g' -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' tests/test_ready_ingest.sh
```

Then open `tests/test_ready_ingest.sh` and, wherever it asserts the post-ingest phase, change the expected value from `running` to `planned` (the ingest now leaves phase `planned`). If it asserts `phase: running`, make it assert `phase: planned`.

- [ ] **Step 5: Run the two renamed tests**

Run: `bash tests/test_plan_lib.sh && bash tests/test_ready_ingest.sh`
Expected: both `PASS=… FAIL=0`. If `test_ready_ingest.sh` still expects `running`, fix the expectation to `planned` and re-run.

- [ ] **Step 6: Update `test_ready_resolve.sh` script path**

The resolver's output contract is unchanged; only its path changed.

```bash
sed -i '' 's#/spar-weighin-resolve\.sh#/spar-ready-resolve.sh#g' tests/test_ready_resolve.sh 2>/dev/null \
  || sed -i 's#/spar-weighin-resolve\.sh#/spar-ready-resolve.sh#g' tests/test_ready_resolve.sh
```

Run: `bash tests/test_ready_resolve.sh`
Expected: `PASS=… FAIL=0` (the `spar-ready-resolve.sh` content is unchanged from the old weighin resolver, which already emits the 4-field output).

- [ ] **Step 7: Rewrite `ready.md` — prep only, no launch**

`ready.md` is the old `spar-weighin.md` with: (a) frontmatter/description updated, (b) the setup block writing `.claude/spar-plan.local.md` with `phase: planned` and `branch:` (not `worktree:`), (c) **Step 4 "Launch task 1" removed** and replaced with a "stop here" instruction, (d) all `spar-weighin-*` paths and `WGN_` vars renamed.

Set the frontmatter:

```
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
```

In the setup bash block, apply these substitutions to the existing `spar-weighin.md` body:
- `spar-weighin.local.md` → `spar-plan.local.md` (all occurrences, including the guard `if [ -f .claude/spar-plan.local.md ]` and the `mktemp` temp name)
- the guard message "a weigh-in is already active. Finish it or run /spar-cancel." → "a plan is already ready. Run /spar:fight, or /spar:cancel first."
- `spar-weighin-resolve.sh` → `spar-ready-resolve.sh`
- `WGN_` → `RDY_` for every shell variable
- In the state heredoc, change `phase: plan` → `phase: planned`, keep `mode/reviewer/unattended/plan_path/tasks/current/current_review_id`, and change `worktree: ${RDY_BRANCH}` → `branch: ${RDY_BRANCH}`
- The final `printf` message: `Ready — plan on branch %s. Review the plan, then run /spar:fight to execute.\nSPEC=%s\n`

Then update the numbered steps after the setup block:
- Step 1 (produce the plan): unchanged except it now says the plan is for `/spar:fight` to execute; keep the "do NOT run writing-plans' execution handoff" note.
- Step 2 (record plan path): change `. ".../commands/spar-weighin-lib.sh"` → `. ".../commands/spar-plan-lib.sh"` and `wgn_set_field plan_path …` → `plan_set_field plan_path …`.
- Step 3 (ingest): change the ingest script path to `spar-ready-ingest.sh`.
- **Delete Step 4 (launch task 1) entirely.** Replace it with: *"Now stop. The plan is written and ingested; `/spar:ready` does not execute. Tell the user the plan path and branch, and that running `/spar:fight` (no arguments) will drive the plan task-by-task."*
- Remove the "Hard rules" bullets that describe launching/convergence-driving (those move to `fight.md`); keep the "never hand-edit state; cancel via /spar:cancel" rule and point cancellation at `/spar:cancel`.

- [ ] **Step 8: Update `spar-ready-resolve.sh` self-reference**

The resolver prints usage strings referencing its own name only in comments; ensure the header comment says `spar-ready-resolve.sh` and mentions this is `/spar:ready`'s resolver. No logic change.

Run: `bash -n plugins/spar/commands/spar-ready-resolve.sh plugins/spar/commands/spar-ready-ingest.sh plugins/spar/commands/spar-plan-lib.sh && echo "syntax OK"`
Expected: `syntax OK`.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: /spar:ready — prep-only rename of the weigh-in plan half"
```

---

### Task 2: `fight` — single-task mode

Rename `/spar` → `/spar:fight` and its family resolver, keeping the single-task loop behavior identical. `stop-hook.sh` (the round engine) is unchanged. Plan-detection is added in Task 3; here `fight <task>` behaves exactly like today's `/spar <task>`.

**Files:**
- Rename: `plugins/spar/commands/spar.md` → `plugins/spar/commands/fight.md`
- Rename: `plugins/spar/commands/spar-resolve-family.sh` → `plugins/spar/commands/spar-fight-resolve.sh`
- Rename: `tests/test_resolve_family.sh` → `tests/test_fight_resolve.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `spar-fight-resolve.sh` prints `<family>\t<include-dirty>\t<unattended>\t<task text>` (unchanged from the old family resolver). `fight.md` single-task path writes `.claude/spar.local.md` (phase `task`) exactly as `spar.md` did.

- [ ] **Step 1: Rename with git**

```bash
git mv plugins/spar/commands/spar.md plugins/spar/commands/fight.md
git mv plugins/spar/commands/spar-resolve-family.sh plugins/spar/commands/spar-fight-resolve.sh
git mv tests/test_resolve_family.sh tests/test_fight_resolve.sh
```

- [ ] **Step 2: Point the fight-resolve test at the new path**

```bash
sed -i '' 's#/spar-resolve-family\.sh#/spar-fight-resolve.sh#g' tests/test_fight_resolve.sh 2>/dev/null \
  || sed -i 's#/spar-resolve-family\.sh#/spar-fight-resolve.sh#g' tests/test_fight_resolve.sh
```

Run: `bash tests/test_fight_resolve.sh`
Expected: `PASS=… FAIL=0` (resolver logic unchanged).

- [ ] **Step 3: Update `fight.md` frontmatter and resolver path (single-task body preserved)**

In `fight.md`, set the description and fix the resolver invocation. Replace the description line:

```
description: "Sparring loop: implement the task, then iterate independent reviews until the reviewer declares CONVERGED"
```
with
```
description: "Fight: run the sparring review loop — a single task, or a plan prepared by /spar:ready"
```

Replace the resolver call:
```bash
RESOLVED="$("${CLAUDE_PLUGIN_ROOT}/commands/spar-resolve-family.sh" "$SPAR_RAW")" || { printf '%s\n' "$RESOLVED" >&2; exit 1; }
```
with
```bash
RESOLVED="$("${CLAUDE_PLUGIN_ROOT}/commands/spar-fight-resolve.sh" "$SPAR_RAW")" || { printf '%s\n' "$RESOLVED" >&2; exit 1; }
```

Leave the rest of the single-task setup (state file `.claude/spar.local.md`, `phase: task`, the `unattended` field, activation echo) unchanged for now. The activation echo may read `Fight (single task) activated …`.

- [ ] **Step 4: Verify single-task fight still activates a loop**

Run:
```bash
bash -n plugins/spar/commands/spar-fight-resolve.sh && echo "syntax OK"
```
Expected: `syntax OK`. (The full loop is exercised by the unchanged `test_stop_hook.sh`, which does not depend on the command file name.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: /spar:fight — rename of the single-task spar loop"
```

---

### Task 3: `fight` plan-aware mode + orchestration

Give `fight` the execute half of the old weigh-in: detect a pending plan and drive it task-by-task via the renamed Stop dispatcher. Add the safety rule (pending plan + task arg → refuse). Renames the launcher, checkbox-flipper, and Stop dispatcher, and repoints `hooks.json`.

**Files:**
- Rename: `plugins/spar/commands/spar-weighin-launch.sh` → `plugins/spar/commands/spar-fight-launch.sh`
- Rename: `plugins/spar/commands/spar-weighin-check.sh` → `plugins/spar/commands/spar-fight-check.sh`
- Rename: `plugins/spar/hooks/stop-weighin.sh` → `plugins/spar/hooks/stop-fight.sh`
- Rename: `tests/test_weighin_launch.sh` → `tests/test_fight_launch.sh`
- Rename: `tests/test_weighin_check.sh` → `tests/test_fight_check.sh`
- Rename: `tests/test_stop_weighin.sh` → `tests/test_stop_fight.sh`
- Rename: `tests/test_weighin_hooks_json.sh` → `tests/test_hooks_json.sh`
- Modify: `plugins/spar/commands/fight.md` (add plan-detection dispatch)
- Modify: `plugins/spar/hooks/hooks.json` (Stop → `stop-fight.sh`)
- Create: `tests/test_fight_dispatch.sh`

**Interfaces:**
- Consumes: `.claude/spar-plan.local.md` (Task 1's handoff state, phase `planned`).
- Produces:
  - `spar-fight-launch.sh <plan-state-file> <task-text-file>` — writes `.claude/spar.local.md` for the current task and records `current_review_id` in plan state (unchanged behavior; sources `spar-plan-lib.sh`, uses `plan_*`, reads `unattended`).
  - `stop-fight.sh` — the single Stop hook: runs `stop-hook.sh`, and when `.claude/spar-plan.local.md` is active + phase `running` + spar approved, advances the plan (commit, next task, relaunch, or finish) exactly as the old `stop-weighin.sh` did.
  - `fight.md` dispatch contract:
    - plan state present + **no** task arg → set plan phase `running`, launch task 1, instruct to implement it.
    - plan state present + task arg → **refuse** (exit non-zero) with: "A plan is ready (run `/spar:fight` with no task), or clear it with `/spar:cancel`."
    - no plan state + task arg → single-task loop (Task 2 behavior).
    - no plan state + no task arg → error: "Nothing to fight. Give a task, or run `/spar:ready <spec>` first."

- [ ] **Step 1: Rename with git**

```bash
git mv plugins/spar/commands/spar-weighin-launch.sh plugins/spar/commands/spar-fight-launch.sh
git mv plugins/spar/commands/spar-weighin-check.sh plugins/spar/commands/spar-fight-check.sh
git mv plugins/spar/hooks/stop-weighin.sh plugins/spar/hooks/stop-fight.sh
git mv tests/test_weighin_launch.sh tests/test_fight_launch.sh
git mv tests/test_weighin_check.sh tests/test_fight_check.sh
git mv tests/test_stop_weighin.sh tests/test_stop_fight.sh
git mv tests/test_weighin_hooks_json.sh tests/test_hooks_json.sh
```

- [ ] **Step 2: Update `spar-fight-launch.sh` (lib source, `plan_*`, state path, log)**

Apply these substitutions to `spar-fight-launch.sh`:

```bash
sed -i '' \
  -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' \
  -e 's/wgn_field/plan_field/g' -e 's/wgn_set_field/plan_set_field/g' \
  -e 's/wgn_task_line/plan_task_line/g' -e 's/wgn_set_task_status/plan_set_task_status/g' \
  plugins/spar/commands/spar-fight-launch.sh 2>/dev/null \
  || sed -i \
  -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' \
  -e 's/wgn_field/plan_field/g' -e 's/wgn_set_field/plan_set_field/g' \
  -e 's/wgn_task_line/plan_task_line/g' -e 's/wgn_set_task_status/plan_set_task_status/g' \
  plugins/spar/commands/spar-fight-launch.sh
```

Then open the file and confirm the header comment references `/spar:fight` (not weigh-in) and that it still reads `reviewer`, `unattended` via `plan_field`. No logic change beyond names.

- [ ] **Step 3: Update `spar-fight-check.sh` (any lib/state references)**

```bash
sed -i '' -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' -e 's/wgn_/plan_/g' -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' plugins/spar/commands/spar-fight-check.sh 2>/dev/null \
  || sed -i -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' -e 's/wgn_/plan_/g' -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' plugins/spar/commands/spar-fight-check.sh
```

(If `spar-fight-check.sh` has no such references, this is a no-op — verify with `grep -n 'wgn\|weighin' plugins/spar/commands/spar-fight-check.sh` returning nothing.)

- [ ] **Step 4: Rewrite `stop-fight.sh` (dispatcher rename + `plan_*` + state path + `branch:`)**

Apply the full rename sweep to `stop-fight.sh`:

```bash
sed -i '' \
  -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' \
  -e 's/spar-weighin\.log/spar-fight.log/g' \
  -e 's/spar-weighin-task\.txt/spar-fight-task.txt/g' \
  -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' \
  -e 's/spar-weighin-check\.sh/spar-fight-check.sh/g' \
  -e 's/spar-weighin-launch\.sh/spar-fight-launch.sh/g' \
  -e 's/wgn_field/plan_field/g' -e 's/wgn_set_field/plan_set_field/g' \
  -e 's/wgn_task_line/plan_task_line/g' -e 's/wgn_set_task_status/plan_set_task_status/g' \
  -e 's/SPAR_WEIGHIN_SPAR_HOOK/SPAR_FIGHT_SPAR_HOOK/g' \
  plugins/spar/hooks/stop-fight.sh 2>/dev/null \
  || sed -i \
  -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' \
  -e 's/spar-weighin\.log/spar-fight.log/g' \
  -e 's/spar-weighin-task\.txt/spar-fight-task.txt/g' \
  -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' \
  -e 's/spar-weighin-check\.sh/spar-fight-check.sh/g' \
  -e 's/spar-weighin-launch\.sh/spar-fight-launch.sh/g' \
  -e 's/wgn_field/plan_field/g' -e 's/wgn_set_field/plan_set_field/g' \
  -e 's/wgn_task_line/plan_task_line/g' -e 's/wgn_set_task_status/plan_set_task_status/g' \
  -e 's/SPAR_WEIGHIN_SPAR_HOOK/SPAR_FIGHT_SPAR_HOOK/g' \
  plugins/spar/hooks/stop-fight.sh
```

Then open `stop-fight.sh` and update user-facing message text: replace "weigh-in" / "sparring weigh-in" wording with "fight" wording (e.g. `systemMessage` "sparring weigh-in: …" → "sparring fight: …"; the completion message "run /spar-cancel" → "run /spar:cancel"). Update the `worktree` read if present (`plan_field worktree` → `plan_field branch`). Behavior/control-flow unchanged.

- [ ] **Step 5: Repoint `hooks.json` at `stop-fight.sh`**

Replace `plugins/spar/hooks/hooks.json` with:

```json
{
  "description": "Sparring fight loop: the Stop hook blocks exit until the independent reviewer declares CONVERGED (the fight dispatcher wraps the round engine and drives a /spar:ready plan task-by-task). SessionStart surfaces pending unattended design decisions.",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh",
            "timeout": 10,
            "statusMessage": "sparring: checking for pending design decisions..."
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop-fight.sh",
            "timeout": 60,
            "statusMessage": "sparring: checking loop phase..."
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 6: Add plan-detection dispatch to `fight.md`**

In `fight.md`, immediately after `RESOLVED=…`/`SPAR_TASK=…` parsing and before the single-task `.claude/spar.local.md` guard, insert the dispatch. The single-task setup that follows stays as the "no plan state + task arg" branch. Insert:

```bash
# ── Dispatch: plan-aware vs single-task ──────────────────────────────────────
PLAN_STATE=".claude/spar-plan.local.md"
if [ -f "$PLAN_STATE" ]; then
  # A plan prepared by /spar:ready is pending.
  if [ -n "$SPAR_TASK" ]; then
    echo "Error: a plan is ready (run /spar:fight with no task to execute it), or clear it with /spar:cancel." >&2
    exit 1
  fi
  . "${CLAUDE_PLUGIN_ROOT}/commands/spar-plan-lib.sh"
  PHASE="$(plan_field phase "$PLAN_STATE")"
  if [ "$PHASE" = "running" ]; then
    echo "Error: this plan is already being fought. Continue by stopping, or /spar:cancel to abandon it." >&2
    exit 1
  fi
  [ "$PHASE" = "planned" ] || { echo "Error: plan state is not ready to fight (phase: $PHASE)." >&2; exit 1; }
  if [ -f .claude/spar.local.md ]; then echo "Error: a fight loop is already active. Use /spar:cancel first."; exit 1; fi
  PLAN="$(plan_field plan_path "$PLAN_STATE")"
  MODE="$(plan_field mode "$PLAN_STATE")"
  [ -f "$PLAN" ] || { echo "Error: plan file not found: $PLAN" >&2; exit 1; }
  plan_set_field phase running "$PLAN_STATE"
  H1="$(plan_task_line 1 "$PLAN_STATE" | cut -f3)"
  if [ "$MODE" = "whole" ]; then cp "$PLAN" .claude/spar-fight-task.txt
  else awk -v h="### ${H1}" '$0==h{f=1} f&&/^### /&&$0!=h&&seen{exit} $0==h{seen=1} f{print}' "$PLAN" > .claude/spar-fight-task.txt; fi
  bash "${CLAUDE_PLUGIN_ROOT}/commands/spar-fight-launch.sh" "$PLAN_STATE" .claude/spar-fight-task.txt || { echo "Error: could not launch task 1." >&2; exit 1; }
  echo "Fight started on the ready plan (task 1/$(plan_field tasks "$PLAN_STATE")). Implement task 1, then stop."
  exit 0
fi
if [ -z "$SPAR_TASK" ]; then
  echo "Error: nothing to fight. Give a task description, or run /spar:ready <spec> first." >&2
  exit 1
fi
# else: no plan state + a task arg → fall through to the single-task setup below.
```

Keep the existing single-task guard/setup after this block unchanged. Update the "Loop protocol"/"Hard rules" prose in `fight.md` to mention that with a `/spar:ready` plan, `fight` drives task-by-task and commits at each boundary, and that cancellation is `/spar:cancel`.

- [ ] **Step 7: Update the renamed orchestration tests**

Sweep the three renamed tests to the new script paths, `plan_*`, and `.claude/spar-plan.local.md`, and repoint the hooks-json test:

```bash
for f in tests/test_fight_launch.sh tests/test_fight_check.sh tests/test_stop_fight.sh; do
  sed -i '' \
    -e 's/spar-weighin-launch\.sh/spar-fight-launch.sh/g' \
    -e 's/spar-weighin-check\.sh/spar-fight-check.sh/g' \
    -e 's/stop-weighin\.sh/stop-fight.sh/g' \
    -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' \
    -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' \
    -e 's/wgn_field/plan_field/g' -e 's/wgn_set_field/plan_set_field/g' \
    -e 's/wgn_task_line/plan_task_line/g' -e 's/wgn_set_task_status/plan_set_task_status/g' \
    "$f" 2>/dev/null || sed -i \
    -e 's/spar-weighin-launch\.sh/spar-fight-launch.sh/g' \
    -e 's/spar-weighin-check\.sh/spar-fight-check.sh/g' \
    -e 's/stop-weighin\.sh/stop-fight.sh/g' \
    -e 's/spar-weighin-lib\.sh/spar-plan-lib.sh/g' \
    -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' \
    -e 's/wgn_field/plan_field/g' -e 's/wgn_set_field/plan_set_field/g' \
    -e 's/wgn_task_line/plan_task_line/g' -e 's/wgn_set_task_status/plan_set_task_status/g' \
    "$f"
done
sed -i '' -e 's/stop-weighin\.sh/stop-fight.sh/g' -e 's/\.hooks\.Stop/.hooks.Stop/g' tests/test_hooks_json.sh 2>/dev/null \
  || sed -i -e 's/stop-weighin\.sh/stop-fight.sh/g' tests/test_hooks_json.sh
```

Then, in any renamed test that builds a plan-state fixture with `phase: running` and expects the launcher/dispatcher to advance, ensure the fixture uses `branch:` instead of `worktree:` where it seeds that key (grep for `worktree:` in the three files and rename to `branch:`). In `test_stop_fight.sh`, the fixtures that drove task-advance already start at `phase: running`, which matches how `fight` sets it — no behavioral change.

Run: `bash tests/test_fight_launch.sh && bash tests/test_fight_check.sh && bash tests/test_stop_fight.sh && bash tests/test_hooks_json.sh`
Expected: all `PASS=… FAIL=0`. Fix any remaining `worktree:`/name mismatches surfaced by failures.

- [ ] **Step 8: Write `tests/test_fight_dispatch.sh` (the new routing)**

Create `tests/test_fight_dispatch.sh`. Because the dispatch lives inside the `fight.md` slash-command body (not a standalone script), this test extracts and exercises the dispatch block against fixture states. Simplest robust approach: assert the four routes via a harness that seeds state and greps the command body for the guard logic, plus a direct behavioral check of the launcher path already covered by `test_fight_launch.sh`. Concretely, assert the command file encodes each route:

```bash
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
F="$ROOT/plugins/spar/commands/fight.md"
chk(){ if grep -qF "$2" "$F"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }

chk "detects a pending plan state" '.claude/spar-plan.local.md'
chk "refuses plan + task arg (safety rule)" 'a plan is ready (run /spar:fight with no task'
chk "refuses when already running" 'already being fought'
chk "requires phase planned before launch" 'phase: $PHASE'
chk "launches task 1 via fight-launch" 'spar-fight-launch.sh'
chk "errors on no plan and no task" 'nothing to fight'
chk "single-task path still guarded" 'a fight loop is already active'

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

Run: `bash tests/test_fight_dispatch.sh`
Expected: `PASS=7 FAIL=0`.

- [ ] **Step 9: Syntax-check the touched shell**

Run: `bash -n plugins/spar/hooks/stop-fight.sh plugins/spar/commands/spar-fight-launch.sh plugins/spar/commands/spar-fight-check.sh && jq -e . plugins/spar/hooks/hooks.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "refactor: /spar:fight drives a ready plan; stop-fight dispatcher + hooks repoint"
```

---

### Task 4: `cancel` rename + stale-token sweep

Rename the cancel command, point it at both state files, and prove no `weighin`/`wgn` token survives anywhere in `plugins/` or `tests/`.

**Files:**
- Rename: `plugins/spar/commands/spar-cancel.md` → `plugins/spar/commands/cancel.md`
- Modify: `plugins/spar/shared/policy.md` (weighin wording)
- Modify: any remaining stragglers found by the sweep grep.

**Interfaces:**
- Consumes: `.claude/spar-plan.local.md`, `.claude/spar.local.md`, loop artifacts.
- Produces: `/spar:cancel` removes both states and the loop artifacts; keeps `reviews/` artifacts.

- [ ] **Step 1: Rename cancel and update its state paths**

```bash
git mv plugins/spar/commands/spar-cancel.md plugins/spar/commands/cancel.md
sed -i '' -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' -e 's/spar-weighin\.log/spar-fight.log/g' -e 's/spar-weighin-task\.txt/spar-fight-task.txt/g' plugins/spar/commands/cancel.md 2>/dev/null \
  || sed -i -e 's/spar-weighin\.local\.md/spar-plan.local.md/g' -e 's/spar-weighin\.log/spar-fight.log/g' -e 's/spar-weighin-task\.txt/spar-fight-task.txt/g' plugins/spar/commands/cancel.md
```

Then update its description frontmatter to `"Cancel: clear the active fight loop and/or ready plan state"` and any "Weigh-in state cleared." message to "Plan state cleared."

- [ ] **Step 2: Update `policy.md` wording**

```bash
sed -i '' -e 's/spar-weighin/spar:fight/g' -e 's/weigh-in/fight/g' -e 's/weighin/fight/g' plugins/spar/shared/policy.md 2>/dev/null \
  || sed -i -e 's/spar-weighin/spar:fight/g' -e 's/weigh-in/fight/g' -e 's/weighin/fight/g' plugins/spar/shared/policy.md
```

Then read `policy.md` and fix any sentence the blunt sed made awkward (e.g. reflow "the fight orchestrator" phrasing so it reads naturally). This is prose — verify it reads correctly.

- [ ] **Step 3: Sweep for stragglers**

Run:
```bash
grep -rn 'weighin\|weigh-in\|wgn_\|WGN_\|stop-weighin\|worktree:' plugins/ tests/ || echo "CLEAN"
```
Expected: `CLEAN`. For each hit that remains, rename per the Task's rename map (commands/scripts already handled in Tasks 1–3; anything left is a missed reference — fix it and re-run until `CLEAN`). Note: `worktree:` should now be `branch:` everywhere the plan state is written or read.

- [ ] **Step 4: Full suite green**

Run:
```bash
FAILED=0; for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 || { echo "FAIL: $t"; FAILED=1; }; done; [ "$FAILED" = 0 ] && echo "ALL GREEN"
```
Expected: `ALL GREEN`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: /spar:cancel rename; purge weighin/wgn tokens from plugin + tests"
```

---

### Task 5: Docs, plugin metadata, and end-to-end dogfood

Bring user-facing docs in line with `ready`/`fight`/`cancel`, update plugin metadata, and validate the finished commands with one real run.

**Files:**
- Modify: `README.md`
- Modify: `docs/design-decisions.md`
- Modify: `plugins/spar/.claude-plugin/plugin.json`
- Modify: the Phase 5 plan/spec docs' command references (light touch — historical docs get a one-line note, not a rewrite).

**Interfaces:** none (docs + validation).

- [ ] **Step 1: Update `README.md` command names and usage**

Replace `/spar-weighin` → `/spar:fight` (for the orchestrator role) and `/spar` → `/spar:fight` for single-task, and add `/spar:ready` where the plan step is described. Specifically:
- The status line and Phase 8 row: describe the split — "`/spar:ready` writes a checkbox plan; `/spar:fight` runs it task-by-task (or a single ad-hoc task)."
- The usage block (`/spar <task description>`) → `/spar:fight <task description>` and add a `/spar:ready <spec>` example followed by `/spar:fight`.
- The `--reviewer` / `--include-dirty` / `--unattended` mentions: keep, now under `/spar:fight` and `/spar:ready`.
- The image `alt` text "weighin — …" can stay (it's an image caption); update the surrounding prose to "ready → fight".
- The repo-layout blurb "`/spar, /spar-cancel, setup guards`" → "`/spar:ready, /spar:fight, /spar:cancel, setup guards`".

- [ ] **Step 2: Update `docs/design-decisions.md`**

Replace command references (`/spar-weighin` → `/spar:fight`, note the `ready`/`fight` split in the Phase 8 section). Add a short note in the relevant section: "As of this refactor, the weigh-in is split into `/spar:ready` (plan) and `/spar:fight` (execute); `fight` auto-detects a pending plan and refuses a task argument while one is pending."

- [ ] **Step 3: Update `plugin.json` description + version**

In `plugins/spar/.claude-plugin/plugin.json`, update the description to name the split and bump the version:

```json
  "version": "0.5.0",
  "description": "Enforced review sparring with blind rounds, safe skips, intent pointers, a risk-triggered final sweep, unattended mode, and a /spar:ready plan → /spar:fight execute workflow",
```

- [ ] **Step 4: Add a one-line note to the Phase 5 plan/spec docs**

At the top of `docs/superpowers/plans/2026-07-24-phase5-unattended-mode.md` and the two 2026-07-24 spec docs that reference `/spar` or `/spar-weighin`, add a single italic note: *"Command names updated post-refactor: `/spar` → `/spar:fight`, `/spar-weighin` → `/spar:ready` (plan) + `/spar:fight` (execute)."* Do not rewrite their bodies.

- [ ] **Step 5: Full suite green (final)**

Run:
```bash
FAILED=0; for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 || { echo "FAIL: $t"; FAILED=1; }; done; [ "$FAILED" = 0 ] && echo "ALL GREEN"
```
Expected: `ALL GREEN`.

- [ ] **Step 6: Dogfood the finished commands (validation)**

This validates the *result*, not the process (safe now — the machinery is stable). On a throwaway spec:
- Run `/spar:ready` on a tiny one-task spec; confirm it writes `.claude/spar-plan.local.md` (phase `planned`), writes a plan doc, and **stops without launching**.
- Confirm `/spar:fight my ad-hoc task` is **refused** while the plan is pending (safety rule).
- Run `/spar:fight` (no args); confirm it launches task 1 and the Stop hook (`stop-fight.sh`) drives it.
- After it converges/commits, confirm `/spar:cancel` clears `.claude/spar-plan.local.md`.
- Record the observed behavior in the commit message.

If any step misbehaves, that is a finding — fix it and re-run the suite before committing.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "docs: ready/fight/cancel rename across README, design-decisions, plugin metadata"
```

---

## Self-Review notes

- **Split (plan vs execute):** `ready` (Task 1, phase `planned`, no launch) + `fight` plan-detection (Task 3). The original complaint — "weigh-in planned *and* executed" — is resolved by the `planned` stop point.
- **Safety rule (pending plan + task arg → refuse):** Task 3 Step 6 dispatch + `test_fight_dispatch.sh`.
- **Behavior parity:** dedicated branch, per-task commits, task-by-task advance, honest non-converge stop, `--whole`/`--reviewer`/`--unattended` all preserved — only moved from one command into `ready`+`fight`. `stop-fight.sh` is a pure rename of `stop-weighin.sh` (control flow untouched).
- **Scope-B completeness:** Task 4 Step 3 greps `plugins/` + `tests/` for `weighin|wgn_|WGN_|stop-weighin|worktree:` and requires `CLEAN`.
- **Executed as plain TDD, not via the loop:** the header banner forbids self-driving; every task ends on a green suite run. The only loop run is the final dogfood in Task 5, against the finished commands.
- **Unattended (Phase 5) carried intact:** `spar-fight-launch.sh` still reads `unattended` via `plan_field`; `stop-hook.sh` (unchanged) still honors it.
