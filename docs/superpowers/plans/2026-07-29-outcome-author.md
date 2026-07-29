# Outcome file records `author` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write `author` into `reviews/spar-<id>-outcome.md`, so a report assembled after the loop state is gone names the author seat instead of guessing it.

**Architecture:** One field added to `spar-record-outcome.sh`, read from the loop state beside `reviewer` and validated the same way. No reader changes — `spar-report.sh` already prefers the outcome file — only its comment moves. New coverage goes in the writer's suite; the report suite must keep passing untouched.

**Tech Stack:** POSIX-ish bash, pure-bash test suites, no framework.

## Global Constraints

- No change to `plugins/spar/hooks/stop-hook.sh`, `stop-fight.sh`, `cleanup()`, or any activation site. `author` is already in the loop state on every path that has one.
- No change to `spar-report.sh` beyond a comment.
- `tests/test_spar_report.sh` must keep passing **unedited**. It is the regression guard for what this change is for; if it needs editing, something outside this scope moved.
- The outcome file's existing fields, their order and their spelling stay as they are.

## Also in the working tree

This runs on a tree that already carries uncommitted work from a previous task
whose loop ended at the round cap: `adapters/codex/verify-live.sh` and
`tests/test_verify_live.sh` — the Codex release-gate checklist gaining the plan
path, plus the fixes from that loop's six rounds. They are in this run's review
surface deliberately. The last of those fixes, for that loop's round-6 finding,
was never independently reviewed, and this run is where it gets read. Treat them
as part of what is under review, not as noise; `docs/superpowers/plans/2026-07-29-maintenance-0-9-2.md`
is modified for the same reason.

---

### Task 1: The outcome writer records the author seat

**Files:**
- Modify: `plugins/spar/commands/spar-record-outcome.sh` — the field reads at `:21-23`, the validation block at `:41-42`, the heredoc at `:59-70`
- Modify: `plugins/spar/commands/spar-report.sh` — the comment at `:105-108` only
- Test: `tests/test_record_outcome.sh`

**Interfaces:**
- Produces: `reviews/spar-<id>-outcome.md` gains one line, `author: codex|claude|unknown`, written after `reviewer`. No consumer changes: `spar-report.sh:109` already reads `author` from the outcome file before falling back.

**Why the field is missing and what it costs.** The writer records `reason`,
`review_id`, `rounds`, `reviewer`, `reviewer_version`, `sweep` and `recorded_at`
(`:59-70`). `spar-report.sh` needs `author` for the pairing sentence; it reads the
outcome file at `:109` and the live loop state at `:110`, and that fallback is
gated on the live state's `review_id` matching the report being asked for.

A finished run does not keep a usable loop state. Some terminal branches call
`cleanup()` directly (`stop-hook.sh:113`, `:143`, `:1374`); the skipped, cap and
sweep-at-cap branches instead call `deactivate_state` (`:1397`, `:1720`, `:1805`)
and the file is deleted on the following Stop, at `:287`. Either way, by the time
a report is asked for later the state is gone — and while it still exists it is
`active: false`, which is not a source the report may use for another run. So for
a finished run there is no source at all and `:111` resolves the empty value to
`claude`. A
Codex-authored run reported later reads as Claude-authored, and the pairing
sentence inverts with it.

**Where the value comes from.** The loop state, beside `reviewer`.
`spar-fight-launch.sh:57` writes `author` for plan-driven runs; the Codex skill's
single-task state carries `author: codex`; `fight.md`'s single-task state writes
none, and absent means `claude` — the convention `stop-hook.sh` and
`spar-report.sh` both already apply.

- [x] **Step 1: Write the failing tests**

`tests/test_record_outcome.sh` has `chk` and a `fresh` helper that writes one
fixed loop state with **no** `author` line (`:15-30`). That state only ever
exercises the default arm, so the three cases need their own states, each with its
own `review_id` so the outcome files do not collide. Add after the existing
assertions on the first fixture:

```bash
# author is the one header field the outcome file never carried, so a report
# assembled after cleanup() deleted the loop state had no source for it and took
# the historical claude default — inverting the pairing sentence for a
# Codex-authored run.
oc_state() { # $1=review-id  $2=author line, or empty to omit it
  { printf -- '---\nactive: true\nphase: review\nround: 3\nreview_id: %s\n' "$1"
    printf 'base_sha: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nreviewer: codex\n'
    [ -n "$2" ] && printf '%s\n' "$2"
    printf 'max_rounds: 5\n---\ntask\n'
  } > .claude/spar.local.md
}

ID_CODEX=20260729-010000-aaaaaa
oc_state "$ID_CODEX" 'author: codex'
bash "$WRITER" converged .claude/spar.local.md clean
chk "the outcome records a codex author" "author: codex" \
  "$(cat "reviews/spar-${ID_CODEX}-outcome.md")"

# Absent means claude — the convention every reader already applies. Written out
# rather than omitted, so a consumer of the outcome file needs no default.
ID_PLAIN=20260729-020000-bbbbbb
oc_state "$ID_PLAIN" ''
bash "$WRITER" converged .claude/spar.local.md clean
chk "and claude when the state says nothing" "author: claude" \
  "$(cat "reviews/spar-${ID_PLAIN}-outcome.md")"

# Same discipline reviewer gets at :42 — an unexpected value must not reach the
# frontmatter as itself.
ID_BOGUS=20260729-030000-cccccc
oc_state "$ID_BOGUS" 'author: banana'
bash "$WRITER" converged .claude/spar.local.md clean
chk "and refuses a bogus author" "author: unknown" \
  "$(cat "reviews/spar-${ID_BOGUS}-outcome.md")"
```

`$WRITER` is the suite's own at `:5`, and its calls take
`<reason> <state-file> <sweep-result>` — the first is at `:34`. Confirm both
against the existing call before writing, not from this snippet.

**No new test in `tests/test_spar_report.sh`.** Its `:110-112` already asserts
that a Codex-authored, Claude-reviewed outcome with no live state yields
`cross-model (codex author ↔ claude reviewer)` — the end-to-end consequence. It
passes today only because that fixture writes `author` by hand, which is what the
writer does not do, so it is a reader test that stays green either way and a
second copy would measure nothing. Step 5's first mutation makes that concrete.

- [x] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_record_outcome.sh`
Expected: all three new checks fail — the writer emits no `author:` line at all,
so each reads an outcome file that lacks it.

Run: `bash tests/test_spar_report.sh`
Expected: unchanged and green. It is the regression guard for what this change is
for and must not need editing.

- [x] **Step 3: Record the field**

In `plugins/spar/commands/spar-record-outcome.sh`, beside the other field reads
(`:21-23`):

```bash
author=$(field author)
```

beside the other validations (`:41-42`):

```bash
# Absent means claude — the historical default for every pre-Phase-6 run, and
# what stop-hook.sh and spar-report.sh both resolve it to. Resolved here rather
# than left empty so a reader of the outcome file needs no default of its own.
case "$author" in ''|claude) author=claude ;; codex) ;; *) author=unknown ;; esac
```

and in the heredoc, on the line after `reviewer`:

```bash
  echo "author: ${author}"
```

`echo`, matching its neighbours: the value is one of three literals after the
`case`, so it carries nothing `printf` is needed to protect against — unlike
`reviewer_version`, which is third-party text and is deliberately the one
`printf` line there.

Then in `plugins/spar/commands/spar-report.sh`, update the comment at `:105-108`.
It currently explains why `author` is resolved from the pair and why absent means
`claude`; add that the outcome file now carries the field, so the live-state read
at `:110` serves only outcome files written before this change. No code change.

- [x] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_record_outcome.sh` → `FAIL=0`.
Run: `bash tests/test_spar_report.sh` → still green, still unedited.

Then every suite, because the writer runs at every terminal path of the loop and
`tests/test_stop_hook.sh` exercises those:

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
echo "rc=$rc"
```

- [x] **Step 5: Prove each part is independently caught**

Three scratch copies. In each, make the change, run
`bash tests/test_record_outcome.sh` and `bash tests/test_spar_report.sh`, and
confirm the named checks fail while the rest stay green:

1. Remove `echo "author: ${author}"` → all three new writer checks fail, and
   `tests/test_spar_report.sh` stays **entirely** green. That is the point of
   putting the coverage in the writer's suite: the report fixtures write `author`
   by hand, so no reader test can catch a writer that omits it.
2. Remove the validating `case` → **two** checks fail: "refuses a bogus author",
   and "and claude when the state says nothing" — without the `case` an absent
   line leaves `$author` empty and the writer emits a bare `author:`. Only the
   explicit `author: codex` check stays green, because that value needs no
   resolution. So the `case` carries both the mapping and the defaulting, and
   either fixture alone would under-report what it does.
3. Change the default arm from `claude` to `unknown` → "and claude when the state
   says nothing" fails.

- [x] **Step 6: Commit**

Stage only this task's files. The `verify-live.sh` and `test_verify_live.sh`
changes in the tree belong to the previous task and are committed separately after
this loop converges, so that the two are not tangled in one commit message.

```bash
bash tests/test_record_outcome.sh >/dev/null || { echo "not committing"; exit 1; }
bash tests/test_spar_report.sh >/dev/null || { echo "not committing"; exit 1; }
git add plugins/spar/commands/spar-record-outcome.sh plugins/spar/commands/spar-report.sh tests/test_record_outcome.sh
git commit -m "fix(outcome): record the author seat so a later report does not guess it"
```

---

## Non-goals

- Backfilling `author` into outcome files already written. They record what was
  known when they were written.
- Keeping the loop state alive past a terminal path so the fallback could work.
  The outcome file is the durable record by design; completing it is the fix.
- Any change to `spar-report.sh` beyond the comment, and none to the activation
  sites, which already write `author` where they have one.

## Verification this plan cannot do

Whether anyone has been misled by the inverted pairing. It needs a report asked
for after its run's loop state was deleted, and nothing records that a report was
read. It was found by the previous change's plan review asking what the outcome
file does *not* carry.
