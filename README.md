# sparring

> A cross-model review sparring loop — the author never grades its own work.

**Status: v0.1.0 — the Claude-hosted loop is complete.**

Phases 1 and 2 are implemented and verified end-to-end against a real Codex reviewer — a planted-bug task went FINDINGS → fix → blind re-review → CONVERGED. Today `/spar` gives you:

- an **enforced** review loop that iterates until the *reviewer* declares convergence;
- a **blind Codex judge** that rules factual (`[MECHANICAL]`) stalemates;
- a **batched user gate + decision ledger** for genuine design choices;
- **cross-round matching** of re-worded findings.

Phases 3–6 (final sweep, unattended mode, the Codex-hosted mirror, model economics) are design only — the [Roadmap](#roadmap) marks what exists today.

## Direction

Coding agents are good at writing code and bad at noticing what they got wrong. Asking the same model to review its own output does not fix this: it is lenient toward its own work, and it shares the blind spots that produced the bug in the first place.

**sparring** pairs an *author* model with an *independent reviewer* model from a different vendor (Claude ↔ Codex), and turns review into an enforced, converging debate. Three ideas drive the design:

1. **Review is enforced, not requested.** A deterministic Stop hook blocks the author's exit until the loop completes. Prompt discipline is never trusted — if the harness can't guarantee it, it didn't happen.
2. **Only the reviewer can declare the work done.** The loop ends when the reviewer outputs `STATUS: CONVERGED` — the author has no way to grade its own work as finished. Self-assessment bias is removed structurally, not by exhortation.
3. **Debate, with guardrails against persuasion.** Findings are split into `[MECHANICAL]` (fixed immediately, no questions asked) and `[DESIGN]` (a choice among valid alternatives). Design findings don't interrupt the loop: the author states a position, the reviewer accepts or contests it next round, and only a genuine stalemate escalates — a *blind judge* (a fresh agent that sees the code and the finding but **never the debate**) for factual disputes, or a single batched question to the human at loop end for real design choices. Convergence must come from evidence, not from whoever argues more confidently. *(Implemented for the Claude-hosted `/spar` loop: `[MECHANICAL]` auto-fix; `[DESIGN]` debate → a blind Codex judge rules factual stalemates, a batched user gate + decision ledger settles genuine design choices; re-worded repeats of a finding are matched across rounds by a blind matcher.)*

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

## How it works

The diagram below is the **full target design**. `✅` marks what runs today
(Phases 1–2); `(planned Pn)` marks steps that are designed but not yet built.

```
/spar <task description>
      │
      ▼
[Implement]   the author writes the code, then tries to stop            ✅
      │
      ▼
 Stop hook ─── skip conditions (docs-only, tiny diff)? ──yes──▶ exit    (planned P3)
      │ no
      ▼
[Round N]     reviewer (read-only sandbox) reviews diff + requirements  ✅
      │        (re-worded repeats matched to the canonical finding)      ✅
      ├─ STATUS: FINDINGS
      │    ├─ [MECHANICAL] ──▶ author fixes immediately, no questions asked   ✅
      │    ├─ [DESIGN]     ──▶ debate-first; parked, batched at the gate       ✅
      │    ├─ stalemate (2 rounds on the same finding)                        ✅
      │    │    ├─ factual → blind Codex judge: sees code + finding,
      │    │    │            never the debate; UPHELD/DISMISSED is binding    ✅
      │    │    └─ design  → batched user gate + decision ledger at loop end  ✅
      │    └─ author writes a per-finding response → round N+1 (cap: 5)        ✅
      │
      └─ STATUS: CONVERGED
           ├─ exit (state cleaned up)                                         ✅
           │        └─ final report                                          (planned P4)
           └─ high-stakes? (risky repo · 3+ rounds · design findings)         (planned P3)
                 ▼
           [Final sweep]  fresh author-model subagent, blind to loop history,
                          verifies diff + requirements → clean ? exit : loop
```

The same structure runs in both directions. The seats swap; the invariants don't:

| Seat | Claude-hosted (`/spar`) | Codex-hosted (planned) |
|---|---|---|
| Author (sole writer) | Claude Code session | Codex CLI session |
| Reviewer (declares `CONVERGED`) | `codex exec --sandbox read-only` | `claude -p` (read-only tools) |
| Enforcement | Stop hook blocks exit | git pre-commit hook blocks commit (gates landing, not session exit) |

## Invariants

1. **Single-writer** — only the author edits code. The reviewer runs in a read-only sandbox.
2. **Reviewer-declares** — the author never writes the convergence marker. Ever.
3. **Deterministic enforcement** — hooks gate exit/commit; instructions alone are never the safety mechanism. Hooks fail *open* (a broken hook must not trap the user).
4. **Blind adjudication** — judges and sweepers never see the debate, only the artifact and the requirements.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Core loop: `/spar`, Stop hook, round machinery, per-finding response enforcement, round cap, read-only reviewer | ✅ done |
| 2 | `[DESIGN]` debate-first (conveyance boundary + decision ledger) · stalemate blind judge · batched end-of-loop gate · cross-round semantic finding matcher | ✅ done |
| 3 | Final sweep + skip conditions (docs-only, tiny diff) | planned |
| 4 | Unattended mode + final report | planned |
| 5 | Codex-hosted adapter (mirror seats, git pre-commit enforcement) | planned |
| 6 | Model economics: reviewer model + effort config, same-model fallback, tiered writers (judgment stays on the session model; a cheaper tier types the fixes from a brief; escalates when fixes cause new findings) | planned |

## Install

```bash
claude plugin marketplace add wnjoon/sparring
claude plugin install spar@sparring
```

Requires the [Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`) and `jq`.

## Repository layout

```
plugins/spar/            Claude Code plugin (commands, Stop hook)
  shared/policy.md       loop policy — source of truth for both adapters
  shared/prompts/        reviewer / judge / matcher prompt templates
docs/superpowers/plans/  phase implementation plans
tests/                   pure-bash hook tests
```

## Development

- `main` — releases only. `dev` — integration. `task/<n>-<name>` — one branch per plan task, merged into `dev`.
- The plan is the spec: [docs/superpowers/plans/](docs/superpowers/plans/). This README is updated in the same change whenever implementation diverges from it.
- Decisions agreed for phases not yet implemented live in [docs/design-decisions.md](docs/design-decisions.md) — each phase's plan document starts from its section there.

## License

MIT
