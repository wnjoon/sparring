# Final Report at Every Terminal Path + Docs Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate the final run report at *every* Stop-hook terminal path — not just `converged` — and bring the docs in line with what actually ships.

**Architecture:** The generator (`plugins/spar/commands/spar-report.sh`) is already terminal-reason-agnostic: it reads the reason from `reviews/spar-<id>-outcome.md`. `stop-hook.sh` already has the fail-open `generate_report()` helper. So this is three added call sites — `cap`, `sweep-findings-at-cap`, `skipped` — each immediately after that path's `record_outcome`, where the ledger and registry are still on disk (those paths `deactivate_state` and `block`; `cleanup()` only runs on the following stop). No new script, no change to any decision, no new phase.

**Tech Stack:** POSIX-ish bash (Claude Code plugin hook + scripts), pure-bash test scripts under `tests/`.

**Why this now:** the report exists to summarize a run, and the runs a human most needs summarized are the ones that did *not* converge. This branch's own predecessor task ended at the round cap and produced no report — the five-round history had to be reconstructed by hand. `converged`-only was the report spec's deliberate v1 scope; this plan closes it.

**Source specs:**
- `docs/superpowers/specs/2026-07-24-spar-report-design.md` §Scope — "extending to `cap`, `sweep-findings-at-cap`, or `skipped` is a one-line change at those terminal paths — deferred." This plan does exactly that and updates the spec.
- `docs/design-decisions.md` §Phase 5 — the report-delivery decision record.

**Predecessor branches (already on this branch's history):** the generator and `/spar:report` shipped via `docs/superpowers/plans/2026-07-25-spar-report.md` (Task 1) and `…-spar-report-remaining.md` (Tasks 1-4).

---

## Global Constraints

- **Fail-open, always.** `generate_report()` is best-effort by contract: a missing, non-executable, or failing generator logs and continues. Adding call sites must not change that, and must not alter any block message, decision, phase, or outcome.
- **Order is load-bearing:** at every path the sequence must be `record_outcome …` → `generate_report` → (`deactivate_state` / `cleanup`). The generator reads the outcome file (so it must exist) and the ledger + registry (so cleanup must not have run). At `cap`, `sweep-findings-at-cap`, and `skipped` the hook calls `deactivate_state` then `block` — `cleanup()` happens on the *next* stop via the `active != true` branch — so inserting after `record_outcome` satisfies both.
- **Do not touch the change-surface code** (`changed_files`, `dir_prefix`, `dir_is_cwd`, `untracked_files`, `CWD_REV` / `CWD_STATE`). It consumed five review rounds already; it is finished. A finding there is out of scope for this plan.
- **`cancelled` is deliberately excluded.** It is written by `plugins/spar/commands/cancel.md`, a command file with no test harness, and the user is present by definition when they cancel. Recorded as a non-goal rather than silently skipped.
- **No plugin version bump / release commit.** `plugin.json` stays at `0.5.0`; versioning is a separate release step.
- **Test harness detail:** `tests/test_stop_hook.sh`'s `chk` calls `grep -qF "$2"` **without** `--`, so no expectation there may start with `-`. `tests/test_spar_report.sh`'s `chk` uses `grep -qF -- "$2"`.
- **Style:** `stop-hook.sh` keeps its existing no-`set` style and ERR trap. Never write `[ cond ] && cmd` as a function's last statement there — use `if … fi`.

---

### Task 1: Generate the report at `cap`, `sweep-findings-at-cap`, and `skipped`

Add the three call sites and pin each with a test. Also pin the executable bit the `[ -x "$REPORT_GEN" ]` gate depends on — the final sweep of the previous task flagged that a lost mode bit would silently disable reports with no test failing.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` (three one-line insertions: after `record_outcome cap` at ~line 1083, after `record_outcome sweep-findings-at-cap findings` at ~line 1156, after `record_outcome skipped not-triggered` at ~line 812)
- Test: `tests/test_stop_hook.sh` (append a section before the trailing PASS/FAIL lines)
- Test: `tests/test_spar_report.sh` (one executable-bit assertion)

**Interfaces:**
- Consumes: `generate_report()` — the existing no-argument fail-open helper in `stop-hook.sh` (added by the predecessor plan), which uses `REVIEW_ID` and `BASE` and always returns 0.
- Produces: no new interface. After this task `reviews/spar-<id>-report.md` exists for `converged`, `blocked-pending-user`, `cap`, `sweep-findings-at-cap`, and `skipped`.

- [x] **Step 1: Write the failing test**

Append to `tests/test_stop_hook.sh`, immediately before the final `echo; echo "PASS=$PASS FAIL=$FAIL"` and `exit "$FAIL"` lines. It reuses that file's existing `chk`, `chk_file`, `fresh_dir`, `write_state`, `run_hook` helpers and the `RPT` variable defined by the Phase 5 report block above it:

```bash
# ── Phase 5 follow-up: a report at every terminal path, not just converged ──

# T1. round cap → report generated, and it is honest about the reason
fresh_dir; write_state review 5; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] off by one\n- file: a.py:1\n- problem: p\n- suggestion: s\n' \
  > reviews/spar-20260721-120000-abc123-r5.md
printf '### F5-1: REJECTED — intended\n' > reviews/spar-20260721-120000-abc123-r5-response.md
OUT=$(run_hook)
chk "cap → still blocks with the unconverged notice" 'unconverged' "$OUT"
chk_file "cap → report generated" "$RPT"
chk "cap report names the cap outcome" "outcome: cap" "$(cat "$RPT" 2>/dev/null)"
chk "cap report carries the round count" "rounds: 5" "$(cat "$RPT" 2>/dev/null)"
chk "cap report tallies the unresolved finding" "rejected: 1" "$(cat "$RPT" 2>/dev/null)"

# T2. the cap report is written BEFORE cleanup, so the ledger survives into it
fresh_dir; write_state review 5; mkdir -p reviews
printf '# decisions\n\n### P1: keep the flag — it is published\n' > .claude/spar-ledger.md
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] off by one\n- file: a.py:1\n- problem: p\n- suggestion: s\n' \
  > reviews/spar-20260721-120000-abc123-r5.md
printf '### F5-1: REJECTED — intended\n' > reviews/spar-20260721-120000-abc123-r5-response.md
run_hook >/dev/null
chk "cap report captured the ledger decision" "#### P1: keep the flag" "$(cat "$RPT" 2>/dev/null)"
chk "cap report survives the deactivated-loop cleanup" "present" \
  "$(run_hook >/dev/null; [ -f "$RPT" ] && echo present || echo absent)"

# T3. sweep findings at the cap → report generated with the sweep recorded
fresh_dir; write_state review 5; mkdir -p reviews
sed -i '' 's/^phase: review/phase: sweep/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^phase: review/phase: sweep/' .claude/spar.local.md
printf 'SWEEP: FINDINGS\n\n### S-1 [MECHANICAL] missing test\n- file: a.py:1\n- problem: p\n- suggestion: s\n' \
  > reviews/spar-20260721-120000-abc123-sweep.md
OUT=$(run_hook)
chk "sweep findings at cap → still blocks" 'at cap' "$OUT"
chk_file "sweep-findings-at-cap → report generated" "$RPT"
chk "report names the sweep-findings-at-cap outcome" "outcome: sweep-findings-at-cap" \
  "$(cat "$RPT" 2>/dev/null)"
chk "report records the sweep result" "sweep: findings" "$(cat "$RPT" 2>/dev/null)"
chk "report lists the sweep finding" "S-1 [MECHANICAL] missing test" "$(cat "$RPT" 2>/dev/null)"

# T4. safe skip → report generated (no rounds ran, so the tally is empty but honest)
# Reuses this file's existing `skip_repo` helper (test 4d): the skip path needs a
# REAL base_sha, because the change classifier must be able to diff against it —
# write_state's placeholder base_sha would make the classifier fail and disable
# the skip entirely. skip_repo also gives the report a usable diff baseline.
skip_repo
printf 'safe\n' >> tracked.txt
OUT=$(run_hook)
chk "small safe change → skip reported" 'skipped' "$OUT"
chk_file "skipped → report generated" "$RPT"
chk "skip report names the skipped outcome" "outcome: skipped" "$(cat "$RPT" 2>/dev/null)"
chk "skip report has no findings to tally" "No findings were raised." "$(cat "$RPT" 2>/dev/null)"
chk "skip report lists the changed file" "tracked.txt" "$(cat "$RPT" 2>/dev/null)"

# T5. fail-open at a non-converged path: a failing generator never changes the block
fresh_dir; write_state review 5; mkdir -p reviews
ln -s /dev/null "$RPT"
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] off by one\n- file: a.py:1\n- problem: p\n- suggestion: s\n' \
  > reviews/spar-20260721-120000-abc123-r5.md
printf '### F5-1: REJECTED — intended\n' > reviews/spar-20260721-120000-abc123-r5-response.md
OUT=$(run_hook)
chk "failing generator at cap → block text unchanged" 'unconverged' "$OUT"
chk "failing generator at cap → outcome still recorded" "reason: cap" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
```

Also append this one assertion to `tests/test_spar_report.sh`, before its trailing PASS/FAIL lines (the `[ -x "$REPORT_GEN" ]` gate in the hook silently disables reports if the bit is lost):

```bash
# ── 25. the generator must stay executable — the hook gates on [ -x ] ──
chk "generator is executable" "yes" "$([ -x "$GEN" ] && echo yes || echo no)"
chk "display resolver is executable" "yes" \
  "$([ -x "$ROOT/plugins/spar/commands/spar-report-show.sh" ] && echo yes || echo no)"
```

- [x] **Step 2: Delete the test that asserted the opposite**

`tests/test_stop_hook.sh` already contains `R3`, added when the report was scoped
to converged runs only. It asserts the cap path writes **no** report, which this
task deliberately reverses — leaving it in means the suite fails by design. Delete
the whole block (T1 above replaces it with the correct expectation):

```bash
# R3. round cap → no report (scope: converged only for now)
fresh_dir; write_state review 5; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] t\n- file: a.py:1\n- problem: p\n- suggestion: s\n' \
  > reviews/spar-20260721-120000-abc123-r5.md
printf '### F5-1: FIXED — done\n' > reviews/spar-20260721-120000-abc123-r5-response.md
run_hook >/dev/null
chk "cap → no report (out of scope)" "absent" "$([ -f "$RPT" ] && echo present || echo absent)"
```

Do not weaken it into a report-exists check — T1 already covers the cap path with
richer assertions, and two fixtures for one path would drift apart.

- [x] **Step 3: Run the tests to verify they fail**

```bash
bash tests/test_stop_hook.sh
bash tests/test_spar_report.sh
```
Expected: the new `T1`-`T4` report checks FAIL (`… report generated` reports the file missing) because no call site exists yet. `T5` and the two executable-bit checks may already pass; that is fine. Every pre-existing check must still pass.

- [x] **Step 4: Add the three call sites**

In `plugins/spar/hooks/stop-hook.sh`, at the round-cap path, change:

```bash
      log "round cap ${MAX_ROUNDS} reached — unconverged exit"
      record_outcome cap
      deactivate_state
```

to:

```bash
      log "round cap ${MAX_ROUNDS} reached — unconverged exit"
      record_outcome cap
      # An unconverged run is exactly the one a human needs summarized. Safe here:
      # this path only deactivates and blocks, so cleanup() (and with it the
      # ledger and registry the report reads) has not run yet.
      generate_report
      deactivate_state
```

At the sweep-findings-at-cap path, change:

```bash
      set_sweep_state true findings
      record_outcome sweep-findings-at-cap findings
      deactivate_state
```

to:

```bash
      set_sweep_state true findings
      record_outcome sweep-findings-at-cap findings
      generate_report
      deactivate_state
```

At the safe-skip path, change:

```bash
          record_outcome skipped not-triggered
          deactivate_state
```

to:

```bash
          record_outcome skipped not-triggered
          generate_report
          deactivate_state
```

- [x] **Step 5: Run the tests to verify they pass**

```bash
bash tests/test_stop_hook.sh
bash tests/test_spar_report.sh
```
Expected: `FAIL=0` for both.

- [x] **Step 6: Run the whole suite**

```bash
for t in tests/test_*.sh; do printf '%-34s ' "$t"; bash "$t" >/dev/null 2>&1 && echo OK || echo FAILED; done
```
Expected: every line `OK`.

- [x] **Step 7: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh tests/test_stop_hook.sh tests/test_spar_report.sh
git commit -m "feat: generate the final report at every terminal path, not just converged"
```

---

### Task 2: Sync the docs to what actually ships

Every doc that scopes the report to `converged`, or still calls Phase 5 unimplemented, is now wrong. Fix each one, and leave the two superseded plan documents honest about their own state.

**Files:**
- Modify: `plugins/spar/shared/policy.md` (§Protocol item 10; §Phase roadmap)
- Modify: `README.md` (implemented-phases sentence, feature bullet, v0.5.0 ship sentence)
- Modify: `plugins/spar/commands/fight.md` (the report hint — non-converged runs get one too)
- Modify: `docs/superpowers/specs/2026-07-24-spar-report-design.md` (§Scope, §Terminal state, the open-questions heading)
- Modify: `docs/design-decisions.md` (§Phase 5 report-delivery bullet)
- Modify: `docs/superpowers/plans/2026-07-25-spar-report.md` (status note — its Task 1 shipped, Tasks 2-5 were superseded)

**Interfaces:** documentation only. No code, no tests. The claims below must match Task 1's behavior exactly: a report is written for `converged`, `blocked-pending-user`, `cap`, `sweep-findings-at-cap`, and `skipped`; `cancelled` has none.

- [x] **Step 1: Update `policy.md`**

In `plugins/spar/shared/policy.md` §Protocol, replace item 10's opening:

```markdown
10. A run that converges (and an unattended run that stops at
    `blocked-pending-user`) also gets an informational report,
    `reviews/spar-<id>-report.md`: outcome, rounds, reviewer pairing, sweep
```

with:

```markdown
10. Every terminal that ends a real review — `converged`, `blocked-pending-user`,
    `cap`, `sweep-findings-at-cap`, and `skipped` — also gets an informational
    report, `reviews/spar-<id>-report.md`, since an unconverged run is exactly the
    one a human needs summarized. (`error-bypass` and `cancelled` get none: a
    bailout has no run story, and a cancelling user is already present.) It
    carries: outcome, rounds, reviewer pairing, sweep
```

Then in §Phase roadmap, replace:

```markdown
Phases 1–4 (implemented): core loop; design findings, blind judge, gate,
decision ledger, semantic matcher; same-family Claude review; safe skip,
changed-surface intent harvest, durable outcomes, and final sweep.
Phase 5: unattended mode + final report. Phase 6: Codex-hosted adapter (git
pre-commit enforcement). Phase 7: model economics (reviewer/effort config,
tiered fix writers).
```

with:

```markdown
Phases 1–5 (implemented): core loop; design findings, blind judge, gate,
decision ledger, semantic matcher; same-family Claude review; safe skip,
changed-surface intent harvest, durable outcomes, and final sweep; unattended
mode and the final run report (`/spar:report`).
Phase 6: Codex-hosted adapter (git pre-commit enforcement). Phase 7: model
economics (reviewer/effort config, tiered fix writers).
```

- [x] **Step 2: Update `README.md`**

Replace the implemented-phases sentence:

```markdown
Phases 1–4 are implemented; the core loop is verified end-to-end against real reviewers — a planted-bug task went FINDINGS → fix → blind re-review → CONVERGED. Today `/spar:fight` gives you:
```

with:

```markdown
Phases 1–5 and 8 are implemented; the core loop is verified end-to-end against real reviewers — a planted-bug task went FINDINGS → fix → blind re-review → CONVERGED. Today `/spar:fight` gives you:
```

Replace the feature bullet:

```markdown
- a **final run report** — every converged (and every unattended `blocked-pending-user`) run writes `reviews/spar-<id>-report.md`: outcome, rounds, reviewer pairing, sweep result, findings tally, judge rulings, your settled design decisions, anything still pending, and the changed files. `/spar:report [id]` shows it (defaults to the latest run).
```

with:

```markdown
- a **final run report** — converged or not, a finished run writes `reviews/spar-<id>-report.md` (`cap`, `sweep-findings-at-cap`, `skipped`, and unattended `blocked-pending-user` included; an internal-error bypass or an explicit `/spar:cancel` writes none): outcome, rounds, reviewer pairing, sweep result, findings tally, judge rulings, your settled design decisions, anything still pending, and the changed files. `/spar:report [id]` shows it (defaults to the latest run).
```

Replace the ship sentence:

```markdown
Phase 8 (the `/spar:ready` + `/spar:fight` orchestrator) and Phase 5 (unattended mode) ship in v0.5.0. Phases 6–7 (the Codex-hosted mirror, model economics) are design only — the [Roadmap](#roadmap) marks what exists today. A small [effect benchmark](bench/README.md) ships with this release.
```

with:

```markdown
Phase 8 (the `/spar:ready` + `/spar:fight` orchestrator) and Phase 5's unattended mode shipped in v0.5.0; Phase 5's final run report (`/spar:report`) lands next. Phases 6–7 (the Codex-hosted mirror, model economics) are design only — the [Roadmap](#roadmap) marks what exists today. A small [effect benchmark](bench/README.md) ships with this release.
```

- [x] **Step 3: Update the `fight.md` hint**

In `plugins/spar/commands/fight.md`, replace:

```markdown
     A summary of the whole run is written to `reviews/spar-<id>-report.md` —
     mention it, or run `/spar:report` to show it.
```

with:

```markdown
     A summary of the whole run is written to `reviews/spar-<id>-report.md` —
     mention it, or run `/spar:report` to show it. Non-converged endings (round
     cap, sweep findings at the cap, safe skip) get the same report; use it when
     you report an unconverged result honestly.
```

- [x] **Step 4: Update the report spec**

In `docs/superpowers/specs/2026-07-24-spar-report-design.md`, replace the §Scope first bullet:

```markdown
- **This design: converged runs only** (the user's ask). The generator reads
  artifacts and is terminal-reason-agnostic, so extending to `cap`,
  `sweep-findings-at-cap`, or `skipped` is a one-line change at those terminal
  paths — deferred.
```

with:

```markdown
- **v1 shipped converged runs only** (the user's ask). Because the generator reads
  artifacts and is terminal-reason-agnostic, `cap`, `sweep-findings-at-cap`, and
  `skipped` were added right after as one `generate_report` line each
  (`docs/superpowers/plans/2026-07-25-report-every-terminal-path.md`). `cancelled`
  is excluded: it is written by the `/spar:cancel` command file, not the hook, and
  the user is present by definition when they cancel.
```

Replace the open-questions heading:

```markdown
## Open questions for the writing-plans stage
```

with:

```markdown
## Open questions for the writing-plans stage — all settled (see Status)
```

Replace §Terminal state's body:

```markdown
Implemented. Scope as designed: converged runs (plus the unattended
`blocked-pending-user` terminal, which shares the same call). `cap`,
`sweep-findings-at-cap`, `skipped`, and the `/spar:fight` roll-up stay deferred.
```

with:

```markdown
Implemented, and extended past the original v1 scope: a report is generated for
every terminal that ends a real review — `converged`, `blocked-pending-user`,
`cap`, `sweep-findings-at-cap`, and `skipped`. Two reasons produce none by design:
`error-bypass` (an internal-error bailout has no run story, and its state is what
could not be trusted) and `cancelled` (written by the `/spar:cancel` command file,
with the user present by definition). The `/spar:fight` plan-wide roll-up stays
deferred — it needs the plan state to retain a review id per task, which is a
separate contract change.
```

- [x] **Step 5: Update `docs/design-decisions.md`**

In §"Phase 5 — unattended + final report", replace:

```markdown
  No new phase and no extra round-trip. Scope: converged first (generator is
  terminal-reason-agnostic, so cap/skip/sweep and a /spar:fight roll-up extend easily).
```

with:

```markdown
  No new phase and no extra round-trip. Scope: converged first, then every other
  hook terminal (generator is terminal-reason-agnostic, so each was one added line).
```

And replace the tail of the implementation note:

```markdown
  post-refactor namespace. `cap`, `sweep-findings-at-cap`, `skipped`, and a
  `/spar:fight` roll-up remain deferred.
```

with:

```markdown
  post-refactor namespace. `cap`, `sweep-findings-at-cap`, and `skipped` followed
  in `docs/superpowers/plans/2026-07-25-report-every-terminal-path.md`. Still
  deferred: `cancelled` (command-file path, user present by definition) and the
  `/spar:fight` plan-wide roll-up (needs a per-task review id in the plan state).
```

- [x] **Step 6: Mark the superseded plan honestly**

`docs/superpowers/plans/2026-07-25-spar-report.md` still shows all 35 steps unchecked even though its Task 1 shipped — its fight ended at the round cap, so nothing checked the boxes. Insert this note directly beneath that document's `**Goal:**` line:

```markdown
> **Status (2026-07-25):** superseded. Task 1 shipped (commits `f9edf97`,
> `ea2e6b7`) but its fight ended at the round cap, so the checkboxes below were
> never ticked — do not read them as "nothing was done". Tasks 2-5 were re-issued
> as Tasks 1-4 of `docs/superpowers/plans/2026-07-25-spar-report-remaining.md`,
> which completed. This file is kept as the historical record of Task 1's design.
```

- [x] **Step 7: Verify no stale claim is left**

```bash
grep -rn 'converged run\|Phases 1–4\|planned P5' README.md docs plugins | grep -v 'docs/superpowers/plans/'
grep -rn '/spar-report' README.md docs plugins | grep -v 'commands/spar-report' | grep -v "own \`/spar-report\`"
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAILED: $t"; done
```
Expected: the first two greps print nothing (or only the intentional rename note), and no suite reports `FAILED`. Docs-only changes must not affect tests — if one fails, a doc string a test asserts on was changed; fix the doc wording rather than the test unless the test's expectation is itself now wrong.

- [x] **Step 8: Commit**

```bash
git add plugins/spar/shared/policy.md README.md plugins/spar/commands/fight.md \
  docs/superpowers/specs/2026-07-24-spar-report-design.md docs/design-decisions.md \
  docs/superpowers/plans/2026-07-25-spar-report.md
git commit -m "docs: report covers every terminal path; sync Phase 5 status"
```

---

## Non-goals

- **`cancelled`** — see Global Constraints.
- **`error-bypass`** — it reaches `finish_approve` (the gate there is
  `[ "$1" = converged ]`), so it produces no report, and that stays true. An
  internal-error bailout has no run story worth summarizing, and the state a
  report would read from is exactly what could not be trusted. Every doc claim in
  Task 2 must therefore name the five reported reasons explicitly rather than
  saying "every terminal path".
- **The `/spar:fight` plan-wide roll-up** — needs the plan state to keep a review id per task (it currently holds a single `current_review_id` that each task overwrites), so it is a state-contract change with its own spec.
- **Unattended non-essential parked decisions** — still needs a reviewer-owned terminal contract and a distinct outcome reason; unchanged here.
- **Any change to the change-surface code, the enforced invariants, block messages, or the convergence decision.**
- **Version bump / release commit / plugin reinstall.**

## Self-Review notes

**Coverage of the stated goal:**
- Report at `cap` → Task 1 Step 3 + tests T1/T2. ✅
- Report at `sweep-findings-at-cap` → Task 1 Step 3 + test T3. ✅
- Report at `skipped` → Task 1 Step 3 + test T4. ✅
- Generated before `cleanup()` at those paths → asserted by T2 (ledger content survives into the report, and the report still exists after the deactivated-loop stop that runs cleanup). ✅
- Fail-open preserved → test T5 (failing generator leaves the block text and outcome untouched). ✅
- Executable-bit regression guard the previous sweep asked for → Task 1 Step 1, second block. ✅
- Docs match behavior → Task 2 Steps 1-6, verified by Step 7's greps. ✅

**Pre-verified (2026-07-25, before hand-off):** Task 1 was applied to a scratch
copy of the repo exactly as written — the three insertions, the T1-T5 block, the
executable-bit block, and the R3 deletion — giving `tests/test_stop_hook.sh`
`PASS=232 FAIL=0` and `tests/test_spar_report.sh` `PASS=109 FAIL=0`. Two problems
were found that way and are already corrected above: T4 originally hand-rolled its
git fixture and never triggered the skip path (the change classifier needs a real
`base_sha`, so it now reuses `skip_repo`), and the pre-existing `R3` test asserts
the exact opposite of this task, so deleting it is now an explicit step rather than
a surprise mid-fight. Task 2 is prose only and was not executed.

**Ordering check:** all three insertion points sit between `record_outcome` and `deactivate_state`. Verified in the current file: cap at `stop-hook.sh:1082-1084`, sweep-findings-at-cap at `:1156-1157`, skipped at `:812-813`. None of the three calls `cleanup()`; that happens on the next stop via the `[ "$ACTIVE" = "true" ] || { record_outcome cap; cleanup; approve; }` branch at `:139`.

**Type/name consistency:** `generate_report` (no arguments, returns 0), `REPORT_GEN`, `reviews/spar-<id>-report.md`, and the outcome reasons `converged` / `blocked-pending-user` / `cap` / `sweep-findings-at-cap` / `skipped` / `cancelled` are spelled identically in both tasks and match `spar-record-outcome.sh`'s enum.

**Known fixture detail:** `tests/test_stop_hook.sh`'s `write_state` sets `base_sha: aaaaaaaa…`, not a real commit, so the report's change surface degrades to `(no usable baseline: …)`. T1-T5 therefore assert on the outcome, rounds, tally, and sweep lines — never on diff content. T4 is the exception: it commits a real baseline because the safe-skip path needs the change classifier to see a small real diff.
