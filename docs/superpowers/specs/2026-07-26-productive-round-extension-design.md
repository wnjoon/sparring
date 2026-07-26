# Productive-round extension — design

**Date:** 2026-07-26
**Status:** implemented (`plugins/spar/hooks/stop-hook.sh`, 56 new checks in `tests/test_stop_hook.sh`)

## The problem, as observed

Run `20260726-114812-30cd4f` (the Codex adapter's Task 3) ended at the round cap
without converging. Its report:

```
outcome: cap        rounds: 5
raised: 14 (MECHANICAL 14, DESIGN 0)
fixed: 14   rejected: 0   unanswered: 0
round 1: 6   round 2: 2   round 3: 1   round 4: 4   round 5: 1
```

Nothing was contested. No judge ran, no design finding was parked, and the
independent matcher returned NO MATCHES in all five rounds — so no finding was a
re-wording of an earlier one. Every round surfaced genuinely new work and the
author fixed all of it. Round 5's single finding was a one-line documentation
inconsistency, and the fix for it was never re-reviewed because there was no
round 6.

That is not the failure the cap was built for. The cap is a circuit breaker
against oscillation: two sides that will not agree, where more rounds buy
nothing. Counting elapsed rounds catches that case *and* this one, which is the
opposite — a review still doing its job.

## Why the rounds have to be granted inside the run

The obvious workaround is to commit and re-run. It does not work, and the reason
is worth recording because it is not visible from the outside.

`/spar:fight` sets `base_sha` to HEAD at activation, and the reviewer is shown
`git diff "$BASE"` (`stop-hook.sh`). Commit the capped work and start a new run
and the base moves to that commit, so the diff is empty — the reviewer reviews
nothing. It does not silently pass: a zero diff is deliberately routed through
review rather than safe-skipped ("Zero-diff is sent through review so
requirement-fit can catch an implementation omission"), so it fails loudly rather
than laundering unreviewed work into a green exit. But it is not a continuation.

The only manual continuation that works is leaving the work uncommitted and
re-running with `--include-dirty`: the base stays at the pre-work commit, the
whole surface is in the diff, and the automatic skip is disabled. Even that is a
restart rather than a resume — the new reviewer knows nothing of the earlier
rounds and re-reviews everything from scratch.

Conclusion: whatever rounds a run needs, it must get them while its own baseline
is still intact. A report that advises "re-run to continue" is advising something
that does not exist.

## Design

Two cap levels.

**Soft cap** — `max_rounds`, default 5. Reaching it ends the run only if the
round that reached it was *not* productive.

**Hard cap** — `hard_cap`, default `2 × max_rounds`. Always ends the run.

A round is **productive** when none of these hold:

- the author REJECTED any finding;
- the author's response for a finding says neither FIXED nor REJECTED (ambiguous
  — treated as dispute, never as progress);
- a blind judge dispatch is pending;
- any design finding is parked.

Those are the three ways a round can mean "the two sides disagree". Their absence
means the reviewer raised real work and the author did it.

### Rejected alternatives

- **Raise the flat cap to 7–10.** Moves the wall without fixing the conflation: a
  genuine deadlock would burn 10 rounds instead of 5 before reporting, and each
  round is a full re-review of the whole diff by a fresh reviewer. Cost is
  linear, and the cap is counted *per task*, so a 10-task plan multiplies it.
- **Stop on diminishing returns** (findings-per-round below a threshold).
  Severity is not modeled — only MECHANICAL/DESIGN — so "trivial" is not
  machine-visible, and the rule would risk stopping on a small but real finding.
- **Include recurrence in the productivity test.** A finding raised again is
  either fixed again, which is still progress, or rejected, which the test
  already catches. It would add a signal without adding information.
- **A "grace round" that may not raise new findings.** Bounded and cheap, but it
  weakens the guarantee: a review forbidden from reporting what it sees is not
  the same instrument, and it needs a separate prompt to express that.

### Why doubling rather than a constant

`max_rounds` is a stated budget. A user who sets 3 to keep a run cheap has not
agreed to 10. Doubling keeps the ceiling proportional and the rule easy to state:
*a clearly productive run may spend up to twice its budget.* An explicit
`hard_cap` field overrides it, including setting it equal to `max_rounds` to
restore the old behaviour exactly.

## What the cap message says now

Either cap still exits with an honest unconverged summary. Two additions: it asks
the author to say plainly **which fixes were never re-reviewed** — the specific
gap this failure mode produces — and it explicitly warns against the
commit-and-re-run path for the reason above.

## Verification

56 checks in `tests/test_stop_hook.sh` (suite total 293 → 349), both totals
measured by running the suite with and without the change rather than counted
from the diff.

Extension and capping: a productive round 5 and 8 extend; a rejection, an
ambiguous response, an omitted response in a multi-finding review, an
unrecognised free-prose response, an empty response file, and a `FINDINGS`
review with nothing parseable all cap; a two-finding review answered `FIXED`
twice extends. The hard cap stops a productive round 10. The doubling rule holds
at `max_rounds: 3` (extends past 3, stops at 6), an explicit `hard_cap: 5`
disables extension entirely, and the cap message carries both new requirements.

Numeric hygiene: `max_rounds: 08` is read as 8 rather than raising bash's octal
error, and its hard cap is 16; a twenty-digit `max_rounds` or `hard_cap` falls
back to the default and the run still terminates; `max_rounds: 0` is invalid.
Values that WRAP to something plausible are rejected too — 2^64+1 arrives as 1
under bash arithmetic, so the bound is enforced on the digit string before any
`$(( ))` — and a `round` that wraps fails open instead of adopting another
round's artifacts. `max_rounds: 60` gets a hard cap of 120, `max_rounds: 101` gets 202, and an
explicit `hard_cap: 120` or `250` is honoured rather than shrunk — the bound is
arithmetic safety, not a view about sensible budgets.

Disposition strictness: `FIXEDLY` does not count as `FIXED`, nor do the hedges
`FIXED?`, `FIXED/REJECTED`, `FIXED-ish` and `FIXED.REJECTED`; a finding answered
twice is a conflict rather than an answer; a bare `FIXED` and the documented
`FIXED — <prose>` form both count. Dispute states: a mixed round containing a parked finding caps with the
report and teardown unchanged, a design question parked in an earlier round
blocks extension even when this round is spotless, and a pending judge dispatch
never advances past the cap.

Thirteen mutations were each confirmed to fail the checks that should catch them:
removing the extension, removing the hard cap, dropping REJECTED from the
productivity test (which also breaks the pre-existing cap tests, as it should),
replacing the doubling with a constant 10, scoring productivity from the response
file alone instead of from the review's findings, dropping base-10
normalisation, dropping the range check, validating after the arithmetic instead
of before it, bounding the hard cap by the soft cap's limit, reinstating the arbitrary
100/200 policy limit, accepting a permissive or duplicated disposition, and
dropping the parked-finding guard.

## Not covered

Whether this changes real convergence rates is not something tests can answer.
The next few dogfooding runs are the evidence; if productive runs routinely reach
the hard cap, the productivity test is too permissive and should tighten rather
than the ceiling rising.
