# sparring Phase 2a (Conveyance Boundary + Stalemate Detection) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch the reviewer to a stateless blind re-review (retire the round-2+ prev-context addendum, add an empty decision-ledger injection slot), and add deterministic orchestrator-side finding tracking that detects a 2-round stalemate and escalates it once to the user.

**Architecture:** The Stop hook stays the deterministic gatekeeper. Task 1 removes the prev-review/prev-response context from every reviewer prompt (the **conveyance boundary**) and inserts a `{{LEDGER}}` slot that is empty until Phase 2b. Task 2 adds a hook-owned sidecar registry (`.claude/spar-registry.tsv`): after each round's review + response exist, the hook parses the reviewer's findings and the author's dispositions, computes a deterministic fingerprint per finding (`file | normalized-title`), and folds it into the registry once per round. Task 3 reads that registry to detect a **stalemate** — a finding raised by the reviewer AND rejected by the author for 2 consecutive rounds — and blocks once with an escalation message (automated judge/gate is Phase 2b), marking the finding `escalated` so it never re-fires.

**Tech Stack:** Bash (hook + `awk`/`sed` parsing), pure-bash test harness (`tests/test_stop_hook.sh`), Claude Code plugin. No new runtime dependencies.

## Global Constraints

- Plugin name: `spar`. Repo root: `~/Workspace/sparring`. Work on branches `task/7-*`, `task/8-*`, `task/9-*` (task numbering continues globally from Phase 1's `task/6`); merge each into `dev`. This plan document is committed directly to `dev`.
- Invariant 2 (reviewer-declares) is inviolate: a fresh review whose first line is `STATUS: CONVERGED` is authoritative and exits. Nothing in this plan forces an extra round after convergence or lets the orchestrator second-guess `CONVERGED`.
- Invariant 3 (deterministic enforcement, fail-open): every new code path must fail **open** (approve / continue) on internal error — never trap the user. Registry/parse failures degrade to "no stalemate detected", never to a block the user cannot escape.
- Conveyance boundary: the reviewer is NEVER told what was fixed or rejected. Response files remain for accountability but are not passed to the reviewer.
- Fingerprint (2a) is deterministic: `fp = "<file-without-line> | <normalized-title>"`, where normalized-title is lowercased, non-alphanumeric runs collapsed to single spaces, trimmed. Model-based semantic matching for ambiguous pairs is explicitly OUT OF SCOPE (Phase 2c). Accepted limitation: a reviewer that re-phrases a finding across rounds may not match (false negative) → that stalemate is simply not detected and the loop proceeds under the existing round cap.
- Registry is hook-owned bookkeeping in `.claude/`, not a `reviews/` artifact; it is removed by `cleanup()` and `/spar-cancel`. Durable audit persistence is Phase 4 (final report), not here.
- Stalemate scope (2a): a finding of ANY tag rejected 2 consecutive rounds triggers one escalation block. The factual→judge / design→gate split is Phase 2b.
- Existing state-file format is unchanged (no new front-matter fields); all new state lives in sidecar files.

## File Structure

```
plugins/spar/
├── hooks/stop-hook.sh                 # MODIFY: prepare_round (conveyance), + registry/stalemate functions and review-phase integration
├── shared/prompts/reviewer.md         # MODIFY: drop {{PREV_CONTEXT}}, add {{LEDGER}}
├── shared/prompts/reviewer-prev-context.md   # DELETE
├── shared/policy.md                   # MODIFY: protocol step 2 (conveyance) + stalemate note
└── commands/
    ├── spar.md                        # MODIFY: loop protocol note for stalemate escalation
    └── spar-cancel.md                 # MODIFY: also remove registry sidecar files
tests/test_stop_hook.sh                # MODIFY: invert case 8 (no prev refs); add conveyance + registry + stalemate cases
```

New hook-owned files created at runtime (added to `cleanup()`):
- `.claude/spar-registry.tsv` — canonical finding registry.
- `.claude/spar-registry-round` — highest round already folded (idempotency marker).
- `.claude/spar-ledger.md` — decision ledger; **not created in 2a** (Phase 2b writes it). When absent, `{{LEDGER}}` injects empty.

---

### Task 7: Conveyance boundary — retire prev-context, add empty ledger slot

Branch: `task/7-conveyance-boundary`.

**Files:**
- Modify: `plugins/spar/shared/prompts/reviewer.md`
- Delete: `plugins/spar/shared/prompts/reviewer-prev-context.md`
- Modify: `plugins/spar/hooks/stop-hook.sh` (function `prepare_round`, lines ~56–87)
- Modify: `plugins/spar/shared/policy.md` (protocol step 2)
- Modify: `tests/test_stop_hook.sh` (case 8 assertions)

**Interfaces:**
- Consumes: `review_file`, `response_file`, `TASK`, `BASE`, `PROMPT_FILE`, `RUNNER` (unchanged from Phase 1).
- Produces: reviewer prompts that reference NO prior review/response file for any round; a `{{LEDGER}}` placeholder in `reviewer.md` that `prepare_round` substitutes with the contents of `LEDGER_FILE` (empty when the file is absent). Later tasks/phases rely on `prepare_round` no longer reading `reviewer-prev-context.md`.

- [ ] **Step 1: Update the test to expect NO prev-context (edit case 8)**

In `tests/test_stop_hook.sh`, find case 8 (`── 8. FINDINGS + response → next round prepared ──`). Replace its two prev-reference assertions:

```bash
chk "r2 prompt references r1 review" "$RF1" "$(cat .claude/spar-reviewer-prompt.txt)"
chk "r2 prompt references r1 response" "$RP1" "$(cat .claude/spar-reviewer-prompt.txt)"
```

with these (the conveyance boundary forbids referencing prior files):

```bash
chk "r2 prompt does NOT reference r1 review" "absent" \
  "$(grep -qF "$RF1" .claude/spar-reviewer-prompt.txt && echo present || echo absent)"
chk "r2 prompt does NOT reference r1 response" "absent" \
  "$(grep -qF "$RP1" .claude/spar-reviewer-prompt.txt && echo present || echo absent)"
chk "r2 prompt has no Previous-round section" "absent" \
  "$(grep -qi 'Previous round' .claude/spar-reviewer-prompt.txt && echo present || echo absent)"
```

- [ ] **Step 2: Add a conveyance assertion after case 4 (ledger slot resolves, prev-context file gone)**

Immediately after case 4b (the `no base_sha → HEAD fallback` block, before the `# helper: enter review phase` line), insert:

```bash
# ── 4c. conveyance boundary: no {{LEDGER}} placeholder leaks; prev-context template deleted ──
fresh_dir; write_state task 0
run_hook >/dev/null
chk "prompt resolves ledger slot (no {{LEDGER}})" "absent" \
  "$(grep -qF '{{LEDGER}}' .claude/spar-reviewer-prompt.txt && echo present || echo absent)"
chk "prev-context template deleted from plugin" "absent" \
  "$([ -f "$CLAUDE_PLUGIN_ROOT/shared/prompts/reviewer-prev-context.md" ] && echo present || echo absent)"
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: FAILs on the new/edited case-8 and case-4c assertions (hook still injects prev-context; template still exists), non-zero exit.

- [ ] **Step 4: Rewrite `reviewer.md` — replace `{{PREV_CONTEXT}}` with `{{LEDGER}}`**

In `plugins/spar/shared/prompts/reviewer.md`, replace the single line:

```
{{PREV_CONTEXT}}
```

with:

```
{{LEDGER}}
```

(The `{{LEDGER}}` slot sits in the same place, right after the "What to review" section. In Phase 2a it resolves to an empty string; Phase 2b fills it with recorded design decisions.)

- [ ] **Step 5: Delete the retired template**

Run:

```bash
git rm plugins/spar/shared/prompts/reviewer-prev-context.md
```

- [ ] **Step 6: Update `prepare_round` in the hook**

In `plugins/spar/hooks/stop-hook.sh`, replace the current `prepare_round` body's substitution block. Find:

```bash
  local prompt prev_ctx=""
  prompt=$(cat "$tpl_dir/reviewer.md")
  if [ "$n" -gt 1 ]; then
    prev_ctx=$(cat "$tpl_dir/reviewer-prev-context.md")
    prev_ctx=${prev_ctx//\{\{PREV_REVIEW\}\}/$(review_file $((n-1)))}
    prev_ctx=${prev_ctx//\{\{PREV_RESPONSE\}\}/$(response_file $((n-1)))}
  fi
  prompt=${prompt//\{\{TASK\}\}/$TASK}
  prompt=${prompt//\{\{ROUND\}\}/$n}
  prompt=${prompt//\{\{DIFF_BASE\}\}/$BASE}
  prompt=${prompt//\{\{PREV_CONTEXT\}\}/$prev_ctx}
```

and replace it with (no prior-round context; ledger injected from `LEDGER_FILE` if present):

```bash
  local prompt ledger=""
  prompt=$(cat "$tpl_dir/reviewer.md")
  [ -f "$LEDGER_FILE" ] && ledger=$(cat "$LEDGER_FILE")
  prompt=${prompt//\{\{TASK\}\}/$TASK}
  prompt=${prompt//\{\{ROUND\}\}/$n}
  prompt=${prompt//\{\{DIFF_BASE\}\}/$BASE}
  prompt=${prompt//\{\{LEDGER\}\}/$ledger}
```

- [ ] **Step 7: Declare `LEDGER_FILE` with the other path constants**

In `plugins/spar/hooks/stop-hook.sh`, find the path-constant block near the top:

```bash
LOG_FILE=".claude/spar.log"
STATE_FILE=".claude/spar.local.md"
RUNNER=".claude/spar-run-reviewer.sh"
PROMPT_FILE=".claude/spar-reviewer-prompt.txt"
RETRY_FILE=".claude/spar-retries"
```

Add one line after `RETRY_FILE`:

```bash
LEDGER_FILE=".claude/spar-ledger.md"
```

- [ ] **Step 8: Run tests — case 4, 4b, 4c, 8 all pass**

Run: `bash tests/test_stop_hook.sh`
Expected: all PASS, `FAIL=0`, exit 0.

- [ ] **Step 9: Update `policy.md` protocol step 2**

In `plugins/spar/shared/policy.md`, replace protocol step 2:

```
2. Reviewer receives: task description + instruction to inspect the diff
   itself (+ from round 2: previous review and author response files).
```

with:

```
2. Reviewer receives: task description + instruction to inspect the diff
   itself. Conveyance boundary — the reviewer is NEVER told what was fixed
   or rejected; every round is a full fresh re-review against the frozen
   baseline. The only loop-generated context conveyed is the decision ledger
   (empty until Phase 2b).
```

- [ ] **Step 10: Commit**

```bash
git add plugins/spar/shared/prompts/reviewer.md plugins/spar/hooks/stop-hook.sh plugins/spar/shared/policy.md tests/test_stop_hook.sh
git rm plugins/spar/shared/prompts/reviewer-prev-context.md
git commit -m "feat: conveyance boundary — retire prev-context, add empty ledger slot"
```

---

### Task 8: Finding parsing + fingerprint registry

Branch: `task/8-finding-registry`.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` (add parse/registry functions; extend `cleanup()`; call `fold_registry` in the `review` case)
- Modify: `plugins/spar/commands/spar-cancel.md` (remove registry sidecars)
- Modify: `tests/test_stop_hook.sh` (registry-folding cases)

**Interfaces:**
- Consumes: `review_file`, `response_file` (from Phase 1).
- Produces:
  - `REGISTRY_FILE=".claude/spar-registry.tsv"` — one row per canonical finding, tab-separated: `fp <TAB> tag <TAB> last_rejected_round <TAB> rejected_streak <TAB> status` (`status` ∈ `open` | `escalated`).
  - `REG_MARKER=".claude/spar-registry-round"` — highest round folded.
  - Functions used by Task 9: `fold_registry <round>`, `new_stalemates` (stdout: fingerprints with `rejected_streak >= 2` and `status == open`), `mark_escalated <fp>`.

- [ ] **Step 1: Write failing registry tests**

In `tests/test_stop_hook.sh`, immediately before the final `echo; echo "PASS=$PASS FAIL=$FAIL"` line, insert:

```bash
# ── 12. registry: DESIGN finding rejected once → recorded, streak 1, open ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: too big\n- suggestion: split\n' > "$RF1"
printf '### F1-1: REJECTED — cohesive on purpose\n' > "$RP1"
run_hook >/dev/null   # folds round 1, advances to round 2
chk "registry file created" 'kept' "$([ -f .claude/spar-registry.tsv ] && echo kept || echo lost)"
chk "registry recorded fingerprint" 'mod.py | split the module' "$(cat .claude/spar-registry.tsv)"
chk "registry streak 1 open" "$(printf 'DESIGN\t1\t1\topen')" "$(cat .claude/spar-registry.tsv)"

# ── 13. registry: FIXED disposition breaks the contest streak ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] missing guard\n- file: a.py:3\n- problem: npe\n- suggestion: guard\n' > "$RF1"
printf '### F1-1: FIXED — added guard\n' > "$RP1"
run_hook >/dev/null
chk "fixed finding → streak 0" "$(printf 'a.py | missing guard\tMECHANICAL\t0\t0\topen')" "$(cat .claude/spar-registry.tsv)"

# ── 14. registry: fold is idempotent per round ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] rename thing\n- file: x.py:1\n- problem: p\n- suggestion: s\n' > "$RF1"
printf '### F1-1: REJECTED — name is fine\n' > "$RP1"
run_hook >/dev/null                       # folds round 1 → row present, marker=1
LINES1=$(wc -l < .claude/spar-registry.tsv)
# force a second run at the SAME round by rewinding state to round 1
sed -i '' 's/^round: .*/round: 1/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^round: .*/round: 1/' .claude/spar.local.md
run_hook >/dev/null                       # marker already 1 → must NOT double-fold
LINES2=$(wc -l < .claude/spar-registry.tsv)
chk "fold idempotent (no duplicate rows)" "same" "$([ "$LINES1" = "$LINES2" ] && echo same || echo grew)"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: cases 12–14 FAIL (no registry file, functions absent), non-zero exit.

- [ ] **Step 3: Declare the registry path constants**

In `plugins/spar/hooks/stop-hook.sh`, after the `LEDGER_FILE=...` line added in Task 7, add:

```bash
REGISTRY_FILE=".claude/spar-registry.tsv"
REG_MARKER=".claude/spar-registry-round"
```

- [ ] **Step 4: Extend `cleanup()` to remove the registry sidecars**

Find:

```bash
cleanup() { rm -f "$STATE_FILE" "$RUNNER" "$PROMPT_FILE" "$RETRY_FILE"; }
```

Replace with:

```bash
cleanup() { rm -f "$STATE_FILE" "$RUNNER" "$PROMPT_FILE" "$RETRY_FILE" \
  "$LEDGER_FILE" "$REGISTRY_FILE" "$REG_MARKER"; }
```

- [ ] **Step 5: Add the parse + registry functions**

In `plugins/spar/hooks/stop-hook.sh`, insert this block immediately AFTER the `response_file()` definition (around line 46) and BEFORE `set_state()`:

```bash
# ── finding registry (Phase 2a: deterministic fingerprint) ──────────────────
# Parse reviewer findings → "id<TAB>tag<TAB>file<TAB>normalized-title" per line.
parse_findings() { # $1 = review file
  awk '
    function flush() {
      if (id != "") {
        t = tolower(title); gsub(/[^a-z0-9]+/, " ", t); gsub(/^ +| +$/, "", t)
        printf "%s\t%s\t%s\t%s\n", id, tag, file, t
      }
      id=""; tag=""; file=""; title=""
    }
    /^### F[0-9]+-[0-9]+/ {
      flush()
      id=$2
      tag="UNKNOWN"
      if (match($0, /\[MECHANICAL\]/)) tag="MECHANICAL"
      else if (match($0, /\[DESIGN\]/)) tag="DESIGN"
      title=$0
      sub(/^### F[0-9]+-[0-9]+[ ]*(\[[A-Z]+\][ ]*)?/, "", title)
      next
    }
    /^-[ ]*file:/ {
      if (id != "" && file == "") {
        file=$0
        sub(/^-[ ]*file:[ ]*/, "", file)
        sub(/:[0-9]+.*$/, "", file)
        gsub(/^[ ]+|[ ]+$/, "", file)
      }
      next
    }
    END { flush() }
  ' "$1" 2>/dev/null
}

# Parse author response → "id<TAB>FIXED|REJECTED|UNKNOWN" per finding.
parse_responses() { # $1 = response file
  awk '
    /^### F[0-9]+-[0-9]+:/ {
      id=$2; sub(/:$/, "", id)
      disp="UNKNOWN"
      if (match($0, /:[ ]*FIXED/)) disp="FIXED"
      else if (match($0, /:[ ]*REJECTED/)) disp="REJECTED"
      print id "\t" disp
      next
    }
  ' "$1" 2>/dev/null
}

# Upsert one finding into the registry.
update_registry() { # $1=fp $2=tag $3=round $4=disposition
  local fp="$1" tag="$2" n="$3" disp="$4"
  local tmp="${REGISTRY_FILE}.tmp.$$"
  touch "$REGISTRY_FILE"
  awk -F'\t' -v OFS='\t' -v fp="$fp" -v tag="$tag" -v n="$n" -v disp="$disp" '
    $1==fp {
      found=1; lastrej=$3; streak=$4; status=$5
      if (disp=="REJECTED") { if (lastrej==n-1) streak=streak+1; else streak=1; lastrej=n }
      else { streak=0 }
      print $1, tag, lastrej, streak, status
      next
    }
    { print }
    END {
      if (!found) {
        if (disp=="REJECTED") print fp, tag, n, 1, "open"
        else print fp, tag, 0, 0, "open"
      }
    }
  ' "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

# Fold one round's findings+responses into the registry (idempotent per round).
fold_registry() { # $1 = round
  local n="$1"
  local marker; marker=$(cat "$REG_MARKER" 2>/dev/null || echo 0)
  case "$marker" in ''|*[!0-9]*) marker=0;; esac
  [ "$n" -le "$marker" ] && return 0
  local rf resp; rf=$(review_file "$n"); resp=$(response_file "$n")
  [ -f "$rf" ] && [ -f "$resp" ] || return 0
  local dmap; dmap=$(mktemp) || return 0
  parse_responses "$resp" > "$dmap"
  local id tag file nt disp fp
  while IFS=$'\t' read -r id tag file nt; do
    [ -n "$id" ] || continue
    disp=$(awk -F'\t' -v i="$id" '$1==i{print $2; exit}' "$dmap")
    [ -n "$disp" ] || disp="UNKNOWN"
    fp="${file} | ${nt}"
    update_registry "$fp" "$tag" "$n" "$disp"
  done < <(parse_findings "$rf")
  rm -f "$dmap"
  echo "$n" > "$REG_MARKER"
}

# Fingerprints at a 2-round stalemate and not yet escalated.
new_stalemates() {
  [ -f "$REGISTRY_FILE" ] || return 0
  awk -F'\t' '$4>=2 && $5=="open" {print $1}' "$REGISTRY_FILE" 2>/dev/null
}

# Mark a fingerprint escalated so it never re-fires.
mark_escalated() { # $1=fp
  local fp="$1" tmp="${REGISTRY_FILE}.tmp.$$"
  [ -f "$REGISTRY_FILE" ] || return 0
  awk -F'\t' -v OFS='\t' -v fp="$fp" '$1==fp{$5="escalated"} {print}' \
    "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}
```

- [ ] **Step 6: Call `fold_registry` in the review case (after the response gate)**

In the `review)` case of `stop-hook.sh`, find the response-gate block that ends:

```bash
        "sparring [${REVIEW_ID}] round ${ROUND}: respond to findings"
    fi

    if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
```

Insert a `fold_registry` call between the `fi` and the round-cap check:

```bash
        "sparring [${REVIEW_ID}] round ${ROUND}: respond to findings"
    fi

    fold_registry "$ROUND"

    if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
```

(Task 9 adds the stalemate check right after this `fold_registry` line.)

- [ ] **Step 7: Run tests — cases 12–14 pass**

Run: `bash tests/test_stop_hook.sh`
Expected: all PASS, `FAIL=0`, exit 0.

- [ ] **Step 8: Update `/spar-cancel` to remove registry sidecars**

In `plugins/spar/commands/spar-cancel.md`, replace the cleanup line:

```bash
rm -f .claude/spar.local.md .claude/spar-run-reviewer.sh .claude/spar-reviewer-prompt.txt .claude/spar-retries
```

with:

```bash
rm -f .claude/spar.local.md .claude/spar-run-reviewer.sh .claude/spar-reviewer-prompt.txt .claude/spar-retries .claude/spar-ledger.md .claude/spar-registry.tsv .claude/spar-registry-round
```

- [ ] **Step 9: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh plugins/spar/commands/spar-cancel.md tests/test_stop_hook.sh
git commit -m "feat: deterministic finding fingerprint registry (fold per round)"
```

---

### Task 9: Stalemate detection + one-shot user escalation

Branch: `task/9-stalemate-escalation`.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` (stalemate check after `fold_registry`)
- Modify: `plugins/spar/shared/policy.md` (stalemate note)
- Modify: `plugins/spar/commands/spar.md` (loop-protocol note)
- Modify: `tests/test_stop_hook.sh` (stalemate cases)

**Interfaces:**
- Consumes: `fold_registry`, `new_stalemates`, `mark_escalated` (Task 8); `block`, `review_file` (Phase 1).
- Produces: a review-phase branch that, when a finding reaches a 2-round rejected streak, blocks once with an escalation message and marks each such fingerprint `escalated`; on the next stop the loop resumes normally.

- [ ] **Step 1: Write failing stalemate tests**

In `tests/test_stop_hook.sh`, before the final `echo; echo "PASS=$PASS FAIL=$FAIL"` line, insert:

```bash
# ── 15. stalemate: same finding rejected two consecutive rounds → escalation block ──
fresh_dir; write_state review 1; mkdir -p reviews
RFa="reviews/spar-20260721-120000-abc123-r1.md"
RPa="reviews/spar-20260721-120000-abc123-r1-response.md"
RFb="reviews/spar-20260721-120000-abc123-r2.md"
RPb="reviews/spar-20260721-120000-abc123-r2-response.md"
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFa"
printf '### F1-1: REJECTED — cohesive on purpose\n' > "$RPa"
run_hook >/dev/null            # fold r1 (streak 1), advance to r2
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: still big\n- suggestion: split\n' > "$RFb"
printf '### F2-1: REJECTED — still cohesive\n' > "$RPb"
OUT=$(run_hook)                # fold r2 (streak 2) → stalemate
chk "stalemate → block" '"decision":"block"' "$OUT"
chk "stalemate → message says stalemate" 'stalemate' "$OUT"
chk "stalemate → fingerprint marked escalated" 'escalated' "$(cat .claude/spar-registry.tsv)"

# ── 16. stalemate fires once: next stop resumes the loop (round 3 prepared) ──
OUT2=$(run_hook)
chk "stalemate one-shot → advances to round 3" 'round: 3' "$(cat .claude/spar.local.md)"
chk "stalemate one-shot → block runs reviewer" 'run-reviewer' "$OUT2"

# ── 17. no stalemate when the streak is broken by a FIXED round ──
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFa"
printf '### F1-1: REJECTED — cohesive\n' > "$RPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFb"
printf '### F2-1: FIXED — split it\n' > "$RPb"
OUT=$(run_hook)
chk "fixed second round → no stalemate block" 'round: 3' "$(cat .claude/spar.local.md)"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: cases 15–16 FAIL (no stalemate branch yet — hook just advances the round), non-zero exit. Case 17 already passes.

- [ ] **Step 3: Add the stalemate branch after `fold_registry`**

In `stop-hook.sh`, find the line added in Task 8:

```bash
    fold_registry "$ROUND"

    if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
```

Insert the stalemate check between `fold_registry` and the round-cap check:

```bash
    fold_registry "$ROUND"

    STALE=$(new_stalemates)
    if [ -n "$STALE" ]; then
      while IFS= read -r fp; do [ -n "$fp" ] && mark_escalated "$fp"; done <<STALE_EOF
$STALE
STALE_EOF
      block "Stalemate: the following finding(s) were raised by the reviewer AND
rejected by you for 2 consecutive rounds:

${STALE}

Automated adjudication (blind judge / batched user gate) lands in Phase 2b.
For now, do NOT keep deciding this yourself: surface the disagreement to the
user — give the reviewer's problem and your rejection reason — and let them
rule. Apply their decision and note it. Then stop again; the loop continues
on everything else (this stalemate will not be raised again)." \
        "sparring [${REVIEW_ID}] round ${ROUND}: stalemate — user decision needed"
    fi

    if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
```

- [ ] **Step 4: Run tests — all pass**

Run: `bash tests/test_stop_hook.sh`
Expected: all cases PASS, `PASS=… FAIL=0`, exit 0.

- [ ] **Step 5: Update `policy.md` with the stalemate protocol note**

In `plugins/spar/shared/policy.md`, in the `## Protocol` section, append a step after the current step 5:

```
6. Stalemate — a finding the reviewer raises AND the author rejects for 2
   consecutive rounds. The orchestrator detects it deterministically (a
   file+title fingerprint) and escalates ONCE to the user, then continues the
   loop on everything else. (Phase 2b routes factual stalemates to a blind
   judge and design stalemates to a batched end-of-loop gate; Phase 2a does
   the single user escalation for both.)
```

- [ ] **Step 6: Add a loop-protocol note to `/spar`**

In `plugins/spar/commands/spar.md`, in the `## Loop protocol` list, after item 4, add:

```
5. If the hook reports a **stalemate**, do not keep re-deciding the finding
   yourself. Present the reviewer's problem and your rejection reason to the
   user, apply their ruling, and stop again — the loop continues on the rest.
```

- [ ] **Step 7: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh plugins/spar/shared/policy.md plugins/spar/commands/spar.md tests/test_stop_hook.sh
git commit -m "feat: 2-round stalemate detection + one-shot user escalation"
```

- [ ] **Step 8: Full suite + reinstall + honest status note**

Run the whole test suite once more and reinstall the plugin locally:

```bash
bash tests/test_stop_hook.sh && echo "ALL PASS"
claude plugin marketplace update sparring 2>/dev/null || true
```

Expected: `ALL PASS`. Phase 2a is NOT the whole of Phase 2 — the README roadmap row for Phase 2 stays `planned` (judge, gate, and ledger population are Phase 2b/2c). Do not mark Phase 2 done.

---

## Self-Review Notes

- **Spec coverage (design-decisions.md Phase 2):** conveyance boundary (Task 7 — prev-context retired, ledger slot added), orchestrator-side finding identity with reviewer-local `F<r>-<n>` vs deterministic canonical fingerprint (Task 8), registry separate from the ledger (Task 8 — registry is a sidecar; ledger file is untouched here), stalemate = raised+rejected 2 consecutive rounds (Task 9), reviewer-declares preserved (no path forces a round after `CONVERGED`; the stalemate branch runs only in the `FINDINGS`+response flow), staged implementation order followed (this is stage 1–2 of the doc's five; judge/gate = 2b, semantic matching = 2c). Out of scope for 2a and intentionally deferred: blind judge, end-of-loop gate, decision-ledger population, parked vs blocked-pending-user split, model-based semantic matching, final report.
- **Fail-open check:** `parse_findings`/`parse_responses` swallow errors (`2>/dev/null`); `fold_registry` returns early on any missing file or `mktemp` failure; `new_stalemates` returns nothing if the registry is absent. No new path can block on internal error — worst case a stalemate simply goes undetected and the existing round cap still bounds the loop.
- **Idempotency:** `fold_registry` is guarded by `REG_MARKER` (round already folded → no-op), covered by case 14. The stalemate branch does not advance the round; it marks `escalated` so `new_stalemates` returns empty on the next stop (cases 15–16), then the normal advance path runs.
- **Type/name consistency:** `REGISTRY_FILE`/`REG_MARKER`/`LEDGER_FILE` declared in Tasks 7–8, consumed in Tasks 8–9 and `cleanup()`/`/spar-cancel`. Registry row shape `fp<TAB>tag<TAB>last_rejected_round<TAB>rejected_streak<TAB>status` is written by `update_registry` and read by `new_stalemates`/`mark_escalated` with matching field indices (`$4` streak, `$5` status). Fingerprint format `"<file> | <normtitle>"` identical in `fold_registry` (build) and the case-12 assertion.
- **Placeholder scan:** none — every step carries full file contents or exact commands.
