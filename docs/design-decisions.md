# Design decisions (agreed, not yet implemented)

Decisions settled in design sessions, recorded so a fresh session can write
each phase's implementation plan without re-litigating them. When a phase is
implemented, its section here is the spec source for the plan document.
Ideas marked *(EP)* are adapted from the review-loop protocol in
[jongwony/epistemic-protocols](https://github.com/jongwony/epistemic-protocols) (MIT).

## Phase 2 — design findings, deadlocks, gate

**Debate-first, gate-last.** `[DESIGN]` findings do NOT interrupt the loop:

1. The author states a position in its response file; the reviewer either
   accepts next round (→ settled by models, recorded in the ledger) or
   contests it.
2. Stalemate = the same finding contested for 2 rounds. Finding identity is
   **semantic** — same defect asserted about the same code surface — never
   line numbers or wording *(EP)*.
3. Stalemate on a factual question (is this a real bug?) → **blind judge**:
   a fresh subagent that receives the finding + the code + the task
   requirements and NEVER the debate transcript. One ruling, binding.
4. Stalemate on a genuine design choice → **park it**: leave that surface
   unmodified, continue the loop on everything else, and ask the user ONCE
   at loop end with all parked questions batched.
5. Model-settled design decisions are listed prominently in the final report
   for after-the-fact user review — settled silently is not acceptable,
   because model agreement can be persuasion (sycophancy), not truth.

**Conveyance boundary** *(EP)*. The reviewer is never told what was "fixed"
or "rejected" — response files exist for accountability and audit, but are
NOT passed to the reviewer. Each round is a full fresh re-review of the code
against the frozen baseline. The only loop-generated context conveyed is the
**decision ledger** (below). Consequence: the round-2+ prompt addendum
(`reviewer-prev-context.md`) that points at prior review/response files is
retired when this lands.

**Decision ledger.** Design decisions constituted at a gate or settled by
models accumulate in the state file, are injected into every subsequent
reviewer prompt as design intent ("this is a deliberate choice: <basis>"),
and at loop exit the user is offered — never required — to record them in a
durable home (issue/PR/docs) *(EP)*. Conveying a decision never includes an
instruction about what the reviewer must not flag; the reviewer stays free
to flag a defect the decision itself causes *(EP)*.

**Gate mechanics** (for the single end-of-loop gate) *(EP)*:
- Cluster parked questions by shared disposition — one question per cluster,
  not per finding.
- All analysis and evidence goes in text BEFORE the question; the question
  carries only the options and their differential consequences.
- Collapse test: if every option leads to materially the same outcome, do
  not ask — resolve automatically and note it in the report.

## Phase 3 — sweep + skip + intent harvest

**Final sweep** (existing roadmap): after convergence, when risk signals are
present — risky repo (smart contracts, DDL, auth), 3+ rounds, or any design
finding occurred — a fresh author-family subagent, blind to loop history,
verifies diff + requirements once. Findings → back into the loop.

**Skip conditions**: docs-only changes or tiny diffs exit without a loop.
Thresholds decided at implementation time; the skip must be reported, never
silent.

**Design-intent harvest** *(EP)*: before round 1, collect the project rules
that intersect the changed surface — relevant `.claude/rules/*.md`, the
design-rationale sections of `CLAUDE.md`/`AGENTS.md`, and "why this is
intentional" comments adjacent to changed hunks — and pass them to the
reviewer **as file pointers, not copied content**, bounded to the changed
files (never the whole rules directory). Purpose: stop the reviewer from
spending findings refuting documented intentional choices.

## Phase 4 — unattended + final report

- Unattended mode: `[MECHANICAL]` fixes proceed; design questions are parked
  (same machinery as Phase 2 parking) and reported at the next session start
  as "N design decisions pending".
- Final report contents: rounds run, findings fixed/rejected (with reasons),
  judge rulings, model-settled design decisions (prominent), parked/pending
  questions, sweep result, reviewer pairing used (cross- or same-model).

## Phase 5 — Codex-hosted adapter

- Seats mirror; policy identical. Enforcement moves from the Stop hook to a
  **git pre-commit hook**: an active unconverged loop blocks commits.
- Reviewer = `claude -p` restricted to read-only tools; declares CONVERGED.
- The sweep in this direction uses a fresh `codex exec` (read-only) so the
  "different model + no context" axis symmetry is preserved.
- Entry point: `~/.codex/prompts/` custom prompt; shares
  `plugins/spar/shared/` policy and templates.

## Phase 6 — model economics

**Tiering contract** *(EP)*: judgment never delegates; typing may.

- Session model (chosen by the user at launch) does: planning, initial
  implementation, reading reviews, classifying, rejecting with grounds,
  compiling fix briefs, gate handling. The plugin cannot and does not switch
  the session model — "use a strong model for planning" is a documented
  recommendation, not a mechanism.
- Fix execution during rounds goes to a cheaper-tier fresh subagent given a
  self-contained brief (file:line + verified basis + fix direction). Safe
  because the next round's full re-review re-judges the result — the loop is
  the quality gate, so writer tier does not weaken guarantees.
- Escalation: if a round's findings were caused by the previous round's
  fixes, the session model writes inline until a clean round, then
  de-escalates *(EP)*.
- Stay inline for trivial few-line fixes and risk-screened edits.
- Config (`shared/config.toml`): reviewer model per family, writer tier per
  family, reviewer reasoning effort scaled to diff size (symmetric principle
  — codex: `model_reasoning_effort`; claude adapter's equivalent to be
  confirmed at implementation).
- Same-model fallback (existing roadmap): reviewer CLI missing → fresh
  same-family reviewer with an explicit "reduced cross-model coverage"
  notice, per-round lens rotation (correctness / security / requirement
  fit), and a cross-family sweep when the other CLI exists.

## Cross-cutting stances

- **Round cap = circuit breaker, not a quality mechanism.** Healthy loops end
  by convergence; contested loops end via judge/parking; the cap only stops
  pathological oscillation. Configurable (`max_rounds`), always exits with an
  honest "unconverged" report, never pressures acceptance. Revisit with
  dogfooding data (does 5 ever fire?).
- **Simplicity guard.** Invariants stay at 4. Every absorbed idea lands as
  hook code + tests or a small prompt change — never as prose rules the
  model must remember. When a new rule seems needed, first ask "can structure
  solve this?".
- **Upstream re-check.** Borrowed ideas are point-in-time forks; skim
  hamelsmu/claude-review-loop and jongwony/epistemic-protocols for changes at
  each phase boundary.
- **Out of roadmap (candidate Phase 7):** PR-scope review (review a PR by
  number, stale-checkout reconciliation) — jongwony's remaining structural
  advantage, deliberately deferred.
- **Release**: merge `dev` → `main` + tag + GitHub release; verify remote
  install (`claude plugin marketplace add wnjoon/sparring`) as the release
  gate. Phase 1 may ship as v0.1.0 before later phases (decision pending).
