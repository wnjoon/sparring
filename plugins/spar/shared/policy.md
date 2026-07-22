# sparring loop policy (SoT)

Both adapters (Claude-hosted, Codex-hosted) implement exactly this policy.

## Roles

- **Author** — the model the user is working with. Sole writer of code.
  Never declares convergence.
- **Reviewer** — the opposite model, invoked read-only, stateless per round.
  Sole authority on `STATUS: CONVERGED`.

## Protocol

1. Author implements the task, then tries to stop; a deterministic hook
   blocks exit and prepares round 1.
2. Reviewer receives: task description + instruction to inspect the diff
   itself. Conveyance boundary — the reviewer is NEVER told what was fixed
   or rejected; every round is a full fresh re-review against the frozen
   baseline. The only loop-generated context conveyed is the decision ledger
   (empty until Phase 2b).
3. Reviewer output: first line `STATUS: CONVERGED` or `STATUS: FINDINGS`;
   findings tagged `[MECHANICAL]` or `[DESIGN]` with file/problem/suggestion.
4. Author must fix every MECHANICAL finding, decide DESIGN findings on the
   merits, and write a response file (`FIXED — ...` / `REJECTED — <grounded
   reason>` per finding) before the hook prepares the next round.
5. Exit is released only by reviewer convergence, the round cap (default 5,
   exits with an honest "unconverged" summary), or explicit cancel.
6. Stalemate — a finding the reviewer raises AND the author rejects for 2
   consecutive rounds. The orchestrator detects it deterministically (a
   file+title fingerprint) and escalates ONCE to the user, then continues the
   loop on everything else. (Phase 2b routes factual stalemates to a blind
   judge and design stalemates to a batched end-of-loop gate; Phase 2a does
   the single user escalation for both.)

## Invariants

- Single-writer: reviewer sandbox is read-only.
- Reviewer-declares: author never writes the convergence marker.
- Deterministic enforcement: hooks block exit; prompts alone are not trusted.
- Fail-open: any hook-internal error approves exit; never trap the user.
- Review artifacts (`reviews/spar-*.md`) are append-only for the author:
  never edited or deleted (except via explicit user cleanup).

## Phase roadmap

Phase 1 (this): core loop. Phase 2: Gate + deadlock judge. Phase 3: sweep +
skip conditions. Phase 4: unattended mode + final report. Phase 5: Codex-side
adapter (git pre-commit enforcement). Phase 6: model economics — reviewer
model/effort config, same-model fallback, tiered writers (judgment never
delegates; edit execution may go to a cheaper tier, verified by the next
round's full re-review; escalates back on fix-induced findings).
