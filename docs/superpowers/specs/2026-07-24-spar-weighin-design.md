# `/spar-weighin` — Plan-to-Spar Orchestrator — Design

**Status:** design, rev. 1. Awaiting spec review → writing-plans.

**Roadmap placement:** a **new, independent phase** (Phase 8), not folded into
Phase 5/6/7. Those phases extend the `spar` loop itself (unattended mode, the
Codex-hosted adapter, model economics); the weigh-in is an orchestration layer
*above* `spar`, a different axis. Its only dependency is the already-shipped
Phase 1–4 loop — it needs neither unattended mode, the Codex adapter, nor model
economics — so it is **order-independent** and may be built now, ahead of 5–7.

## Context & goal

Getting from a spec to a reviewed implementation today means driving four
superpowers steps by hand, one after another:

1. `brainstorming` — turn an idea into a spec (`docs/superpowers/specs/…`).
2. `writing-plans` — turn the spec into a checkbox plan (`docs/superpowers/plans/…`).
3. `using-git-worktrees` — create an isolated branch/worktree.
4. `executing-plans` (or `subagent-driven-development`) — implement task-by-task
   with self-review between tasks.

The friction is two-fold. The four invocations are manual and sequential, and
the final step reviews the author's work with the **same** model that wrote it —
exactly the self-assessment bias `spar` exists to remove.

`/spar-weighin` collapses steps 2–4 into one command and swaps the executor:
instead of `executing-plans` self-reviewing, each unit of work is driven to
convergence by the enforced cross-model `spar` loop. The boxing metaphor is the
pre-fight weigh-in — the ritual that gets the fighter ready and into the ring
before the sparring starts.

**Scope boundary — start from a plan, not an idea.** Deciding *what* to build
(brainstorming, or pulling requirements from an issue) stays the user's job and
happens before `/spar-weighin`. The command begins at "I have a spec; make the
plan and run it." This keeps the orchestrator non-interactive and predictable —
it never drags the user into a long brainstorming dialogue.

## Non-goals (this design)

- **Running `brainstorming`.** The user produces the spec separately. If no spec
  is supplied and none is found, the command stops and points the user at
  `brainstorming` — it does not start one.
- **Reimplementing planning, worktrees, or checklist tracking.** The command is a
  thin conductor over the existing superpowers skills. The `writing-plans` output
  *is* the progress-tracking document — its `- [ ]` tasks are the checklist.
- **Changing `spar` internals.** `spar` keeps its single responsibility
  ("implement one task, then review to convergence"). `/spar-weighin` wraps it;
  it does not add flags or phases inside `spar`.
- **Unattended / headless operation.** Design assumes an interactive session, as
  `spar` does today. (Phase 5 unattended mode is separate.)

## Design

### 1. Form — a separate command in the `spar` plugin

A new `/spar-weighin` command lives beside `/spar` and `/spar-cancel` in
`plugins/spar/commands/`. It is an orchestrator, not part of the `spar` review
loop. Keeping it separate preserves `spar`'s single responsibility and lets the
weigh-in evolve (more prep steps, reporting) without touching the loop.

### 2. Input

One argument: the spec.

- A path to a spec file (`docs/superpowers/specs/…`), or
- a short inline description, or
- nothing → resolve the most recent `docs/superpowers/specs/*.md`; if none
  exists, stop with a message telling the user to run `brainstorming` first.

Flags:
- `--whole` — run the entire plan as a single `spar` task (default is one `spar`
  cycle per plan task; see §4).
- Reviewer selection is delegated to `spar` unchanged — `/spar-weighin` forwards
  `--reviewer codex|claude` through to each `spar` invocation.

### 3. Flow

1. **Resolve the spec** (§2).
2. **Plan.** Invoke `writing-plans` on the spec → `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`.
   This document, with its checkbox tasks, is both the plan and the live progress
   tracker.
3. **Ring setup.** Invoke `using-git-worktrees` to create the isolated
   branch/worktree for the feature.
4. **Execute via `spar`** (§4).
5. **Done** when every task has converged. Report which tasks converged, the
   branch/worktree, and the plan path.

### 4. Execution — per-task (default) vs. `--whole`

**Per-task (default).** For each unchecked task in the plan, in order:

1. Start `spar` on that task's content (its Files / Interfaces / Steps block).
2. Let the enforced loop run to `CONVERGED` (or its honest cap/skip outcome).
3. On convergence, check off that task's `- [ ]` boxes in the plan document and
   commit (plan update + the task's code together).
4. Advance to the next task.

Committing after each task gives the next `spar` cycle a clean worktree and a
fresh frozen baseline — which is exactly what `spar` setup requires
(`spar.md`: refuses a pre-existing dirty worktree; freezes `base_sha` at `HEAD`).
Per-task keeps each review diff small, which raises reviewer signal and speeds
convergence, and it mirrors `executing-plans`' per-task checkpoint — with a
cross-model `spar` loop in place of same-model self-review.

**`--whole`.** Feed the entire plan document as one `spar` task. One review loop
over one large diff. Simpler orchestration, but a big diff lowers reviewer signal
and a single late finding can re-open the whole surface. Offered as an option;
not the default.

### 5. The controller — the key new machinery (to be resolved in writing-plans)

This is the design's one genuinely new and risky piece and the part
`writing-plans` must nail down.

`spar` is driven by its own Stop hook across multiple turns and assumes a single
active loop (`spar.md` setup refuses to start if `.claude/spar.local.md` exists).
The per-task mode therefore is **not** a bash loop — it is a meta-loop layered on
top of `spar`'s loop: after one task converges and `spar` cleans up its state, the
weigh-in must re-activate `spar` for the next task and resume until the plan is
exhausted.

That implies a small controller with its own durable state — e.g.
`.claude/spar-weighin.local.md` holding the plan path, the ordered task list, the
current index, the mode (per-task / whole), the resolved reviewer, and the
worktree — plus a hook that, on each Stop, asks: is a weigh-in active, did the
current task's `spar` just terminate, and if so, advance to the next task or
finish. Open questions for `writing-plans`:

- **Hook coexistence — RESOLVED (single combined dispatcher).** A spike found
  Claude Code does not guarantee Stop-hook order, cross-hook decision
  aggregation, or side-effect visibility (`docs/superpowers/notes/weighin-hook-order-spike.md`).
  So the weigh-in registers exactly ONE Stop hook that calls `spar`'s unchanged
  `stop-hook.sh` in-process and then overrides the decision only when a weigh-in
  is active and `spar` approved. No two-hook race remains.
- **Task-boundary detection.** How does the controller know a task's `spar`
  reached a *terminal* outcome (`converged` / `cap` / `skipped` / `cancelled`)
  vs. is still mid-round? `spar` already writes a durable outcome per terminal
  path (`policy.md` §9) — the controller should read that, not re-derive it.
- **Non-converged tasks.** If a task ends at the round cap or a sweep-at-cap, does
  the weigh-in stop and surface it, or continue to the next task? Default:
  **stop and report honestly** — never present unconverged work as done.
- **Checkbox mapping.** How task blocks in the plan map to `- [ ]` lines to check
  off, and how a partial/failed task is reflected.
- **Cancellation.** `/spar-weighin` needs its own cancel (or `/spar-cancel` must
  also tear down weigh-in state).

### 6. Reuse, don't reinvent

Each prep step is an existing skill invoked as-is. `/spar-weighin` contributes
only the glue and the per-task `spar` handoff. If a step's skill changes upstream,
the weigh-in inherits it.

## Risks & open questions

- **Controller/hook design (§5)** is the crux; everything else is orchestration
  of existing pieces. It should be prototyped before the rest is built out.
- **Worktree + `spar` baseline interaction** — `spar` freezes `HEAD`; the
  worktree provides isolation. They compose, but the commit-per-task cadence
  (§4) is load-bearing for a clean baseline and must be verified.
- **`writing-plans` is interactive-ish** (it may ask about decomposition). Confirm
  it can run to completion inside the orchestrator without a separate approval
  gate, or decide where the human checkpoint sits.
- **Whole-plan review quality** — measure whether `--whole` converges acceptably
  or whether per-task should be the only supported mode.

## Terminal state

Spec review → on approval, `writing-plans` produces the implementation plan for
`/spar-weighin` itself.
