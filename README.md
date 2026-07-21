# sparring

> A cross-model review sparring loop — the author never grades its own work.

**Status: 🚧 under active development.** Phase 1 (core loop) is in progress; nothing is installable yet. This README describes the direction the plugin is pursuing — the [Roadmap](#roadmap) marks what exists today.

## Direction

Coding agents are good at writing code and bad at noticing what they got wrong. Asking the same model to review its own output does not fix this: it is lenient toward its own work, and it shares the blind spots that produced the bug in the first place.

**sparring** pairs an *author* model with an *independent reviewer* model from a different vendor (Claude ↔ Codex), and turns review into an enforced, converging debate. Three ideas drive the design:

1. **Review is enforced, not requested.** A deterministic Stop hook blocks the author's exit until the loop completes. Prompt discipline is never trusted — if the harness can't guarantee it, it didn't happen.
2. **Only the reviewer can declare the work done.** The loop ends when the reviewer outputs `STATUS: CONVERGED` — the author has no way to grade its own work as finished. Self-assessment bias is removed structurally, not by exhortation.
3. **Debate, with guardrails against persuasion.** Findings are split into `[MECHANICAL]` (fixed immediately, no questions asked) and `[DESIGN]` (escalated to the human). When author and reviewer stalemate on a finding, a *blind judge* — a fresh agent that sees the code and the finding but **never the debate** — rules once. Convergence must come from evidence, not from whoever argues more confidently.

sparring is inspired by [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop), which pioneered the Stop-hook-enforced Codex review. sparring keeps that skeleton and extends it where a single-pass review falls short:

| | review-loop (origin) | sparring |
|---|---|---|
| Review rounds | one | until the reviewer converges (capped) |
| Reviewer input | diff only | diff **+ the task requirements** |
| Fix verification | none (fixes are never re-reviewed) | every round re-reviews the previous round's fixes |
| Author accountability | "use your own judgment" | per-finding response file (`FIXED` / `REJECTED` + grounded reason), enforced by the hook |
| Finding triage | severity only | `[MECHANICAL]` auto-fix / `[DESIGN]` user gate |
| Disagreement | author decides | 2-round stalemate → blind judge or user gate |
| Reviewer sandbox | full bypass | `--sandbox read-only` |

## How it works

```
/spar <task description>
      │
      ▼
[Implement]   the author writes the code, then tries to stop
      │
      ▼
 Stop hook ─── skip conditions (docs-only, tiny diff)? ──yes──▶ exit, no loop
      │ no
      ▼
[Round N]     reviewer (read-only sandbox) reviews diff + requirements
      │
      ├─ STATUS: FINDINGS
      │    ├─ [MECHANICAL] ──▶ author fixes immediately, no questions asked
      │    ├─ [DESIGN]     ──▶ attended: user gate / unattended: parked in report
      │    └─ stalemate (2 rounds on the same finding)
      │         ├─ factual → blind judge: fresh agent, sees code + finding,
      │         │            never the debate transcript
      │         └─ design  → user gate
      │    then: author writes a per-finding response → round N+1 (cap: 5)
      │
      └─ STATUS: CONVERGED
           ├─ low-stakes ─────────────▶ exit + final report
           └─ high-stakes or uncertain
              (risky repo · 3+ rounds · design findings occurred)
                 ▼
           [Final sweep]  fresh author-model subagent, blind to loop history,
                          verifies diff + requirements only
                 ├─ clean    ──▶ exit + final report
                 └─ findings ──▶ back to round N+1
```

The same structure runs in both directions. The seats swap; the invariants don't:

| Seat | Claude-hosted (`/spar`) | Codex-hosted (planned) |
|---|---|---|
| Author (sole writer) | Claude Code session | Codex CLI session |
| Reviewer (declares `CONVERGED`) | `codex exec --sandbox read-only` | `claude -p` (read-only tools) |
| Enforcement | Stop hook blocks exit | git pre-commit hook blocks commit |

## Invariants

1. **Single-writer** — only the author edits code. The reviewer runs in a read-only sandbox.
2. **Reviewer-declares** — the author never writes the convergence marker. Ever.
3. **Deterministic enforcement** — hooks gate exit/commit; instructions alone are never the safety mechanism. Hooks fail *open* (a broken hook must not trap the user).
4. **Blind adjudication** — judges and sweepers never see the debate, only the artifact and the requirements.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Core loop: `/spar`, Stop hook, round machinery, per-finding response enforcement, round cap, read-only reviewer | 🚧 in progress |
| 2 | `[DESIGN]` user gate + stalemate blind judge | planned |
| 3 | Final sweep + skip conditions (docs-only, tiny diff) | planned |
| 4 | Unattended mode + final report | planned |
| 5 | Codex-hosted adapter (mirror seats, git pre-commit enforcement) | planned |
| 6 | Same-model fallback + reviewer model config | planned |

## Install (once released)

```bash
claude plugin marketplace add wnjoon/sparring
claude plugin install spar@sparring
```

Requires the [Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`) and `jq`.

## Repository layout

```
plugins/spar/            Claude Code plugin (commands, Stop hook)
  shared/policy.md       loop policy — source of truth for both adapters
  shared/prompts/        reviewer / judge / sweeper prompt templates
docs/superpowers/plans/  phase implementation plans
tests/                   pure-bash hook tests
```

## Development

- `main` — releases only. `dev` — integration. `task/<n>-<name>` — one branch per plan task, merged into `dev`.
- The plan is the spec: [docs/superpowers/plans/](docs/superpowers/plans/). This README is updated in the same change whenever implementation diverges from it.

## License

MIT
