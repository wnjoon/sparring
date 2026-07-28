# Phase 9 — plan review

An independent pass over a plan before `/spar:fight` executes it.

## Why

The plan is the one artifact in this system that no independent pass ever reads.
`/spar:ready` stops so a human can review it, and that checkpoint was deliberate;
a *machine* review was never considered rather than considered and rejected.

Three plan defects reached execution or came close, each a fact about the code
rather than a matter of taste, and each invisible to someone reading a long plan
against a longer hook:

- `2026-07-26-phase6-remaining.md` gave a task an unsatisfiable placement
  instruction. It was followed, the round cap was reached, and the plan had to be
  corrected before the task could converge — a full loop spent on a defect that
  predated the first line of code.
- `2026-07-27-phase7-model-economics.md` told the implementer to splice flags into
  "the reviewer, judge, matcher and sweep emitters". There are two emitters and
  they branch on different families; the sweep is author-family, so the reviewer's
  model reaching it would misconfigure a cross-model run silently.
- `2026-07-28-judge-and-sweep-cap.md` told the implementer to insert a fixture
  edit "after `sweep_review_repo 5`" in two test cases. One of them does not call
  that helper at all, so the instruction was not executable for a task-scoped
  implementer who sees nothing else.

The last two were caught by running this pass **by hand**, twice, on 2026-07-28.
Both passes returned a blocker. That is the whole argument: the loop's premise is
that an author does not grade its own work, a plan is authored work, and today it
is graded by its author until execution proves otherwise.

## What it is

One blind pass, dispatched by the hook while the plan is waiting at its human
checkpoint. It reads the plan, the spec the plan came from, and the repository.
It reports findings. It does not block execution, does not iterate, and never
declares anything converged.

## Decisions

| Question | Decision |
|---|---|
| When does it run | Always, with `/spar:ready --no-plan-review` to opt out |
| Who enforces it | The Stop hook, not skill instructions |
| Which reviewer | The `reviewer:` already resolved and stored by `/spar:ready` |
| What may it examine | Checkable facts only — see the brief below |
| What happens on findings | They reach the human at the existing checkpoint |
| Does a finding block `/spar:fight` | No |
| What if the plan changes after review | Record a hash, report the mismatch, proceed |

Three of these were settled during the 2026-07-28 session; the enforcement and
staleness answers were settled while writing this spec.

## Architecture

`stop-fight.sh:59` returns early whenever the plan's phase is not `running`, so
the `planned` phase is a seat the dispatcher currently ignores. That is where this
lives — no new hook, no change to the loop engine.

**Flow.**

1. `/spar:ready` setup writes the spec text to `.claude/spar-plan-spec.txt` and
   `plan_review: pending` into the plan state. With `--no-plan-review` it writes
   `plan_review: skipped` instead and nothing below fires.
2. The session writes the plan, records `plan_path`, ingests the task table. Phase
   becomes `planned`. The session stops.
3. The dispatcher sees `planned` + `pending`, prepares the runner, and **blocks**
   with an instruction to run it.
4. The session runs the runner and stops.
5. The dispatcher validates the result, records the plan file's hash as
   `plan_hash`, sets `plan_review: done`, and **blocks once more** telling the
   session to present the findings to the user.
6. The next stop passes through. The plan sits at its checkpoint as before, now
   with a machine reading attached.
7. `/spar:fight` compares the plan's current hash against `plan_hash`. A mismatch
   is reported and execution proceeds.

**Why the hook rather than an instruction.** `/spar:ready` is a markdown skill; a
step added to it is a sentence a session may skip. This project exists because
instructions get skipped — the loop is hook-enforced for exactly that reason, and
Phase 9's own argument is that authored work needs a grader that is not the
author. An unenforced plan review would be the author choosing whether to be
graded.

**Why a separate preparation script.** `stop-hook.sh`'s `emit_runner` is bound to
loop state — `REVIEW_ID`, `BASE`, the frozen baseline — and no loop exists at plan
time. A new `plugins/spar/commands/spar-plan-review-prepare.sh` writes the prompt
and the runner. It reuses the reviewer family resolution and the economics reader
the same way, so a configured model and effort apply here too.

## The brief

Bounded to what a reader with the repository can check and a human cannot cheaply.
Five questions:

1. Does every claim the plan makes about existing code hold — line numbers,
   function names, helper behaviour, what a document currently says?
2. Is every step satisfiable as written, by an implementer who sees only that one
   task's text?
3. Would each test the plan specifies actually fail before the change, for the
   stated reason?
4. Does the plan cover the spec — is there a requirement with no task?
5. Does any task body contain a line beginning with `### `? The extractor that
   hands one task to the implementer splits on exactly that, so a stray one
   truncates the task.

Question 3 is not in the original Phase 9 sketch and is the one addition. Both
hand-run passes found checks that would have passed before the change they were
meant to prove, and that is a fact about the plan's own text rather than a
judgment about its design.

**Deliberately excluded: design critique.** The most valuable finding across the
two hand-run passes was that a task's design was wrong — the plan told the
implementer to withhold a diff that two prompts instruct their reader to inspect.
Including that in the brief would have caught it. It is excluded anyway, because
it is the door through which a reviewer starts proposing a different plan, and a
plan that grows each round is the failure mode this pass is shaped to avoid. The
human checkpoint remains the place where design is questioned.

## Output contract

First line is `PLAN-REVIEW: CLEAN` or `PLAN-REVIEW: FINDINGS`, then findings in
the same shape the loop's reviewers use.

The marker deliberately differs from the loop's `STATUS:` — the same reason the
final sweep uses `SWEEP:`. Convergence is the reviewer's word inside a task loop,
and no artifact produced outside one may be mistaken for it.

The result is written to `reviews/spar-plan-<slug>-<timestamp>.md` and kept.
`reviews/spar-*` is already in `.git/info/exclude`, so it never enters a later
review surface.

## Failure behaviour

The hook's existing discipline: block up to three times, then open.

| Condition | Result |
|---|---|
| Reviewer CLI absent | `plan_review: skipped`, say why, pass through |
| No result file after 3 dispatches | `plan_review: error`, pass through |
| First line is not a `PLAN-REVIEW:` marker | Set aside as `.invalid-N`, re-dispatch; after 3, pass through |
| `plan_review` absent from an older state file | Treated as `skipped` |

Nothing here ever blocks `/spar:fight`. The pass is information attached to a
human checkpoint, not a gate — a gate with no convergence criterion is a lock
with no key.

## State and artifacts

| Name | Purpose |
|---|---|
| `plan_review` | New plan-state field: `pending` / `done` / `skipped` / `error` |
| `plan_hash` | The plan file's hash at review time |
| `.claude/spar-plan-spec.txt` | The spec text, whether it arrived as a path or inline |
| `.claude/spar-run-plan-review.sh` | Generated runner |
| `.claude/spar-plan-review-prompt.txt` | Generated prompt |
| `.claude/spar-plan-review-retries` | Retry counter |
| `reviews/spar-plan-<slug>-<timestamp>.md` | The result, kept |
| `plugins/spar/shared/prompts/plan-reviewer.md` | New template |

The five `.claude/spar*` entries must be added to the `rm -f` lists in
`plugins/spar/commands/cancel.md` and `adapters/codex/skills/spar-cancel/SKILL.md`.
A cancelled run that leaves them behind gives the next run's author a review of a
plan that no longer exists — the same defect the fix brief had, for the same
reason. `tests/test_stop_hook.sh` already asserts that both cancel documents name
every artifact the engine's own `cleanup()` removes; these are plan-layer
artifacts rather than loop-layer ones, so they need their own equivalent check.

## Testing

Pure bash, no reviewer CLI, stubs on `PATH` where one is needed.

- **`planned` + `pending` blocks and names the runner.** Reverting the dispatcher
  branch makes the run pass straight through, so this is the check that the
  enforcement exists at all.
- **`CLEAN` leads to a present-the-findings block, then passes through.**
- **`FINDINGS` does the same** — and `/spar:fight` still starts afterwards, which
  is the check that this is not a gate.
- **Three failure paths**, each asserting both the pass-through and the recorded
  `plan_review` value: no CLI, no file after three dispatches, bad marker three
  times.
- **Hash mismatch reported**, with a control: an unedited plan produces no such
  message.
- **Teardown**: run the bash block out of each cancel document against a fixture
  holding all five artifacts and assert they are gone.

Each independently revertible part needs its own failing check, and each revert
is performed rather than assumed.

## Non-goals

- A convergence loop. One pass. A plan has no tests to converge on, and a
  document iterated with a model grows rather than improves.
- Design critique — see the brief above.
- Blocking `/spar:fight`.
- Reusing the judge or the matcher. There is no dispute to adjudicate and nothing
  to merge; the findings go to a person.
- Reviewing the plan again after the author acts on the findings. That edit is the
  expected outcome, and re-reviewing it is the loop this pass is defined against.

## What this cannot verify

Whether the pass changes outcomes. Two hand-run passes both returned a blocker,
which is why this is being built, but two is not a rate. The comparison that would
settle it — plans executed with and without the pass, counted by rounds spent and
by defects that predated the code — needs runs that do not exist yet. The
`reviewer_version` field added in the previous phase is what will make those runs
comparable at all.
