# Phase 6 — Codex-hosted adapter — Design

**Status:** design, ready for writing-plans. Supersedes the `git pre-commit`
premise recorded in `docs/design-decisions.md` §Phase 6 — see §1. Revised
2026-07-25 after a blind cross-model review found a high-severity error in the
first draft — see §9.

## Context & goal

Today sparring is Claude-hosted: a Claude Code session is the author, an
independent reviewer (`codex exec` by default) declares convergence, and a **Stop
hook** makes the loop non-optional — the session cannot end until the reviewer
converges. Phase 6 mirrors the seats: a **Codex CLI session authors**, and a
read-only **`claude -p` reviewer** declares convergence.

Goal: the same enforced loop with the seats swapped, sharing one policy and one
gatekeeper implementation — not a second, weaker copy.

## 1. The premise changed: Codex has a blocking Stop hook

`docs/design-decisions.md` §Phase 6 assumed Codex had no session-exit hook, so
enforcement had to move to a **git pre-commit hook**, explicitly accepting a
"weaker guarantee" ("you cannot commit unconverged work", not "you cannot stop").

**That is no longer true.** Verified against `codex-cli 0.144.1` on 2026-07-25:

- Hooks are a **stable, default-on** feature (`codex features list` → `hooks  stable  true`).
- The event set includes **`stop`**, alongside `preToolUse`, `permissionRequest`,
  `postToolUse`, `preCompact`, `postCompact`, `sessionStart`, `userPromptSubmit`,
  `subagentStart`, `subagentStop`.
- Config shape is the same as Claude Code's:
  `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"..."}]}]}}`.
- The hook payload on stdin is near-identical: `session_id`, `transcript_path`,
  `cwd`, `hook_event_name`, `stop_hook_active`, plus Codex extras `turn_id`,
  `model`, `permission_mode`, `last_assistant_message`.
- **A Stop hook returning `{"decision":"block","reason":"…"}` forces another
  turn.** Proven by spike: a hook that blocked its first invocation and allowed
  the second made Codex continue and carry out the instruction embedded in
  `reason` (it created the requested file), then stop on the second pass. The
  binary also carries the guard string `hook returned decision:block without a
  non-empty reason`, matching Claude's contract.
- **Consecutive blocks are honored, so a real multi-round loop is possible.** A
  second spike blocked five times in a row with a different instruction each time:
  the hook fired six times and all five instructions were carried out in order.
  `stop_hook_active` flips to `true` after the first block and stays true — Codex
  reports the condition but does not cap on it, delegating the loop guard to the
  hook. Sparring's `max_rounds` remains the circuit breaker, exactly as on the
  Claude side. This was the load-bearing risk: a run fires the Stop hook 15+ times,
  mostly as consecutive blocks, so a cap at 2-3 would have killed the design.

**Measured vs inferred.** Both spikes ran with `--dangerously-bypass-hook-trust`,
so the blocking contract above is measured but the *trust* path is not: "the first
run prompts once to trust the hook" and "Codex refuses to run an untrusted hook"
rest on binary strings and the TUI copy quoted in §6, not on execution. The
implementation must exercise the trust path once and record the result.

**Decision:** enforcement for the Codex seat is the **Codex Stop hook**, not a git
pre-commit hook. The strong guarantee — *a session cannot end unconverged* — is
preserved in both directions, so the two adapters have identical enforcement
strength. A pre-commit hook is dropped from the design entirely: it is weaker
(`git commit --no-verify` bypasses it), it gates the wrong event, and it is now
unnecessary. `docs/design-decisions.md`, `README.md`, and
`plugins/spar/shared/policy.md` are corrected in the same change as this spec.

## 2. Architecture — one gatekeeper, two hosts

The Claude adapter registers **two** hooks (`plugins/spar/hooks/hooks.json`):

| Event | Script | Role |
|---|---|---|
| `Stop` | `stop-fight.sh` | Plan dispatcher — runs the round engine in-process, then advances a `/spar:ready` plan: per-task commit (`stop-fight.sh:61`), launch the next task (`:76-86`), flip checkboxes |
| `SessionStart` | `session-start.sh` | Announces design decisions left pending by unattended runs (`reviews/spar-pending.md`) |

`stop-hook.sh` is the **inner engine**, invoked by the dispatcher — not the
registered entry point. Registering the engine directly would silently drop plan
mode: a Codex-authored `/spar:ready` plan would never advance past its first task.

The engine is genuinely host-agnostic — it consumes stdin and discards it
(`HOOK_INPUT=$(cat)` at `stop-hook.sh:130` is never read), and every decision
comes from `.claude/spar.local.md` plus the `reviews/` artifacts.

So the Codex adapter adds **no second gatekeeper**. It registers the same two
scripts on the same two events, and adds:

| Piece | What it is |
|---|---|
| `adapters/codex/hooks.json` | Registers `stop-fight.sh` on `Stop` and `session-start.sh` on `SessionStart`, both with an absolute path |
| `adapters/codex/skills/spar-fight/SKILL.md` | Author-seat entry point — the Codex equivalent of `/spar:fight`, carrying the same loop protocol text |
| `adapters/codex/skills/spar-ready/SKILL.md`, `spar-cancel`, `spar-report` | The rest of the command surface, mirroring `plugins/spar/commands/*.md` |
| `adapters/codex/install.sh` | Idempotent installer: places the skills and merges the hook registration, never clobbering an existing `hooks.json` |

### 2.1 Three shared-hook changes the Codex seat requires

The first draft claimed the engine needed no changes. That was wrong. Items (a)-(c)
are each small, keep Claude-side behavior identical, and are covered by new tests
(§7); (d) is recorded as a retraction so the mistake is not re-made.

**(a) The sweep is hardcoded to `claude`, not family-resolved.**
`emit_sweep_runner` calls `claude -p --safe-mode` (`stop-hook.sh:495`) and the
dispatch guard checks `command -v claude` (`:885`). Only reviewer/judge/matcher
resolve by family. The sweep is meant to be a *fresh author-family* instance
(`policy.md` §Protocol 8), so with the seats swapped it must be
`codex exec --sandbox read-only`. **Decision:** add an `author: claude|codex`
field to the state file, defaulting to `claude` when absent, and resolve the sweep
runner and its guard from it. A missing field therefore reproduces today's
behavior exactly.

**(b) `CLAUDE_PLUGIN_ROOT` is load-bearing and fails open silently.**
With the variable unset, the engine cannot find its prompt templates and takes
`finish_approve error-bypass` (`:549-550`); the outcome writer resolves to the
same broken root, so **not even a durable outcome is written** — the author sees
a session that simply ended. That is a third silent no-enforcement mode, and it is
worse than the two in §6 because nothing records it. **Decision:** make the engine
**self-locating** — derive the plugin root from `BASH_SOURCE` (the script lives at
`<root>/hooks/stop-hook.sh`), and use `CLAUDE_PLUGIN_ROOT` only as an override
when set. This removes the failure class for both hosts rather than papering over
it in the Codex installer. The installer still exports an absolute
`CLAUDE_PLUGIN_ROOT`, as belt and braces.

**(c) One Codex session must not join another host's run.**
The engine participates whenever a state file exists (`:132`) and mutates it
(`:830-831`). With a **user-scope** registration the hook runs in *every* Codex
session, so opening an unrelated Codex session in a repo with an active
Claude-side loop would pull it into that run and advance the state machine.
**Decision:** the state file records the owning host and session
(`author`, plus an opaque `owner_session` captured at activation). The engine
approves immediately when the current session is not the owner. On the Claude
side the field is absent → no behavior change.

**(d) Risky-path coverage for `.codex` — already sufficient, no change needed.**
The cross-review reported that `spar-classify-change.sh:66` misses
`.codex/hooks.json`, and this spec's first revision accepted it. **That was wrong,
and so was the adjudication that confirmed it** — both re-implemented the `case`
without the slash-wrapping the script applies (`spar-classify-change.sh:52`:
`lower="/$path/"`), which changes what the patterns match. Measured with the real
classifier: a change touching `.codex/hooks.json` reports
`touched_risk: true, touched_reasons: hooks-enforcement` via the existing
`*/hooks.json/*` pattern, which is correctly written for the wrapped form, not
malformed. The enforcement registration is therefore already protected from the
safe-skip path.

The one genuine gap is `.codex/hooks/*` — a *directory* of hook scripts is not
matched — but this design puts no scripts there: only `hooks.json` lands in
`.codex/`, and the scripts stay in the plugin directory. Optional hardening at
most; out of scope.

### 2.2 Seat mapping

Author: Codex CLI session (`author: codex`). Reviewer / judge / matcher:
`claude -p` read-only + `--safe-mode`, already built and tested in Phase 3 as the
`claude` family, selected by `reviewer: claude`. Sweep: fresh
`codex exec --sandbox read-only`, selected by `author: codex` per §2.1(a).

One consequence to fix while there: with `reviewer=claude` the engine appends
"same-model review … Install the Codex CLI for cross-model review"
(`stop-hook.sh:834-835`). In the Codex seat that configuration *is* cross-model,
so the notice must key off `author` too, not `reviewer` alone.

## 3. Entry point: a Codex skill, not `~/.codex/prompts/`

The design-decisions record named `~/.codex/prompts/` as the entry point. It does
not appear to be a mechanism in 0.144.1: the directory does not exist, and a sweep
of the binary for `.codex/<dir>` discovery paths turns up `.codex/config` and
`.codex/skills` but no prompts directory. What exists is **skills**:
`~/.codex/skills/<name>/SKILL.md` (three are already installed on this machine),
with `SkillMetadata` / `SkillsListEntry` / `skill_md_contents` in the binary and a
`.codex/skills` project path.

**Decision:** the author entry point is a Codex skill, `spar-fight`, carrying the
same content as `plugins/spar/commands/fight.md`. Codex plugins cannot supply the
hooks: the `plugin_hooks` feature is **removed**, which is why registration is a
separate file rather than a packaged plugin.

## 4. Hook installation: install once, self-disabling

Codex tracks hook trust per source with states `untrusted` / `trusted` /
`modified` and a `currentHash`; a changed `hooks.json` returns to `modified` and
must be re-trusted. Rewriting the file per run would therefore re-prompt for trust
on every single loop — unacceptable.

**Decision:** install the hook registration **once**, and let the hook disable
itself. Verified: with no state file the engine returns `{"decision":"approve"}`
with zero filesystem side effects — it does not even create `.claude/`, because
`log()` is not reached before the guard at `:130-132`. Activation and cancellation
touch only the state file — exactly as on the Claude side — and never
`hooks.json`; confirmed by reading `fight.md:86-107` and `cancel.md:8-21`, and by
the absence of any runtime writer of `hooks.json` in the repository.

`install.sh` must: merge into an existing `hooks.json` rather than overwrite it,
be idempotent (re-running changes nothing and so does not disturb trust), and
refuse to write through a symlink. The first run after install prompts the user to
trust the hook once; the installer says so plainly.

**Scope — user vs project, unresolved and contradictory.** User scope
(`~/.codex/hooks.json`) is preferred: adopting sparring then adds nothing to the
user's repository, mirroring how the Claude plugin lives outside the project. The
evidence conflicts and the implementation must settle it:

- This spec's spike fired a **project-scope** `.codex/hooks.json` successfully.
- The cross-review reproduced project scope three ways (absolute, shell-form, and
  relative commands; with and without `trust_level="trusted"`) and it **never
  fired**, while a user-scope hook fired in the same run. That environment had an
  Orca-managed `CODEX_HOME` with a pre-existing user-scope `hooks.json`, so the
  cause was not isolated: unsupported project scope, user-scope precedence rather
  than merge, or a managed-home constraint.

Note that user scope makes §2.1(c) mandatory, not optional.

**Working directory.** Every state path in the engine is cwd-relative
(`stop-hook.sh:7-49`), so the host must run hooks with the repository root as cwd.
The spike's relative command (`./.codex/stop-hook.sh`) resolved, which implies it,
but this was not measured directly. Verify during implementation; if Codex does
not guarantee it, the fallback is to read `cwd` from the payload — a contained
change, since the engine currently discards stdin.

## 5. State and artifacts stay where they are

State remains `.claude/spar.local.md`; artifacts remain `reviews/spar-*`.

Renaming to something host-neutral (`.spar/`) is tidier for a Codex user but is
not a Phase 6 prerequisite, and both reviewers agreed. Corrected cost, measured:
`.claude/spar` appears **320 times across 15 files** in `plugins/` + `tests/`, of
which **6 of the 19 test suites** (not 19, as the first draft claimed) touch it.
The rename is also not mechanical — `.claude/rules`
(`spar-harvest-intent.sh:123,140`), `.claude/hooks/`
(`spar-classify-change.sh:66`) and the `.claude/` skip in `spar-report.sh:327`
refer to **Claude-owned inputs that must not be renamed**, and git-exclude
patterns in `fight.md:80`, `ready.md:46`, `stop-fight.sh:60` and
`stop-hook.sh:485` are entangled with them. A blanket substitution would break
intent harvesting and the sweep snapshot's exclusions.

**No correctness problem was found**, which is a stronger basis than the first
draft's "cosmetic" claim: Codex's only reader of `.claude/` is the
`external_agent_config` importer, whose feature flag is `external_migration =
removed` in 0.144.1, and whose file list (`settings.json`, `CLAUDE.md`,
`hooks.json`, commands/subagents/skills) never includes `spar*`. If that importer
ever returns, the risk is not state pollution but the Claude spar hook being
imported into Codex and registered twice — which a rename would not prevent
anyway, so it is tracked here rather than used as an argument about paths.

## 6. Error handling

Fail-open is a property of the shared engine, so it holds identically for both
hosts: any internal error records `error-bypass` and approves; a missing reviewer
CLI blocks with an explicit message; a broken report generator degrades to "no
report". §2.1(b) closes the one case where fail-open was also *silent*.

Two host-specific failure modes are new, and both are honesty requirements rather
than enforcement mechanisms:

- **Hook not trusted.** Codex will not run an untrusted hook, so the loop simply
  never engages — silent no-enforcement.
- **Hooks disabled by policy.** `allowManagedHooksOnly` exists in Codex's config
  requirements, so a managed environment can forbid user hooks.

**How liveness is actually verified.** The first draft required activation to
"verify the hook is live", which is **not implementable as a static check** — and
this matters, because an implementer would otherwise write a `trustStatus` check
that proves nothing. Two independent findings established it: no CLI surface
reports hook state (`codex doctor` says nothing about hooks; there is no `codex
hooks` subcommand; the only query path is the app-server `hooks/list` method), and
trust is a **per-session choice** — the TUI offers `Continue without trusting
(hooks won't run)`, so a file whose `trustStatus` is `trusted` still proves
nothing about the current session.

**Decision:** liveness is proven by *observing the hook fire*, not by inspecting
configuration. The `SessionStart` registration (§2) writes a marker keyed by the
payload's `session_id`; the skill's activation step refuses to start a loop when
no marker exists for the current session. This reuses the hook the adapter already
needs for pending-decision surfacing, so it costs one extra write.

Residual, to be settled in implementation: whether `SessionStart` fires before the
skill's first action. If it does not, activation must instead treat the first Stop
as the liveness proof and say plainly, up front, that enforcement is unconfirmed
until then — never claiming coverage it has not observed.

## 7. Testing

- **New pure-bash suite `tests/test_codex_adapter.sh`:** `hooks.json` is valid JSON
  registering `Stop` → **`stop-fight.sh`** and `SessionStart` → `session-start.sh`
  with absolute paths; `install.sh` is idempotent, merges into a pre-existing
  `hooks.json` without dropping other events, and refuses a symlinked target; the
  skill files exist and carry the loop protocol's load-bearing rules (never write
  `STATUS: CONVERGED`, per-finding response format).
- **`tests/test_stop_hook.sh` gains cases** — the first draft's "needs no
  Codex-specific additions" is retracted, since §2.1 changes the engine:
  author-family sweep selection (`author: codex` → codex runner; absent → claude,
  unchanged); self-location when `CLAUDE_PLUGIN_ROOT` is unset (must not silently
  approve without an outcome); and owner-session mismatch → immediate approve.
- **Spike note** `docs/superpowers/notes/codex-hooks-spike.md` — written alongside
  this spec, with the reproduction, so §1 stays auditable when Codex changes.
- **Manual end-to-end once:** a planted-bug task authored by Codex, reviewed by
  `claude -p`, must go FINDINGS → fix → re-review → CONVERGED, mirroring the
  Phase 1 verification. This run is also where the trust path (§1), the hook scope
  (§4), the cwd guarantee (§4), and `systemMessage` handling get measured. CI
  cannot cover it (model credentials), so it is a release gate.

## 8. Non-goals

- **A git pre-commit hook.** Dropped, with reasons in §1.
- **Renaming state paths** to be host-neutral (§5).
- **Codex-Codex same-family sparring.** Falls out of the family abstraction once
  `author` exists, but is not designed or tested here.
- **Shipping the adapter through a Codex plugin.** Impossible today —
  `plugin_hooks` is removed.
- **Broad Claude-side change.** The three engine changes in §2.1 are the entire
  permitted surface, each defaults to today's behavior, and all 19 suites must stay
  green.

## Invariants respected

- **Deterministic enforcement** — the same two hooks, same strength, both hosts.
- **Fail-open** — inherited from the shared engine; §2.1(b) makes the one silent
  case loud without making it trapping.
- **Single-writer / reviewer-declares / blind adjudication** — unchanged; only the
  seat occupants swap.
- **Honest exit** — extended: if the hook is untrusted or policy-disabled, say so
  instead of running an unenforced loop (§6), and never claim enforcement that has
  not been observed.

## 9. Settled by blind cross-verification (2026-07-25)

The first draft was reviewed independently by two agents that could not see each
other's work, each given the same brief, the code, and the invariants. Both
returned **conditional agreement on §2 and §4 and full agreement on §5**, and both
independently found the same high-severity error: the draft registered
`stop-hook.sh` rather than `stop-fight.sh`, which would have dropped plan mode from
the Codex seat. Both also found the hardcoded sweep and the unimplementable
liveness check. Single-source findings — session hijacking (§2.1c), the silent
`CLAUDE_PLUGIN_ROOT` failure (§2.1b), and the missing `SessionStart` port — were
adjudicated against the code before being accepted. One single-source finding, the
risky-path gap, survived a first adjudication and was then **rejected** on
re-measurement with the real classifier (§2.1d) — the adjudication had repeated the
reviewer's own modelling error.
The corrected reference counts in §5 came from the same pass.

## Open questions for writing-plans

1. **Hook scope** — user vs project (§4). Evidence conflicts; settle by
   measurement, prefer user scope.
2. **`SessionStart` ordering** relative to the skill's first action (§6), which
   decides whether the liveness marker or the first-Stop fallback is used.

Both are measurements, not judgments, and both are covered by the manual
end-to-end run in §7.

## Terminal state

Design-complete and cross-verified. The premise is corrected and evidenced, the
entry point identified, the enforcement decision measured rather than assumed, and
the four engine changes the Codex seat actually requires are enumerated with their
default-safe behavior. Ready for writing-plans.
