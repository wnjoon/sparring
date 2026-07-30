# sparring

<img src="image/main.png" alt="sparring — a cross-model code-review loop" width="100%">


> A cross-model review sparring loop — the author never grades its own work.

**Status: v0.9.2 — a plan gets an independent reading before it is fought. `/spar:ready` prepares one review of the plan it just wrote, and `/spar:fight` refuses to start until every finding has a disposition: accepted, or rejected with a reason grounded in the plan, the spec or the code. A grounded rejection clears a finding — agreement is not required. `--no-plan-review` skips the pass and records that it was skipped. Both seats are verified end to end and use their own command spellings. The Codex release-gate checklist exercises the plan path too, so the seat that mirrors this one is checked against the feature rather than around it. Model economics ships alongside: the reviewer's model and effort are configurable, and nothing is enabled by default.**

Phases 1–9 are implemented; the core loop is verified end-to-end against real reviewers — a planted-bug task went FINDINGS → fix → blind re-review → CONVERGED. Today `/spar:fight` gives you:

- an **enforced** review loop that iterates until the *reviewer* declares convergence;
- a **blind judge** that rules factual (`[MECHANICAL]`) stalemates;
- a **batched user gate + decision ledger** for genuine design choices;
- **cross-round matching** of re-worded findings;
- **single-agent mode** — auto-detects the reviewer (Codex if installed → cross-model, the recommended default; otherwise Claude), so `/spar:fight` works with no second vendor. `--reviewer codex|claude` overrides;
- a reported **safe skip** for changes no larger than 10 lines / 2 paths when no risky path or unsafe change kind is touched;
- changed-surface **design-intent pointers** on every fresh review;
- a once-only, fresh author-family **final sweep** after risky, long, or design-bearing loops;
- a **final run report** — converged or not, a finished run writes `reviews/spar-<id>-report.md` (`cap`, `sweep-findings-at-cap`, `skipped`, and unattended `blocked-pending-user` included; an internal-error bypass or an explicit `/spar:cancel` writes none): outcome, rounds, reviewer pairing, sweep result, findings tally, judge rulings, your settled design decisions, anything still pending, and the changed files. `/spar:report [id]` shows it (defaults to the latest run).

<br>

<img src="image/weighin.png" alt="weighin — a cross-model code-review loop" width="100%">



Phase 8 (the `/spar:ready` + `/spar:fight` orchestrator) and Phase 5's unattended mode shipped in v0.5.0; Phase 5's final run report (`/spar:report`) completes Phase 5 in v0.6.0. Phase 6 (the Codex-hosted mirror) closes in v0.8.0, after a live run in an isolated Codex home: trust accepted, the user-scope `SessionStart` hook firing before the skill's first action, and a planted off-by-one going FINDINGS → fix → blind re-review → CONVERGED with `claude -p` as the reviewer. That run also found three defects no test had, all fixed here. Phase 7 (model economics — reviewer model and effort config, a tiered fix writer) and Phase 9 (plan review) both first ship in v0.9.1; nothing Phase 7 adds is on by default. There is no v0.9.0 release — the version was prepared, then the first live run of the Codex seat against it found the plan-review gate naming the Claude command spellings in its refusal, so what shipped is v0.9.1 with that corrected. v0.9.2 fixes three defects that using the tool surfaced rather than reading it: the branch slug mangled an inline spec, the outcome file omitted the author seat so a later report guessed it, and the Codex release-gate checklist never exercised the plan path. The two-level round cap arrived in v0.7.0 after three dogfooding runs ended at the cap with nothing contested — see [the design note](docs/superpowers/specs/2026-07-26-productive-round-extension-design.md). The [Roadmap](#roadmap) marks what exists today. A small [effect benchmark](bench/README.md) has shipped since v0.2.0.

## Direction

Coding agents are good at writing code and bad at noticing what they got wrong. Asking the same model to review its own output does not fix this: it is lenient toward its own work, and it shares the blind spots that produced the bug in the first place.

**sparring** pairs an *author* model with an *independent reviewer* model from a different vendor (Claude ↔ Codex), and turns review into an enforced, converging debate. Three ideas drive the design:

1. **Review is enforced, not requested.** A deterministic Stop hook blocks the author's exit until the loop completes. Prompt discipline is never trusted — if the harness can't guarantee it, it didn't happen.
2. **Only the reviewer can declare the work done.** The loop ends when the reviewer outputs `STATUS: CONVERGED` — the author has no way to grade its own work as finished. Self-assessment bias is removed structurally, not by exhortation.
3. **Debate, with guardrails against persuasion.** Findings split into `[MECHANICAL]` (fixed on sight) and `[DESIGN]` (a choice among valid alternatives). Design findings don't interrupt the loop — the author states a position, and the reviewer accepts or contests it the next round. Only a genuine stalemate escalates: a **blind judge** (sees the code and the finding, never the debate) settles factual disputes; a single batched question to the human settles real design choices. Convergence comes from evidence, not from whoever argues more confidently.

sparring is inspired by [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop), which pioneered the Stop-hook-enforced Codex review. Several loop-hardening ideas — the fixed review baseline, the conveyance boundary (never tell the reviewer what was "fixed"), the decision ledger, design-intent harvesting, and tiered fix writers — are adapted from the review-loop protocol in [jongwony/epistemic-protocols](https://github.com/jongwony/epistemic-protocols). sparring keeps hamelsmu's skeleton and extends it where a single-pass review falls short:

| | review-loop (origin) | sparring | Status |
|---|---|---|---|
| Review rounds | one | until the reviewer converges (capped) | ✅ Phase 1 |
| Reviewer input | diff only | diff **+ the task requirements** | ✅ Phase 1 |
| Fix verification | none (fixes are never re-reviewed) | every round re-reviews the previous round's fixes | ✅ Phase 1 |
| Author accountability | "use your own judgment" | per-finding response file (`FIXED` / `REJECTED` + grounded reason), enforced by the hook | ✅ Phase 1 |
| Finding triage | severity only | `[MECHANICAL]` auto-fix / `[DESIGN]` debate-first → gate | ✅ Phase 2 |
| Disagreement | author decides | 2-round stalemate → blind judge (factual) or batched user gate (design) | ✅ Phase 2 |
| Cross-round identity | (n/a) | re-worded findings matched to the canonical one | ✅ Phase 2 |
| Reviewer sandbox | full bypass | `--sandbox read-only` | ✅ Phase 1 |
| Trivial change handling | always review | reported size + kind safe skip | ✅ Phase 4 |
| Project intent | reviewer rediscovers it | changed-surface rule / rationale / comment pointers | ✅ Phase 4 |
| Closure check | none | risk-triggered fresh blind author-family sweep | ✅ Phase 4 |

## How it works

Everything below runs today. `/spar:ready` turns a spec into a checkbox plan; `/spar:fight` then runs each task through the loop independently (or runs a single ad-hoc task on its own).

```
/spar:fight <task description>
      │
      ▼
[Implement]   the author writes the code, then tries to stop
      │
      ▼
 Stop hook ─── small AND safe kind? ──▶ reported skipped exit
      │
      ▼
[Round N]     reviewer (read-only sandbox) reviews diff + requirements
      │        re-worded repeats are matched to the canonical finding
      ├─ STATUS: FINDINGS
      │    ├─ [MECHANICAL] → author fixes immediately, no questions asked
      │    ├─ [DESIGN]     → debate-first; parked, then batched at the gate
      │    │                 (unattended: no gate → blocked-pending-user exit)
      │    ├─ stalemate (2 rounds on the same finding)
      │    │    ├─ factual → blind judge (code + finding, never the
      │    │    │            debate); UPHELD / DISMISSED is binding
      │    │    └─ design  → batched user gate + decision ledger at loop end
      │    ├─ author writes a per-finding response → round N+1
      │    └─ soft cap (5) reached
      │         ├─ that round was productive — every finding answered
      │         │  FIXED, nothing rejected, ambiguous or unanswered,
      │         │  no judge pending, no parked design finding, and
      │         │  no finding repeating an earlier one (same
      │         │  fingerprint, or a matcher SAME for a re-wording)
      │         │  → keep going, up to hard_cap
      │         │  (2 x max_rounds, so 10 by default; no
      │         │  supported user override)
      │         └─ otherwise, or hard cap → cap exit
      │
      └─ STATUS: CONVERGED
              ├─ risky repo/path · 3+ rounds · design finding?
              │    → final sweep: fresh blind Claude subagent re-verifies
              │      diff + requirements
              │        ├─ clean            → converged exit
              │        └─ findings         → respond, re-enter the loop at
              │                              round r+1; at the hard cap instead
              │                              → sweep-findings-at-cap exit
              └─ otherwise → converged exit

  The soft cap is passed only while rounds stay productive, because it exists to
  stop a deadlock and elapsed rounds alone cannot tell one from a review still
  finding real work. A re-raised finding counts against a round: a repeat means a
  fix landed incomplete. Any repeat blocks it, not just a third appearance —
  strict is the reversible direction. Full rationale, including what overturned
  the first version, is in docs/design-decisions.md.

  every exit above — converged · blocked-pending-user · cap ·
  sweep-findings-at-cap · skipped — writes the detailed final report
  to reviews/spar-<id>-report.md, shown by /spar:report.
  An internal-error bypass or an explicit /spar:cancel writes none.
```

The reviewer / judge / matcher run as **Codex** (`codex exec --sandbox read-only`, the default cross-model setup) or **Claude** (`claude -p`, read-only + isolated — single-agent mode); the protocol and invariants are identical either way.

The same structure runs in both directions. The seats swap; the invariants don't:

| Seat | Claude-hosted (`/spar:fight`) | Codex-hosted (`spar-fight` skill) |
|---|---|---|
| Author (sole writer) | Claude Code session | Codex CLI session |
| Reviewer (declares `CONVERGED`) | `codex exec --sandbox read-only` (default) or `claude -p` (single-agent) | `claude -p` (read-only tools) |
| Enforcement | Stop hook blocks exit | Codex `Stop` hook blocks exit — same guarantee, same gatekeeper script |

## Invariants

1. **Single-writer** — only the author edits code. The reviewer runs in a read-only sandbox.
2. **Reviewer-declares** — the author never writes the convergence marker. Ever.
3. **Deterministic enforcement** — hooks gate exit/commit; instructions alone are never the safety mechanism. Hooks fail *open* (a broken hook must not trap the user).
4. **Blind adjudication** — judges and sweepers never see the debate, only the artifact and the requirements.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Core loop: `/spar:fight`, Stop hook, round machinery, per-finding response enforcement, two-level round cap, read-only reviewer | ✅ done |
| 2 | `[DESIGN]` debate-first (conveyance boundary + decision ledger) · stalemate blind judge · batched end-of-loop gate · cross-round semantic finding matcher | ✅ done |
| 3 | Single-agent mode: same-family sparring (Claude reviewer/judge/matcher) so `/spar:fight` works without Codex — auto-detect + explicit override; cross-model stays the default | ✅ done |
| 4 | Safe skip + changed-surface intent harvest + risk-triggered final sweep + durable exit reason | ✅ done |
| 5 | Unattended mode + final report (`/spar:report`) | ✅ done |
| 6 | Codex-hosted adapter: mirror the seats (Codex authors, `claude -p` reviews) and reuse the same Stop-hook gatekeeper via Codex's own `Stop` hook | ✅ done |
| 7 | Model economics: reviewer model + effort config, tiered fix writers (judgment stays on the session model; a cheaper tier types the fixes) | ✅ done |
| 8 | `/spar:ready` + `/spar:fight` orchestrator: writing-plans → dedicated branch → per-task (or `--whole`) fight loop, single Stop-hook dispatcher wrapping the loop hook, per-task checkbox commits | ✅ done |
| 9 | Plan review: one blind pass over a `/spar:ready` plan before it is fought — do its claims about the code hold, is every step satisfiable, does it cover the spec — enforced as a `/spar:fight` precondition | ✅ done |

## Install

```bash
claude plugin marketplace add wnjoon/sparring
claude plugin install spar@sparring
```

Requires `jq`. The [Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`) is **recommended** — with it, `/spar:fight` runs cross-model (Claude author ↔ Codex reviewer). Without it, single-agent mode reviews with Claude alone. Force a family with `/spar:fight --reviewer codex|claude -- <task>`.

A single ad-hoc `/spar:fight <task>` starts only from a clean worktree by default.
`--include-dirty` explicitly adopts the entire pre-existing dirty surface and
disables automatic skip. Executing a plan prepared by `/spar:ready` does not check
the worktree: the plan is fought task by task and each task's commit lands on the
plan's branch, so uncommitted work at the start is part of the first task's review
surface rather than something to refuse.

## Repository layout

```
plugins/spar/            Claude Code plugin (commands, Stop hook)
  commands/              /spar:ready, /spar:fight, /spar:cancel, /spar:report, setup guards + surface helpers
  hooks/                 Stop dispatcher + round engine + SessionStart
  shared/policy.md       loop policy — source of truth for both seats
  shared/prompts/        reviewer / judge / matcher / sweeper / plan-reviewer templates
adapters/codex/          Codex-hosted seat: hooks.json template, installer, skills
docs/superpowers/        specs, plans, and design-decisions per phase
tests/                   pure-bash hook + resolver tests
bench/                   effect benchmark (living report + tasks/oracles)
```

## Development

- `main` carries releases and the work that leads to them. Each run of `/spar:ready` cuts its own `spar/<slug>-<timestamp>` branch, fights the plan task by task on it, and is merged back with `--no-ff` so the phase boundary stays visible in the history. (An earlier `dev` + `task/<n>-<name>` scheme is no longer used; the `dev` branch is left where it stopped.)
- Tests are pure bash: `bash tests/test_<name>.sh`, or all of them with `for t in tests/test_*.sh; do bash "$t"; done`. CI ([.github/workflows/tests.yml](.github/workflows/tests.yml)) runs every suite on Linux and macOS for each push and pull request — no reviewer CLI required, since the suites stub it.
- The Codex seat's release gate is a scripted manual run:
  `bash adapters/codex/verify-live.sh setup` builds an isolated Codex home with a
  planted bug and prints a checklist, and `… check` judges the artifacts
  afterwards. It covers the plan path as well as the single-task loop, so a change
  to Phase 9's gate is exercised there too. Two of its five items rest on what the
  human saw — the trust prompt's wording, and whether the plan-review gate actually
  refused — because neither leaves an artifact; `check` says so rather than
  implying it judged them.
- A change to a surface both seats share — the Stop hook's output or exit contract,
  the state file, the runner scripts — is exercised in a live session of each seat
  before the release that carries it. Green suites are not enough: they assert what
  the hook prints, not what each harness does with it.
- Reviewer model and reasoning effort are optional per-family settings in
  [plugins/spar/shared/config.toml](plugins/spar/shared/config.toml). Nothing is enabled
  out of the box: with no value set, no flag is passed and the loop behaves as it did
  before. Configuration selects the instrument, never the verdict.
- The plan is the spec: [docs/superpowers/plans/](docs/superpowers/plans/). This README is updated in the same change whenever implementation diverges from it.
- Decisions agreed for phases not yet implemented live in [docs/design-decisions.md](docs/design-decisions.md) — each phase's plan document starts from its section there.

## License

MIT
