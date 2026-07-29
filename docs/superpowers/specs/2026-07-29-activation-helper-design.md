# Shared plan-activation helper — design

## The problem

`/spar:fight` and the Codex `spar-fight` skill each carry their own copy of the
plan-activation sequence: the phase checks, the plan-file check, the plan-review
gate, the phase flip, the task-1 extraction and the launch. The two copies are
~35 lines each and differ in five small ways — command names in messages, the
Codex seat's `author`/`owner_session` stamps, and the plugin-root variable.

Two consequences, both already observed:

- **They drift.** The plan-review gate was added to both by hand. In `fight.md`
  it sits immediately before the phase flip; in the Codex skill it sits before
  the author stamps, because a refusal there must not leave the state modified.
  That difference was a deliberate improvement in one seat that never reached the
  other — the Claude seat has no stamps, so it is invisible there, but the next
  such change may not be.
- **They cannot be tested through one path.** `tests/test_stop_hook.sh` extracts
  and executes `fight.md`'s block; `tests/test_codex_adapter.sh` only greps the
  skill. A finding in the previous phase (F4-2) named this and its suggested
  remedy — a shared executable helper — was deferred to here.

## What is built

`plugins/spar/commands/spar-plan-activate.sh`, invoked by both documents.

```
spar-plan-activate.sh <state-file> <plan-review-flag> <seat> [session-id]
```

- `<state-file>` — the plan state, normally `.claude/spar-plan.local.md`.
- `<plan-review-flag>` — `false` when `--no-plan-review` was given, else `true`.
  Passed straight through from the resolver's fourth field.
- `<seat>` — `claude` or `codex`. Selects the command names used in messages
  (`/spar:fight` vs `spar-fight`, `/spar:cancel` vs `spar-cancel`) and whether the
  author/owner stamps are written.
- `[session-id]` — required for the `codex` seat, recorded as `owner_session`.
  Ignored for `claude`.

Exit 0 having printed the "Fight started" line; exit 1 with a message on stderr
naming what is wrong. Any refusal leaves the state exactly as it found it.

**The helper resolves its own siblings.** `spar-plan-lib.sh`,
`spar-plan-review-check.sh` and `spar-fight-launch.sh` are located from
`BASH_SOURCE`, not from a caller-supplied root. That removes the
`CLAUDE_PLUGIN_ROOT` / `SPAR_ROOT` difference from the shared code entirely — the
one remaining reason the two copies had to differ in a place that matters.

### Order of operations

Unchanged from what the two documents do today, with the Codex seat's ordering
adopted as the shared one:

1. Phase must be `planned` — `running` gets its own message.
2. No active loop state (`.claude/spar.local.md`).
3. The plan file named by `plan_path` must exist.
4. The plan-review gate: `false` records `plan_review: overridden` via
   `plan_put_field`; otherwise `spar-plan-review-check.sh` must pass.
5. `codex` seat only: `plan_put_field author codex`, `plan_put_field
   owner_session`.
6. `plan_set_field phase running`.
7. Extract task 1 (or the whole plan in `whole` mode) to
   `.claude/spar-fight-task.txt`.
8. `spar-fight-launch.sh`.

The gate stays at step 4 for both seats: after the checks whose failure is a more
likely explanation of what the user did wrong, and before any state is written.

### What stays in the documents

Argument resolution, the `SPAR_TASK`-with-a-plan refusal, the Codex liveness
check, and the single-task path. Those are entry-point concerns, not activation.

## Testing

`tests/test_plan_activate.sh` exercises the helper directly, both seats: refusal
on each precondition, the override recording `overridden` on a state with no such
key, the gate refusing an unreviewed plan without flipping the phase, the
`codex` seat writing both stamps and the `claude` seat writing neither, `whole`
vs per-task extraction, and seat-appropriate command names in messages.

The two existing block-extraction tests stay: they now prove each document
*invokes* the helper with the right arguments, which is the part that can still
drift. `tests/test_codex_adapter.sh` gains an execution test of the skill's
activation block, which it has never had.

## Non-goals

- Changing any observable behaviour. Every message, exit status and state write
  stays as it is today; only the seat-specific wording is derived rather than
  duplicated.
- Merging the single-task path. It differs between seats in ways that are about
  argument handling, not activation.
- Touching `stop-hook.sh` or `stop-fight.sh`. Task advancement after the first is
  the hook's, and it already has one implementation.
