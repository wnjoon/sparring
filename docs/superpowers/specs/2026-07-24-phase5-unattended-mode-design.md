# Phase 5 — Unattended Mode (+ Final Report) — Design

**Status:** design, prepared for **Phase 5**. NOT yet implemented. Consolidates
the Phase 5 decisions in `docs/design-decisions.md` §Phase 5 and flags the open
questions that must be resolved (a short brainstorm) before a writing-plans plan.

Phase 5 has **two halves**:

1. **Final report** — already designed in
   `docs/superpowers/specs/2026-07-24-spar-report-design.md` (deterministic
   `spar-report.sh` generates `reviews/spar-<id>-report.md` before cleanup; a
   `/spar-report [id]` command displays it). This document does not re-specify it;
   it only notes how unattended mode feeds it (parked / blocked-pending-user).
2. **Unattended mode** — the subject of this document.

## Context & goal

Today the loop assumes a human is present for one thing: the **design gate**. When
the loop is stuck on nothing but parked `[DESIGN]` findings, `stop-hook.sh` fires
one batched gate and **holds the loop there** — the only ways out are the user
recording a decision in the ledger or `/spar-cancel` (the round cap does NOT
release a gated loop). That is correct when a human is watching, but it means an
unattended run (scheduled, CI-adjacent, or simply "go do this while I'm away")
can hang forever at the gate.

Goal: let `/spar` (and, through it, `/spar-weighin`) run without a human to answer
design questions — **without ever fabricating completion**. Mechanical progress
continues; genuine design decisions are deferred honestly rather than guessed.

## Decided (from design-decisions.md §Phase 5)

- `[MECHANICAL]` fixes proceed automatically (already true today — no user is
  ever consulted for these).
- `[DESIGN]` findings split by the Phase 2 rule into two kinds:
  - **Parked (non-essential)** — batched and surfaced at the **next session
    start** ("N design decisions pending"). They do NOT block; the run can still
    complete and be reported as done, with the parked questions attached.
  - **Blocked-pending-user (essential)** — leave the work **INCOMPLETE**. It stays
    pending across sessions and is **never reported as done**. Unattended mode has
    no user to rule on an essential decision, so it must not fabricate completion
    around one.
- The outcome enum already carries `blocked-pending-user`
  (`spar-record-outcome.sh`), so the durable-outcome machinery is ready for this
  terminal state.
- The final report surfaces parked and blocked-pending-user items prominently
  (see the report spec's content list).

## Design

### 1. Activation — how a run is marked "unattended"

A run must declare it has no human at the gate. Options (decision needed, see
Open Questions): an explicit `/spar --unattended` flag written into the state
file (mirrors `--reviewer` / `--include-dirty`); or auto-detection (no TTY on
stdin). **Recommendation:** an explicit flag written to the state file as
`unattended: true`, because auto-detection is easy to get wrong (a piped session
is not necessarily unattended) and enforcement must be deterministic. The flag
threads to `/spar-weighin` too (an unattended weigh-in runs its tasks unattended).

### 2. Gate behavior changes only at the gate

Everything up to the gate is unchanged: the reviewer runs, MECHANICAL findings
are fixed, DESIGN findings are parked, the judge rules factual stalemates. The
change is only where the loop would otherwise **hold at the batched design gate**:

- **Attended (today):** hold; wait for a ledger decision per parked finding.
- **Unattended:** do NOT hold. Classify each parked design finding as
  *non-essential* or *essential* (§3), then take a terminal path:
  - If every pending design finding is non-essential → the loop may **converge/exit
    as done**, writing the parked questions to a pending store (§4) for next-session
    surfacing. Completion is honest because nothing essential is unresolved.
  - If any is essential → exit `blocked-pending-user`: work is **incomplete**,
    recorded durably, never reported as done.

### 3. Essential vs. non-essential — the crux (OPEN)

The split between "surface later, still done" and "blocks completion" is the
hardest undecided piece. Today all design stalemates are simply *parked*; there is
no essential/non-essential signal. Candidates (to resolve in brainstorm):

- The **reviewer** tags a design finding's essentiality when it raises it (adds a
  marker the parser reads). Pro: the party who sees the defect judges its weight.
  Con: adds reviewer-prompt surface and a new contract.
- A **conservative default**: in unattended mode, treat *every* unresolved design
  stalemate as essential (→ `blocked-pending-user`). Safest (never fabricates
  completion), simplest to implement, at the cost of more "incomplete" exits.
  **Recommended as the Phase 5 v1**, with reviewer-tagged essentiality as a later
  refinement once dogfooding shows the conservative default stops too often.

### 4. Cross-session surfacing (OPEN mechanism)

Parked (non-essential) questions and blocked-pending-user items must appear "at
the next session start." There is **no SessionStart hook today**. Options:

- Add a **SessionStart hook** that checks a pending store (e.g.
  `.claude/spar-pending.md`, which survives loop cleanup) and prints
  "N design decisions pending" with pointers.
- Or leave surfacing to the **final report** + a durable pending file the user
  reads on return, with no automatic session-start prompt.

**Recommendation:** a small pending file written at the unattended terminal path,
plus a SessionStart hook that announces its presence — but the file is the source
of truth; the hook is only a reminder (fail-open, like every other hook).

### 5. Interaction with `/spar-weighin`

An unattended weigh-in runs each task's `/spar` unattended. If a task exits
`blocked-pending-user`, the weigh-in stops at that task (its existing
"non-converged → stop honestly" path already covers this) and the pending
decision is surfaced. No new weigh-in logic beyond threading the `unattended`
flag into each task's launched state.

## Non-goals

- Changing MECHANICAL auto-fix behavior.
- Guessing or fabricating any design decision when no user is present.
- The final-report content/format (owned by the report spec).

## Invariants respected

- **Never report incomplete as done** — an essential unresolved decision forces a
  `blocked-pending-user` terminal, never `converged`.
- **Deterministic enforcement / fail-open** — the unattended terminal is chosen by
  the hook from durable state; any SessionStart reminder is best-effort.
- **Honest exit** — reuses the existing outcome enum; adds no "success-y" reason.

## Open questions to resolve before writing-plans

1. **Essential vs. non-essential classification** (§3) — reviewer-tagged vs. the
   conservative "all essential in unattended" default. This is the key design
   decision; recommend the conservative default for v1.
2. **Activation** (§1) — explicit `--unattended` flag (recommended) vs.
   auto-detection.
3. **Cross-session surfacing** (§4) — SessionStart hook vs. pending-file-only, and
   where the pending store lives so it survives `cleanup()`.
4. Whether unattended mode should also raise/adjust the round cap (an unattended
   run has no human to nudge it), or keep the cap identical.

## Terminal state

Prepared for Phase 5. The three open questions above (especially §3) warrant a
short brainstorm to settle before the Phase 5 plan is written. The final-report
half is already design-complete in its own spec.
