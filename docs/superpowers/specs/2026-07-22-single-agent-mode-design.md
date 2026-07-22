# Single-Agent Mode (same-family sparring) — Design

**Status:** design (approved direction; awaiting spec review). Target: **Phase 3**.

## Context & goal

The Claude-hosted `/spar` loop currently **hard-requires the Codex CLI**. All three model-invoking runners — the reviewer, the blind judge, and the semantic matcher — are `codex exec --sandbox read-only` calls, and the hook blocks with "install Codex" when it is absent. That excludes everyone who runs Claude Code without Codex.

This phase adds a **single-agent mode**: the same loop with a **Claude** reviewer/judge/matcher, so `/spar` works with Claude alone. Cross-model (Claude author ↔ Codex reviewer) stays the **recommended default** — same-family review loses cross-vendor blind-spot diversity — but everything else the loop provides still applies: enforced review, fresh blind re-review, convergence, the judge, the gate + ledger, and the matcher. Value breaks into three layers; same-family keeps two of them:

1. **Enforced review** (Stop hook forces the loop; author can't self-declare done) — kept.
2. **Fresh blind independent review** (a stateless reviewer re-derives findings against the frozen baseline) — kept; a fresh Claude instance has a different blind spot than the author's session.
3. **Cross-vendor diversity** (different-vendor blind spots) — this is what same-family drops.

## Non-goals (this phase)

- **Codex-Codex** same-family — rides with the Codex-hosted adapter (a later phase), reusing this phase's family abstraction.
- **Per-round lens rotation** (correctness / security / requirement-fit) to compensate for reduced diversity — documented future enhancement; not required for v1. Whether same-family needs it is an empirical (dogfooding) question.
- **Persistent reviewer config / `config.toml`** — later (model-economics phase). This phase uses auto-detection + a per-invocation override only.
- Any change to the cross-model default behavior or to the prompts' review protocol.

## Design

### 1. Reviewer family as a single parameter

Introduce one notion — the **reviewer family**: `codex` | `claude`. It is resolved once at `/spar` setup and written to the state file's `reviewer:` field (which exists today but is unused by the hook). Every model-invoking runner is generated from that family instead of hardcoding `codex exec`.

A single runner-emitter — `emit_runner(family, prompt_file, output_file)` — writes either a codex or a claude command. The reviewer, judge, and matcher runner generators all call it. The three prompt templates (`reviewer.md`, `judge.md`, `matcher.md`) are model-agnostic and reused **unchanged** across families.

### 2. Activation — auto-detect + explicit override

At `/spar` setup, resolve the family in this order:

1. **Explicit override:** a leading `--reviewer <codex|claude>` token on the `/spar` arguments. Parsed only as a leading token and stripped from the task text (so it can't collide with task content).
2. **Auto-detect:** `codex` on `PATH` → `codex`; otherwise → `claude`.
3. Write the resolved family to `reviewer:` in the state file.

The current codex-missing hard block changes: instead of "install Codex", a missing codex simply resolves the family to `claude`. If the *resolved* family's CLI is absent (e.g. `--reviewer codex` but no codex on PATH), error clearly at setup — never silently swap an explicit choice. If neither CLI is available, error (the loop cannot review).

Single-agent users need **zero configuration** — they run `/spar` and auto-detect picks `claude`. The override exists only for "have codex, deliberately want same-model".

### 3. Read-only, blind Claude reviewer (the crux)

The Claude reviewer/judge/matcher run headless and read-only:

```
claude -p --allowedTools "<read-only set>" [--append-system-prompt "<read-only reminder>"]  <prompt>  →  <output file>
```

- **Read-only enforcement:** the allowlist permits only inspection — `Read`, `Grep`, `Glob`, and read-only git/inspection shell (`Bash(git diff:*)`, `Bash(git status:*)`, `Bash(git log:*)`, `Bash(cat:*)`, `Bash(ls:*)`) — and excludes `Edit`, `Write`, and general `Bash`. In `-p` (print) mode a non-allowlisted tool call is denied without an interactive prompt, so the reviewer **cannot modify the repo**. This preserves Invariant 1 (single-writer).
- **Difference from codex:** codex uses an OS-level `--sandbox read-only`; the Claude reviewer uses **permission-level** gating (Claude Code enforcing its own tool allowlist). The invariant that matters — the reviewer cannot write — holds under both. The spec accepts permission-level enforcement here.
- **I/O contract:** the runner feeds the generated prompt in and captures the model's final message to the review/ruling/matcher output file. The output's first line follows the exact same protocol as codex (`STATUS: …` / `RULING: …` / `SAME …`), so the hook's parsing is unchanged.

**Top implementation risk (verify first in the plan):** the exact `claude -p` invocation that (a) is genuinely read-only under the installed CLI, and (b) reliably writes only the final message to the output file (prompt via stdin vs arg; stdout redirect vs an output flag). Confirm against the installed `claude` before building the runner.

### 4. Blindness & invariants — unchanged

- **Reviewer-declares / conveyance boundary / blind judge / blind matcher** all hold regardless of family; the prompts already exclude the debate. A fresh `claude -p` has no session history, so it is blind by construction — the same property a fresh `codex exec` gives.
- **Single-writer** is preserved by the read-only allowlist (§3).
- **Deterministic enforcement / fail-open** unchanged — the hook logic around the runners does not change; only what command the runner emits does.

### 5. Honest coverage notice

When the resolved reviewer family equals the author's family (Claude author + Claude reviewer), the loop is same-family. Surface a one-line notice — at activation and in the final report once that exists:

> same-model review — reduced cross-vendor blind-spot coverage. Install the Codex CLI for cross-model review.

No behavior change; honesty consistent with the project's no-false-completion ethos.

### 6. Failure / edge handling

- Explicit override to a family whose CLI is absent → clear setup error (no silent swap).
- Neither `codex` nor `claude` available → error.
- Within one loop, the judge and matcher inherit the resolved family — a single-agent loop uses `claude` for all three; a cross-model loop uses `codex` for all three. **No mixing within a loop** in this phase.

## Testing

Pure-bash hook tests (existing harness):

- **Runner generation per family:** with `reviewer: claude`, the generated reviewer/judge/matcher runners invoke `claude -p` with the read-only allowlist (not `codex`); with `reviewer: codex`, output is unchanged from today.
- **Activation:** codex present → `reviewer: codex`; codex absent → `reviewer: claude`; `--reviewer claude` override with codex present → `reviewer: claude`; `--reviewer codex` with codex absent → setup error.
- **Family propagation:** all three runners honor the resolved family.
- **Coverage notice** appears when the loop is same-family.

The actual read-only/blind behavior of the Claude reviewer is validated by an **E2E dogfood** (as done for the codex reviewer), not by the unit tests.

## Roadmap position

New **Phase 3** (next to build). Renumbering: final sweep + skip + intent harvest → Phase 4; unattended + final report → Phase 5; Codex-hosted adapter → Phase 6; model economics → Phase 7. The "same-model fallback" bullet moves out of model-economics into this phase — **promoted from a CLI-missing fallback to a first-class single-agent mode**. Codex-Codex same-family arrives with the Codex-hosted adapter (Phase 6), reusing this phase's family abstraction.
