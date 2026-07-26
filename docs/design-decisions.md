# Design decisions

Decisions settled in design sessions, recorded so a fresh session can write
each phase's implementation plan without re-litigating them. Implemented
phases are marked as such and defer to `policy.md`; remaining sections are
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

- `/spar:fight <task>` writes the state file (`.claude/spar.local.md`); a bash Stop
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
  `/spar:fight` are currently mixed into the reviewed surface. A status/file-list
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
4. Stalemate on a genuine design choice → **parked** (status `parked`): leave
   that surface unmodified and continue the loop on everything else; the
   question is batched for the single end-of-loop gate. There is no separate
   author-declared "essential" state (decided: a single gate, no essentiality
   flag the author could game). "Blocked-pending-user" is not a distinct state
   — it is simply a parked question the user **defers** at the gate: that
   finding stays unsettled and the loop may not report the work "done". This
   preserves the no-false-completion property (an unresolved essential choice
   keeps the deliverable honestly incomplete) without a second code path.
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

**Decision ledger.** Lives in `.claude/spar-ledger.md` (the `{{LEDGER}}` slot
wired in Phase 2a injects it into every subsequent reviewer prompt). A gate
ruling produces one ledger entry: the author transcribes the user's decision
(the author runs the gate and writes the entry; it does not invent the
ruling), and the hook verifies an entry exists for each parked finding before
marking it `settled` and preparing the next round. The injected ledger is
framed as design intent ("these are deliberate choices — do not re-flag them
as defects"), but conveying a decision never tells the reviewer what it may
not flag: the reviewer stays free to flag a genuine defect the decision itself
causes *(EP)*. At loop exit the user is offered — never required — to copy the
ledger into a durable home (issue/PR/docs) *(EP)*.

**Gate trigger (2c).** The gate is deterministic, not a vibe. It fires when a
round makes no forward progress on anything but parked findings — i.e. after
folding a round, every open finding the reviewer raised is already `parked`
(nothing new, no `[MECHANICAL]` to judge, no fresh stalemate). At that point the
hook blocks once, instructing the author to run the batched gate for ALL
parked findings; the loop cannot converge while a parked finding keeps being
raised, so the ledger entry the gate produces is what unblocks the next
round's reviewer.

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

**Semantic matcher mechanism (stage 5 / Phase 2d).** The deterministic
fingerprint (`file | normalized-title`) misses a defect the reviewer re-words
across rounds — a false negative that keeps a real stalemate from being
detected (it degrades to the round cap, never to false convergence). Phase 2d
adds a blind matcher, same runner pattern as reviewer/judge: when a round
raises a finding whose fingerprint is new AND an already-tracked open/parked
finding shares its file (a cheap deterministic prefilter — a re-wording is
always on the same code surface), the hook generates a `codex exec --sandbox
read-only` matcher runner. It runs at most once per round and only on that
prefiltered ambiguous set (never every pair — too costly). The matcher is
shown the new findings' full text and the existing tracked findings (by short
tags), and outputs `SAME N<i> E<j>` pairs; the hook records each as an alias
(`variant-fp → canonical-fp`) that `fold_registry` resolves, so the re-worded
occurrence accumulates the streak on the canonical finding. The author only
runs the matcher — it cannot merge its own findings. Safety: a wrong match
never breaks an invariant — it only shifts WHEN a stalemate is detected, since
a missed match just means the reviewer keeps raising the finding until the
cap.

**Gate mechanics** (for the single end-of-loop gate) *(EP)*:
- Cluster parked questions by shared disposition — one question per cluster,
  not per finding.
- All analysis and evidence goes in text BEFORE the question; the question
  carries only the options and their differential consequences.
- Collapse test: if every option leads to materially the same outcome, do
  not ask — resolve automatically and note it in the report.

## Phase 3 — single-agent mode (same-family sparring)

Spec: [superpowers/specs/2026-07-22-single-agent-mode-design.md](superpowers/specs/2026-07-22-single-agent-mode-design.md).

Adds a Claude reviewer/judge/matcher so `/spar:fight` works with Claude alone — the
Codex CLI is no longer a hard requirement. Cross-model (Claude author ↔ Codex
reviewer) stays the recommended default; same-family keeps the enforced loop +
fresh blind review + judge/gate/matcher and drops only cross-vendor blind-spot
diversity. **This promotes the old "same-model fallback" from a CLI-missing
degradation to a first-class mode.**

- **Reviewer family** (`codex` | `claude`) resolved once at setup and stored
  in the state file's `reviewer:` field (unused today). All three
  model-invoking runners (reviewer, judge, matcher) are generated from that
  family instead of hardcoding `codex exec`; the three prompts are
  model-agnostic and reused unchanged.
- **Activation**: an explicit leading `--reviewer <codex|claude>` token on
  `/spar:fight` overrides; else auto-detect (`codex` on PATH → codex, else claude).
  Codex-missing stops being a hard block — it resolves to `claude`. An
  explicit override to an absent CLI errors (no silent swap).
- **Read-only blind Claude reviewer**: `claude -p` with a tool allowlist
  limited to inspection (Read/Grep/Glob + read-only git), excluding
  Edit/Write/general Bash. Permission-level enforcement (vs codex's OS
  sandbox); single-writer still holds. Blind by construction (fresh `-p`
  instance, no session history).
- **Honest notice** when same-family: "reduced cross-vendor blind-spot
  coverage; install Codex for cross-model review."
- Judge + matcher inherit the resolved family — no mixing within a loop.
- Out of scope here: Codex-Codex same-family (rides with the Codex-hosted
  adapter, Phase 6, reusing this family abstraction); per-round lens rotation
  (future, empirical); persistent config (Phase 7).

## Phase 4 — sweep + skip + intent harvest (implemented)

Implemented behavior has migrated to `plugins/spar/shared/policy.md`, the
current-behavior source of truth. The Phase 4 brainstorming text was removed
from this future-decisions document after landing.

## Phase 5 — unattended + final report

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
  or same-model). Plus **changed files** (`git diff --stat` vs `base_sha`).
- Final report delivery (agreed 2026-07-24, see
  `docs/superpowers/specs/2026-07-24-spar-report-design.md`): **generation vs
  display are split.** A deterministic `spar-report.sh` assembles
  `reviews/spar-<id>-report.md` and a `/spar:report [id]` command displays it.
  The report is informational, so it stays OUT of the hook's enforcement
  machinery — the hook's only role is one **fail-open** call to the generator at
  the terminal path. Generation MUST run **before `cleanup()`**, because cleanup
  deletes the ledger (`.claude/spar-ledger.md`) and registry that hold the
  settled-decision and finding data; the reviews/ files persist but those do not.
  No new phase and no extra round-trip. Scope: converged first, then every other
  hook terminal (generator is terminal-reason-agnostic, so each was one added line).
  Implemented 2026-07-25 (`docs/superpowers/plans/2026-07-25-spar-report.md` for
  the generator, `…-spar-report-remaining.md` for the rest): `spar-report.sh`
  plus a `generate_report()` fail-open call from `finish_approve` for
  `converged` (the unattended `blocked-pending-user` terminal shares it),
  displayed by `/spar:report [id]`. Command spelled `/spar:report` to match the
  post-refactor namespace. `cap`, `sweep-findings-at-cap`, and `skipped` followed
  in `docs/superpowers/plans/2026-07-25-report-every-terminal-path.md`. No report
  for `error-bypass` (a bailout has no run story) or `cancelled` (command-file
  path, user present by definition). Still deferred: the `/spar:fight` plan-wide
  roll-up, which needs a per-task review id in the plan state.

## Phase 6 — Codex-hosted adapter

- Seats mirror; policy identical. **Enforcement stays a Stop hook** — Codex has
  one. Superseded 2026-07-25: this section previously specified a **git
  pre-commit hook** and accepted a weaker guarantee ("you cannot commit
  unconverged work", not "you cannot stop"), because Codex was believed to have
  no session-exit hook. `codex-cli 0.144.1` does: hooks are stable and default-on,
  the event set includes `stop`, and a Stop hook returning
  `{"decision":"block","reason":…}` forces another turn — verified by spike
  (`docs/superpowers/notes/codex-hooks-spike.md`). The pre-commit hook is
  therefore dropped: it is bypassable with `git commit --no-verify`, it gates the
  wrong event, and it is unnecessary. Both adapters now have identical enforcement
  strength, and both share one gatekeeper — `stop-hook.sh` already discards its
  stdin and decides only from the state file and artifacts. Full design:
  `docs/superpowers/specs/2026-07-25-phase6-codex-adapter-design.md`.
- **Implementation status (2026-07-26):** code complete on the Phase 6 branch —
  `adapters/codex/{hooks.json.template,install.sh,skills/}` register both hooks and
  install four author-seat skills, and the shared engine gained the three seat-aware
  changes (self-locating plugin root, `author` field driving the sweep,
  `owner_session` gating). **Not yet run end to end with live models**, so the
  roadmap does not mark it done. The four things only a real session can settle:
  the hook trust path, user-vs-project hook scope, whether `SessionStart` fires
  before a skill's first action, and a planted-bug run going FINDINGS → fix →
  re-review → CONVERGED. Plan:
  `docs/superpowers/plans/2026-07-26-phase6-remaining.md`. The run itself is set up and
  judged by `adapters/codex/verify-live.sh` (isolated CODEX_HOME, planted bug,
  per-item verdict); the trust prompt stays interactive, so items 1 and 2 also need
  the human's observation.
- **Enforcement is proven per session, by a liveness marker.** Codex makes hook
  trust a per-session choice and exposes no way to query it; measured against
  0.144.1, an untrusted registration is *silently* skipped and the run completes
  as if no hook existed. So `SessionStart` writes the session id to
  `<git-dir>/spar-hook-live`, and `spar-fight` refuses to start unless that file
  names the session running right now. Existence alone is not proof — a marker
  outlives the session that wrote it. It sits in the git directory, not under
  `reviews/`: activation must read it before it creates anything, so it has to be
  somewhere a clean checkout already has, and writing `reviews/` from a hook would
  litter every repository the user opens.
  - `--git-dir`, not `--git-common-dir`: the marker names one session, and linked
    worktrees are how one repository hosts several at once. A shared marker would
    let a session started in worktree B invalidate worktree A, which then refuses
    to activate while insisting its hooks never ran. The loop's git-excludes keep
    using the common directory — those really are repository-wide.
  - The skill reads its own id from `CODEX_THREAD_ID`, which is measured to equal
    the session id Codex reports. Whether the *hook payload's* `session_id` is the
    same string is the one link still unmeasured; the check is fail-closed, so a
    divergence refuses to start rather than registering a run no session can
    advance. The live end-to-end run settles it.
- Entry point for the author seat is a **Codex skill**
  (`~/.codex/skills/spar-fight/SKILL.md`), not `~/.codex/prompts/` (no such
  mechanism in 0.144.1). Hook registration is a standalone `hooks.json` installed
  once — a Codex plugin cannot carry it (`plugin_hooks` is a removed feature), and
  rewriting the file per run would reset Codex's hook trust every loop.
- Reviewer = `claude -p` restricted to read-only tools; declares CONVERGED.
  Reuses the read-only blind Claude reviewer built in Phase 3, and Codex-Codex
  same-family sparring falls out of this direction for free (Phase 3's family
  abstraction, mirrored).
- The sweep in this direction uses a fresh `codex exec` (read-only) so the
  "different model + no context" axis symmetry is preserved.
- Both seats share `plugins/spar/shared/` policy and templates, and the installer
  stamps the resolved `plugins/spar` path into each installed skill so a skill
  read from `~/.codex/skills/` still finds the helper scripts.

## Phase 7 — model economics

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
- Same-family sparring graduated to **Phase 3** (single-agent mode). What
  remains here as *optional refinements* on top of that mode, if dogfooding
  shows same-family misses too much: per-round lens rotation (correctness /
  security / requirement fit) and a cross-family sweep when the other CLI
  exists.

## Cross-cutting stances

- **Round cap = circuit breaker, not a quality mechanism.** Healthy loops end
  by convergence; contested loops end via judge/parking; the cap only stops
  pathological oscillation. Always exits with an honest "unconverged" report,
  never pressures acceptance.
  - **Two levels, since 2026-07-26.** The dogfooding question above got its
    answer: 5 fired, on a run that was not oscillating at all. Fourteen findings
    raised, fourteen fixed, nothing rejected, no judge, and the matcher returned
    NO MATCHES in all five rounds — every round found *new* work. Counting
    elapsed rounds conflates a deadlock with a review that is still productive,
    and only the first deserves a circuit breaker.
  - So `max_rounds` (default 5) is now a **soft** cap, passed when the round that
    reached it was productive: nothing REJECTED, no ambiguous response, no judge
    dispatch, no parked design finding. Those are the three ways a round means
    "we disagree"; their absence means the author simply did the work. `hard_cap`
    (default `2 × max_rounds`) always stops the run — a reviewer that invents one
    fresh nitpick per round would otherwise never terminate, and each round is a
    full re-review of the whole diff. Doubling rather than a constant keeps the
    ceiling proportional to the budget the run asked for: `max_rounds: 3` gets 6,
    not a 10 the user never agreed to.
  - **The productivity test reads the REVIEW's findings, not the response's
    sections.** The gate before it only checks that a response file exists, so a
    response that omits a finding reaches it; scoring what the author wrote would
    read that silence as agreement, on exactly the finding the cap should stop
    for. A finding with no disposition is UNKNOWN, the same rule
    `fold_registry` applies.
  - **Cap fields are bounded on the digit string, before arithmetic.** Bash reads
    a leading zero as octal and wraps at 64 bits, so `18446744073709551617`
    evaluates to `1` — an absurd value that a range check placed after the
    conversion cannot distinguish from a real one. Out of range is rejected, not
    clamped: a cap of 10^19 is a typo, not a budget. The bound is arithmetic
    safety (18 digits, so doubling cannot overflow) and *not* a view about
    sensible budgets — `max_rounds: 101` is honoured, because rejecting a number
    the user stated plainly is the same silent reshaping the parse exists to
    avoid.
  - **Only an unambiguous FIXED buys extra rounds.** The shared response parser
    is permissive so the registry survives "FIXED (see below)"; the productivity
    test is not, because this is the one disposition that grants budget.
    `FIXEDLY` does not count, and a finding answered twice is a conflict.
  - **Recurrence counts against a round — revised 2026-07-26 after the second
    run.** The first version left it out, reasoning that a finding raised again is
    either fixed again (progress) or rejected (already caught). That enumeration
    missed the case the review of this very change produced three times: a finding
    fixed *incompletely* and re-raised. It is neither progress nor a rejection —
    it is the reviewer having to say the same thing twice, which is the clearest
    "not converging" signal short of an outright rejection, and the soft cap is
    what it should hit. Neither half is the author's judgment: identity across
    rounds is the engine's deterministic fingerprint, the same one the stalemate
    streak has always used (policy §7), and the matcher decides only the
    re-worded case, its verdict recorded per round so an early match does not
    condemn a later one.
    Deliberately the strict form (any repeat) rather than a "third appearance"
    counter: the evidence is two runs, relaxing later is easy, and rounds lost to
    a rule that was too generous cannot be recovered.
  - **Why the rounds must be granted inside the run.** There is no cheap manual
    continuation, and the obvious-looking one is wrong: a fresh `/spar:fight`
    sets `base_sha` to HEAD, and the reviewer sees `git diff $BASE`. Commit the
    capped work and re-run, and the reviewer is handed an *empty* diff — it
    reviews nothing. (It is not silently green: a zero diff is deliberately sent
    through review rather than safe-skipped, so it fails loudly.) The only real
    manual continuation is leaving the work uncommitted and re-running with
    `--include-dirty`, which re-reviews the whole surface from scratch with a
    reviewer blind to the earlier rounds — a restart, not a resume. The cap
    message therefore tells the author what was never re-reviewed and explicitly
    warns against the commit-and-re-run path.
- **Simplicity guard.** Invariants stay at 4. Every absorbed idea lands as
  hook code + tests or a small prompt change — never as prose rules the
  model must remember. When a new rule seems needed, first ask "can structure
  solve this?".
- **Exit honesty.** Every loop exit carries a machine-readable reason, at
  least: `converged`, `cap`, `error-bypass` (fail-open fired), `cancelled`
  (`/spar:cancel`), `skipped` (skip conditions), `blocked-pending-user`, and
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
  mutations use temp+rename, but `/spar:fight`'s initial state creation is a direct
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
  first-line protocol and deferred to config (Phase 7) — never offered as an
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
