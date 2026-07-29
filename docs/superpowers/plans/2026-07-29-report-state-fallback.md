# Report state-fallback gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `spar-report.sh` from filling a missing field in an older run's report out of the currently live loop state.

**Architecture:** `spar-report.sh` reads each header field from the run's own outcome file and falls back to `.claude/spar.local.md` when it is absent. That file describes whichever run is live *now*. Only the `reviewer_version` fallback checks that the live state's `review_id` matches the report being asked for; the four beside it do not. One guarded helper replaces all five call sites, so the check cannot be present on some and missing on others.

**Tech Stack:** POSIX-ish bash, pure-bash test suite (`tests/test_spar_report.sh`), no framework.

## Global Constraints

- The report stays best-effort: no new exit path, no new failure mode. A field with no honest source degrades to its existing default (`unknown`, `0`, `not-run`), exactly as an absent outcome file already does.
- Read-only apart from the report it publishes. No change to `.claude/spar.local.md`.
- No change to `plugins/spar/hooks/stop-hook.sh`, `stop-fight.sh`, or any caller. The signature stays `spar-report.sh <review-id> <base-sha> [reviews-dir] [state-dir]`.
- A report for the run that IS live must keep every value it produces today. This is a narrowing of when the fallback applies, not of what it yields.

---

### Task 1: One guarded fallback for every live-state read

**Files:**
- Modify: `plugins/spar/commands/spar-report.sh:76`, `:87-91`, `:99`, `:106`, `:116`
- Test: `tests/test_spar_report.sh`

**Interfaces:**
- Produces: `from_state <key>` — the value of `<key>` in `${state_dir}/spar.local.md`, but only when that file's `review_id` equals the `review_id` this report is being generated for. Empty otherwise. Internal to the script; no caller outside it.

**The defect, concretely.** `reviews/spar-<id>-outcome.md` is written at every terminal path, so for a finished run it carries the header fields. When it is absent or partial the script reads `.claude/spar.local.md` instead — and that file belongs to whatever run is active at the moment `/spar:report` is typed. Ask for the report of a run from this morning while a different loop is running now, and the older run's report states this run's reviewer, author, round count and sweep result as fact. Nothing marks them as borrowed.

`reviewer_version` already guards against this (`:87-91`) with the comment "The live state is a fallback only for the run it belongs to". The guard is correct and its four neighbours never got it. Five sites, one rule, one of them implementing it — that asymmetry is the thing to remove, not just the `reviewer` line the spec names.

**Why all five and not only `reviewer`.** `author` feeds the same `pairing` sentence `reviewer` does (`:111-115`), so guarding one and not the other still lets a report claim a cross-model pairing that never happened. `rounds` and `sweep` are the same shape with the same consequence. Fixing one line would satisfy the request and leave the defect.

- [x] **Step 1: Write the failing tests**

`tests/test_spar_report.sh` already has `fresh`, `outcome`, `state`, `chk` and `chk_absent`, and its `state()` writes `review_id: ${ID}` — the matching case. Add a second writer beside it for the mismatching case, then the fixtures.

```bash
# A live loop belonging to a DIFFERENT run. Same shape as state(), different id:
# that one difference is the whole point, so it is a separate helper rather than
# an argument to the existing one.
foreign_state() { # $1=round $2=reviewer $3=sweep_result [$4=author]
  cat > .claude/spar.local.md <<EOF
---
active: true
phase: review
round: $1
review_id: 20260101-000000-ffffff
base_sha: none
reviewer: $2
max_rounds: 5
sweep_done: false
sweep_result: $3
${4:+author: $4}
---
EOF
}
```

The cases. Each drives the script with **no outcome file at all**, which is the
only way every fallback is reached at once:

```bash
# ── a foreign live state supplies nothing ──
fresh
foreign_state 4 codex findings codex
rm -f "reviews/spar-${ID}-outcome.md"
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R")"
chk "a foreign run's reviewer is not borrowed" "- reviewer: unknown" "$OUT"
chk_absent "and its family is not stated" "reviewer: codex" "$OUT"
chk "a foreign run's rounds are not borrowed" "- rounds: 0" "$OUT"
chk_absent "and not its round count" "rounds: 4" "$OUT"
chk "a foreign run's sweep is not borrowed" "- sweep: not-run" "$OUT"
chk_absent "and not its result" "sweep: findings" "$OUT"
chk "and the pairing is not invented" "unknown pairing" "$OUT"

# ── author, on its own ──
# The case above cannot see author at all: with reviewer guarded it is empty, and
# :109 prints "unknown pairing" whatever author says. So author needs a fixture
# where reviewer IS known — from the outcome file, which records reviewer but
# never author (spar-record-outcome.sh:59-70). Then the only variable left in the
# pairing sentence is where author came from.
fresh
printf -- '---\nreason: converged\nreview_id: %s\nrounds: 1\nreviewer: claude\nsweep: not-run\n---\n' \
  "$ID" > "reviews/spar-${ID}-outcome.md"
foreign_state 1 codex not-run codex
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R")"
chk "a foreign run's author is not borrowed" \
  "same-model (claude author ↔ claude reviewer)" "$OUT"
chk_absent "so no pairing is invented from it" \
  "cross-model (codex author ↔ claude reviewer)" "$OUT"

# ── the run that IS live keeps everything it has today ──
# The control. Without it a fix that simply deleted the fallbacks would pass
# every check above.
fresh
state 4 codex findings
rm -f "reviews/spar-${ID}-outcome.md"
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R")"
chk "its own live state still supplies the reviewer" "- reviewer: codex" "$OUT"
chk "and the rounds" "- rounds: 4" "$OUT"
chk "and the sweep" "- sweep: findings" "$OUT"

# ── no live state at all ──
# The third source of a missing value, and the one that must not start erroring:
# the report is best-effort and a stateless machine still gets a report.
fresh
rm -f .claude/spar.local.md "reviews/spar-${ID}-outcome.md"
bash "$GEN" "$ID" none >/dev/null 2>&1; RC=$?
chk "a missing state file is not an error" "0" "$RC"
chk "and the report still exists" "- reviewer: unknown" "$(cat "$R")"
```

Note `chk_absent "and its family is not stated" "reviewer: codex"` matches
without the leading `- `, so it also catches the value appearing anywhere else in
the report — the pairing sentence included.

- [x] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_spar_report.sh`

Expected: the seven foreign-state checks and the two author-fixture checks fail —
today the report borrows all four values. The three control checks and the two missing-state checks pass already;
they are regression guards, not red-phase checks, and if any of them is red the
fixture is wrong rather than the code.

- [x] **Step 3: Write the guarded helper and route every site through it**

In `plugins/spar/commands/spar-report.sh`, beside `field()` (`:44-47`):

```bash
# The live state describes whichever run is active NOW. As a fallback it is
# sound only for the run it belongs to: a report asked for an older id would
# otherwise state this run's reviewer, rounds and sweep as that run's facts, and
# nothing in the report would mark them as borrowed. Every live-state read goes
# through here so the check cannot be present on some fields and missing on
# others — which is exactly how it stood: one of five sites had it.
from_state() { # $1=key → its value, or empty when the live state is another run's
  [ "$(field review_id "$STATE")" = "$review_id" ] || return 0
  field "$1" "$STATE"
}
```

Then replace all five reads. `field <k> "$STATE"` → `from_state <k>`:

- `:76` `rounds=$(field round "$STATE")` → `rounds=$(from_state round)`
- `:90` `reviewer_version=$(field reviewer_version "$STATE")` → `from_state reviewer_version`, and drop the now-duplicated `&& [ "$(field review_id "$STATE")" = "$review_id" ]` from its `if`
- `:99` `reviewer=$(field reviewer "$STATE")` → `from_state reviewer`
- `:106` `author=$(field author "$STATE")` → `from_state author`
- `:116` `sweep=$(field sweep_result "$STATE")` → `from_state sweep_result`

Keep the `reviewer_version` comment about *why* the guard exists — move it to
`from_state`, since it now explains all five rather than one.

**Nothing else changes.** Each site already has its own default for an empty
value, and an empty return from `from_state` reaches exactly those — which is why
this needs no new failure path:

| field | line | empty becomes |
|---|---|---|
| `rounds` | `:77` | `0` |
| `reviewer_version` | `:98` | `unknown` |
| `author` | `:107` | `claude` — absent means pre-Phase-6, matching `stop-hook.sh` |
| `reviewer` | `:108` | `unknown` |
| `sweep` | `:117` | `not-run` |

`author` is the one that does **not** become `unknown`, so the pairing sentence
is decided by `reviewer` here: `:109` reads `unknown` in either seat as
`unknown pairing`, and a foreign state leaves `reviewer` empty. That is why the
pairing check in Step 1 expects `unknown pairing` rather than an unknown author.

- [x] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_spar_report.sh`
Expected: `FAIL=0`.

Then the whole suite, because `spar-report.sh` is called by the hook's terminal
paths and `tests/test_stop_hook.sh` exercises them:

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
echo "rc=$rc"
```

- [x] **Step 5: Prove each part is independently caught**

Four scratch copies of the repository. In each, make the named change, run
`bash tests/test_spar_report.sh`, and confirm the named checks fail while the
rest stay green:

1. `from_state` drops its `review_id` check (`return 0` on mismatch removed) →
   all seven foreign-state checks fail, and the three control checks stay green.
2. `from_state` always returns empty (the guard inverted) → the three control
   checks fail and the foreign-state checks stay green. This is the mutation the
   control exists for: without it, deleting the fallback entirely would look
   like a fix.
3. Only the `reviewer` site is routed through `from_state`; `author` still calls
   `field … "$STATE"` → the two author-fixture checks fail while every other one
   passes. This is the half-fix the spec's wording would have allowed, and it
   must not be green. It is caught only by the author fixture: in the
   no-outcome-at-all case a guarded `reviewer` is already empty, so `:109` prints
   `unknown pairing` whatever `author` holds.
4. Only `rounds` is left unrouted → "a foreign run's rounds are not borrowed"
   and "and not its round count" fail.

- [x] **Step 6: Commit**

```bash
bash tests/test_spar_report.sh >/dev/null || { echo "not committing — the suite failed"; exit 1; }
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
git add plugins/spar/commands/spar-report.sh tests/test_spar_report.sh
git commit -m "fix(report): never fill an older run's report from the live state"
```

---

## Non-goals

- Recording the missing fields somewhere durable so a report could recover them.
  For `reason`, `rounds`, `reviewer`, `reviewer_version` and `sweep` the outcome
  file already is that record. `author` is the exception: `spar-record-outcome.sh:59-70`
  does not write it, so after this change a finished run's report takes `author`
  from a matching live state or falls back to the historical `claude` default —
  the same value every pre-Phase-6 run gets. Teaching the outcome writer to
  record it is the right fix and a different change; a report that borrows it
  from an unrelated run is wrong either way.
- Marking borrowed values in the report rather than dropping them. A report that
  says "reviewer: codex (from another run)" is a sentence no reader needs; the
  field simply has no source.
- Any change to `stop-hook.sh` or the outcome writer. `record_outcome` runs first
  at every terminal path, so for the five fields it does record, a run that ended
  normally never reaches this fallback. `author` is not among them (see above),
  and adding it belongs with the outcome writer rather than here.

## Verification this plan cannot do

Whether anyone has actually been misled by this. The defect needs a report asked
for an older id while a different loop is live, and nothing records that a report
was read, let alone believed. It was found by reading the `reviewer_version` fix
and asking what else had that shape.
