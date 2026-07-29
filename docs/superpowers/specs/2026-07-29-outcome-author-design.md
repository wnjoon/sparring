# The outcome file records `author` — design

## The defect

`plugins/spar/commands/spar-record-outcome.sh:59-70` writes `reason`,
`review_id`, `rounds`, `reviewer`, `reviewer_version`, `sweep` and
`recorded_at`. Not `author`.

`spar-report.sh` needs `author` for the pairing sentence. It reads the outcome
file first (`:109`) and falls back to the live loop state (`:110`), and since the
previous change that fallback is correctly gated on the live state's `review_id`
matching the report being asked for. So a finished run whose loop state is gone —
which is every finished run, because `cleanup()` deletes it at every terminal
path — has no source for `author` and takes the historical `claude` default
(`:111`).

A Codex-authored run reported later is therefore reported as Claude-authored, and
the pairing sentence inverts with it: a cross-model run reads as same-model, or
the reverse.

This was raised as PR2 by the plan review of the previous change and deferred
there as a separate concern. It is that concern.

## What is built

`spar-record-outcome.sh` reads `author` from the loop state alongside `reviewer`,
validates it, and writes it into the outcome frontmatter.

`author` is already in the loop state on every path that has one:
`spar-fight-launch.sh:57` writes it for plan-driven runs, the Codex skill's
single-task state carries `author: codex`, and `fight.md`'s single-task state
writes none — absent meaning `claude`, the convention every reader in the
codebase already applies.

**Absent becomes `claude`, written out.** The outcome file is read by consumers
that should not have to know a default, so the field is always present with a
resolved value rather than omitted. An unexpected value becomes `unknown`, the
same discipline `reviewer` already gets at `:42`.

**No reader changes.** `spar-report.sh:109` already prefers the outcome file, so
once the field is written the live-state fallback stops being reached for it. Its
comment is updated to say the fallback now serves only outcome files written by
an older version.

## Verification

`tests/test_record_outcome.sh` gains three cases — a state with `author: codex`, a
state with the line absent, and a state with a bogus value — each with its own
review id so the outcome files do not collide, since the suite's existing state
fixture carries no `author` line and would only ever exercise the default arm.

`tests/test_spar_report.sh` is **not** extended. Its `:110-112` already asserts
that a Codex-authored, Claude-reviewed outcome with no live state yields
`cross-model (codex author ↔ claude reviewer)`, which is the end-to-end
consequence. It passes today only because that fixture writes `author` by hand —
which is precisely what the writer does not do — so it is a reader test that stays
green either way, and a second copy of it would measure nothing. It must keep
passing unedited: if it needs editing, something outside this change's scope moved.

## Also in the working tree

This change is made on a tree that already carries uncommitted work from a
previous task whose loop ended at the round cap: `adapters/codex/verify-live.sh`
and `tests/test_verify_live.sh`, the Codex release-gate checklist gaining the plan
path. Those changes are in this run's review surface and are meant to be —
one of them, the fix for that loop's last finding, was never independently
reviewed. Treat them as part of what is under review here rather than as noise.

## Non-goals

- Backfilling `author` into outcome files already written. They record what was
  known when they were written.
- Any change to `cleanup()`, so that a finished run keeps its loop state. The
  outcome file is the durable record by design; that is the thing to complete.
- Any change to `spar-report.sh` beyond the comment.
