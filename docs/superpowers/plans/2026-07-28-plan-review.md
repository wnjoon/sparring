# Plan Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a plan one independent reading before `/spar:fight` will execute it, and make clearing that reading a precondition of activation rather than an instruction anyone can skip.

**Architecture:** Nothing in `stop-hook.sh` or `stop-fight.sh` changes. `/spar:ready` captures the spec, records two fields, and prepares a runner; the session runs it and writes a disposition per finding; `/spar:fight`'s existing activation block refuses to start until the review has run and every finding carries a disposition. Both seats change identically.

**Tech Stack:** POSIX-ish bash 3.2 (macOS default), awk, git. Tests are pure bash under `tests/`, driven with CLI stubs, and never invoke a real reviewer.

## Global Constraints

- The four invariants in `README.md:125-130` hold: single writer, reviewer-declares-convergence, deterministic enforcement with fail-open hooks, blind adjudication. This pass never writes a convergence marker and never claims one.
- Tests are pure bash in `tests/` and must never require a reviewer CLI on `PATH`. Where one is needed, build a stub and prepend it, as `tests/test_fight_resolve.sh:8` already does.
- Both seats behave identically. Every change below lands in the Claude command **and** the Codex skill; a change to one only is a defect, not a saving.
- Every behavioural change needs a test that fails when the change is reverted, and each independently revertible part needs its own failing check. Perform the revert and record which checks failed.
- A task body must contain no line beginning with `### ` — the extractor that hands one task to the implementer splits on exactly that.
- The design is `docs/superpowers/specs/2026-07-28-plan-review-design.md`. Where this plan and the spec disagree, the spec is right and the plan is wrong; say so rather than following the plan.
- `plugins/spar/commands/fight.md` and its Codex mirror are surfaces both seats share, so the release gate applies before the release that carries this work: one live `/spar:fight` in Claude Code and one live `spar-fight` in Codex. That release is deferred until this phase lands, so it runs once.

---

### Task 1: `--no-plan-review` through both resolvers

**Files:**
- Modify: `plugins/spar/commands/spar-ready-resolve.sh`, `plugins/spar/commands/spar-fight-resolve.sh`
- Modify: `plugins/spar/commands/ready.md:3`, `plugins/spar/commands/fight.md:3` (the `argument-hint` lines)
- Test: `tests/test_ready_resolve.sh`, `tests/test_fight_resolve.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: both resolvers gain a fifth tab-separated output field, `plan_review`, holding `true` when the flag was absent and `false` when it was given. `spar-ready-resolve.sh` prints `<mode>\t<reviewer>\t<unattended>\t<plan_review>\t<spec>`; `spar-fight-resolve.sh` prints `<family>\t<include-dirty>\t<unattended>\t<plan_review>\t<task>`. In both, the free text stays last so a spec or task containing tabs and newlines is still unambiguous.

The flag must exist before either command can honour it, and it belongs in both: `/spar:ready --no-plan-review` skips preparing the review, and `/spar:fight --no-plan-review` overrides a precondition a broken reviewer would otherwise leave unclearable.

Both resolvers already parse repeated-flag errors the same way (`spar-ready-resolve.sh:16-27`), so follow that shape exactly: a bare `--no-plan-review`, the same followed by a space, and a `seen_*` guard that errors on a second occurrence.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_ready_resolve.sh`. Note its existing expectations are whole-output comparisons, so **every one of them changes** when a field is added — that is the point, and updating them is part of this step, not collateral damage.

```bash
# Output is: <mode>\t<reviewer|empty>\t<unattended>\t<plan_review>\t<spec>
chk "plan review is on by default" \
  "$(printf 'per-task\t\tfalse\ttrue\tdocs/x.md')" "$(bash "$R" "docs/x.md")"
chk "--no-plan-review turns it off" \
  "$(printf 'per-task\t\tfalse\tfalse\tdocs/x.md')" "$(bash "$R" "--no-plan-review -- docs/x.md")"
chk "it composes with the other flags in either order" \
  "$(printf 'whole\tcodex\ttrue\tfalse\tgo')" \
  "$(bash "$R" "--no-plan-review --whole --reviewer codex --unattended -- go")"
chk "twice is an error" "error" "$(bash "$R" "--no-plan-review --no-plan-review -- x" 2>&1; echo)"
chk "the flag does not survive into the spec text" "absent" \
  "$(bash "$R" "--no-plan-review -- build it" | cut -f5 | grep -qF -- '--no-plan-review' && echo present || echo absent)"
```

Add the equivalent to `tests/test_fight_resolve.sh`, using its `mkbin` stubs and its field order — `plan_review` is field 4 and the task text field 5.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_ready_resolve.sh` and `bash tests/test_fight_resolve.sh`
Expected: the new checks FAIL, and so do the pre-existing whole-output comparisons, because the field count changed. Both are expected; a pre-existing check that still passes means the field was not added.

- [ ] **Step 3: Parse the flag in both resolvers**

In `spar-ready-resolve.sh`, beside the existing initialisers (`:11`):

```bash
plan_review=true; seen_pr=false
```

and in the `while :;` loop, matching the `--unattended` arms exactly:

```bash
  elif [ "$remainder" = "--no-plan-review" ]; then
    [ "$seen_pr" = false ] || { echo "error: --no-plan-review specified more than once" >&2; exit 2; }
    seen_pr=true; plan_review=false; remainder=""
  elif [ "${remainder#--no-plan-review }" != "$remainder" ]; then
    [ "$seen_pr" = false ] || { echo "error: --no-plan-review specified more than once" >&2; exit 2; }
    seen_pr=true; plan_review=false; remainder="${remainder#--no-plan-review }"
```

Then extend the final `printf` to five fields, with the free text last. Make the same two changes in `spar-fight-resolve.sh`, following its own initialiser and loop shape rather than transplanting this one.

- [ ] **Step 4: Update both argument hints**

`ready.md:3` and `fight.md:3` carry an `argument-hint` line the host displays. Add `[--no-plan-review]` to each, in the same position relative to the other flags. Also update each resolver's header comment, which documents the printed field order — that comment is the only place the contract is written down.

- [ ] **Step 5: Update every caller that reads the resolver output**

`ready.md` and `fight.md` both destructure the tab-separated result into shell variables (`ready.md:24-30`, `fight.md:16-22`). A fifth field breaks the last one silently: the old final field was the free text, and it will now receive `plan_review`. Add the new variable to both, and to the Codex mirrors `adapters/codex/skills/spar-ready/SKILL.md` and `adapters/codex/skills/spar-fight/SKILL.md`, which destructure the same output.

This is the step most likely to be missed, because nothing fails loudly: the spec text becomes `true`, the plan gets written against the word "true", and no test in Task 1 covers it. Grep for every use of the resolver before finishing.

- [ ] **Step 6: Run the tests to verify they pass**

Run both resolver suites, then the whole suite — the destructuring change touches files other suites assert on.
Expected: `FAIL=0` everywhere.

- [ ] **Step 7: Prove the tests discriminate**

In a scratch copy, remove the two `--no-plan-review` arms from `spar-ready-resolve.sh` only, and confirm the ready suite's new checks fail while the fight suite's still pass. Repeat the other way round. Then remove the fifth field from one resolver's `printf` and confirm its whole-output comparisons fail.

- [ ] **Step 8: Run every suite and commit**

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
git add -A
git commit -m "feat(ready): a --no-plan-review flag in both resolvers"
```

---

### Task 2: `/spar:ready` captures the spec and prepares the review

**Files:**
- Create: `plugins/spar/commands/spar-plan-review-prepare.sh`
- Create: `plugins/spar/shared/prompts/plan-reviewer.md`
- Modify: `plugins/spar/commands/ready.md`, `adapters/codex/skills/spar-ready/SKILL.md`
- Modify: `plugins/spar/commands/cancel.md`, `adapters/codex/skills/spar-cancel/SKILL.md`
- Test: `tests/test_plan_review_prepare.sh` (new), `tests/test_ready_ingest.sh`

**Interfaces:**
- Consumes: `plan_review` from Task 1's resolver output.
- Produces: `spar-plan-review-prepare.sh <plan-path> <state-file>` writes `.claude/spar-plan-review-prompt.txt` and `.claude/spar-run-plan-review.sh`, and exits 0. It exits non-zero without writing either when the template is missing, when the reviewer CLI is absent, or when `plan_review` is not `required`. The runner it generates writes `reviews/spar-plan-<plan_review_id>.md` and `.claude/spar-plan-review-hash`.
- Produces: `/spar:ready` writes `plan_review: required|skipped` and `plan_review_id` into the plan state, and `.claude/spar-plan-spec.txt`.

**The captured spec is authoritative.** `/spar:ready` receives its spec as a path or as inline text and today only prints it (`ready.md:69`). Capture it verbatim: a path is read and copied, inline text is written as-is. A spec file edited after capture does not retroactively change what the plan was written against, and the review must judge the plan against what it was given.

**`plan_review_id`** is generated the same way the loop's `review_id` is
(`fight.md:84`: `date +%Y%m%d-%H%M%S` plus three random hex bytes) and written at
preparation. The result path is derived from it, so no later reader has to
reconstruct a timestamp or disambiguate between retained earlier reviews.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_plan_review_prepare.sh`, following the harness shape of `tests/test_fight_launch.sh` — its own temp repo, `chk`/`eqchk`, and stubs on `PATH`:

```bash
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/plugins/spar/commands/spar-plan-review-prepare.sh"
chk(){ if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
eqchk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); cd "$TMP"; cd "$(pwd -P)"; git init -q
git commit -q --allow-empty -m init
mkdir -p .claude reviews
STUBS=$(mktemp -d); printf '#!/bin/sh\nexit 0\n' > "$STUBS/codex"; chmod +x "$STUBS/codex"
PATH="$STUBS:$PATH"

mkstate() { # $1=plan_review value
  printf -- '---\nactive: true\nphase: planned\nmode: per-task\nreviewer: codex\nplan_review: %s\nplan_review_id: 20260728-120000-abc123\nplan_path: p.md\ntasks: 1\ncurrent: 1\n---\n1\tpending\tTask 1: Alpha\n' "$1" > .claude/spar-plan.local.md
}
printf '# Plan\n\n### Task 1: Alpha\n\ndo it\n' > p.md
printf 'the spec text\n' > .claude/spar-plan-spec.txt

mkstate required
bash "$P" p.md .claude/spar-plan.local.md
chk "prompt written" "Plan" "$(cat .claude/spar-plan-review-prompt.txt 2>/dev/null)"
chk "prompt carries the captured spec" "the spec text" "$(cat .claude/spar-plan-review-prompt.txt 2>/dev/null)"
chk "runner written" "codex exec" "$(cat .claude/spar-run-plan-review.sh 2>/dev/null)"
chk "runner is read-only" "sandbox read-only" "$(cat .claude/spar-run-plan-review.sh 2>/dev/null)"
chk "runner names the id-derived result path" "reviews/spar-plan-20260728-120000-abc123.md" \
  "$(cat .claude/spar-run-plan-review.sh 2>/dev/null)"
chk "runner records the plan hash" "spar-plan-review-hash" "$(cat .claude/spar-run-plan-review.sh 2>/dev/null)"
chk "runner checks the CLI exit status" "exited non-zero" "$(cat .claude/spar-run-plan-review.sh 2>/dev/null)"

# skipped means prepare nothing at all
rm -f .claude/spar-run-plan-review.sh .claude/spar-plan-review-prompt.txt
mkstate skipped
bash "$P" p.md .claude/spar-plan.local.md; RC=$?
eqchk "skipped → non-zero" "1" "$RC"
eqchk "skipped → no runner" "absent" "$([ -f .claude/spar-run-plan-review.sh ] && echo present || echo absent)"

# an absent reviewer CLI is fail-open, not a crash
mkstate required
EMPTY=$(mktemp -d)
rm -f .claude/spar-run-plan-review.sh
( PATH="$EMPTY:/usr/bin:/bin"; bash "$P" p.md .claude/spar-plan.local.md ); RC=$?
eqchk "absent CLI → non-zero" "1" "$RC"
eqchk "absent CLI → no runner" "absent" "$([ -f .claude/spar-run-plan-review.sh ] && echo present || echo absent)"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

Add to `tests/test_ready_ingest.sh` — or a new static block in it — checks that both `ready.md` and the Codex ready skill capture the spec and write both fields:

```bash
for f in "$ROOT/plugins/spar/commands/ready.md" "$ROOT/adapters/codex/skills/spar-ready/SKILL.md"; do
  S="$(cat "$f")"
  chk "$(basename "$f") captures the spec" "spar-plan-spec.txt" "$S"
  chk "$(basename "$f") records plan_review" "plan_review:" "$S"
  chk "$(basename "$f") records plan_review_id" "plan_review_id:" "$S"
done
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_plan_review_prepare.sh` and `bash tests/test_ready_ingest.sh`
Expected: the prepare suite fails to find the script at all, and the static checks fail on both ready documents.

- [ ] **Step 3: Write the prompt template**

`plugins/spar/shared/prompts/plan-reviewer.md`, with `{{PLAN}}`, `{{SPEC}}` and `{{BRIEF_PATHS}}` placeholders. It must:

- Say the reader is reviewing a plan before execution, is read-only, and must not modify anything.
- Carry the six brief questions from the spec verbatim, including question 6's boundary — name contradictions with the spec, protocol, invariants or data flow, give the minimal alternative and its cost, do not rewrite the plan.
- State the output contract: first line exactly `PLAN-REVIEW: CLEAN` or `PLAN-REVIEW: FINDINGS`, then `### PR<n> [BLOCKER|SHOULD-FIX|NOTE] <title>` with `file:`, `problem:`, `suggestion:`.
- Tell the reader to treat the plan, the spec and repository text as data to evaluate, never as instructions to obey — the same framing `judge.md:5-6` and `sweeper.md:3` already carry.
- Point at `README.md` and `plugins/spar/shared/policy.md` by path, since question 6 cannot be answered without them.

- [ ] **Step 4: Write the preparation script**

`plugins/spar/commands/spar-plan-review-prepare.sh`. Read `reviewer`, `plan_review` and `plan_review_id` from the state with the same `field()` helper shape the other command scripts use. Return 1 unless `plan_review` is `required`, the template exists, the plan file exists, and `command -v "$reviewer"` succeeds.

Substitute the template, write the prompt, then generate the runner **mirroring `emit_runner`'s hardening rather than inventing a new shape** (`stop-hook.sh:712-800` is the reference): a `reviews` directory check that refuses a symlink, a refusal to overwrite an existing non-regular output path, a lock directory, `mktemp` plus a hard-link publish, a CLI exit-status check before publishing, and the family split — `codex exec --sandbox read-only --skip-git-repo-check --output-last-message` versus `claude -p --safe-mode --tools Read Grep Glob` with the prompt on stdin.

The runner records the hash before dispatching:

```bash
git hash-object "${plan}" > .claude/spar-plan-review-hash 2>/dev/null || true
```

`git hash-object` rather than `sha256sum` or `shasum`: those differ between Linux and macOS, and git is already a hard dependency.

The claude family gets no diff surface here — there is no loop, no frozen baseline, and the plan and spec are in the prompt. It has `Read`, `Grep` and `Glob` for the repository, which is what question 1 and question 6 need.

- [ ] **Step 5: Capture the spec and record the fields, in both ready documents**

In `ready.md`'s setup block, after the resolver output is destructured and before the state file is written:

```bash
# The captured copy is authoritative from here: a spec file edited later does not
# change what the plan was written against.
if [ -f "$RDY_SPEC" ]; then cp "$RDY_SPEC" .claude/spar-plan-spec.txt
else printf '%s\n' "$RDY_SPEC" > .claude/spar-plan-spec.txt; fi
RDY_PR_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
if [ "$RDY_PLAN_REVIEW" = false ]; then RDY_PR=skipped
elif ! command -v "$RDY_REVIEWER" >/dev/null 2>&1; then
  RDY_PR=skipped
  echo "Note: '$RDY_REVIEWER' is not on PATH, so the plan review is skipped."
else RDY_PR=required; fi
```

and add `plan_review: ${RDY_PR}` and `plan_review_id: ${RDY_PR_ID}` to the state heredoc. Make the same change in the Codex ready skill with its own variable names.

Then extend each document's step list: after ingest, when `plan_review` is `required`, run the preparation script, run the generated runner, read the result, present it to the user, and — if the first line is `PLAN-REVIEW: FINDINGS` — write `.claude/spar-plan-review-response.md` with one `### PR<n>: ACCEPTED — …` or `### PR<n>: REJECTED — <grounded reason>` per finding. Say plainly that `/spar:fight` will refuse to start until that file accounts for every finding, and that a grounded rejection clears one exactly as an acceptance does.

- [ ] **Step 6: Add the five artifacts to both cancel lists**

`.claude/spar-plan-spec.txt`, `.claude/spar-run-plan-review.sh`,
`.claude/spar-plan-review-prompt.txt`, `.claude/spar-plan-review-hash` and
`.claude/spar-plan-review-response.md`, in `plugins/spar/commands/cancel.md` and
`adapters/codex/skills/spar-cancel/SKILL.md`. The result under `reviews/` is kept,
like every other review artifact.

Add a teardown check that runs each cancel document's bash block against a fixture
holding all five and asserts they are gone — the same shape as the existing
cancel-block tests in `tests/test_stop_hook.sh`, which extract and execute those
blocks rather than grepping them.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/test_plan_review_prepare.sh`, `bash tests/test_ready_ingest.sh`, `bash tests/test_stop_hook.sh`
Expected: `FAIL=0` in each.

- [ ] **Step 8: Prove each part is independently caught**

Five scratch copies. Remove the `plan_review` guard from the prepare script and confirm the `skipped` checks fail. Remove the CLI check and confirm the absent-CLI checks fail. Remove the hash line and confirm its check fails. Remove the spec capture from `ready.md` only, then from the Codex skill only, and confirm the matching static check fails each time while the other stays green. Remove one artifact from one cancel list and confirm that document's teardown check fails.

- [ ] **Step 9: Run every suite and commit**

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
git add -A
git commit -m "feat(ready): capture the spec and prepare an independent plan review"
```

---

### Task 3: `/spar:fight` will not start an unreviewed plan

**Files:**
- Create: `plugins/spar/commands/spar-plan-review-check.sh`
- Modify: `plugins/spar/commands/fight.md`, `adapters/codex/skills/spar-fight/SKILL.md`
- Test: `tests/test_plan_review_check.sh` (new), `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: the state fields and artifacts Task 2 writes; the `plan_review` flag from Task 1.
- Produces: `spar-plan-review-check.sh <plan-path> <state-file>` exits 0 when activation may proceed and 1 with a message on stderr naming what is missing when it may not. It prints a hash-mismatch note on stdout and still exits 0. It never modifies state.

Putting the check in its own script keeps the two entry points identical by construction — the alternative is the same twenty lines duplicated in a markdown command and a markdown skill, which is how the two seats drift.

The precondition sits immediately before `plan_set_field phase running` (`fight.md:51`, `adapters/codex/skills/spar-fight/SKILL.md:130`), after the existing phase and plan-file checks so its message is never the first thing a user sees when the real problem is a missing plan.

| Condition | Exit | Message |
|---|---|---|
| `plan_review` is `skipped` or absent | 0 | none |
| `--no-plan-review` was given at fight time | 0 | records `overridden`, says so |
| Result file missing, or first line is not a `PLAN-REVIEW:` marker | 1 | name the runner to run |
| `PLAN-REVIEW: CLEAN` | 0 | none |
| `PLAN-REVIEW: FINDINGS` and the response file is missing | 1 | name the response path and the finding ids |
| `FINDINGS` and any `PR<n>` has no matching response section | 1 | name the ids still needing one |
| Every finding dispositioned | 0 | none |
| Recorded hash differs from the plan's current hash | 0 | note the mismatch |

- [ ] **Step 1: Write the failing tests**

Create `tests/test_plan_review_check.sh` with the same harness shape as Task 2's suite. Fixtures, each asserting the exit status and the message:

```bash
mkresult() { printf 'PLAN-REVIEW: %s\n%s' "$1" "$2" > "reviews/spar-plan-${PRID}.md"; }
# Built with printf on one line ON PURPOSE. A heredoc or a quoted multi-line
# string would put `### PR1` at the start of a line in THIS PLAN, and the
# extractor that hands one task to an implementer splits on exactly that — it
# would deliver 33 lines of this task instead of all of it. Which is brief
# question 5, in the plan that specifies brief question 5.
F2="$(printf '### PR1 [BLOCKER] first\n- file: a.py:1\n- problem: p\n- suggestion: s\n\n### PR2 [SHOULD-FIX] second\n- file: b.py:2\n- problem: q\n- suggestion: t\n')"

# skipped → proceed
mkstate skipped; eqchk "skipped proceeds" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

# required, no result → refuse and name the runner
mkstate required; rm -f "reviews/spar-plan-${PRID}.md"
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "missing result refuses" "1" "$RC"
chk "and names the runner" "spar-run-plan-review.sh" "$OUT"

# a bad marker is not a review
mkstate required; printf 'STATUS: CONVERGED\n' > "reviews/spar-plan-${PRID}.md"
eqchk "a foreign marker refuses" "1" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

# CLEAN → proceed
mkstate required; mkresult CLEAN ''
eqchk "CLEAN proceeds" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

# FINDINGS with no response → refuse, naming both ids
mkstate required; mkresult FINDINGS "$F2"; rm -f .claude/spar-plan-review-response.md
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "findings without a response refuse" "1" "$RC"
chk "and name the first id" "PR1" "$OUT"
chk "and the second" "PR2" "$OUT"

# one of two dispositioned → still refuse, naming only the outstanding one
printf -- '### PR1: ACCEPTED — fixed the plan\n' > .claude/spar-plan-review-response.md
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "a partial response still refuses" "1" "$RC"
chk "and names the outstanding id" "PR2" "$OUT"
chk_absent "and not the answered one" "PR1" "$OUT"

# both dispositioned, one rejected → proceed
printf -- '### PR1: ACCEPTED — fixed\n### PR2: REJECTED — the cited line is a comment\n' \
  > .claude/spar-plan-review-response.md
eqchk "a grounded rejection clears a finding" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

# hash mismatch is a note, not a refusal
printf 'deadbeef\n' > .claude/spar-plan-review-hash
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "a changed plan still proceeds" "0" "$RC"
chk "and the change is reported" "changed since it was reviewed" "$OUT"
# control: the same fixture with a matching hash says nothing
git hash-object p.md > .claude/spar-plan-review-hash
chk_absent "an unchanged plan is not reported" "changed since it was reviewed" \
  "$(bash "$C" p.md "$ST" 2>&1)"
```

Add to `tests/test_stop_hook.sh`'s existing static checks of the Claude command, and to `tests/test_codex_adapter.sh`'s mirror checks, that both fight documents invoke the checker before setting the phase:

```bash
chk "/spar:fight gates on the plan review" 'spar-plan-review-check.sh' \
  "$(cat "$CLAUDE_PLUGIN_ROOT/commands/fight.md")"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_plan_review_check.sh`, `bash tests/test_stop_hook.sh`, `bash tests/test_codex_adapter.sh`
Expected: the checker suite cannot find the script; both static checks fail.

- [ ] **Step 3: Write the checker**

`plugins/spar/commands/spar-plan-review-check.sh`. Read `plan_review`, `plan_review_id` and the reviewer from the state. Parse finding ids from the result with a single awk pass on `^### PR[0-9]+`, and response ids with `^### PR[0-9]+:`, then report ids present in the first and absent from the second. Compare `git hash-object "$plan"` against the recorded hash and print the note when they differ.

Every refusal message must name the exact next action — the runner path, or the response path plus the outstanding ids. A precondition that says only "not allowed" is a lock without a key even when a key exists.

- [ ] **Step 4: Wire it into both entry points**

Immediately before `plan_set_field phase running`, in `fight.md` and in the Codex skill:

```bash
  PRCHK="${CLAUDE_PLUGIN_ROOT}/commands/spar-plan-review-check.sh"
  if [ "$SPAR_PLAN_REVIEW" = false ]; then
    plan_set_field plan_review overridden "$PLAN_STATE"
    echo "Note: starting without a plan review because --no-plan-review was given."
  elif [ -x "$PRCHK" ] && ! bash "$PRCHK" "$PLAN" "$PLAN_STATE"; then
    exit 1
  fi
```

`[ -x "$PRCHK" ]` is the fail-open: an installation whose checker is missing behaves as it did before this phase rather than refusing every plan. Use each document's own plugin-root variable — the Codex skill resolves `SPAR_ROOT` rather than `CLAUDE_PLUGIN_ROOT`.

- [ ] **Step 5: Run the tests to verify they pass**

Run all three suites, then the whole suite.
Expected: `FAIL=0` everywhere.

- [ ] **Step 6: Prove each part is independently caught**

Six scratch copies: remove the `FINDINGS` branch and confirm the no-response and partial-response checks fail; remove the id-comparison and confirm only the partial-response check fails; remove the marker validation and confirm the foreign-marker check fails; remove the hash comparison and confirm the mismatch check fails while the control still passes; remove the wiring from `fight.md` only, then from the Codex skill only, and confirm the matching static check fails each time.

- [ ] **Step 7: Record the decision and commit**

Add a Phase 9 section to `docs/design-decisions.md` replacing the "not yet designed" note: what was built, that enforcement is a `/spar:fight` precondition rather than a Stop-hook branch and why the hook branch was rejected, that the brief includes bounded design critique and why the first draft's exclusion was wrong, and that a plan edited after review is reported rather than re-reviewed — with the objection to that recorded, since an independent review argued the other way.

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
git add -A
git commit -m "feat(fight): refuse to start a plan whose review has not been cleared"
```

---

## Non-goals

- Any change to `stop-hook.sh` or `stop-fight.sh`. The first draft of the design put a `planned`-phase branch in the dispatcher; it was rejected because such a branch can only enforce that an artifact exists, not that its findings were acted on.
- Re-reviewing a plan the author edited after the review. Reported, not repeated — see the spec's non-goals for the objection this overrides and why.
- A retry counter. The author drives this pass, and a refusal that names the runner is a state they can act on.
- Requiring agreement. A grounded `REJECTED` clears a finding.
- Fixing `spar-report.sh`'s pre-existing `reviewer` fallback, which has the same shape as the `reviewer_version` defect fixed in the previous phase: a report asked for an older id can inherit the live state's reviewer family. Real, unrelated to this phase, and worth its own change.

## Verification this plan cannot do

Whether the pass changes outcomes. Two hand-run passes both returned a blocker, which is why this is being built, but two is not a rate. The comparison that would settle it needs plans executed with and without the pass, counted by rounds spent and by defects that predated the code, and those runs do not exist yet.

Whether requiring a disposition per finding produces reasoning or ritual. The check can verify a disposition is present and never that it is true. The loop has lived with that limit since Phase 1 on the same bet.
