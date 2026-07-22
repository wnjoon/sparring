# sparring Phase 2c (Design Gate + Decision Ledger) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the interim per-finding user escalation for `[DESIGN]` stalemates with the debate-first, gate-last model: a design stalemate is **parked** (loop continues on everything else); when the loop is stuck on nothing but parked findings, the hook fires one **batched gate**; the author presents the parked questions to the user and transcribes each ruling into a **decision ledger** (`.claude/spar-ledger.md`); the hook verifies a ledger entry per parked finding, marks them `settled`, and the ledger — injected into every later reviewer prompt (slot wired in Phase 2a) — is what lets the reviewer stop re-flagging the settled choice so the loop can converge.

**Architecture:** The gate is deterministic like the judge, but the "external run" is a human decision. On the stuck-on-parked trigger the hook writes a gate manifest (`.claude/spar-gate-manifest.tsv`, lines `P<k><TAB><fp>`) and a human-readable worksheet (`.claude/spar-gate.md`), then blocks. The author runs the batched gate against the worksheet and appends `### P<k>: <decision + basis>` sections to the ledger. On the next stop the hook checks each manifest entry against the ledger; missing ones re-block (escape is `/spar-cancel`), and once all are present each parked fingerprint becomes `settled`. `prepare_round` frames the non-empty ledger as design intent when injecting it.

**Tech Stack:** Bash (hook + `awk`/`grep` parsing), pure-bash test harness. No new runtime dependencies. Builds on the Phase 2a registry and the Phase 2b judge/extraction helpers.

## Global Constraints

- Plugin name: `spar`. Repo root: `~/Workspace/sparring`. Branches `task/13-*`, `task/14-*` (numbering continues globally); merge each into `dev`. Plan doc committed directly to `dev`.
- Builds on merged Phase 2a + 2b: registry (`.claude/spar-registry.tsv`, `fp<TAB>tag<TAB>last_rejected_round<TAB>rejected_streak<TAB>status`), `new_stalemates` (streak≥2 AND status==open), `registry_tag`, `set_registry_status`, `mark_escalated`, `parse_findings`, `extract_finding`, `prepare_judge`, and the review-case sections A (resolve pending judge) and B (route stalemates). The `{{LEDGER}}` slot exists in `reviewer.md` and `prepare_round`.
- Decision (design-decisions.md Phase 2 point 4): **single gate, parked-only model.** All `[DESIGN]` stalemates → status `parked`. There is NO author-declared "essential" flag. "Blocked-pending-user" is not a separate state — a parked question the user does not decide simply never gets a ledger entry, so the reviewer keeps raising it and the loop cannot converge (honest incompleteness, bounded by the round cap). The user's escape from an undecidable gate is `/spar-cancel`.
- Gate trigger (design-decisions.md): fire when a round makes no forward progress except on parked findings — after folding, every finding the current round's review raised is already `parked` — OR the cap is about to end the loop with parked findings. The gate blocks once and batches ALL currently-parked findings.
- Ledger (design-decisions.md): `.claude/spar-ledger.md`. The author transcribes the user's ruling (it does not invent it); the hook verifies an entry exists per parked finding before settling. Injected as design intent ("deliberate choices — do not re-flag as defects; you MAY still flag a genuine defect a decision causes"); never an instruction about what the reviewer must not flag.
- Invariant 2 (reviewer-declares) unchanged: `STATUS: CONVERGED` exits before any stalemate/gate code. Invariant 3 (fail-open): any gate-internal error degrades to continuing the loop or the top-level ERR-trap approve; the only "sticky" block is the gate/gate-incomplete block, which the user always escapes with `/spar-cancel`.
- Registry status vocabulary after 2c: `open`, `escalated` (judge-unavailable fail-open only), `judging`/`upheld`/`dismissed` (2b), `parked` (design stalemate awaiting gate), `settled` (gate decision recorded). `new_stalemates` returns only `open`.
- `[MECHANICAL]` stalemate routing (blind judge) is UNCHANGED from Phase 2b.
- OUT OF SCOPE: the final report and the "N design decisions pending" / durable-home offer at exit (Phase 4); model-based semantic matching (Phase 2d). 2c must not falsely report completion — that property holds automatically because an unsettled parked finding keeps the loop unconverged.

## File Structure

```
plugins/spar/
├── hooks/stop-hook.sh                 # MODIFY: constants; registry_status/parked_fingerprints/only_parked_this_round helpers; prepare_round ledger framing; DESIGN→parked routing; gate resolution + trigger; cleanup
├── shared/prompts/reviewer.md         # (unchanged — {{LEDGER}} slot already present)
├── shared/policy.md                   # MODIFY (Task 14): protocol gate/ledger note
└── commands/
    ├── spar.md                        # MODIFY (Task 14): loop-protocol gate instruction
    └── spar-cancel.md                 # MODIFY (Task 14): remove gate sidecars
tests/test_stop_hook.sh                # MODIFY: update DESIGN cases 14b/15/16/23 to parked+gate; add gate round-trip + injection + incomplete cases
```

New hook-owned runtime files (added to `cleanup()`):
- `.claude/spar-gate-manifest.tsv` — `P<k><TAB><fp>` per parked finding in the current gate.
- `.claude/spar-gate.md` — human worksheet the author reads for the batched gate.
- `.claude/spar-ledger.md` — the decision ledger (author-written; already cleaned by 2a/2b cancel + cleanup).

---

### Task 13: Parked routing, batched gate, and decision ledger

Branch: `task/13-design-gate`.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh`
- Modify: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: `new_stalemates`, `registry_tag`, `set_registry_status`, `parse_findings`, `extract_finding`, `review_file`, `prepare_judge`, `block`, `prepare_round` (existing).
- Produces: `registry_status <fp>`, `parked_fingerprints`, `only_parked_this_round <round>`; gate sidecars; `parked`/`settled` statuses; ledger-framed injection.

- [ ] **Step 1: Update the DESIGN stalemate tests and add gate tests (RED)**

In `tests/test_stop_hook.sh`:

(a) **Case 14b** — its expected status changes from `escalated` to `parked` (a DESIGN stalemate now parks). Find the assertion:

```bash
chk "consecutive rejection → streak 2" "$(printf 'mod.py | split the module\tDESIGN\t2\t2\tescalated')" "$(cat .claude/spar-registry.tsv)"
```

replace with:

```bash
chk "consecutive rejection → streak 2, parked" "$(printf 'mod.py | split the module\tDESIGN\t2\t2\tparked')" "$(cat .claude/spar-registry.tsv)"
```

(b) **Cases 15 and 16** — these asserted the old "design stalemate → user escalation, fires once, advances". Replace the entire block of cases 15 and 16 (from the `# ── 15.` comment through the end of case 16) with the new parked+gate behavior:

```bash
# ── 15. DESIGN stalemate → parked + batched gate fires ──
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFa"
printf '### F1-1: REJECTED — cohesive on purpose\n' > "$RPa"
run_hook >/dev/null   # fold r1 (streak 1), advance to r2
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFb"
printf '### F2-1: REJECTED — still cohesive\n' > "$RPb"
OUT=$(run_hook)       # fold r2 (streak 2) → parked → gate (round raised only the parked finding)
chk "design stalemate → parked status" "$(printf 'mod.py | split the module\tDESIGN\t2\t2\tparked')" "$(cat .claude/spar-registry.tsv)"
chk "stuck on parked → gate block" 'gate' "$OUT"
chk "no judge runner for design" "absent" "$([ -f .claude/spar-run-judge.sh ] && echo present || echo absent)"
chk_file "gate manifest written" .claude/spar-gate-manifest.tsv
chk "manifest maps P1 to fingerprint" "$(printf 'P1\tmod.py | split the module')" "$(cat .claude/spar-gate-manifest.tsv)"
chk_file "gate worksheet written" .claude/spar-gate.md
chk "worksheet shows the finding" 'split the module' "$(cat .claude/spar-gate.md)"

# ── 16. gate: ledger entry recorded → settled → round advances, ledger injected ──
printf '### P1: keep it cohesive — the module owner owns this boundary.\n' > .claude/spar-ledger.md
run_hook >/dev/null   # verify ledger → settle → advance to r3
chk "ledger present → status settled" "$(printf 'mod.py | split the module\tDESIGN\t2\t2\tsettled')" "$(cat .claude/spar-registry.tsv)"
chk "gate cleared → advanced to round 3" 'round: 3' "$(cat .claude/spar.local.md)"
chk "gate manifest removed" "gone" "$([ -f .claude/spar-gate-manifest.tsv ] && echo present || echo gone)"
chk "r3 prompt injects the ledger decision" 'keep it cohesive' "$(cat .claude/spar-reviewer-prompt.txt)"
chk "r3 prompt frames ledger as design intent" 'design decision' "$(cat .claude/spar-reviewer-prompt.txt)"
```

(c) **Case 23** (added in Phase 2b: "DESIGN stalemate still uses Phase 2a user escalation") — its premise is now wrong. Replace the case 23 block with:

```bash
# ── 23. DESIGN stalemate routes to gate (parked), never the judge ──
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] rename thing\n- file: x.py:2\n- problem: unclear\n- suggestion: rename\n' > "$RFa"
printf '### F1-1: REJECTED — name matches the spec\n' > "$RPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] rename thing\n- file: x.py:2\n- problem: unclear\n- suggestion: rename\n' > "$RFb"
printf '### F2-1: REJECTED — name matches the spec\n' > "$RPb"
OUT=$(run_hook)
chk "design → gate, not judge" "absent" "$([ -f .claude/spar-run-judge.sh ] && echo present || echo absent)"
chk "design → parked" 'parked' "$(cat .claude/spar-registry.tsv)"
chk "design → gate block" 'gate' "$OUT"

# ── 25. gate incomplete: no ledger entry → re-block, still pending ──
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFa"
printf '### F1-1: REJECTED — cohesive\n' > "$RPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFb"
printf '### F2-1: REJECTED — cohesive\n' > "$RPb"
run_hook >/dev/null   # gate fires, manifest written, no ledger yet
OUT=$(run_hook)       # still no ledger → gate incomplete
chk "gate incomplete → re-block" 'gate' "$OUT"
chk "gate incomplete → manifest kept" "kept" "$([ -f .claude/spar-gate-manifest.tsv ] && echo kept || echo gone)"
chk "gate incomplete → not settled" 'parked' "$(cat .claude/spar-registry.tsv)"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: the updated 14b/15/16/23 and new 25 FAIL (DESIGN still escalates via 2b code; no gate machinery). Non-zero exit.

- [ ] **Step 3: Add gate sidecar constants**

In `plugins/spar/hooks/stop-hook.sh`, after the `JUDGE_RETRY=...` line, add:

```bash
GATE_MANIFEST=".claude/spar-gate-manifest.tsv"
GATE_FILE=".claude/spar-gate.md"
```

- [ ] **Step 4: Add the gate sidecars to `cleanup()`**

In `cleanup()`, append `"$GATE_MANIFEST" "$GATE_FILE"` to the `rm -f` list (the `LEDGER_FILE` is already there).

- [ ] **Step 5: Add `registry_status`, `parked_fingerprints`, `only_parked_this_round` helpers**

In `stop-hook.sh`, immediately after the `registry_tag` definition, add:

```bash
# Status of a fingerprint (column 5).
registry_status() { # $1=fp
  [ -f "$REGISTRY_FILE" ] || return 0
  awk -F'\t' -v fp="$1" '$1==fp{print $5; exit}' "$REGISTRY_FILE" 2>/dev/null
}

# All fingerprints currently parked.
parked_fingerprints() {
  [ -f "$REGISTRY_FILE" ] || return 0
  awk -F'\t' '$5=="parked"{print $1}' "$REGISTRY_FILE" 2>/dev/null
}

# True if the round's review raised ≥1 finding and EVERY raised finding is parked.
only_parked_this_round() { # $1=round
  local rf; rf=$(review_file "$1"); [ -f "$rf" ] || return 1
  local any=0 nonparked=0 id tag file nt fp
  while IFS=$'\t' read -r id tag file nt; do
    [ -n "$id" ] || continue
    any=1; fp="${file} | ${nt}"
    [ "$(registry_status "$fp")" = "parked" ] || nonparked=1
  done < <(parse_findings "$rf")
  [ "$any" = 1 ] && [ "$nonparked" = 0 ]
}
```

- [ ] **Step 6: Frame the injected ledger in `prepare_round`**

In `prepare_round`, replace the current ledger line:

```bash
  local prompt ledger=""
  prompt=$(cat "$tpl_dir/reviewer.md")
  [ -f "$LEDGER_FILE" ] && ledger=$(cat "$LEDGER_FILE")
```

with framing that only appears when the ledger is non-empty:

```bash
  local prompt ledger=""
  prompt=$(cat "$tpl_dir/reviewer.md")
  if [ -s "$LEDGER_FILE" ]; then
    ledger="## Settled design decisions (deliberate choices — do NOT re-flag these
as defects; you MAY still flag a genuine defect that a decision itself causes)

$(cat "$LEDGER_FILE")"
  fi
```

- [ ] **Step 7: Change DESIGN routing to park, and add gate resolution + trigger**

In the `review)` case, replace the Phase 2b section B design-handling. Find the section-B block that currently classifies mech/design and ends with the DESIGN `block "Stalemate: ... design stalemate ..."`. Replace the whole `STALE=$(new_stalemates)` block with:

```bash
    # (B) Route new stalemates: [MECHANICAL] → blind judge, [DESIGN] → parked.
    STALE=$(new_stalemates)
    if [ -n "$STALE" ]; then
      mech_fp=""
      while IFS= read -r fp; do
        [ -n "$fp" ] || continue
        if [ "$(registry_tag "$fp")" = "MECHANICAL" ]; then
          [ -z "$mech_fp" ] && mech_fp="$fp"
        else
          set_registry_status "$fp" parked
        fi
      done <<STALE_EOF
$STALE
STALE_EOF
      if [ -n "$mech_fp" ]; then
        if prepare_judge "$mech_fp"; then
          rm -f "$JUDGE_RETRY"
          block "Factual stalemate on '${mech_fp}': an independent blind judge
must rule (you cannot decide your own rejection). Run:
\`\`\`
bash ${JUDGE_RUNNER}
\`\`\`
Then stop again." "sparring [${REVIEW_ID}] round ${ROUND}: judge dispatched"
        else
          set_registry_status "$mech_fp" escalated
          block "The blind judge is unavailable. Surface finding '${mech_fp}' to
the user for a decision, apply it, then stop." \
            "sparring [${REVIEW_ID}]: judge unavailable — user decision needed"
        fi
      fi
    fi

    # (C1) A gate is pending → verify ledger decisions, settle, or re-block.
    if [ -f "$GATE_MANIFEST" ]; then
      missing=""
      while IFS=$'\t' read -r ptag pfp; do
        [ -n "$ptag" ] || continue
        if grep -q "^### ${ptag}:" "$LEDGER_FILE" 2>/dev/null; then
          set_registry_status "$pfp" settled
        else
          missing="${missing}${ptag} "
        fi
      done < "$GATE_MANIFEST"
      if [ -n "$missing" ]; then
        block "Design gate incomplete. Still need a recorded decision for: ${missing}
Present each to the user (see ${GATE_FILE}), then append to ${LEDGER_FILE} a
section per tag: '### P<k>: <the user's decision and its basis>'. Then stop
again. (To abandon the loop instead: /spar-cancel.)" \
          "sparring [${REVIEW_ID}]: design gate incomplete"
      fi
      rm -f "$GATE_MANIFEST" "$GATE_FILE"
    fi

    # (C2) Stuck on parked findings → fire the single batched gate.
    if only_parked_this_round "$ROUND"; then
      : > "$GATE_MANIFEST"
      {
        echo "# sparring design gate — batched parked decisions"
        echo
        echo "Present these to the user together. Cluster by shared disposition;"
        echo "put analysis before the question; skip any where all options lead to"
        echo "the same outcome (resolve it and note that). For each P<k>, append to"
        echo "${LEDGER_FILE}: '### P<k>: <decision + basis>'."
        echo
      } > "$GATE_FILE"
      k=0
      while IFS= read -r pfp; do
        [ -n "$pfp" ] || continue
        k=$((k+1))
        printf 'P%s\t%s\n' "$k" "$pfp" >> "$GATE_MANIFEST"
        {
          echo "## P${k}  (${pfp})"
          extract_finding "$(review_file "$ROUND")" "$pfp"
          echo
        } >> "$GATE_FILE"
      done < <(parked_fingerprints)
      block "The loop is stuck on parked design finding(s): only decisions you
have deferred remain. Run the batched design gate — read ${GATE_FILE},
present the questions to the user, and record each ruling in ${LEDGER_FILE}
as '### P<k>: <decision + basis>'. Then stop again." \
        "sparring [${REVIEW_ID}] round ${ROUND}: design gate"
    fi
```

Note: section A (resolve pending judge) is unchanged and stays immediately before this block.

- [ ] **Step 8: Run tests — all pass**

Run: `bash tests/test_stop_hook.sh`
Expected: all cases PASS (Phase 1/2a/2b cases plus updated 14b/15/16/23 and new 25), `FAIL=0`, exit 0.

- [ ] **Step 9: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh tests/test_stop_hook.sh
git commit -m "feat: design gate — park DESIGN stalemates, batched gate, decision ledger settle+inject"
```

---

### Task 14: Docs and cancel wiring for the gate

Branch: `task/14-gate-docs`.

**Files:**
- Modify: `plugins/spar/commands/spar-cancel.md`
- Modify: `plugins/spar/shared/policy.md`
- Modify: `plugins/spar/commands/spar.md`

**Interfaces:**
- Consumes: the gate sidecar filenames from Task 13.

- [ ] **Step 1: Extend `/spar-cancel` to remove gate sidecars**

In `plugins/spar/commands/spar-cancel.md`, append to the `rm -f` line:

```
.claude/spar-gate-manifest.tsv .claude/spar-gate.md
```

(The `.claude/spar-ledger.md` entry is already present from Phase 2a.)

- [ ] **Step 2: Update `policy.md` protocol step for the design gate**

In `plugins/spar/shared/policy.md`, replace the current stalemate protocol step 6 (the one describing the judge + the `[DESIGN]` user escalation) with:

```
6. Stalemate — a finding raised AND rejected for 2 consecutive rounds. A
   [MECHANICAL] stalemate goes to a blind `codex exec --sandbox read-only`
   judge (author only runs it; ruling `RULING: UPHELD`/`RULING: DISMISSED` is
   binding). A [DESIGN] stalemate is PARKED: the loop continues on everything
   else. When the loop is stuck on nothing but parked findings, the hook fires
   one batched gate — the author presents all parked questions to the user and
   records each ruling in the decision ledger (`.claude/spar-ledger.md`). The
   hook verifies a ledger entry per parked finding, marks them settled, and
   injects the ledger into later reviewer prompts as design intent so the
   settled choice is no longer re-flagged. An undecided parked question simply
   keeps the loop unconverged (bounded by the round cap); the escape is
   explicit cancel.
```

- [ ] **Step 3: Update `/spar` loop protocol for the gate**

In `plugins/spar/commands/spar.md`, replace the current judge/design-stalemate loop item (item 5) with:

```
5. If the hook dispatches a **blind judge** (factual `[MECHANICAL]`
   stalemate), run `bash .claude/spar-run-judge.sh` (600000ms timeout), then
   stop; the ruling is binding (`UPHELD` = you must fix, `DISMISSED` = dropped).
   If the hook fires a **design gate**, read `.claude/spar-gate.md`, present
   the batched parked questions to the user (cluster by shared disposition;
   give the analysis before the question; skip any whose options all lead to
   the same outcome), then record each ruling in `.claude/spar-ledger.md` as
   `### P<k>: <decision + basis>` and stop again. Never invent a ruling — the
   ledger records the user's decision.
```

- [ ] **Step 4: Full suite + honest status**

Run: `bash tests/test_stop_hook.sh && echo "ALL PASS"`
Expected: `ALL PASS`, `FAIL=0`. Phase 2c completes the design gate + ledger. The README roadmap row for Phase 2 stays `planned` until Phase 2d (semantic matching) lands and the phase is called done. Do not mark Phase 2 complete.

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/commands/spar-cancel.md plugins/spar/shared/policy.md plugins/spar/commands/spar.md
git commit -m "docs: policy + /spar + /spar-cancel cover the design gate and ledger"
```

---

## Self-Review Notes

- **Spec coverage (design-decisions.md Phase 2 point 4 + gate/ledger):** parked-only model, no essentiality flag (Task 13 Step 7 DESIGN branch); single batched gate on the stuck-on-parked trigger (Step 7 C2 + `only_parked_this_round`); ledger written by the author and verified per-finding by the hook (Step 7 C1 against the manifest); settle + inject as framed design intent (Steps 6, 7 C1); "blocked-pending-user" = an undecided parked question that keeps the loop unconverged (no separate state — C1 re-blocks, `/spar-cancel` escapes; the round cap bounds it). Out of scope and deferred: final report / durable-home offer (Phase 4), semantic matching (Phase 2d).
- **Invariant checks:** reviewer-declares — `STATUS: CONVERGED` still exits at the top of the review case, before section A/B/C. Fail-open — a DESIGN stalemate parks without a sticky trap; the gate/gate-incomplete blocks are always escapable via `/spar-cancel`; helper failures (`only_parked_this_round` returns 1 on a missing review, `parked_fingerprints`/`registry_status` empty on a missing registry) degrade to "no gate", and any uncaught error hits the top-level ERR-trap approve. `[MECHANICAL]` judge routing unchanged from 2b.
- **Convergence unblock:** a parked finding is re-raised by the blind reviewer every round, so the loop cannot converge until its ledger entry is injected — the gate is the only thing that produces that entry, and `only_parked_this_round` guarantees the gate fires exactly when nothing but parked findings remain. After settle, `prepare_round` injects the framed ledger so the next reviewer stops re-flagging it.
- **Ordering correctness:** DESIGN findings are parked (status set) BEFORE the gate trigger is evaluated in the same stop, and a co-occurring `[MECHANICAL]` stalemate blocks for its judge first (section B), so the gate only fires on a later stop once the judged finding is terminal and only parked findings are raised — no premature gate, no lost design finding.
- **Type/name consistency:** `registry_status`/`parked_fingerprints`/`only_parked_this_round` defined in Step 5 and used in Step 7; `GATE_MANIFEST`/`GATE_FILE` declared (Step 3), cleaned in `cleanup()` (Step 4) and `/spar-cancel` (Task 14). Manifest rows `P<k><TAB><fp>` written in C2 and read in C1 with matching field split (`IFS=$'\t' read -r ptag pfp`). Ledger section key `### P<k>:` written by the author (per the worksheet + `/spar` instructions) and matched by `grep -q "^### ${ptag}:"` in C1. Registry row shape unchanged; only the `status` vocabulary grows (`parked`, `settled`).
- **Placeholder scan:** none — every step carries full file contents or exact commands.
- **Test churn note:** cases 14b/15/16/23 are intentionally rewritten because Phase 2c changes `[DESIGN]` stalemate behavior from the interim user escalation to park+gate; the Phase 1/2a/2b non-DESIGN cases are untouched.
