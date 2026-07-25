# Phase 6 — Codex-hosted adapter — Design

**Status:** design, ready for writing-plans. Supersedes the `git pre-commit`
premise recorded in `docs/design-decisions.md` §Phase 6 — see §1.

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

**Decision:** enforcement for the Codex seat is the **Codex Stop hook**, not a git
pre-commit hook. The strong guarantee — *a session cannot end unconverged* — is
preserved in both directions, so the two adapters have identical enforcement
strength. A pre-commit hook is dropped from the design entirely: it is weaker
(`git commit --no-verify` bypasses it), it gates the wrong event, and it is now
unnecessary. `docs/design-decisions.md`, `README.md`, and
`plugins/spar/shared/policy.md` are corrected in the same change as this spec.

## 2. Architecture — one gatekeeper, two hosts

`plugins/spar/hooks/stop-hook.sh` is already host-agnostic: it consumes stdin and
discards it (`HOOK_INPUT=$(cat)` is never read), and every decision comes from
`.claude/spar.local.md` plus the `reviews/` artifacts. Its only host-specific
behavior is which CLI it invokes for the reviewer/judge/matcher/sweep, and that is
already abstracted by the Phase 3 reviewer *family* resolution (`codex` | `claude`).

So the Codex adapter adds **no second gatekeeper**. It adds:

| Piece | What it is |
|---|---|
| `adapters/codex/hooks.json` | Registers the shared `stop-hook.sh` on the `Stop` event, with `CLAUDE_PLUGIN_ROOT` exported so the hook can find its sibling scripts |
| `adapters/codex/skills/spar-fight/SKILL.md` | The author-seat entry point — the Codex equivalent of `/spar:fight`, carrying the same loop protocol text |
| `adapters/codex/install.sh` | Idempotent installer: places the skill and merges the hook registration, never clobbering an existing hooks.json |

Everything else — round machinery, finding registry, blind judge, design gate,
matcher, sweep, durable outcomes, the final report — is reused unchanged.

**Seat mapping.** Author: Codex CLI session. Reviewer / judge / matcher:
`claude -p` read-only + `--safe-mode`, already built and tested in Phase 3 as the
`claude` family. Sweep: fresh `codex exec --sandbox read-only`, preserving the
"different model, no context" axis in this direction. Setting `reviewer: claude`
in the state file is all that selects this.

## 3. Entry point: a Codex skill, not `~/.codex/prompts/`

The design-decisions record named `~/.codex/prompts/` as the entry point. It does
not appear to be a mechanism in 0.144.1: the directory does not exist, and a sweep
of the binary for `.codex/<dir>` discovery paths turns up `.codex/config` and
`.codex/skills` but no prompts directory. What exists is **skills**:
`~/.codex/skills/<name>/SKILL.md`
(three are already installed on this machine), with `SkillMetadata` /
`SkillsListEntry` / `skill_md_contents` in the binary and a `.codex/skills`
project path.

**Decision:** the author entry point is a Codex skill, `spar-fight`. It carries
the same content as `plugins/spar/commands/fight.md` — activation, then the loop
protocol and hard rules. Codex plugins cannot supply it: the `plugin_hooks`
feature is **removed**, so a plugin cannot register hooks, which is why the hook
registration is a separate file rather than a packaged plugin.

## 4. Hook installation: install once, self-disabling

Codex tracks hook trust per source with states `untrusted` / `trusted` /
`modified` and a `currentHash`; a changed `hooks.json` returns to
`modified` and must be re-trusted. Rewriting the file per run would therefore
re-prompt for trust on every single loop — unacceptable.

**Decision:** install the hook registration **once**, and let the hook disable
itself. `stop-hook.sh` already returns `{"decision":"approve"}` immediately when
`.claude/spar.local.md` is absent, so a registered-but-idle hook is a no-op with
no measurable cost. Activation and cancellation therefore touch only the state
file — exactly as on the Claude side — and never `hooks.json`.

`install.sh` must: merge into an existing `hooks.json` rather than overwrite it,
be idempotent (re-running changes nothing and so does not disturb trust), and
refuse to write through a symlink. The first run after install prompts the user to
trust the hook once; the installer says so plainly.

**Scope, to be settled by a one-command check during implementation:** prefer
**user scope** (`~/.codex/hooks.json`) so that adopting sparring never adds files
to the user's repository — mirroring how the Claude plugin lives outside the
project. Project scope (`<repo>/.codex/hooks.json`) is verified to work (the spike
used it) and is the fallback if user scope is unsupported. The installer resolves
`CLAUDE_PLUGIN_ROOT` to an absolute path at install time, so either scope works
without vendoring anything into the project.

## 5. State and artifacts stay where they are

State remains `.claude/spar.local.md`; artifacts remain `reviews/spar-*`.

Renaming to something host-neutral (`.spar/`) would be tidier for a Codex user,
but it is a migration of every path in a 45KB hook plus 19 test suites, for a
cosmetic gain — and it would have to happen on both adapters at once. Out of scope
here; a Codex user is told plainly in the skill text that loop state lives under
`.claude/` for historical reasons and is git-excluded either way.

## 6. Error handling

Unchanged, and that is the point: fail-open is a property of `stop-hook.sh`, so it
holds identically for both hosts. Any internal error records `error-bypass` and
approves; a missing reviewer CLI blocks with an explicit message and records
`error-bypass`; a broken report generator degrades to "no report".

Two host-specific failure modes are new:

- **Hook not trusted.** Codex will not run an untrusted hook, so the loop simply
  never engages — a silent no-enforcement state. The skill's activation step must
  therefore verify the hook is live and refuse to proceed if it is not, rather than
  letting the author believe they are being reviewed when they are not.
- **Hooks disabled by policy.** `allowManagedHooksOnly` exists in Codex's config
  requirements, so a managed environment can forbid user hooks. Same treatment:
  detect and refuse, never pretend.

Both are honesty requirements, not enforcement mechanisms — consistent with the
existing invariant that a broken hook must not trap the user, and with the rule
that the loop never reports unconverged work as done.

## 7. Testing

- **Pure-bash suite `tests/test_codex_adapter.sh`:** `hooks.json` is valid JSON
  registering `Stop` → the shared hook with `CLAUDE_PLUGIN_ROOT` set; `install.sh`
  is idempotent, merges into a pre-existing `hooks.json` without dropping other
  events, and refuses a symlinked target; the skill file exists and carries the
  loop protocol's load-bearing rules (never write `STATUS: CONVERGED`, per-finding
  response format).
- **Reuse:** `tests/test_stop_hook.sh` already covers the gatekeeper for both
  hosts — that is the payoff of sharing it. It needs no Codex-specific additions.
- **Spike note** `docs/superpowers/notes/codex-hooks-spike.md` — already written,
  alongside this spec: the 0.144.1 findings and the exact reproduction, so the
  premise behind §1 is auditable and re-checkable when Codex changes.
- **Manual end-to-end once:** a planted-bug task authored by Codex, reviewed by
  `claude -p`, must go FINDINGS → fix → re-review → CONVERGED, mirroring the
  Phase 1 verification. CI cannot cover this (it would need model credentials), so
  it is a release gate, not an automated test.

## Non-goals

- **A git pre-commit hook.** Dropped, with reasons in §1.
- **Renaming state paths** to be host-neutral (§5).
- **Codex-Codex same-family sparring.** It falls out of the family abstraction for
  free once this lands, but it is not designed or tested here.
- **Shipping the adapter through a Codex plugin.** Impossible today —
  `plugin_hooks` is removed.
- **Changing any Claude-side behavior.** The shared hook is touched only if the
  Codex seat genuinely requires it, and any such change must keep all 19 suites
  green.

## Invariants respected

- **Deterministic enforcement** — the same Stop-hook gatekeeper, with the same
  strength, in both directions.
- **Fail-open** — inherited from the shared hook, not reimplemented.
- **Single-writer / reviewer-declares / blind adjudication** — unchanged; only the
  seat occupants swap.
- **Honest exit** — plus a new obligation: if the hook cannot be trusted or is
  policy-disabled, say so instead of running an unenforced loop.

## Open question for writing-plans

Hook **scope** (user-level `~/.codex/hooks.json` vs project-level
`<repo>/.codex/hooks.json`) — §4. Project scope is proven; user scope is preferred
and needs one check. Everything else is settled.

## Terminal state

Design-complete. The Phase 6 premise is corrected and evidenced, the entry-point
mechanism is identified, and the enforcement decision is verified by spike rather
than assumed. Ready for writing-plans.
