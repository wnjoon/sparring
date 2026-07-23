# Single-Agent Mode (same-family sparring) — Design

**Status:** design, rev. 2 (incorporates the blind cross-verification: Claude + Codex reviewers, adjudicated). Target: **Phase 3**. Awaiting spec review → writing-plans.

## Context & goal

The Claude-hosted `/spar` loop currently **hard-requires the Codex CLI**. All three model-invoking runners — the reviewer, the blind judge, and the semantic matcher — are `codex exec --sandbox read-only` calls (`stop-hook.sh:252`, `:323`, `:396`), and there are **two** codex-missing hard blocks: one in `/spar` setup (`spar.md`) and one that runs on **every Stop** before the phase switch (`stop-hook.sh:462`). That excludes everyone who runs Claude Code without Codex.

This phase adds a **single-agent mode**: the same loop with a **Claude** reviewer/judge/matcher, so `/spar` works with Claude alone. Cross-model (Claude author ↔ Codex reviewer) stays the **recommended default** — same-family loses cross-vendor blind-spot diversity — but the enforced loop, fresh blind re-review, convergence, judge, gate + ledger, and matcher all still apply. Value = (1) enforced review + (2) fresh blind independent review + (3) cross-vendor diversity; same-family keeps 1 and 2, drops 3.

## Non-goals (this phase)

- **Codex-Codex** same-family — rides with the Codex-hosted adapter (Phase 6), reusing this phase's family abstraction.
- **Per-round lens rotation** to compensate for reduced diversity — future, empirical (dogfooding decides if needed).
- **Persistent reviewer config / `config.toml`** — Phase 7. This phase uses auto-detection + a per-invocation override only.
- Changing the cross-model default behavior, or the reviewer output **protocol** (`STATUS:` / `RULING:` / `SAME` first-line contract stays identical).

## Design

### 1. Reviewer family as a single parameter

One notion — the **reviewer family**: `codex` | `claude` — resolved once at `/spar` setup and written to the state file's `reviewer:` field (present today but unused by the hook). Every model-invoking runner is generated from that family. A single runner-emitter — `emit_runner(family, prompt_file, output_file)` — writes either a codex or a claude command; the reviewer, judge, and matcher generators all call it.

The three prompt templates are **reused with a small family-neutral adaptation** (not byte-for-byte unchanged — corrected from rev. 1):
- The word "sandbox" (`reviewer.md:2`, `judge.md`, `matcher.md`) is a codex term; make it family-neutral ("read-only — you must not modify anything").
- The reviewer prompt currently tells the reviewer to **run `git diff` itself**. The Claude reviewer has no shell (§3), so for the claude family the change surface is **provided by the hook** instead. This is a family-conditional line in the prompt, not a protocol change.

### 2. Activation — auto-detect + explicit override

At `/spar` setup, resolve the family:

1. **Explicit override:** a leading `--reviewer <codex|claude>` token on the `/spar` arguments, terminated by `--` before the task text (e.g. `/spar --reviewer claude -- <task>`). Parsed as a reserved leading token only; the `--` separator removes ambiguity with tasks that themselves begin with `--…`. `$ARGUMENTS` is captured into a quoted bash variable **before** any expansion (the current setup interpolates `$ARGUMENTS` inside an unquoted heredoc — that must change so `$`/backticks in the task text are not expanded).
2. **Auto-detect** (no override): `codex` on `PATH` → `codex`; else `claude`.
3. **Existence check:** verify the resolved family's CLI is actually on `PATH` — for `codex` AND for `claude` (a Claude Code session does not guarantee the `claude` binary is on `PATH`). Resolved CLI absent → clear setup error, never a silent swap. Neither CLI present → error.
4. Write the resolved family to `reviewer:` in the state file.

Single-agent users need **zero config** — auto-detect picks `claude`. The override is only for "have codex, want same-model".

### 3. Read-only, blind Claude reviewer — the crux (rewritten per cross-verification)

The rev. 1 mechanism (`claude -p --allowedTools <set>`) was wrong on two counts, both confirmed against the installed Claude Code:

- `--allowedTools` is **additive** — it auto-approves the listed tools on top of existing settings; it does **not** remove `Edit`/`Write`/`Bash`. Restriction requires `--tools` (sets the available built-in set) and/or `--disallowedTools`.
- A default `claude -p` **loads customizations** — project `CLAUDE.md`, memory, plugins, hooks, MCP. That means the reviewer would load **the sparring plugin itself, including its Stop hook (recursion)** and could inherit debate context via shared memory. `--safe-mode` disables all customizations.

**Revised mechanism** (structural, not trust-based):

- **Read-only by toolset restriction:** `--tools "Read Grep Glob"` — read-only built-ins, with **no `Bash`, `Edit`, or `Write`**. With no write-capable tool available, the reviewer cannot modify the repo — single-writer holds *by construction*, not by an allowlist. (Belt-and-suspenders: `--disallowedTools "Edit Write"`.)
- **No shell → the hook provides the change surface:** because the reviewer has no `Bash`, it cannot run `git diff`/`git status`. The hook pre-computes the diff against the frozen baseline plus the untracked-file listing/contents and hands them to the reviewer (inlined in the prompt or a read-only input file it `Read`s). The reviewer still uses `Read`/`Grep`/`Glob` to open cited files for context.
- **Isolation via `--safe-mode`:** disables CLAUDE.md/memory/plugins/hooks/MCP/custom commands. This is what makes **blind** hold for a same-repo Claude reviewer (preventing debate-leak via shared memory) and prevents **recursion** into spar's own Stop hook — NOT "a fresh process is blind by construction" (rev. 1 was too weak).
- **I/O:** prompt in; the model's final message captured to the review/ruling/matcher output file (e.g. `claude -p … > out`, since `-p` prints the response to stdout). First line follows the identical `STATUS:` / `RULING:` / `SAME` protocol, so the hook's parsing is unchanged.
- Enforcement is toolset/permission-level (vs codex's OS sandbox). The single-writer invariant holds because no write tool exists in the reviewer and customizations are off.

**Top implementation risk — verify FIRST, E2E, before writing any runner:** the exact `claude -p` invocation that (a) runs genuinely read-only with no write path, (b) does not recurse into spar's hook (safe-mode confirmed), (c) does not hang in `-p` when a tool call is denied, and (d) reliably writes only the final message to the output file. If `--tools`/`--safe-mode` behave differently than assumed on the installed CLI, this mechanism is revisited before any runner code. (The blind Codex judge / matcher for single-agent are the same `claude -p` mechanism, applied to those prompts.)

### 4. Hook changes & invariants (corrected — the hook DOES change)

Rev. 1 wrongly claimed "the hook logic does not change." It does, in three bounded ways:

- **Read the `reviewer:` field** (the hook does not read it today) and validate it: only `codex`|`claude` accepted; missing/garbage → `log + cleanup + approve` (fail-open, matching how `review_id`/`round` are already validated at `stop-hook.sh:58-64`).
- **Family-ize the unconditional codex check** at `stop-hook.sh:462` (and the `/spar` setup check): `command -v codex` becomes `command -v <resolved CLI>`, so a codex-less single-agent loop is not killed on every Stop.
- **Branch the three runner emitters** (`prepare_round`, `prepare_judge`, `build_matcher`) on the resolved family via `emit_runner`.

Invariants are **preserved by this new code**, not by leaving the hook untouched:
- **Single-writer** — the read-only toolset (§3) leaves the reviewer no write tool.
- **Reviewer-declares / conveyance boundary** — unchanged; the author still never writes the marker; the prompts still exclude the debate; `--safe-mode` blocks memory/instruction leakage.
- **Deterministic enforcement / fail-open** — the new `reviewer:` validation fails open; no new sticky block.
- **Blind adjudication** — held by `--safe-mode` isolation (§3), not by process freshness alone.

### 5. Honest coverage notice

When the resolved family equals the author's family (Claude author + Claude reviewer), surface at activation (and in the final report once it exists):

> same-model review — reduced cross-vendor blind-spot coverage. Install the Codex CLI for cross-model review.

### 6. SoT & doc updates in scope

`plugins/spar/shared/policy.md` currently declares the reviewer as the "opposite model" and fixes judge/matcher to `codex exec` — the SoT both adapters "exactly" implement. This phase must update policy.md's Roles/Protocol to the family-based model (reviewer = resolved family, read-only), or it becomes a documented policy violation. (Its phase-roadmap trailer was already updated when Phase 3 was promoted.)

### 7. Failure / edge handling

- Override to an absent CLI → setup error (no silent swap).
- Neither `codex` nor `claude` on PATH → error.
- Corrupt/unknown `reviewer:` value → fail-open (log + cleanup + approve).
- Within one loop the judge and matcher inherit the resolved family — a single-agent loop uses `claude` for all three; a cross-model loop uses `codex` for all three. **No mixing within a loop** this phase.

## Testing

The activation logic lives in `/spar` setup, which is **inline fenced bash inside `spar.md`** — the current harness (`tests/test_stop_hook.sh`) only executes `stop-hook.sh` with hand-written state fixtures, so it cannot reach activation today. This phase **extracts the setup resolver into a callable shell script** (`spar.md` calls it) so it is unit-testable.

Pure-bash tests:
- **Activation resolver** (extracted script): codex present → `reviewer: codex`; codex absent → `reviewer: claude`; `--reviewer claude` override with codex present → `claude`; `--reviewer codex` with codex absent → error; neither present → error; task text after `--` preserved verbatim (incl. leading `--…`).
- **Runner generation per family:** `reviewer: claude` → the three generated runners invoke `claude -p` with the read-only `--tools`/`--safe-mode` set (no `codex`); `reviewer: codex` → unchanged from today.
- **`reviewer:` validation:** garbage value → hook fails open (approve), no runner emitted.
- **Coverage notice** present when same-family.

The **actual read-only / no-recursion / no-hang / output-capture behavior of `claude -p`** is validated by an **E2E dogfood** (as done for codex), not by unit tests — and is the §3 top risk to clear before building runners.

## Roadmap position

New **Phase 3** (next). Renumbered: sweep/skip/harvest → 4, unattended/report → 5, Codex-hosted adapter → 6, model economics → 7. Same-model promoted from a CLI-missing fallback to a first-class mode. Codex-Codex same-family arrives with the Codex-hosted adapter (Phase 6), reusing this family abstraction and this phase's read-only `claude -p` reviewer.
