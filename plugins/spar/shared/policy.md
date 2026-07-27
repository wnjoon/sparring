# sparring loop policy (SoT)

The Claude-hosted adapter implements this policy. The planned Codex-hosted
adapter mirrors it exactly, including enforcement strength: Codex has a Stop hook
that honors `decision:block`, so both directions share this policy and one
gatekeeper implementation.

## Roles

- **Author** — the model the user is working with. Sole writer of code.
  Never declares convergence.
- **Reviewer** — the resolved reviewer family (`codex` or `claude`), invoked
  read-only, stateless per round. Judge and matcher use the same resolved
  family. Sole authority on `STATUS: CONVERGED`.
- Single-agent mode (Phase 3): same-family review is a first-class mode;
  cross-model is the recommended default.

## Protocol

1. Setup refuses a pre-existing dirty worktree by default because the frozen
   baseline cannot separate old and loop-induced hunks. `--include-dirty`
   explicitly adopts the entire dirty surface and disables automatic skip.
   After implementation, the Stop hook classifies the complete tracked,
   staged, and untracked surface. A non-zero change no larger than 10 lines
   across 2 paths may exit with the reported `skipped` reason only when no
   risky touched path or unsafe kind (rename/copy/delete/type/mode/binary/
   symlink/submodule) is present. Zero-diff still goes to review for
   requirement fit.
   Repo-level risk does not by itself block a small unrelated-path skip.
2. Reviewer receives: task description + instruction to inspect the change
   surface — the codex reviewer runs git itself in its sandbox; the claude
   reviewer is given the diff inline. Conveyance boundary — the reviewer is
   NEVER told what was fixed or rejected; every round is a full fresh
   re-review against the frozen baseline. The only loop-generated context
   conveyed is the decision ledger (empty until Phase 2c). Each round also
   receives fresh repository-resident design-intent pointers bounded to its
   current changed surface: applicable `.claude/rules`, ancestor
   `CLAUDE.md`/`AGENTS.md` rationale headings, and hunk-adjacent intentional
   comments. Pointers are re-harvested because fixes can grow the surface;
   repository content is never copied into this channel.
3. Reviewer output: first line `STATUS: CONVERGED` or `STATUS: FINDINGS`;
   findings tagged `[MECHANICAL]` or `[DESIGN]` with file/problem/suggestion.
4. Author fixes every MECHANICAL finding on sight, and decides DESIGN findings
   on the merits. A MECHANICAL finding may be rejected only with a reason
   grounded in the code or the task requirements — never for convenience —
   which is why item 6 has a MECHANICAL stalemate path at all; and write a response file (`FIXED — ...` / `REJECTED — <grounded
   reason>` per finding) before the hook prepares the next round.
5. Exit is released only by reviewer convergence, the round cap, or explicit
   cancel. The cap has two levels. The **soft cap** (`max_rounds`, default 5) is
   passed when the round that reached it was *productive* — every finding answered
   with an unambiguous `FIXED`, nothing rejected or unanswered, nothing escalated
   to the judge or parked, and no finding that repeats an earlier one — by the
   deterministic fingerprint of item 7, or by a matcher `SAME` verdict for a
   re-wording — because that is a review still finding real work, not a
   deadlock. Recurrence was excluded when the soft cap was first introduced and
   added on 2026-07-26: a repeat is a fix that landed incomplete, which is churn,
   not progress. Any repeat blocks the round rather than only a third appearance
   — the evidence is two runs, and a rule that grants rounds too freely cannot
   have them back, while a rule that is too strict can be relaxed. The
   **hard cap**
   (`hard_cap`, default `2 × max_rounds`) always ends the run. Either cap exits
   with an honest "unconverged" summary and never pressures acceptance.
6. Stalemate — a finding raised AND rejected for 2 consecutive rounds. A
   [MECHANICAL] stalemate goes to a blind judge, invoked read-only in the same
   resolved family as the reviewer (author only runs it; ruling
   `RULING: UPHELD`/`RULING: DISMISSED` is binding). A [DESIGN] stalemate is
   PARKED: the loop continues on everything else. When the loop is stuck on
   nothing but parked findings, the hook fires one batched gate — the author
   presents all parked questions to the user and records each ruling in the
   decision ledger (`.claude/spar-ledger.md`). The hook verifies a ledger
   entry per parked finding, marks them settled, and injects the ledger into
   later reviewer prompts as design intent so the settled choice is no longer
   re-flagged. An undecided parked question holds the loop at the gate — it
   is not released by the round cap; the only way out is to record the
   decision or `/spar-cancel`.
7. Finding identity across rounds is a deterministic fingerprint
   (file + normalized title). When a round raises a finding whose fingerprint
   is new but an already-tracked open or parked finding shares its file, a
   blind matcher, invoked read-only in the same resolved family as the
   reviewer (once per round, author only runs it), decides which are the same
   defect re-worded; matches become aliases so the re-wording accumulates the
   stalemate streak on the canonical finding. A wrong or absent match never
   breaks an invariant, but it has three effects. An ABSENT match delays
   stalemate detection (the reviewer keeps raising it) and can let a RE-WORDED
   repeat score as productive and extend — both bounded by the round cap. A
   repeat under the same fingerprint is unaffected: it is caught without the
   matcher. A WRONG match runs the other way: a false `SAME` caps a genuinely
   productive round at the soft cap. That one is not bounded by the cap, it
   triggers it, and it is the deliberately reversible direction — rounds
   withheld can be granted by relaxing the rule, rounds granted in error cannot
   be taken back.
8. After reviewer convergence, a final sweep fires for a risky touched
   surface or risky repository, 3+ reviewer rounds, or any reviewer design
   finding. It is one fresh, read-only author-family instance, blind to
   the ledger and all loop history but allowed repository intent pointers.
   It uses `SWEEP: CLEAN|FINDINGS`, never `STATUS: CONVERGED`, and runs at
   most once. The sweep itself is not a reviewer round. Findings below the cap
   receive a separate response and re-enter at reviewer round `r+1`; findings
   at the cap terminate honestly as `sweep-findings-at-cap`.
9. Every terminal path atomically writes one immutable outcome before cleanup:
   at least `converged`, `cap`, `error-bypass`, `cancelled`, `skipped`,
   `blocked-pending-user`, or `sweep-findings-at-cap`. Only `converged` asserts
   a clean review result.
10. Every terminal that ends a real review — `converged`, `blocked-pending-user`,
    `cap`, `sweep-findings-at-cap`, and `skipped` — also gets an informational
    report, `reviews/spar-<id>-report.md`, since an unconverged run is exactly the
    one a human needs summarized. (`error-bypass` and `cancelled` get none: a
    bailout has no run story, and a cancelling user is already present.) It
    carries: outcome, rounds, reviewer pairing, sweep
    result, findings tally, judge rulings, the user's settled decisions, still
    pending decisions, and the changed files. It is generated deterministically
    BEFORE cleanup (the ledger and registry it reads are deleted there), is
    fail-open (a failure only means "no report"), and is never part of
    enforcement. `/spar:report [id]` displays it.
11. Reviewer model and reasoning effort are configuration, not protocol
   (`plugins/spar/shared/config.toml`, read per family). Absent or unreadable
   configuration means exactly the behaviour that predates it — no flag is
   passed rather than an empty one. Nothing configurable here can change who
   declares convergence, who may write the convergence marker, or which findings
   escalate: configuration selects the instrument, never the verdict. The final
   sweep reads the AUTHOR family's settings, not the reviewer's, because it is a
   fresh author-family instance.

## Invariants

- Single-writer: reviewer sandbox is read-only.
- Reviewer-declares: author never writes the convergence marker.
- Deterministic enforcement: hooks block exit; prompts alone are not trusted.
- Fail-open: any hook-internal error approves exit; never trap the user.
- Review artifacts (`reviews/spar-*.md`) are append-only for the author:
  never edited or deleted (except via explicit user cleanup).

## Phase roadmap

Phases 1–5 (implemented): core loop; design findings, blind judge, gate,
decision ledger, semantic matcher; same-family Claude review; safe skip,
changed-surface intent harvest, durable outcomes, and final sweep; unattended
mode and the final run report (`/spar:report`).
Phase 6: Codex-hosted adapter (mirrored seats, same Stop-hook enforcement via
Codex's own `Stop` hook). Phase 7: model
economics (reviewer/effort config, tiered fix writers).
Phase 8 (orchestration): `/spar:ready` + `/spar:fight` — a plan-to-fight
workflow layered ABOVE the loop. `/spar:ready` runs writing-plans → dedicated
branch → task table, then stops; `/spar:fight` runs the plan (per-task by
default, `--whole` optional), driven by a single combined Stop-hook dispatcher
that wraps the loop's own `stop-hook.sh`. It reads each task's durable outcome
to advance, flips the plan's checkboxes, and commits per task. Depends only on
Phases 1–4; order-independent of 5–7. It never writes convergence and stops
honestly on a non-converged task.
