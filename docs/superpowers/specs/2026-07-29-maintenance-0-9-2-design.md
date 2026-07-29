# 0.9.2 maintenance — design

Three defects found by using 0.9.0/0.9.1 rather than by reading them. None
changes the loop's behaviour; all three make it tell the truth or read plainly.

## 1. The branch slug mangles an inline spec

`/spar:ready` builds its branch name from the spec argument
(`plugins/spar/commands/ready.md:41`, mirrored at
`adapters/codex/skills/spar-ready/SKILL.md:72`):

```
sed 's#.*/##; s/\.[A-Za-z0-9]*$//' | tr '[:upper:] ' '[:lower:]-' \
  | tr -cd 'a-z0-9-' | sed 's/^-*//; s/-*$//' | cut -c1-40
```

Observed on a real run:

```
spar/specs------spar-reportsh-reviewer------i-20260729-132605
```

Two distinct defects produced that.

**Basename-stripping applied to prose.** `s#.*/##` is there to turn
`docs/.../a-design.md` into `a-design`. The spec may also be an inline
description, and this one mentioned a path — so everything before the last `/`
was cut and the name begins mid-sentence at `specs`.

**Runs of `-` are not collapsed.** `tr '[:upper:] ' '[:lower:]-'` turns each
space into `-`, then `tr -cd 'a-z0-9-'` deletes every non-ASCII character. A
Korean word between two spaces leaves `--` behind, a phrase leaves `------`.
Only leading and trailing dashes are trimmed.

**Decided: the slug stays ASCII.** Git accepts UTF-8 refs, so keeping the
original characters was the other option and was rejected — a git branch name is
not where anyone reads the topic, and byte-safe truncation of multibyte text is
machinery this does not need. A spec written entirely in non-ASCII therefore
still yields `spar/run-<timestamp>`, which is unique and uninformative, and that
is accepted. The spec text itself is untouched: it is already captured verbatim
to `.claude/spar-plan-spec.txt` and handed to the reviewer as written.

**Required behaviour.** Basename and extension stripping apply only when the
spec argument names an existing file. Runs of `-` collapse to one. Everything
else — lowercasing, the ASCII filter, the trim, the 40-character cut, the `run`
fallback — stays as it is.

## 2. The Codex release-gate checklist predates Phase 9

`adapters/codex/verify-live.sh setup` prints the human checklist for the
Codex-seat live run. It contains no mention of `spar-ready`, of a plan, or of the
plan review — the string `plan` does not appear in the file. It was written for
Phase 6 and its item 4 drives `spar-fight` with a task, which is the single-task
path.

Phase 9 added a plan path to that seat: `spar-ready` captures the spec, prepares
a review, and `spar-fight` refuses to activate until every finding has a
disposition. None of it is exercised by the checklist, so the 0.9.1 gate run
needed items written by hand — and the next one would too.

**Required behaviour.** The checklist gains the plan path as its own item, after
the existing end-to-end item: run `spar-ready` on a small change in the same
session, confirm `plan-review=required` is printed, confirm a
`reviews/spar-plan-*.md` result appears, confirm `spar-fight` refuses before the
disposition is written and starts after, and confirm the refusal names
`spar-fight`/`spar-cancel` rather than the Claude spellings. `check` asserts what
it can from the artifacts left behind; the observations only a human can make
stay with the human, as they already do for the trust prompt.

## 3. The outcome file does not record `author`

`spar-record-outcome.sh` writes `reason`, `review_id`, `rounds`, `reviewer`,
`reviewer_version`, `sweep` and `recorded_at` (`:59-70`). Not `author`.

`spar-report.sh` needs it for the pairing sentence, so it reads the live state —
and since the previous change that read is correctly gated on a matching
`review_id`, a finished run whose loop state is gone now falls back to the
historical `claude` default (`:112`). A Codex-authored run reported later is
therefore reported as Claude-authored, and the pairing sentence inverts with it.

This was raised as PR2 by the plan review of the previous change and deferred
there as a separate concern. It is that concern.

**Required behaviour.** The outcome writer records `author` alongside `reviewer`,
taking it from the loop state the same way it takes the others, with the same
absent-means-`claude` default the rest of the codebase uses. A report assembled
from an outcome file alone then names the pairing correctly with no live state
present at all.

## Non-goals

- The `/spar:fight` plan-wide roll-up report (`docs/design-decisions.md:294`). It
  needs a per-task review id in the plan state, which is a larger change than
  these three.
- Teaching the slug to transliterate. Rejected above.
- Any change to the loop: rounds, caps, conveyance, the gate's own rules.
