# Judge Reachability and the Sweep's Round Cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the two parts of the loop's own escape machinery that this repository's runs have proved do not work: the blind judge cannot be dispatched for the kind of stalemate that actually occurs, and the final sweep's findings are killed by the soft round cap even when the run has rounds left.

**Architecture:** Both changes are in `plugins/spar/hooks/stop-hook.sh`. Neither adds a concept: each reuses a helper or a rule the file already has and applies it at a site that was missed. No new state fields, no new artifacts, no change to who declares convergence.

**Tech Stack:** POSIX-ish bash 3.2 (macOS default), awk, git. Tests are pure bash under `tests/`, driven with CLI stubs, and never invoke a real reviewer.

## Global Constraints

- The four invariants in `README.md` hold: single writer, reviewer-declares-convergence, deterministic enforcement with fail-open hooks, blind adjudication.
- Tests are pure bash in `tests/` and must never require a reviewer CLI on PATH.
- Both seats behave identically. A change that works only under Claude Code or only under Codex is a defect, not a saving.
- Every behavioural change needs a test that fails when the change is reverted. Perform the revert and record which checks failed; do not assert that a test would catch it.
- **The working tree already carries uncommitted work** from an earlier, unconverged loop: the finding-grammar unification and the economics short-circuit, across `plugins/spar/hooks/stop-hook.sh`, `plugins/spar/commands/spar-config.sh`, `tests/test_stop_hook.sh`, `tests/test_config.sh` and one plan document. It is deliberately uncommitted so that this run's frozen baseline excludes it and every reviewer round sees it. Do not commit it separately, and do not treat findings against it as out of scope — five of its edits were made after its own sweep and have never been reviewed.
- `stop-hook.sh` is a surface both seats share, so the release gate applies before the release that carries this work: one live `/spar:fight` in Claude Code and one live `spar-fight` in Codex.

---

### Task 1: The judge can reach a re-worded stalemate

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh:1031` (`prepare_judge`)
- Modify: `docs/design-decisions.md` (Step 6)
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: `resolve_finding_text` (`stop-hook.sh:1013-1023`), already present and already used for parked design findings.
- Produces: no signature change. `prepare_judge` returns 0 and writes a prompt in cases where it previously returned 1 and forced escalation to the user.

The blind judge fires when a `[MECHANICAL]` finding is rejected in two consecutive rounds. The registry accumulates that streak against the **canonical** fingerprint, which is what `new_stalemates` returns and what `prepare_judge` is handed. But `prepare_judge` looks the finding text up with

```bash
finding=$(extract_finding "$(review_file "$ROUND")" "$fp")
```

which searches only the current round's review, and only for that exact fingerprint. When the streak was reached because the reviewer re-worded the finding — the case the matcher exists to detect — the current round's review carries the **variant** title, the canonical fingerprint is not in it, extraction returns empty, and `prepare_judge` returns 1. The caller then escalates to the user with "The blind judge is unavailable".

`gate_finding_text` (`:996`) already solves the alias half of this and `resolve_finding_text` (`:1013`) wraps it with a search backwards through earlier rounds, for exactly the reason stated in its own comment: "A finding parked in an EARLIER round may not appear in the terminal round's review". The judge has the same problem and was never given the same helper.

This is not hypothetical, though the evidence for it is external to the repository and should be read that way. On 2026-07-28 the first judge dispatch this repository had ever needed failed this way — observed in the session log as `cannot extract finding for judge:` — and the dispute went to the user instead. The zero-judge count across 29 runs was counted from `reviews/` in that session, not from anything a later reader can re-derive here. **The code diagnosis above stands on its own and does not depend on either claim.**

- [ ] **Step 1: Write the failing test**

Add to `tests/test_stop_hook.sh`, before the `PASS=`/`FAIL=` summary:

```bash
# ── the judge reaches a re-worded stalemate ─────────────────────────────────
# The streak accumulates against the canonical fingerprint, but the round that
# completes it carries the finding under its new wording. Looking the text up by
# canonical fingerprint in that round alone finds nothing, so the judge never
# dispatches and the dispute falls through to the user instead of being settled
# by the blind adjudicator the protocol reserves for it.
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] mod.py off by one\n- file: mod.py:10\n- problem: original wording\n- suggestion: s\n' > "$RFa"
printf -- '### F1-1: REJECTED — not a defect\n' > "$RPa"
run_hook >/dev/null                     # fold round 1 (streak 1), advance to 2
printf 'STATUS: FINDINGS\n\n### F2-1 [MECHANICAL] mod.py stops one short\n- file: mod.py:10\n- problem: reworded here\n- suggestion: s\n' > "$RFb"
printf -- '### F2-1: REJECTED — still not a defect\n' > "$RPb"
run_hook >/dev/null                     # matcher dispatched on the same file
printf 'SAME N1 E1\n' > "$(cat .claude/spar-matcher-pending)"
OUT=$(run_hook)                         # alias applied, streak 2 → judge
chk "a re-worded stalemate dispatches the judge" 'run-judge' "$OUT"
chk_file "judge runner generated" .claude/spar-run-judge.sh
chk "the judge prompt carries the finding text" "reworded here" \
  "$(cat .claude/spar-judge-prompt.txt 2>/dev/null)"
chk "and the user is not asked to adjudicate instead" "absent" \
  "$(printf '%s' "$OUT" | grep -qF 'judge is unavailable' && echo present || echo absent)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL: a re-worded stalemate dispatches the judge` and the three checks below it. The block message will contain "The blind judge is unavailable", and `.claude/spar.log` will carry `cannot extract finding for judge:`.

- [ ] **Step 3: Give the judge the resolver the gate already uses**

In `prepare_judge`, replace the single extraction line with:

```bash
  # resolve_finding_text, not extract_finding: the streak is held against the
  # CANONICAL fingerprint, while the round that completed it may carry only the
  # re-worded variant — which is precisely the case the matcher exists to
  # create. It also searches earlier rounds, for the same reason the parked-
  # finding path does. Without it the one stalemate this repository has ever
  # produced fell through to the user rather than the blind adjudicator.
  local finding; finding=$(resolve_finding_text "$fp" "$ROUND")
  [ -n "$finding" ] || { log "cannot extract finding for judge: $fp"; return 1; }
```

`resolve_finding_text` is defined at `:1013`, above `prepare_judge` at `:1027`, so no reordering is needed.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL=0`, with four more checks than before.

- [ ] **Step 5: Prove the test discriminates**

Copy the tree to a scratch directory, restore `extract_finding "$(review_file "$ROUND")" "$fp"`, run the suite, and record which checks fail — all four new ones must. Then, in a second copy, make `resolve_finding_text` always return 1 and confirm the escalation path still works (the run must block with "judge is unavailable" and not crash), which is what shows the fail-open behaviour was preserved rather than removed.

- [ ] **Step 6: Record the defect and its evidence**

Add to `docs/design-decisions.md`, under the Phase 2 section that describes the judge, a short paragraph: the judge was unreachable for re-worded stalemates from its introduction until 2026-07-28; the streak is canonical while the completing round is a variant; the parked-finding path had the resolver and the judge did not; zero judge dispatches across 29 runs is consistent with this and was not investigated at the time.

- [ ] **Step 7: Run every suite and commit**

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
```

Then commit. **`git add -A` here deliberately folds in the carried-over work** described in the Global Constraints — the finding-grammar unification and the economics short-circuit. That is intended: this run's rounds reviewed it alongside the judge fix, so it is adopted, not smuggled. Say so in the message rather than labelling it as the judge change alone.

```bash
git add -A
git commit -m "fix(judge): reach a stalemate the reviewer re-worded

Also adopts the finding-grammar unification and the economics short-circuit
carried in from the previous unconverged loop; this run's reviewer rounds saw
them in the same diff."
```

---

### Task 2: Sweep findings obey the two-level cap, not the soft cap alone

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh:1692` (the sweep-findings branch)
- Modify: `tests/test_stop_hook.sh` — cases 44 and T3, whose premise this changes
- Modify: `plugins/spar/shared/policy.md:99`, `README.md:97`, `plugins/spar/commands/fight.md:125`
- Modify: `docs/design-decisions.md` (Step 8)
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: `HARD_CAP` (`stop-hook.sh:208-217`), already parsed and already used by the reviewer-round cap.
- Produces: no new outcome reason. `sweep-findings-at-cap` still exists and still terminates honestly; it now fires at the hard cap rather than the soft one.

The reviewer-round cap at `:1603` implements a deliberate two-level rule: at the soft cap, extend while rounds stay productive; stop unconditionally at the hard cap, which defaults to twice the soft one. The comment above it explains why the extension exists — "whatever rounds this run needs, it has to get inside this run", because committing and re-running hands the reviewer an empty diff.

The sweep-findings branch at `:1692` never got that rule. It reads

```bash
if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
```

so a run that legitimately extended past the soft cap — round 6 of 10, say — is killed the moment the sweep finds anything, with four reviewer rounds still available and a block message claiming the loop "already used all 5 reviewer rounds", which by then is false.

This is the failure that ended the previous loop on this repository: the run reached round 6 under the productivity extension, the sweep returned findings, and the whole plan stopped with three tasks unstarted. It is also an instance of the pattern this project keeps hitting — a rule was changed in one place and left stated in another.

Routing sweep findings adds exactly one sweep response and one reviewer round. What that round then finds is not bounded by this change — it may itself produce findings and consume several of the rounds still available — but every one of them is governed by the normal cap, and the sweep cannot re-arm (`set_sweep_state true findings` is already set on this path, and the convergence branch checks `SWEEP_DONE` before sweeping again). The hard cap therefore remains the thing that guarantees termination, which is what it is for.

- [ ] **Step 1: Write the failing test**

```bash
# ── sweep findings use the hard cap, not the soft one ───────────────────────
# A run that extended past the soft cap under the productivity rule still has
# rounds; killing it the moment the sweep speaks discards them, and the block
# message's "already used all 5 reviewer rounds" is false by then.
sweep_review_repo 6
RF6="reviews/spar-20260721-120000-abc123-r6.md"
printf 'STATUS: CONVERGED\n' > "$RF6"
run_hook >/dev/null
printf 'SWEEP: FINDINGS\n\n### S-1 [MECHANICAL] something left\n' > "$SF"
OUT=$(run_hook)
chk "past the soft cap, sweep findings are routed, not dropped" 'respond to sweep' "$OUT"
chk "and the run is still active" 'active: true' "$(cat .claude/spar.local.md)"
printf -- '### S-1: FIXED — handled\n' > "$SRESP"
OUT=$(run_hook)
chk "the sweep response advances to a reviewer round" 'round 7' "$OUT"

# At the hard cap it still terminates honestly.
sweep_review_repo 10
RF10="reviews/spar-20260721-120000-abc123-r10.md"
printf 'STATUS: CONVERGED\n' > "$RF10"
run_hook >/dev/null
printf 'SWEEP: FINDINGS\n\n### S-1 [MECHANICAL] something left\n' > "$SF"
OUT=$(run_hook)
chk "at the hard cap, sweep findings still end the run" 'at cap' "$OUT"
chk "hard-cap sweep exit deactivates" 'active: false' "$(cat .claude/spar.local.md)"
chk "hard-cap sweep exit records the honest reason" 'reason: sweep-findings-at-cap' \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"
```

`sweep_review_repo` and `$SF` are the existing helpers used by case 44; `$SRESP` is the sweep response path the hook already names. Confirm `sweep_review_repo` accepts a round argument above 5 before relying on it — case 44 calls it with 5 and case 45 with 3.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: the first three checks FAIL — at round 6 the hook currently reports `at cap` and deactivates. The hard-cap checks should already pass, which is what shows the terminal is not being removed.

- [ ] **Step 3: Move the comparison to the hard cap**

Replace the branch condition at `:1692`:

```bash
    # The hard cap, not the soft one. The reviewer-round cap at :1603 extends
    # past the soft cap while rounds stay productive, and a run that took that
    # extension still has rounds to spend — killing it here discards them and
    # the message below would claim a budget that was not exhausted. Routing
    # sweep findings costs one fix-and-verify cycle at most: the sweep runs once
    # per loop, and the rounds that follow obey the normal cap.
    if [ "$ROUND" -ge "$HARD_CAP" ]; then
      log "sweep findings at hard cap $HARD_CAP"
```

and correct the block message, which currently names `${MAX_ROUNDS}`:

```
      block "The final sweep found unresolved issues, but the loop has reached
its hard cap of ${HARD_CAP} rounds. Do not fix them inside this loop. Report
${SF} as an unconverged/blocked result; the sweep findings were not silently
dropped." "sparring [${REVIEW_ID}]: sweep findings at hard cap"
```

- [ ] **Step 4: Re-point the two existing tests whose premise this changes**

Case 44 (`tests/test_stop_hook.sh:759`) and case T3 (`:987`) both put the loop at round 5 and assert the run terminates. Under the new rule round 5 is below the hard cap and routes instead, so both would be asserting behaviour the engine no longer has. Do not delete them — they are the only coverage of the terminal. Give each a state file whose caps coincide, using the idiom already at `:1388`:

```bash
sed -i '' 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 5/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 5/' .claude/spar.local.md
```

**The two cases set their state differently, so the insertion point differs.** Case 44 calls `sweep_review_repo 5` at `tests/test_stop_hook.sh:760`; insert immediately after that call. T3 does **not** use that helper — it calls `fresh_dir; write_state review 5` at `:988` and then seds the phase to `sweep`; insert after the `write_state` line and before the phase sed. In both cases the edit must precede the first `run_hook`. Update each case's comment to say it is exercising the hard cap.

- [ ] **Step 5: Correct the two documents that state the old rule**

`plugins/spar/shared/policy.md:99` says sweep findings "at the cap terminate honestly as `sweep-findings-at-cap`" — make it say the hard cap, and that below it the findings are routed through one further reviewer round. `README.md:97` shows `findings at cap → sweep-findings-at-cap exit` in the flow diagram; make the same correction there. `plugins/spar/commands/fight.md:125` lists "sweep findings at the cap" among the non-converged endings without distinguishing soft from hard; it does not assert the old rule, but say "hard cap" so the ambiguity is not carried forward. The Codex fight skill makes no boundary claim and needs no edit. Historical specs and completed plans that mention `sweep-findings-at-cap` describe runs that happened and are not rewritten.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL=0`.

- [ ] **Step 7: Prove the tests discriminate**

In a scratch copy, restore `[ "$ROUND" -ge "$MAX_ROUNDS" ]` and confirm the three round-6 checks fail while the hard-cap checks still pass. In a second copy, change the condition to a constant `false` and confirm the hard-cap checks fail — that is what shows the terminal still exists rather than having been routed away entirely.

- [ ] **Step 8: Record the decision and commit**

Add to `docs/design-decisions.md`, beside the two-level cap's own entry, that the sweep-findings branch was written before the two-level cap and kept comparing against the soft cap; that this ended a real run with four rounds unspent on 2026-07-28; and that the hard cap is now the single place a round budget is declared exhausted.

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
git add -A
git commit -m "fix(sweep): stop discarding rounds the productivity rule granted"
```

---

## Non-goals

- Anything from `docs/superpowers/plans/2026-07-28-loop-economy-author-discipline.md` that is still unstarted — role-specific runner payloads, the author's fix guidance, the reviewer version in the outcome, and the `hard_cap` documentation gap. Those follow in a second plan, once these two repairs are in the engine that runs them.
- Updating the installed plugin. The loop executes a cached copy under `~/.claude/plugins/cache/sparring/spar/`, and in the session that produced this plan that copy was several versions behind the repository — so nothing built here takes effect in the loop reviewing it. Which version is active is external state the repository cannot confirm; treat it as a release decision with a gate attached, not a task.
- Re-measuring the sweep, the matcher trigger or the every-round full re-read. Their justification rests on runs of an older reviewer CLI and has to be rebuilt before any of them is touched.

## Verification this plan cannot do

Whether repairing the judge changes how disputes end. It has been reachable zero times, so there is no baseline to compare against — the first real ruling will be the first evidence, and it will arrive only when a `[MECHANICAL]` finding is rejected twice in a run using an engine that carries this fix.
