# Design decisions

Decisions settled in design sessions, recorded so a fresh session can write
each phase's implementation plan without re-litigating them. Phase 1 is
implemented — its section below is an as-built summary; later sections are
specs awaiting implementation, and each phase's plan document starts from its
section here. Ideas marked *(EP)* are adapted from the review-loop protocol in
[jongwony/epistemic-protocols](https://github.com/jongwony/epistemic-protocols) (MIT).

**Document hierarchy (which file is authoritative for what).**
`plugins/spar/shared/policy.md` is SoT for **currently implemented** behavior
and moves in lockstep with the hook. This file is SoT for **agreed-but-
unimplemented** future behavior; when a phase lands, its decisions migrate
into `policy.md` and the stale future wording is removed here. `README.md` is
the user-facing overview and labels every diagram/feature row implemented vs
planned. These are not three copies of one policy — they describe different
points in time, and consistency means each is correct for its own scope.

## Phase 1 — core loop (implemented, as-built)

Spec: [superpowers/plans/2026-07-21-phase1-core-loop.md](superpowers/plans/2026-07-21-phase1-core-loop.md) ·
tests: `tests/test_stop_hook.sh` (38 cases) · verified E2E against a real
Codex reviewer (planted-bug task: FINDINGS → fix → re-review → CONVERGED, 2 rounds).

- `/spar <task>` writes the state file (`.claude/spar.local.md`); a bash Stop
  hook is the state machine: task phase → review rounds → converged/cap.
- Reviewer = `codex exec --sandbox read-only`, stateless per round, prompt
  from `shared/prompts/reviewer.md`; first line `STATUS: CONVERGED |
  FINDINGS` is the only exit signal; findings tagged `[MECHANICAL]|[DESIGN]`.
- The author must write a per-finding response file (`FIXED — … / REJECTED —
  <grounded reason>`) before the hook prepares the next round.
- Round cap default 5 → deactivate + honest "unconverged" exit. Hook fails
  open on any internal error.

Post-plan patches (rationale absorbed from *(EP)*, landed after the plan doc
— the plan was not retro-edited):

- **Frozen review baseline**: `base_sha` captured at setup; every round
  reviews `git diff <base_sha>`, so mid-loop commits cannot shrink the
  reviewed surface or fake convergence. Missing/invalid → `HEAD` fallback.
- **Untracked files**: the reviewer explicitly lists and reads untracked
  files — new files never appear in a diff.
- **Pre-existing dirty state (known gap, fix pending)**: `base_sha` = `HEAD`,
  so tracked edits and untracked files that were already present *before*
  `/spar` are currently mixed into the reviewed surface. A status/file-list
  snapshot is NOT enough — if the same file is edited both before and during
  the loop, a list can't tell which hunk came from where. Two options:
  (**v1**) refuse by default when the worktree has pre-existing dirty tracked
  or untracked paths; an explicit `--include-dirty` opt-in reviews the whole
  dirty surface (the author accepts the mixing). (later) capture a real
  **content snapshot** at setup — blob hashes, or a `git stash create` commit
  object PLUS a separate snapshot of untracked file contents (`stash create`
  does not include untracked files) — and diff snapshot vs final worktree, so
  the reviewed surface is exactly the loop-induced delta.
- **Invalid reviewer output**: a review whose first line is neither status is
  set aside (`.invalid-N`) and re-run (3 strikes → fail open); a blank review
  can never converge nor count as findings.
- **Stdin prompt**: the runner feeds the prompt via stdin (no ARG_MAX limit;
  also fixes a codex hang on inherited open non-TTY stdin).

Note: `shared/prompts/reviewer-prev-context.md` (round-2+ addendum pointing
at prior review/response files) is live in Phase 1 but is scheduled for
retirement by Phase 2's conveyance boundary.

## Phase 2 — design findings, deadlocks, gate

**Debate-first, gate-last.** `[DESIGN]` findings do NOT interrupt the loop:

1. The author states a position in its response file; the reviewer either
   accepts next round (→ settled by models, recorded in the ledger) or
   contests it.
2. Stalemate = the same finding contested for 2 rounds. Finding identity is
   **semantic** — same defect asserted about the same code surface, never
   line numbers or wording *(EP)*. Since the reviewer re-reviews blind
   (conveyance boundary) and never sees its own prior findings, identity is
   matched **orchestrator-side**, not by the reviewer. Two distinct IDs:
   the reviewer emits a **reviewer-local ID** (`F<round>-<n>`) that is
   round-scoped and ephemeral; the orchestrator assigns a **canonical finding
   ID** that is stable across rounds by matching each round's reviewer-local
   findings against the prior ones. Matching = a cheap fingerprint (file +
   symbol/hunk + problem-type) for the bulk, with a model judgment call
   reserved for ambiguous pairs. Pure per-pair semantic matching is too
   costly to run on everything. Matching is against the full **open-finding
   registry**, not just the immediately prior round, so stalemate detection
   and audit have a stable cross-round view. The registry (stalemate tracking
   + audit) is **separate from the decision ledger** — the ledger holds only
   design decisions that were adjudicated or model-settled; settled outcomes
   graduate from the registry into it. But identity tracking NEVER overrides
   the reviewer: a **fresh blind re-review that declares `STATUS: CONVERGED`
   is authoritative and exits** (Invariant 2). Because every round re-derives
   findings from scratch against the frozen baseline — the reviewer has no
   memory to "skip" — a finding it stops raising is **treated as resolved by
   protocol** (not proven objectively fixed, but the fresh judgment is what
   the loop acts on). (This retracts an earlier over-reach: forcing extra
   rounds to "reconfirm" a dormant finding, or resuming a contested count on
   reappearance, would reintroduce the exact orchestrator-side memory the
   conveyance boundary removes and let the orchestrator second-guess
   `CONVERGED` — both drift from the design.) The registry drives only
   stalemate detection — a finding raised AND rejected by the author for 2
   consecutive rounds. A fresh `CONVERGED` judgment is authoritative, and this
   **accepts a residual risk**: a stateless reviewer may nondeterministically
   miss a prior defect. Full re-review and the risk-triggered final sweep
   *mitigate* this but do not eliminate it; the round cap provides no quality
   assurance. We accept the residual rather than add per-finding round-forcing
   machinery (simplicity guard).
3. Stalemate on a factual question (is this a real bug?) → **blind judge**:
   a fresh subagent that receives the finding + the code + the task
   requirements and NEVER the debate transcript. One ruling, binding.
   Mechanism (Claude-hosted): the hook generates a `codex exec --sandbox
   read-only` judge runner (same pattern as the reviewer runner); the author
   only executes it, so the author cannot produce the ruling — the "author
   never grades its own work" invariant extends to adjudication. Judge and
   reviewer are the same vendor but the judge is a fresh instance that never
   saw the debate (blindness, not vendor, is the guardrail). Routing is by
   tag: a `[MECHANICAL]` stalemate is a factual question → judge; a
   `[DESIGN]` stalemate is a choice → gate (point 4). Ruling file first line
   `RULING: UPHELD` (finding stands, author must fix — may no longer reject)
   or `RULING: DISMISSED` (finding dropped; recorded as an adjudicated
   decision in the ledger).
4. Stalemate on a genuine design choice → it leaves the loop into one of two
   states, depending on whether the choice is required to finish the task:
   - **Parked** (not required for completion): leave that surface unmodified,
     continue the loop on everything else, batch the question for the single
     end-of-loop gate.
   - **Blocked-pending-user** (the task cannot be called done without the
     decision): the loop must not silently continue-and-finish around it. It
     is a hard gate — the work is not complete until the user rules.
   The split matters because parking assumes the rest of the work still forms
   a finishable deliverable; when it does not, "park and move on" would report
   false completion.
5. Model-settled design decisions are listed prominently in the final report
   for after-the-fact user review — settled silently is not acceptable,
   because model agreement can be persuasion (sycophancy), not truth.

**Conveyance boundary** *(EP)*. The reviewer is never told what was "fixed"
or "rejected" — response files exist for accountability and audit, but are
NOT passed to the reviewer. Each round is a full fresh re-review of the code
against the frozen baseline. The only loop-generated context conveyed is the
**decision ledger** (below). Consequence: the round-2+ prompt addendum
(`reviewer-prev-context.md`) that points at prior review/response files is
retired when this lands. And because the reviewer is blind to its own history,
tracking a finding across rounds is the orchestrator's job, not the
reviewer's (see point 2).

**Decision ledger.** Design decisions constituted at a gate or settled by
models accumulate in the state file, are injected into every subsequent
reviewer prompt as design intent ("this is a deliberate choice: <basis>"),
and at loop exit the user is offered — never required — to record them in a
durable home (issue/PR/docs) *(EP)*. Conveying a decision never includes an
instruction about what the reviewer must not flag; the reviewer stays free
to flag a defect the decision itself causes *(EP)*.

**Implementation order** — Phase 2 is the biggest complexity fork (canonical
matching, judge, parking, ledger at once), so build it as a staged minimal
path, not one drop:
1. consecutive-round fingerprint matching (simpler than full open-registry);
2. stalemate detection;
3. blind judge / user gate;
4. decision ledger;
5. model-based semantic matching for ambiguous pairs (the full open-registry
   refinement).
Each stage ships with tests before the next begins.

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
verifies diff + requirements once. Sweep findings re-enter the loop as normal
rounds under the **same `max_rounds` ceiling counted from loop start** — the
sweep does not reset the counter. If the ceiling is already reached (e.g. the
loop converged exactly at the cap), a sweep finding is not looped further; it
is reported as an unconverged/blocked result, never silently dropped. The
sweep runs at most once per loop, so fixing its findings and re-converging
does not re-arm it.

**Skip conditions**: a change exits without a loop only when it is safe by
BOTH size and kind — a small diff AND no risky path touched. Risky paths
reuse the sweep's risk classifier (auth, migrations/DDL, CI, hooks, smart
contracts, …), so skip-eligibility and sweep-trigger share one definition of
"risky". Line count alone never authorizes a skip. The skip is always
reported, never silent.

**Design-intent harvest** *(EP)*: before round 1, collect the project rules
that intersect the changed surface — relevant `.claude/rules/*.md`, the
design-rationale sections of `CLAUDE.md`/`AGENTS.md`, and "why this is
intentional" comments adjacent to changed hunks — and pass them to the
reviewer **as file pointers, not copied content**, bounded to the changed
files (never the whole rules directory). Purpose: stop the reviewer from
spending findings refuting documented intentional choices.

## Phase 4 — unattended + final report

- Unattended mode: `[MECHANICAL]` fixes proceed; design questions split by the
  Phase 2 rule. **Parked** (non-essential) questions are batched and surfaced
  at the next session start ("N design decisions pending"). **Blocked-
  pending-user** (essential) decisions leave the work INCOMPLETE — it stays
  pending across sessions and is never reported as done. Unattended mode has
  no user to rule on an essential decision, so it must not fabricate
  completion around one.
- Final report contents: exit reason (the full exit-reason enum — see
  Cross-cutting §Exit honesty),
  rounds run, findings fixed/rejected (with reasons), judge rulings,
  model-settled design decisions (prominent), parked questions,
  blocked-pending-user decisions, sweep result, reviewer pairing used (cross-
  or same-model).

## Phase 5 — Codex-hosted adapter

- Seats mirror; policy identical. Enforcement moves from the Stop hook to a
  **git pre-commit hook**: an active unconverged loop blocks commits. This is
  a **weaker guarantee** than Claude's Stop hook and must be stated as such —
  a pre-commit hook gates *landing* the work, not *ending the session*, so a
  Codex author can walk away without converging (only without committing).
  Enforcement contract here is explicit: "you cannot commit unconverged
  work", NOT "you cannot stop". Closing the walk-away gap, if needed, is a
  separate mechanism — never assumed from the pre-commit hook alone.
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
- **Exit honesty.** Every loop exit carries a machine-readable reason, at
  least: `converged`, `cap`, `error-bypass` (fail-open fired), `cancelled`
  (`/spar-cancel`), `skipped` (skip conditions), `blocked-pending-user`, and
  `sweep-findings-at-cap`. Quality is asserted ONLY for `converged`; every
  other reason means the work is not a clean pass and must never read as one —
  not in state, logs, or the final report. The reason must be **persisted to
  a durable outcome record before cleanup**, otherwise the post-exit report
  cannot recover why the loop ended (today's cleanup deletes the state file
  and would lose it).
- **State & artifact integrity.** The state file holds the loop's **control
  state**; review/response files are **immutable transition inputs** the hook
  reads (their presence and first line drive transitions). "Immutable" needs
  a real guarantee, not a convention — the response file especially, since the
  author can edit it after writing. Decision: when the hook consumes an
  artifact at a transition it **atomically archives it as a consumed copy**
  (preferred over a hash alone — a hash detects later tampering but cannot
  restore the original response for the final report), so a later edit cannot
  silently rewrite what a transition was based on. Correcting an earlier overstatement: not every write is atomic today — the hook's state
  mutations use temp+rename, but `/spar`'s initial state creation is a direct
  redirection, and the reviewer runner is a **user-invokable command that can
  be launched twice** (a real multi-process path). Decisions: (a) make initial
  state creation atomic like the hook's; (b) the runner writes its output via
  temp+rename and takes a simple lock, so a double-launch cannot clobber or
  interleave a review file; (c) on corrupt/unparsable control state the hook
  fails open (Invariant 3) and clears it rather than act on garbage. No
  session-level lock beyond the runner — the Stop hook itself serializes
  within one session.
- **Prompt-injection resistance.** Reviewer/judge/sweeper prompts run over
  repo content that may try to steer them ("ignore prior instructions", a
  planted STATUS line). Defenses: the status signal is read only from the
  reviewer's own first output line, never from file content; harvested intent
  is passed as file pointers, not inlined text; the reviewer is told to treat
  repo text as data. These prompt measures are **best-effort**: file pointers
  cut inlined-payload exposure, but the reviewer still reads the file, so the
  risk is reduced, not eliminated. The real blast-radius containment is the
  read-only sandbox (Invariant 1) — the reviewer **cannot modify the
  repository**. It can still be misled into a wrong judgment or into echoing
  sensitive file contents in its output, so the sandbox bounds damage; it does
  not guarantee judgment integrity. These two problems are distinct: the
  defenses above
  address **input steering** (injection); structured output (e.g. JSON) only
  hardens **output parsing** and does not prevent injection. JSON is a
  candidate for parsing robustness, weighed against the deliberately simple
  first-line protocol and deferred to config (Phase 6) — never offered as an
  injection defense.
- **Test strategy.** Beyond the current per-case bash tests: as state
  combinations grow (Phase 2+), add state-transition coverage (phase × round
  × artifacts → expected decision) and crash/replay/recovery cases (killed
  mid-round, corrupt state, stale runner).
- **Upstream re-check.** Borrowed ideas are point-in-time forks; skim
  hamelsmu/claude-review-loop and jongwony/epistemic-protocols for changes at
  each phase boundary.
- **Out of roadmap (candidate Phase 7):** PR-scope review (review a PR by
  number, stale-checkout reconciliation) — jongwony's remaining structural
  advantage, deliberately deferred.
- **Release strategy (decided)**: no incremental release. Each phase merges to
  `dev` as it completes; `main` is untouched until a single `dev` → `main`
  merge at the chosen release milestone. `main` is not touched without an
  explicit "release now".
- **Release checklist** (run at the `dev` → `main` merge, before tagging):
  1. Sync `README.md` to what `dev` actually ships — roadmap, feature table,
     and the "How it works" diagram must mark implemented vs planned against
     dev's real state (README updates were deferred during development, so
     this reconciliation is mandatory at release, not optional).
  2. Confirm `policy.md` (implemented-behavior SoT) matches the shipped hook.
  3. `bash tests/test_stop_hook.sh` green.
  4. Merge `dev` → `main`, tag, GitHub release.
  5. Verify remote install (`claude plugin marketplace add wnjoon/sparring`)
     as the release gate.
