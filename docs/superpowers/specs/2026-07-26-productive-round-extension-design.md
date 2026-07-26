# Productive-round extension — design

**Date:** 2026-07-26
**Status:** implemented (`plugins/spar/hooks/stop-hook.sh`, 65 new checks in `tests/test_stop_hook.sh`)

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
  — treated as dispute, never as progress), or omits it entirely;
- a blind judge dispatch is pending;
- any design finding is parked;
- any of this round's findings repeats an earlier one — by the engine's
  deterministic fingerprint, or by a matcher `SAME` verdict for a re-wording.

The first four are the ways a round can mean "the two sides disagree". The fifth
means something else — see below.

### Rejected alternatives

- **Raise the flat cap to 7–10.** Moves the wall without fixing the conflation: a
  genuine deadlock would burn 10 rounds instead of 5 before reporting, and each
  round is a full re-review of the whole diff by a fresh reviewer. Cost is
  linear, and the cap is counted *per task*, so a 10-task plan multiplies it.
- **Stop on diminishing returns** (findings-per-round below a threshold).
  Severity is not modeled — only MECHANICAL/DESIGN — so "trivial" is not
  machine-visible, and the rule would risk stopping on a small but real finding.
- ~~**Include recurrence in the productivity test.**~~ Rejected in the first
  version on the reasoning that a finding raised again is either fixed again
  (progress) or rejected (already caught) — **reversed on 2026-07-26**, see
  below.
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

65 checks in `tests/test_stop_hook.sh` (suite total 293 → 358), both totals
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

Recurrence: a matcher-declared repeat this round caps while one from an earlier
round does not; an aliases file written before the round column existed is not
attributed to any round; `apply_matches` writes the whole three-field row with
the right round in it; an identical re-raise caps with no matcher involved and no
alias written; a re-raise differing only in case and punctuation caps; and a
genuinely new defect in a file seen before still extends.

Nineteen mutations were each confirmed to fail the checks that should catch them:

1. removing the extension entirely;
2. removing the hard cap;
3. dropping REJECTED from the productivity test (this also breaks the
   pre-existing cap tests, as it should);
4. replacing the doubling with a constant 10;
5. scoring productivity from the response file alone rather than from the
   review's findings;
6. dropping base-10 normalisation;
7. dropping the range check;
8. validating after the arithmetic instead of before it;
9. bounding the hard cap by the soft cap's limit;
10. reinstating the arbitrary 100/200 policy limit;
11. accepting a permissive disposition (`FIXEDLY`) or a duplicated one;
12. loosening what may follow `FIXED` to any non-word character;
13. dropping the parked-finding guard;
14. dropping the `round_had_recurrence` call from `round_was_productive`;
15. comparing the wrong alias column, so any match condemns any round;
16. dropping the round column from what `apply_matches` writes;
17. recording a hardcoded round in it instead of the real one;
18. reverting `gate_finding_text` to a two-variable read, so the new column is
    swallowed into the canonical fingerprint;
19. deriving recurrence from the matcher alone, so an identical re-raise passes.

One change carries no test: scoping `_rnd` with `local` in `gate_finding_text`.
It fixes a name leaking into the script's global scope and has no observable
behaviour today, so there is nothing to assert that would not be a contrivance.

## Revision: recurrence, 2026-07-26

The review of this change (`20260726-143952-4a5f53`) capped at 5 unconverged with
12 findings raised, 12 fixed and 0 rejected — and the matcher flagged three of
them as re-raised. Under the rule as first written, every one of those rounds
scored as productive.

The original enumeration was wrong: it counted two outcomes for a re-raised
finding, and the run produced a third. A finding fixed *incompletely* and raised
again is neither progress nor a rejection. All three here were mine — the FIXED
grammar tightened twice before it was right, and the note's own check count went
stale three times. That is the reviewer having to repeat itself, which is the
clearest "not converging" signal short of an outright rejection, and it is
exactly what the soft cap is for.

So recurrence now counts against a round, from the two sources the engine
already distinguishes (policy §7). Identity is the deterministic fingerprint —
file plus normalized title — which is what the stalemate streak has always used
and needs no judgment. The matcher covers the case identity misses, a repeat
under different wording; a `SAME` verdict is an independent pass, never the
author's own call, and it is recorded per round so a match in round 3 does not
condemn round 5. What is excluded either way is the author deciding for himself
that two findings are the same.

Strict form (any repeat) rather than a "third appearance" counter, deliberately.
A counter needs a raise-count column in the registry, whose exact lines existing
tests compare verbatim, and the evidence for tuning it is two runs. Relaxing a
rule later is easy; rounds granted by a rule that was too generous are gone. On
the evidence available the strict rule keeps the case that motivated the feature
— the first run, matcher `NO MATCHES` in all five rounds, would still extend —
and tightens only the case that looked too permissive.

## Not covered

Whether this changes real convergence rates is not something tests can answer.
The next few dogfooding runs are the evidence, and they now cut both ways: if
productive runs routinely reach the hard cap the test is still too permissive,
and if runs keep capping at the soft cap on a single recurrence it is too strict
and should relax toward the third-appearance rule. Two runs is not enough to tell
which.
