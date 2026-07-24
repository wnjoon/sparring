# Phase 5 — Unattended Mode (+ Final Report) — Design

> _Command names updated post-refactor: `/spar` → `/spar:fight`; `/spar-weighin` → `/spar:ready` (plan) + `/spar:fight` (execute)._

**Status:** **implemented in v0.5.0.** The three formerly-open questions (§1, §3,
§4) were **settled on 2026-07-24 by a blind cross-model check** — Claude and Codex
independently reviewed the same brief against the invariants and the code, and
converged on the same option for all three (no conflicts). Their conclusions, and
the two load-bearing code facts they rest on (`cleanup()` leaves `reviews/` intact;
the design gate fires before the round-cap check), are verified in `stop-hook.sh`.
The unattended terminal, durable queue, and SessionStart surfacing shipped; the
`--unattended` flag threads through `/spar:ready` and `/spar:fight`.

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
recording a decision in the ledger or `/spar:cancel` (the round cap does NOT
release a gated loop). That is correct when a human is watching, but it means an
unattended run (scheduled, CI-adjacent, or simply "go do this while I'm away")
can hang forever at the gate.

Goal: let `/spar:fight` (and, through it, a `/spar:ready` plan) run without a human to answer
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

### 1. Activation — how a run is marked "unattended" — DECIDED (a)

**Decision (cross-verified):** an explicit `--unattended` flag (on `/spar:fight`
and `/spar:ready`), persisted to the state file as `unattended: true|false`
(mirrors `--reviewer` / `--include-dirty`). The Stop hook validates the field once
and makes the gate decision solely from durable state. `/spar:ready` records the
flag in the plan state, and `/spar:fight`'s launcher (`spar-fight-launch.sh`)
copies it into each task's `.claude/spar.local.md`. Auto-detection
(TTY/CI/piping) is **rejected** — a piped session is not necessarily unattended,
and enforcement must be deterministic. An unknown/malformed value must fail as an
internal-state error (fail-open), never silently select unattended behavior.

### 2. Gate behavior in unattended mode — DECIDED

Everything up to the gate is unchanged: the reviewer runs, MECHANICAL findings are
fixed, DESIGN findings are parked, the judge rules factual stalemates. The only
change is where the loop would otherwise **hold at the batched design gate**
(`only_parked_this_round`, which fires *before* the round-cap check):

- **Attended (today):** hold; wait for a ledger decision per parked finding.
- **Unattended (v1):** do NOT hold and do NOT invent a "done" path. Every pending
  design finding is treated as essential (§3), so the terminal sequence is:
  1. persist the pending finding(s) to the durable queue (§4),
  2. `record_outcome blocked-pending-user`,
  3. generate the final report **while the ledger and registry still exist**
     (before `cleanup()`),
  4. `cleanup()` and approve exit.

  The work is **incomplete**, recorded durably, and never reported as done. The
  round cap stays a circuit breaker; it must not become an escape that relabels
  parked findings as complete.

### 3. Essential vs. non-essential — DECIDED (b): conservative default

**Decision (cross-verified):** in unattended mode v1, treat **every** unresolved
`[DESIGN]` stalemate as essential → `blocked-pending-user`. Rationale is stronger
than "honest exit" alone: the reviewer has returned `STATUS: FINDINGS`, so letting
the hook reclassify a finding into "done with non-essential questions" would create
a **second completion authority**, conflicting with the **reviewer-declares**
invariant — and recording `converged` (the only outcome that asserts a clean
review) would be dishonest. Option (b) needs no new reviewer marker, parser, prompt
contract, or model-dependent judgment, and drops cleanly into the existing
`only_parked_this_round` branch.

Cost: v1 stops more often and does not deliver the "complete with non-essential
pending" behavior sketched in `design-decisions.md`. That is the correct
conservative limitation. A later refinement is more than an essentiality tag: it
needs an explicit **reviewer-owned terminal contract** and a distinct durable
outcome that does not falsely claim a clean review. Missing/malformed
classifications must always default to essential.

### 4. Cross-session surfacing — DECIDED (a): SessionStart hook + durable queue

**Decision (cross-verified):** a fail-open **SessionStart hook** backed by a
durable pending queue. The queue must live **outside** the disposable
`.claude/spar*` state that `cleanup()` deletes — verified: `cleanup()` removes only
`.claude/...` state (state file, ledger, registry, gate/judge/matcher/sweep runner
files) and touches **no** `reviews/` path, so the queue lives under `reviews/`
(e.g. `reviews/spar-pending.md`, or per-run records under `reviews/`).

- The unattended terminal path appends to the queue, merging entries keyed by
  **review-id + canonical finding-id** — multiple runs merge, never overwrite —
  with dedup and safe regular-file-vs-symlink handling.
- The SessionStart hook only announces the count and points to the queue and the
  corresponding final reports; the queue file is authoritative.
- The hook is best-effort: a broken SessionStart hook must stay silent / fail open
  and must never alter an outcome or block a session.

With the Q1 v1 decision, the queue initially holds only `blocked-pending-user`
items; it can carry non-essential pending items later if a sound classification
contract (§3) is added.

### 5. Interaction with `/spar:ready` / `/spar:fight`

An unattended `/spar:ready` plan runs each task's `/spar:fight` unattended. If a task exits
`blocked-pending-user`, the fight stops at that task (its existing
"non-converged → stop honestly" path already covers this) and the pending
decision is surfaced. No new fight-orchestration logic beyond threading the
`unattended` flag into each task's launched state.

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

## Settled by cross-verification (2026-07-24)

The three questions that were open are now decided (§1, §3, §4) — Claude and Codex
independently converged on the same option for each, with no conflicts, and the
two load-bearing code facts were verified in `stop-hook.sh`:

1. **Essential vs. non-essential** (§3) → **(b) conservative default**: all
   unattended design stalemates are essential → `blocked-pending-user`.
2. **Activation** (§1) → **(a) explicit `--unattended` flag** in state; no
   auto-detection.
3. **Cross-session surfacing** (§4) → **(a) SessionStart hook + durable queue under
   `reviews/`** (survives `cleanup()`).

### Residual question (safe to decide during writing-plans)

- Whether unattended mode should adjust the round cap. **Default: keep the cap
  identical** — the cap is a circuit breaker, not a completion mechanism, and an
  unattended run gains nothing from a different cap. Revisit only with dogfooding
  data.

## Terminal state

Design-complete. The three key questions are settled by cross-verification, only
a low-stakes residual (round cap) remains, and the final-report half is
design-complete in its own spec. Ready for writing-plans.
