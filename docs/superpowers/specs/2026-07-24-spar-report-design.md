# `/spar-report` — Final Run Report — Design (Phase 5 prep)

> _Command names updated post-refactor: `/spar` → `/spar:fight`; `/spar-weighin` → `/spar:ready` (plan) + `/spar:fight` (execute)._

**Status:** design, prepared for **Phase 5**. NOT yet implemented. This refines
the "Final report" half of Phase 5 (the other half is unattended mode); see
`docs/design-decisions.md` §Phase 5.

## Context & goal

When a `/spar` loop reaches `STATUS: CONVERGED`, the terminal path
(`stop-hook.sh` `finish_approve converged`) records the machine-readable outcome,
cleans up, and releases the session with a bare `{"decision":"approve"}` — no
message. The author's last turn just says "converged, done." The run's actual
story — how many rounds, what findings were raised and how they were resolved,
which design choices the user settled, the sweep result, which files changed —
is spread across `reviews/spar-<id>-*` artifacts and the decision ledger, and is
never summarized for the user.

Goal: produce a **deterministic final report** of a completed run and make it
easy to read.

## Key decision — generation vs. display are split

Two distinct concerns, deliberately separated:

1. **Generation** — a deterministic script `spar-report.sh` assembles the report
   from the run's artifacts and writes `reviews/spar-<id>-report.md`.
2. **Display** — a `/spar-report [id]` command reads that file and presents it to
   the user (default: the most recent run).

The report is **informational, not an enforced invariant**. Enforcement is the
Stop hook's job; a summary is not something to enforce. So the report logic stays
OUT of the hook's decision machinery — the hook's only involvement is one
fail-open call to the generator (below).

### Why generation must run BEFORE cleanup

`cleanup()` in `stop-hook.sh` removes `.claude/spar-ledger.md` (the settled
design decisions) and `.claude/spar-registry.tsv` (finding fingerprints, stalemate
streaks, statuses) along with the rest of the loop state. The per-round
`reviews/spar-<id>-r*.md` / `-response.md`, judge, and sweep files persist, but
the **ledger and registry do not**. A purely post-hoc `/spar-report` therefore
could not reconstruct the "escalations & decisions" section.

So the generator is invoked **at the terminal path, before `cleanup()`**, while
the full live state (state file → `base_sha`, ledger, registry, all reviews) is
still present. The `/spar-report` command then only re-displays the already-frozen
`reviews/spar-<id>-report.md`; it never re-derives from (now-deleted) state.

## `spar-report.sh` — the generator

- **Invocation:** `spar-report.sh <review-id> <base-sha> [reviews-dir] [state-dir]`,
  called from `stop-hook.sh`'s terminal path immediately before `cleanup()`.
- **Fail-open:** any generator error is logged and ignored — it must NEVER block
  the session's release or change the loop outcome. The report is best-effort.
- **Inputs (all read-only):** the state file (`.claude/spar.local.md` → review_id,
  base_sha, reviewer, rounds, sweep_result), the outcome file
  (`reviews/spar-<id>-outcome.md`), the per-round `reviews/spar-<id>-r<N>.md` +
  `-r<N>-response.md`, judge files `reviews/spar-<id>-judge-*.md`, the sweep file
  `reviews/spar-<id>-sweep.md`, the ledger `.claude/spar-ledger.md`, the registry
  `.claude/spar-registry.tsv`, and `git diff --stat <base-sha>`.
- **Output:** `reviews/spar-<id>-report.md` (written atomically; under the
  existing `reviews/spar-*` git-exclude, so not committed — an artifact, like the
  other run files).

### Report content (the four the user chose, aligned with the Phase 5 list)

1. **Result header** — exit reason (full exit-reason enum), total rounds, reviewer
   family (codex / claude — the pairing used), sweep result, `base_sha`, timestamp.
2. **Findings tally** — from each round's review + response: total raised, FIXED,
   REJECTED, split by `[MECHANICAL]` / `[DESIGN]`. Optionally a per-round line
   (round N: raised X, fixed Y, rejected Z).
3. **Escalations & decisions** — judge rulings (`UPHELD` / `DISMISSED`), the
   user's settled design decisions from the ledger (prominent — these are the
   choices a human made), any parked / blocked-pending-user items, and sweep
   findings. (Matches the Phase 5 "final report contents" list.)
4. **Changed files** — `git diff --stat` against `base_sha` (per-file added/removed
   lines). The code surface this run touched.

## Hook change (minimal)

In `stop-hook.sh`, at the converged terminal path, insert one guarded call:
`spar-report.sh "$REVIEW_ID" "$BASE" 2>>"$LOG" || log "report generation failed"`
**before** `finish_approve` runs `cleanup()`. No new phase, no extra round-trip,
no change to the convergence decision. Optionally, the `STATUS: CONVERGED`
handling text in the round prompt gains a one-line hint: "a summary was written
to `reviews/spar-<id>-report.md` — run `/spar-report` to show it."

## `/spar-report [id]` — the display command

Reads `reviews/spar-<id>-report.md` and presents it. With no id, picks the
most recent `reviews/spar-*-report.md`. Read-only and re-runnable (a past run's
report can be shown any time). If the file is missing, it says so plainly.

## Scope

- **This design: converged runs only** (the user's ask). The generator reads
  artifacts and is terminal-reason-agnostic, so extending to `cap`,
  `sweep-findings-at-cap`, or `skipped` is a one-line change at those terminal
  paths — deferred.
- **`/spar-weighin` roll-up** (a Phase-8-flow summary aggregating each task's
  per-run report) is a natural follow-on: weighin controls its own terminal
  path, so it can call the same generator/command. Deferred.

## Non-goals

- Unattended mode (the other half of Phase 5) — separate.
- Committing the report to git — it is a `reviews/spar-*` artifact, excluded like
  the others.
- Any change to the enforced invariants or the convergence decision.

## Invariants respected

- **Deterministic enforcement untouched** — the report is informational; the hook
  only makes one fail-open call and never lets report generation affect the
  outcome.
- **Fail-open** — a broken generator degrades to "no report," never to a trapped
  or mis-released session.

## Testing

- Pure-bash test of `spar-report.sh` over a synthetic `reviews/` + `.claude/`
  fixture set (planted rounds, a judge ruling, a ledger decision, a sweep) →
  assert the report's four sections carry the right tallies and lines. Matches
  the existing `tests/test_*.sh` style.
- Smoke test of `/spar-report` selecting the newest report and printing it.

## Open questions for the writing-plans stage

- Exact markdown layout of `reviews/spar-<id>-report.md`.
- Whether to add the one-line `STATUS: CONVERGED` prompt hint, or leave discovery
  entirely to `/spar-report`.
- Whether findings parsing should reuse `stop-hook.sh`'s `parse_findings` /
  `parse_responses` (extract to a shared sourced helper) or a lightweight
  independent parse in `spar-report.sh` (the report is best-effort, so a simple
  independent parse is acceptable).

## Terminal state

Prepared for Phase 5. Do NOT implement now — this document is the starting point
for the Phase 5 plan.
