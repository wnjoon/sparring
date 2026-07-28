# Phase 9 — plan review

An independent pass over a plan, cleared before `/spar:fight` will execute it.

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
Both returned a blocker; the second was that a task's design contradicted what two
prompts require. That is the argument: the loop's premise is that an author does
not grade its own work, a plan is authored work, and today it is graded by its
author until execution proves otherwise.

## What it is

One blind pass over the plan, prepared by `/spar:ready` and **cleared as a
precondition of `/spar:fight`**. It reads the plan, the spec the plan came from,
and the repository. It reports findings. The author records a disposition for each.
`/spar:fight` will not start a plan whose review has not been run, or whose
findings have no disposition.

It does not iterate, never declares anything converged, and does not require
agreement — a grounded `REJECTED` clears a finding exactly as `ACCEPTED` does.

## Decisions

| Question | Decision |
|---|---|
| When does it run | `/spar:ready` prepares it always; `--no-plan-review` opts out |
| Where is it enforced | `/spar:fight`'s activation check, deterministically |
| Which reviewer | The `reviewer:` already resolved and stored by `/spar:ready` |
| What may it examine | Facts, plus contradictions with the spec, protocol or invariants |
| What clears a finding | An author disposition: `ACCEPTED` or grounded `REJECTED` |
| Does an *undispositioned* finding block `/spar:fight` | Yes — that is the enforcement |
| Does a *rejected* finding block it | No |
| What if the plan changes after review | Record a hash, report the mismatch, proceed |

### Why `/spar:fight` rather than the Stop hook

The first draft of this spec put a `planned`-phase branch in `stop-fight.sh`,
because `stop-fight.sh:59` passes through whenever the phase is not `running` and
that looked like a free seat. An independent review of that draft found the flaw:
such a branch can only enforce that **a reviewer artifact exists**. After the
"present the findings" block, the next stop passes whether the findings were
presented or acted on or not. It buys two extra stops and a new fail-open state
machine while leaving the consequential part unenforced.

`/spar:fight`'s activation is already a deterministic shell block that refuses to
proceed on several conditions — a running plan, a missing plan file, a wrong
phase. A precondition there is enforcement of the same kind, and it has a key: run
the review, write the dispositions. It also removes the dispatcher branch, its
retry state, the two-stop protocol, and the question of which session owns a
prepared plan under Codex's user-scoped hook.

The cost is that a skipped review is discovered when `/spar:fight` is first
invoked rather than at the checkpoint. Nothing can start before that check, so the
discovery is not late for any purpose that matters.

### Why the brief includes bounded design critique

The first draft excluded design critique, reasoning that it invites a reviewer to
propose a different plan. The review of that draft made two points that overturn
it. The strongest observed evidence favours inclusion — the most valuable
hand-run finding was a bad design, and excluding it discards exactly that. And
the stated boundary was not a boundary: "is every step satisfiable" and "does it
cover the spec" are judgments already, so "checkable facts only" described
something the brief did not do.

The boundary is now real: **name design decisions that contradict the spec, the
protocol, the invariants, or the repository's observable data flow; give the
minimal alternative and its cost; do not rewrite or expand the plan.** A human
remains the decision-maker, and the author may reject with grounds.

## Architecture

Nothing in `stop-hook.sh` changes. Nothing in `stop-fight.sh` changes.

**Preparation — `/spar:ready`, both seats.**

1. Capture the spec text to `.claude/spar-plan-spec.txt`, whether it arrived as a
   path or inline. The captured copy is authoritative from that moment: a spec
   file edited afterwards does not retroactively change what the plan was written
   against, and the review must judge the plan against what it was given.
2. Generate `plan_review_id` and write it, plus `plan_review: required`, into the
   plan state. With `--no-plan-review`, write `plan_review: skipped` and stop
   here. If the reviewer CLI is not on `PATH`, write `plan_review: skipped` with
   the reason printed — the same fail-open the loop uses everywhere.
3. After the session has written the plan and ingested it, prepare the prompt and
   the runner via `plugins/spar/commands/spar-plan-review-prepare.sh`, then tell
   the session to run the runner, read the result, present it to the user, and
   write dispositions if there are findings.

**The runner.** Generated with the same hardening as every existing runner, per
family: read-only invocation (`codex exec --sandbox read-only` / `claude -p
--safe-mode --tools Read Grep Glob`), a `mktemp` + hard-link publish so the result
is atomic and never overwritten, a lock directory, a refusal to accept a
pre-existing non-regular or symlinked output path, and a check of the CLI's exit
status before publishing. It also records `git hash-object <plan>` into
`.claude/spar-plan-review-hash` before dispatching, so the hash is written by the
plugin rather than by the author.

**Clearing — `/spar:fight`, both seats.** Before `plan_set_field phase running`:

| Condition | Result |
|---|---|
| `plan_review: skipped` | Proceed |
| Result file absent, or first line not a `PLAN-REVIEW:` marker | Refuse, name the runner |
| `PLAN-REVIEW: CLEAN` | Proceed |
| `PLAN-REVIEW: FINDINGS`, disposition file absent or missing an id | Refuse, name the ids still needing one |
| All findings dispositioned | Proceed |
| Recorded hash differs from the plan's current hash | Report the mismatch, proceed |
| `/spar:fight --no-plan-review` | Proceed, and record `plan_review: overridden` |

The last row is the escape for a reviewer that cannot be made to work. Without it
a broken CLI would be an unclearable gate; with it the override is a recorded fact
rather than a silent skip.

## The brief

Six questions:

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
6. Does any design decision contradict the spec, the protocol in `policy.md`, the
   invariants in `README.md`, or the repository's observable data flow? Name the
   minimal alternative and its cost. Do not rewrite the plan.

## Output contract

**Result.** First line `PLAN-REVIEW: CLEAN` or `PLAN-REVIEW: FINDINGS`. Findings
are `### PR<n> [BLOCKER|SHOULD-FIX|NOTE] <title>` with `file:`, `problem:` and
`suggestion:` lines, mirroring the loop's finding shape. `PR` rather than `P`
because `### P<k>` is already the design ledger's ruling shape.

The marker deliberately differs from the loop's `STATUS:` — the same reason the
final sweep uses `SWEEP:`. Convergence is the reviewer's word inside a task loop,
and nothing produced outside one may be mistaken for it.

**Disposition.** `.claude/spar-plan-review-response.md`, one section per finding:
`### PR<n>: ACCEPTED — <what changed>` or `### PR<n>: REJECTED — <grounded
reason>`. Written by the author. `/spar:fight` checks that every `PR<n>` in the
result has a matching section; it does not and cannot check that the reason is
true. Same limit the loop lives with, same reason it is worth requiring anyway.

**Paths.** The result is `reviews/spar-plan-${plan_review_id}.md`, derived from a
field written at preparation time — not from a timestamp reconstructed later. It
is kept; `reviews/spar-*` is already in `.git/info/exclude`, so it never enters a
later review surface.

## State and artifacts

| Name | Purpose |
|---|---|
| `plan_review` | Plan-state field: `required` / `skipped` / `overridden` |
| `plan_review_id` | Identifies the result file; written at preparation |
| `.claude/spar-plan-spec.txt` | Captured spec text, authoritative once written |
| `.claude/spar-run-plan-review.sh` | Generated runner |
| `.claude/spar-plan-review-prompt.txt` | Generated prompt |
| `.claude/spar-plan-review-hash` | Plan hash at review time, written by the runner |
| `.claude/spar-plan-review-response.md` | Author dispositions |
| `reviews/spar-plan-<id>.md` | The result, kept |
| `plugins/spar/shared/prompts/plan-reviewer.md` | New template |

Five `.claude/spar*` files are created and all five must be added to the `rm -f`
lists in `plugins/spar/commands/cancel.md` and
`adapters/codex/skills/spar-cancel/SKILL.md`. A cancelled run that leaves them
behind gives the next run a review, a hash and dispositions belonging to a plan
that no longer exists — the same defect the fix brief had, for the same reason.
`tests/test_stop_hook.sh` already asserts both cancel documents name every
artifact the engine's `cleanup()` removes; these are plan-layer artifacts, so they
need their own equivalent check.

`plan_hash` from the first draft is gone: the hash lives in a file the runner
writes, so the author never touches it.

## Two-seat surface

Every one of these changes, in both seats:

| File | Change |
|---|---|
| `plugins/spar/commands/ready.md` | Capture spec, write fields, prepare, instruct |
| `adapters/codex/skills/spar-ready/SKILL.md` | The same |
| `plugins/spar/commands/spar-ready-resolve.sh` | Parse `--no-plan-review` |
| `plugins/spar/commands/fight.md` | The activation precondition, and `--no-plan-review` |
| `adapters/codex/skills/spar-fight/SKILL.md` | The same |
| `plugins/spar/commands/spar-fight-resolve.sh` | Parse `--no-plan-review` |
| `plugins/spar/commands/cancel.md` | Five artifacts |
| `adapters/codex/skills/spar-cancel/SKILL.md` | Five artifacts |

Both resolvers need the flag in their parser, their usage string, and their
argument-hint line, with parity tests — `tests/test_ready_resolve.sh` and
`tests/test_fight_resolve.sh` already assert flag behaviour and are where these
belong.

## Failure behaviour

| Condition | Result |
|---|---|
| Reviewer CLI absent at preparation | `plan_review: skipped`, reason printed |
| Runner fails or produces nothing | `/spar:fight` refuses and names the runner; the author re-runs |
| Result's first line is not a marker | Same; the bad file is set aside as `.invalid-N` |
| Reviewer cannot be made to work at all | `/spar:fight --no-plan-review`, recorded as `overridden` |
| `plan_review` absent from an older state file | Treated as `skipped` |

There is no retry counter. The loop needs one because the hook drives it; here the
author drives, and a refusal that names the runner is a state they can act on
directly.

## Testing

Pure bash, no reviewer CLI, stubs on `PATH` where one is needed.

- **Preparation writes the fields and the runner**, and `--no-plan-review` writes
  `skipped` and prepares nothing.
- **Absent CLI at preparation** yields `skipped` with a reason, and `/spar:fight`
  proceeds.
- **`/spar:fight` refuses** when the result is missing, and names the runner.
  Reverting the precondition makes it proceed — that check is the proof the
  enforcement exists.
- **`CLEAN` clears it.**
- **`FINDINGS` without dispositions refuses** and names the outstanding ids;
  **with a complete response it proceeds**; **with one id missing it still
  refuses**, which is the check that the count is enforced rather than the file's
  mere existence.
- **A grounded `REJECTED` clears a finding** exactly as `ACCEPTED` does.
- **Hash mismatch is reported and proceeds**, with a control: an unedited plan
  produces no such message.
- **`--no-plan-review` at fight time** proceeds and records `overridden`.
- **Both resolvers** parse the flag, reject it twice, and keep it out of the spec
  text.
- **Teardown**: run the bash block from each cancel document against a fixture
  holding all five artifacts and assert they are gone.
- **Runner hardening**, mirroring the existing runner tests: read-only invocation
  for both families, refusal of a symlinked output path, non-zero CLI exit
  publishes nothing.

Each independently revertible part needs its own failing check, and each revert is
performed rather than assumed.

## Non-goals

- A convergence loop. One pass. A plan has no tests to converge on, and a document
  iterated with a model grows rather than improves.
- Re-reviewing after the author acts on findings. That edit is the expected
  outcome. An independent review argued a hash mismatch should invalidate the
  review outright, on the grounds that otherwise the executed plan may have had no
  review at all. That is true and it is accepted knowingly: the disposition
  requirement is the accountability, and invalidating on every edit reinstates the
  loop this pass is defined against. The mismatch is reported so the record is
  accurate about what was reviewed.
- Requiring agreement. A grounded `REJECTED` clears a finding. The reviewer has no
  standing to compel a plan change, and there is no judge here.
- Reusing the judge or the matcher. There is no dispute to adjudicate and nothing
  to merge.
- Touching `stop-hook.sh` or `stop-fight.sh`.

## What this cannot verify

Whether the pass changes outcomes. Two hand-run passes both returned a blocker,
which is why this is being built, but two is not a rate. The comparison that would
settle it — plans executed with and without the pass, counted by rounds spent and
by defects that predated the code — needs runs that do not exist yet. The
`reviewer_version` field added in the previous phase is what will make those runs
comparable at all.

Whether requiring a disposition per finding produces reasoning or ritual. The hook
can check that a disposition is present and never that it is true. The loop has
lived with that limit since Phase 1 on the same bet: writing a grounded reason is
harder to fake than skipping one.
