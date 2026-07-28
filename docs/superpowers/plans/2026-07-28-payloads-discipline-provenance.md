# Dispatch Payloads, Author Discipline, and Run Provenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrow each dispatch's payload to the surface its recipient was told to inspect, tell the author *how* to fix rather than only *what*, and record which reviewer build produced a run — everywhere a human can see it.

**Architecture:** Three independent changes. The first narrows the diff surface the Claude-family runner receives, per role, without changing what any prompt asks for. The second adds a few lines to the block message the author reads on every findings round. The third adds one state field, written at the three places a loop is created, echoed by the outcome writer and surfaced in the run report. Nothing changes who declares convergence, how the judge and gate work, or any cap.

**Tech Stack:** POSIX-ish bash 3.2 (macOS default), awk, git. Tests are pure bash under `tests/`, driven with CLI stubs, and never invoke a real reviewer.

## Global Constraints

- The four invariants in `README.md:125-130` hold: single writer, reviewer-declares-convergence, deterministic enforcement with fail-open hooks, blind adjudication.
- Tests are pure bash in `tests/` and must never require a reviewer CLI on PATH. Where a test needs a CLI, it builds a stub and prepends it to `PATH`, as the suite already does elsewhere.
- Both seats behave identically. A change that works only under Claude Code or only under Codex is a defect, not a saving.
- Every behavioural change needs a test that fails when the change is reverted, **and each independently revertible part needs its own failing check**. Perform the revert and record which checks failed; do not assert that a test would catch it.
- A task body must contain no line beginning with `### ` — the extractor that hands one task to the implementer splits on exactly that.
- Historical claims in this plan about particular runs are **external observations** from the sessions of 2026-07-27 and 2026-07-28. They are recorded because they motivated the work; they are not re-derivable from the tree, and no step depends on them being checkable.
- `stop-hook.sh` is a surface both seats share, so the release gate applies before the release that carries this work: one live `/spar:fight` in Claude Code and one live `spar-fight` in Codex. That release is deferred until every remaining phase has landed, so it runs once.

---

### Task 1: Each dispatch sees the surface its prompt names, and no more

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` — the diff-surface write and `emit_runner` (`:712-758`), and its three call sites (`:968` reviewer, `:1048` judge, `:1113` matcher)
- Modify: `plugins/spar/shared/prompts/matcher.md:10-12` and `build_matcher`'s `{{TASK}}` substitution (`:1106-1109`)
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: nothing from the other tasks.
- Produces: `write_diff_surface [pathspec...]` — writes `$DIFF_SURFACE_FILE` from `git diff $BASE` and the untracked listing, limited to the given paths when any are given. And `emit_runner <runner> <prompt> <out> <role> [pathspec...]`, where role is `reviewer`, `judge` or `matcher`. The codex branch is untouched in both cases.

**This is a narrowing, not a removal.** An earlier draft proposed dropping the diff from the judge and matcher entirely. That is wrong: `judge.md:18-23` tells the judge to "inspect the code with `git diff {{DIFF_BASE}}`… If the changes are provided inline below, review those", and `matcher.md:6-8` says the same. The Claude family runs with `Read`, `Grep` and `Glob` and no shell, so the inline surface is the only way it can follow that instruction. Removing it would leave both with an instruction they cannot execute and no baseline at all — and current-file reads are not equivalent when the question turns on what changed, what was deleted, or which files are new.

What is genuinely wasteful is the *scope*. `emit_runner`'s claude branch builds the whole frozen-baseline diff for every role. The judge rules on one finding whose path the fingerprint carries; the matcher compares titles on a set of files it has already computed as overlapping. Each needs the diff **for its own paths**, which is what this task gives them. The prompts stay true and no baseline information relevant to the question is lost.

`matcher.md:10-12` separately carries `{{TASK}}`, which is a different matter: the matcher's question is whether two finding texts describe one defect on the same surface, and the task requirements do not bear on it. Under `/spar:fight --whole` that placeholder is the entire plan file.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_stop_hook.sh`, before the `PASS=`/`FAIL=` summary. Note the reviewer fixture is a **task-phase** state: a review-phase state with findings and no response blocks at `stop-hook.sh:1423-1440` without ever calling `prepare_round`, so no reviewer runner would exist.

```bash
# ── each dispatch sees the surface its prompt names ─────────────────────────
# The claude family has no shell, so the inline surface is the only way it can
# follow "inspect the code with git diff". The reviewer's question is the whole
# change; the judge's is one cited file; the matcher's is the overlapping set.
fresh_dir; write_state task 0; mkdir -p reviews
sed -i '' 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md
no_skip
printf 'one\n' > wanted.py
printf 'two\n' > unrelated.py
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
sed -i '' "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md
printf 'one\nchanged-in-wanted\n' > wanted.py
printf 'two\nchanged-in-unrelated\n' > unrelated.py
run_hook >/dev/null
chk "the reviewer surface carries the whole change" "changed-in-unrelated" \
  "$(cat .claude/spar-diff.txt)"
chk "and the reviewer's own file too" "changed-in-wanted" "$(cat .claude/spar-diff.txt)"

# The judge is dispatched on a finding citing wanted.py; the surface it is given
# must not carry unrelated.py's hunk.
fresh_dir; write_state review 1; mkdir -p reviews
sed -i '' 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md
printf 'one\n' > wanted.py; printf 'two\n' > unrelated.py
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
sed -i '' "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md
printf 'one\nchanged-in-wanted\n' > wanted.py
printf 'two\nchanged-in-unrelated\n' > unrelated.py
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] wanted.py off by one\n- file: wanted.py:1\n- problem: p\n- suggestion: s\n' > "$RFa"
printf -- '### F1-1: REJECTED — no\n' > "$RPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [MECHANICAL] wanted.py off by one\n- file: wanted.py:1\n- problem: p\n- suggestion: s\n' > "$RFb"
printf -- '### F2-1: REJECTED — still no\n' > "$RPb"
run_hook >/dev/null
chk_file "judge dispatched" .claude/spar-run-judge.sh
chk "the judge surface carries the cited file" "changed-in-wanted" "$(cat .claude/spar-diff.txt)"
chk "the judge surface omits an unrelated file" "absent" \
  "$(grep -qF 'changed-in-unrelated' .claude/spar-diff.txt && echo present || echo absent)"

# The matcher is dispatched on an overlap of mod.py; other.py must not ride along.
fresh_dir; write_state review 1; mkdir -p reviews
sed -i '' 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md
printf 'a\n' > mod.py; printf 'b\n' > other.py
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
sed -i '' "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md
printf 'a\nchanged-in-mod\n' > mod.py
printf 'b\nchanged-in-other\n' > other.py
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] mod.py is wrong\n- file: mod.py:1\n- problem: p\n- suggestion: s\n' > "$RFa"
printf -- '### F1-1: REJECTED — no\n' > "$RPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [MECHANICAL] mod.py stops early\n- file: mod.py:1\n- problem: p\n- suggestion: s\n' > "$RFb"
printf -- '### F2-1: REJECTED — no\n' > "$RPb"
run_hook >/dev/null
chk_file "matcher dispatched" .claude/spar-run-matcher.sh
chk "the matcher surface carries the overlapping file" "changed-in-mod" \
  "$(cat .claude/spar-diff.txt)"
chk "the matcher surface omits a file with no overlap" "absent" \
  "$(grep -qF 'changed-in-other' .claude/spar-diff.txt && echo present || echo absent)"

chk "matcher.md names no task placeholder" "absent" \
  "$(grep -qF '{{TASK}}' "$ROOT/plugins/spar/shared/prompts/matcher.md" && echo present || echo absent)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: the two "omits" checks FAIL (today every role gets the whole surface) and the matcher-template check FAILS. The four "carries" checks and both dispatch checks must already PASS — they are the controls that show nothing is losing the context it needs, and if any of them fails before the change the fixture is wrong, not the engine.

- [ ] **Step 3: Extract the surface writer with an optional pathspec**

Today the surface is built inline inside `emit_runner`'s claude branch (`:715-718`). Lift it out, above `emit_runner`:

```bash
# The change surface handed to a claude-family runner, which has no shell and so
# cannot run git itself. With no pathspec this is the whole frozen-baseline
# change; with one it is that change restricted to the given paths, which is
# what a judge ruling on one cited file or a matcher comparing one overlapping
# set actually needs. The prompts tell both to inspect the diff, so the answer
# is to narrow it, not to withhold it.
write_diff_surface() { # $@ = optional pathspec
  { echo "# Changes under review (git diff ${BASE}):"
    if [ "$#" -gt 0 ]; then git diff "${BASE}" -- "$@" 2>/dev/null
    else                    git diff "${BASE}" 2>/dev/null; fi
    echo; echo "# Untracked files:"
    if [ "$#" -gt 0 ]; then git status --porcelain --untracked-files=all -- "$@" 2>/dev/null
    else                    git status --porcelain --untracked-files=all 2>/dev/null; fi
  } > "$DIFF_SURFACE_FILE"
}
```

- [ ] **Step 4: Give `emit_runner` a role and a pathspec**

Change the signature, and call the writer **inside the existing claude-family branch** so a codex dispatch still writes no surface at all:

```bash
emit_runner() { # $1=runner  $2=prompt  $3=out  $4=role  $5.. = optional pathspec
  local runner="$1" pf="$2" out="$3" role="${4:-reviewer}"
  shift 4 2>/dev/null || shift $#
  local ecoflags; ecoflags="$(economics_flags "$REVIEWER")"
  if [ "$REVIEWER" = "claude" ]; then
    write_diff_surface "$@"
    ...
```

Only the pathspec changes per role; the branch structure and the codex arm stay exactly as they are. Update the comment inside the generated claude runner (`:721-724`) so it says the runner is fed the change surface **for the paths this dispatch concerns**, rather than implying it is always the whole diff.

- [ ] **Step 5: Pass the role and the paths at each call site**

- `:968` (`prepare_round`) → `emit_runner "$RUNNER" "$PROMPT_FILE" "$out" reviewer` — no pathspec, the whole change.
- `:1048` (`prepare_judge`) → the fingerprint's file part is `${fp%% | *}`, the same expression `gate_finding_text`'s neighbours use at `:1085` and `:1096`. Compute it into a local and pass it: `emit_runner "$JUDGE_RUNNER" "$JUDGE_PROMPT_FILE" "$out" judge "$jfile"`. When the fingerprint has an empty file part — a finding with no location, which the grammar preserves — pass no pathspec, so the judge falls back to the whole surface rather than to nothing.
- `:1113` (`build_matcher`) → `$overlap` (`:1022` in that function) is the newline-separated list of overlapping files already computed for the prefilter. Pass its entries as separate arguments, guarding against an empty list the same way.

- [ ] **Step 6: Drop the task from the matcher prompt**

In `plugins/spar/shared/prompts/matcher.md`, delete the `## Task the author was given` heading and the `{{TASK}}` line beneath it. Remove the matching substitution inside `build_matcher` (`:1106-1109`) — it is the fourth of four identical `{{TASK}}` substitutions in the engine, so identify it by the function it sits in, not by the string. Leave `{{NEW_FINDINGS}}` and `{{EXISTING}}` untouched.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL=0`.

- [ ] **Step 8: Prove each part is independently caught**

Four scratch copies, because four things can be reverted separately:
1. Drop the pathspec from the judge call site only → the judge "omits" check must fail and the matcher's must not.
2. Drop it from the matcher call site only → the reverse.
3. Make `write_diff_surface` ignore its arguments → both "omits" checks fail.
4. Restore `{{TASK}}` to `matcher.md` → the template check fails.

Also confirm in each copy that the four "carries" controls still pass; if narrowing ever drops the file the dispatch is *about*, that is the failure that matters most.

- [ ] **Step 9: Run every suite and commit**

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
git add -A
git commit -m "perf(engine): narrow the judge's and matcher's diff surface to the paths they were asked about"
```

---

### Task 2: The author is told how to fix, not only what

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh:1434` — the block message demanding a response
- Modify: `plugins/spar/shared/policy.md:43-47` — protocol item 4
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: three lines of advice in the block message the author reads on every findings round. Advice only — the response file's required shape is unchanged and the hook checks nothing new.

The block message says only "fix every `[MECHANICAL]` finding, decide each `[DESIGN]` finding, write the response file". Nothing tells the author how. Each discipline below is traced to a finding that cost a round in the sessions of 2026-07-27 and 2026-07-28 (external observations, per the Global Constraints):

- **Undo the fix and check which tests fail.** Four defects shipped because this was skipped: a substring assertion that passed for every value; a mutation that caught nothing because the fixture could not discriminate between two line-counting methods; an `env -u` correction no test could observe; and a rewrite whose new control flow was never mutated, which emitted every non-final finding twice.
- **Find every place the changed rule is written down.** A fix updated the code and left three documents describing the old rule; the correction for that then missed a fourth. Two documentation claims survived a rewrite and contradicted the code beside them.
- **When narrowing a definition, narrow all of it.** "Location is not empty" let a bare path through when the contract is `file:line`. Twice in one task a rewrite turned a rejection into an acceptance.

Keep it short — this is read on every findings round and becomes wallpaper if it is long. Do **not** make it a required response field: the hook can check such a field is present but never that it is true, and that decision is deferred until the advice has been observed.

- [ ] **Step 1: Capture the baseline size, then write the failing tests**

Before editing anything, record what the message costs today, because Step 5 compares against it:

```bash
cd "$(mktemp -d)" && git init -q && mkdir -p .claude reviews
# …minimal review-phase state with one finding and no response…
echo '{}' | bash "$OLDPWD/plugins/spar/hooks/stop-hook.sh" | jq -r '.reason' | wc -c
```

Record the number. Then add to `tests/test_stop_hook.sh`:

```bash
# ── the author is told how to fix ───────────────────────────────────────────
# Advice, not a required field. The behavioural control below is what proves the
# response contract did not change: an ordinary FIXED response must still be
# accepted and still advance the round.
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] off by one\n- file: a.py:10\n- problem: p\n- suggestion: s\n' > "$RF1"
OUT=$(run_hook)
chk "the fix message names the revert check" "Undo your fix" "$OUT"
chk "the fix message names the every-place check" "every place" "$OUT"
chk "the fix message names the whole-definition check" "narrow all of it" "$OUT"
printf -- '### F1-1: FIXED — did it\n' > "$RP1"
OUT=$(run_hook)
chk "an ordinary response is still accepted and advances the round" 'round 2' "$OUT"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: the first three checks FAIL. The fourth already passes and must keep passing — it is the control, and it is behavioural rather than a search for a phrase.

- [ ] **Step 3: Extend the block message**

Append to the existing reason string, after "Then stop again." and before `${BRIEF_NOTE}`:

```
Three things this loop has paid for repeatedly, each worth the minute it costs:

- Undo your fix and check which tests fail. A test that passes either way is
  not testing the fix.
- Find every place the rule you changed is written down — the code, the comment
  above it, the docs, and the other seat's copy where one exists. One place
  fixed and another left stale reads as a contradiction next round.
- If you narrowed a definition, narrow all of it. "Not empty" and "well formed"
  are different rules.
```

"where one exists" matters: the engine is shared between seats, and only the command and skill documents are mirrored.

- [ ] **Step 4: Record it in the protocol, and repair the sentence while there**

`policy.md:43-47`'s item 4 currently reads "…which is why item 6 has a MECHANICAL stalemate path at all; and write a response file…" — a clause that lost its subject in an earlier edit. Repair it, and add one sentence: the author is given fix guidance in the block message; it is advice rather than an enforced field, because the hook can verify such a field is present but never that it is true, and the next round re-reviews the fix either way.

- [ ] **Step 5: Run the tests, then measure the cost**

Run: `bash tests/test_stop_hook.sh` — expected `FAIL=0`.

Re-run the Step 1 measurement and compare. Put **both** numbers in the commit message below, replacing the placeholders. If the addition more than doubles the message, cut wording rather than dropping a discipline.

- [ ] **Step 6: Run every suite and commit**

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
git add -A
git commit -m "feat(loop): tell the author how to fix, not only what to fix

The findings-round block message grew from <BEFORE> to <AFTER> bytes."
```

---

### Task 3: A run records which reviewer build produced it, where a human can see it

**Files:**
- Modify: `plugins/spar/commands/spar-record-outcome.sh`
- Modify: `plugins/spar/commands/spar-fight-launch.sh`, `plugins/spar/commands/fight.md`, `adapters/codex/skills/spar-fight/SKILL.md` — the three places a loop state is created
- Modify: `plugins/spar/commands/spar-report.sh` — so the field reaches the user
- Modify: `README.md:87-89`
- Test: `tests/test_record_outcome.sh`, `tests/test_fight_launch.sh`, `tests/test_stop_hook.sh`, `tests/test_codex_adapter.sh`, `tests/test_spar_report.sh`

**Interfaces:**
- Consumes: nothing from Tasks 1 or 2.
- Produces: `reviewer_version:` in the loop state, written at activation by all three entry points; echoed by the outcome writer; shown by `/spar:report`. Absent or unreadable becomes `unknown` and never fails a run.

A run records `reviewer: codex` and nothing about which build did the reviewing. On 2026-07-28 the same CLI, on the same code, produced one finding on the build installed weeks earlier and three to four on the current one — and the version string changed twice inside one working session. Without the field, no later reader can tell one baseline from another.

**Name the claim honestly.** This records the version *observed at activation*. A CLI that updates mid-run will have performed some rounds under a version this does not name. Capturing at activation is still the right trade — it is one call instead of one per dispatch — but the field means "the build this run started with", and the documentation must say that rather than "the build that performed the reviews".

`hard_cap` is a separate, smaller correction. `README.md:89` tells the user to "set the `hard_cap` state field to override", and no supported entry point writes it while `fight.md:175` forbids hand-editing the state file. But the engine **does** honour an explicit value (`stop-hook.sh:201-217`) and tests depend on that (`tests/test_stop_hook.sh:1390-1398`), so the fix is to say there is no supported override and that generated runs use twice `max_rounds` — **not** that the value is fixed. `policy.md:61` already states only the default; confirm and leave it.

- [ ] **Step 1: Write the failing tests**

Sanitisation must happen at activation as well as in the writer, because the state file is the first thing a raw version string reaches. Test it where the forgery would land.

In `tests/test_fight_launch.sh`, which drives the launcher as `$L`, build stubs rather than trusting the developer's PATH:

```bash
STUBS=$(mktemp -d)
printf '#!/bin/sh\necho "codex-cli 9.9.9-test"\n' > "$STUBS/codex"; chmod +x "$STUBS/codex"
( PATH="$STUBS:$PATH"; bash "$L" "$ST" .claude/task.txt >/dev/null 2>&1 )
chk "launch records the reviewer build it saw" 'reviewer_version: codex-cli 9.9.9-test' \
  "$(cat .claude/spar.local.md)"
# A version string is third-party output. It must not be able to forge a field.
printf '#!/bin/sh\nprintf "v1\\nreviewer: claude\\n"\n' > "$STUBS/codex"; chmod +x "$STUBS/codex"
( PATH="$STUBS:$PATH"; bash "$L" "$ST" .claude/task.txt >/dev/null 2>&1 )
eqchk "a multi-line version cannot forge a second reviewer line" "1" \
  "$(grep -c '^reviewer:' .claude/spar.local.md)"
```

In `tests/test_record_outcome.sh` (`fresh()` writes a default state, so overwrite it; the writer is `$WRITER`):

```bash
fresh
printf -- '---\nactive: true\nphase: review\nround: 3\nreview_id: 20260728-100000-abc123\nreviewer: codex\nreviewer_version: codex-cli 9.9.9-test\n---\n' > .claude/spar.local.md
bash "$WRITER" converged .claude/spar.local.md clean
chk "outcome records the reviewer build" "reviewer_version: codex-cli 9.9.9-test" \
  "$(cat reviews/spar-20260728-100000-abc123-outcome.md)"

fresh
printf -- '---\nactive: true\nphase: review\nround: 3\nreview_id: 20260728-100001-abc124\nreviewer: codex\n---\n' > .claude/spar.local.md
bash "$WRITER" converged .claude/spar.local.md clean
chk "a missing version is recorded as unknown" "reviewer_version: unknown" \
  "$(cat reviews/spar-20260728-100001-abc124-outcome.md)"

# Control characters in the stored value must not reach the outcome file.
fresh
printf -- '---\nactive: true\nphase: review\nround: 3\nreview_id: 20260728-100002-abc125\nreviewer: codex\nreviewer_version: v1\033[31m: forged\n---\n' > .claude/spar.local.md
bash "$WRITER" converged .claude/spar.local.md clean
chk_absent "an escape sequence is stripped from the outcome" "$(printf '\033')" \
  "$(cat reviews/spar-20260728-100002-abc125-outcome.md)"
```

The two seat-specific activation blocks are static text, so assert on them the way `tests/test_codex_adapter.sh:231-243` already asserts on mirror surfaces. Add to `tests/test_codex_adapter.sh` a check that the fight skill's state block emits `reviewer_version:`, and to `tests/test_stop_hook.sh`'s existing static checks of the Claude command (`:134-137`) the same for `fight.md`.

- [ ] **Step 2: Run the tests to verify they fail**

Run each named suite. Expected failures: both launcher checks, the first and second outcome checks, the escape-sequence check, and both static seat checks. **The "missing version is not an error" property is not asserted separately** — the writer already exits 0 on an absent field, so a check for that would pass before the change and prove nothing; the `unknown` assertion is what carries it.

- [ ] **Step 3: Write one sanitiser and use it in both places**

The value is third-party output written into YAML-ish frontmatter. Bound it to printable ASCII on one line:

```bash
# A version string comes from a third-party CLI and is written into frontmatter
# that later readers parse line-by-line. Anything outside printable ASCII — a
# newline that would forge a field, a tab, a terminal escape — is dropped rather
# than quoted, because every consumer of this value only ever displays it.
sanitise_version() { # $1=raw → one bounded printable line
  printf '%s' "$1" | tr -d '\000-\037\177' | LC_ALL=C tr -cd '\040-\176' | cut -c1-120
}
```

Place it in `spar-record-outcome.sh` and inline the same three-command pipeline at each activation site — a shared file would be a new dependency for three scripts that currently share only `spar-plan-lib.sh`, and the pipeline is short enough to repeat. Whichever way, **the activation sites and the writer must apply the same normalisation**; a test above pins each.

In the writer, beside `reviewer=$(field reviewer)` (`:23`):

```bash
reviewer_version=$(sanitise_version "$(field reviewer_version)")
[ -n "$reviewer_version" ] || reviewer_version=unknown
```

and emit `echo "reviewer_version: ${reviewer_version}"` immediately after the `reviewer:` line (`:53`).

- [ ] **Step 4: Capture it at activation, in all three entry points**

In `spar-fight-launch.sh`, before the state heredoc:

```bash
# Best-effort and one call per run: a CLI that will not report a version must
# not stop a run, and this is the version the run STARTED with — a CLI that
# updates mid-run will have done some rounds under a build this does not name.
reviewer_version="$("$reviewer" --version 2>/dev/null | head -1 \
  | tr -d '\000-\037\177' | LC_ALL=C tr -cd '\040-\176' | cut -c1-120)"
[ -n "$reviewer_version" ] || reviewer_version=unknown
```

and add `reviewer_version: ${reviewer_version}` to the emitted frontmatter. Make the same two changes in `fight.md`'s setup block and in `adapters/codex/skills/spar-fight/SKILL.md`'s state heredoc, using `$SPAR_REVIEWER` as those files already do.

- [ ] **Step 5: Surface it in the run report**

`spar-report.sh` reads `reviewer` from the outcome (`:78`) and folds it into a pairing string (`:90-94`) that is all the report ever shows of either seat. The report is the user-facing record of a run, so a provenance field it omits is a field nobody sees. Read `reviewer_version` the same way, default it to `unknown`, and print it beside the pairing. Add a matching assertion to `tests/test_spar_report.sh`.

- [ ] **Step 6: Correct the README**

Replace `README.md:89`'s "set the `hard_cap` state field to override" with a statement that generated runs use twice `max_rounds` and there is no supported user override. Do not write that the value is fixed — the engine honours an explicit one and `tests/test_stop_hook.sh:1390-1398` depends on it. Confirm `policy.md:61` claims only the default and leave it alone.

- [ ] **Step 7: Run the tests to verify they pass**

Run all five named suites. Expected `FAIL=0` in each.

- [ ] **Step 8: Prove each part is independently caught**

Five scratch copies:
1. Remove the `|| reviewer_version=unknown` fallback in the writer → the `unknown` check fails.
2. Remove the `tr` pipeline from the **launcher** only → the forged-`reviewer:` check fails and the outcome escape check does not.
3. Remove `sanitise_version` from the **writer** only → the escape check fails and the launcher check does not.
4. Remove the field from `fight.md` only, then from the Codex skill only → the corresponding static check fails each time and the launcher checks stay green.
5. Remove the report line → the `test_spar_report.sh` assertion fails.

- [ ] **Step 9: Run every suite and commit**

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
git add -A
git commit -m "feat(outcome): record the reviewer build a run started with, and stop documenting an override nobody has"
```

---

## Non-goals

- Phase 9, the independent review of a plan before it is executed. It was performed by hand for this plan and the one before it, and caught a blocker each time, which strengthens the case for building it — but building it is its own design.
- Re-measuring the sweep, the matcher trigger, or the every-round full re-read. Their justification rests on runs of an older reviewer CLI. The `reviewer_version` field this plan adds is what will make a re-measurement interpretable; the re-measurement itself needs runs that do not exist yet.
- Making the author's verification a required response field. Deferred until the Task 2 advice has been observed against a baseline.
- Rewriting `judge.md` or `matcher.md` to judge from current files rather than a diff. Task 1 narrows the surface so those prompts stay true; changing what they ask for is a separate decision with its own evidence burden.
- Updating the installed plugin, or releasing. Both are held until every remaining phase has landed so the gate runs once.

## Verification this plan cannot do

Whether the Task 2 advice lowers the round count. The prior baseline — 29 runs at 3.2 reviewer rounds each — was measured against a reviewer CLI the project no longer targets, and the runs since are too few and too varied to replace it. A new baseline has to accumulate, and the `reviewer_version` field from Task 3 is what will let anyone tell one baseline from another.

Whether narrowing the judge's and matcher's surface changes their verdicts. It cannot be measured here: the judge has been dispatched successfully once, and the matcher's inputs already restricted it to overlapping files, so the narrowing is expected to be information-neutral for both. If a later judge ruling turns on something outside the cited file, that is the evidence that this was too narrow.
