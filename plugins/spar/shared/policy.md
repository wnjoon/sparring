# sparring loop policy (SoT)

Both adapters (Claude-hosted, Codex-hosted) implement exactly this policy.

## Roles

- **Author** — the model the user is working with. Sole writer of code.
  Never declares convergence.
- **Reviewer** — the resolved reviewer family (`codex` or `claude`), invoked
  read-only, stateless per round. Judge and matcher use the same resolved
  family. Sole authority on `STATUS: CONVERGED`.
- Single-agent mode (Phase 3): same-family review is a first-class mode;
  cross-model is the recommended default.

## Protocol

1. Author implements the task, then tries to stop; a deterministic hook
   blocks exit and prepares round 1.
2. Reviewer receives: task description + instruction to inspect the change
   surface — the codex reviewer runs git itself in its sandbox; the claude
   reviewer is given the diff inline. Conveyance boundary — the reviewer is
   NEVER told what was fixed or rejected; every round is a full fresh
   re-review against the frozen baseline. The only loop-generated context
   conveyed is the decision ledger (empty until Phase 2c).
3. Reviewer output: first line `STATUS: CONVERGED` or `STATUS: FINDINGS`;
   findings tagged `[MECHANICAL]` or `[DESIGN]` with file/problem/suggestion.
4. Author must fix every MECHANICAL finding, decide DESIGN findings on the
   merits, and write a response file (`FIXED — ...` / `REJECTED — <grounded
   reason>` per finding) before the hook prepares the next round.
5. Exit is released only by reviewer convergence, the round cap (default 5,
   exits with an honest "unconverged" summary), or explicit cancel.
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
   breaks an invariant — it only delays stalemate detection (the reviewer
   keeps raising it, bounded by the round cap).

## Invariants

- Single-writer: reviewer sandbox is read-only.
- Reviewer-declares: author never writes the convergence marker.
- Deterministic enforcement: hooks block exit; prompts alone are not trusted.
- Fail-open: any hook-internal error approves exit; never trap the user.
- Review artifacts (`reviews/spar-*.md`) are append-only for the author:
  never edited or deleted (except via explicit user cleanup).

## Phase roadmap

Phases 1–2 (implemented): core loop + design findings, blind judge, gate,
decision ledger, semantic matcher. Phase 3: single-agent mode — same-family
Claude reviewer/judge/matcher so `/spar` runs without Codex (auto-detect +
override; cross-model stays default). Phase 4: final sweep + skip conditions.
Phase 5: unattended mode + final report. Phase 6: Codex-hosted adapter (git
pre-commit enforcement). Phase 7: model economics (reviewer/effort config,
tiered fix writers).
