# sparring Phase 2b (Blind Judge for Factual Stalemates) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a `[MECHANICAL]` (factual) finding reaches a 2-round stalemate, adjudicate it with a blind independent judge — a fresh `codex exec --sandbox read-only` run that sees only the finding, the code, and the task (never the debate) — and act on its binding `UPHELD`/`DISMISSED` ruling. `[DESIGN]` stalemates keep the Phase 2a user-escalation behavior unchanged (the batched gate is Phase 2c).

**Architecture:** Reuse the reviewer-runner pattern. The Stop hook already detects stalemates from the Phase 2a registry (`new_stalemates`). Phase 2b replaces the single Phase 2a stalemate block with routing: a `[MECHANICAL]` stalemate makes the hook generate a judge runner (`.claude/spar-run-judge.sh`) targeting that one finding, record a pending marker, and block asking the author to run it; on the next stop the hook reads the ruling file and either forces a fix (`UPHELD`) or drops the finding (`DISMISSED`). The author only *executes* the judge runner — it cannot author the ruling, so the "author never grades its own work" invariant extends to adjudication. Judges are serialized (one pending at a time). `[DESIGN]` stalemates route to the unchanged Phase 2a user escalation.

**Tech Stack:** Bash (hook + `awk` parsing/extraction), Codex CLI (`codex exec`, read-only, `--output-last-message`), pure-bash test harness (`tests/test_stop_hook.sh`). No new runtime dependencies.

## Global Constraints

- Plugin name: `spar`. Repo root: `~/Workspace/sparring`. Work on branches `task/10-*`, `task/11-*` (task numbering continues globally); merge each into `dev`. This plan document is committed directly to `dev`.
- Builds on Phase 2a (merged): the registry (`.claude/spar-registry.tsv`, rows `fp<TAB>tag<TAB>last_rejected_round<TAB>rejected_streak<TAB>status`), `fold_registry`, `new_stalemates` (streak≥2 AND status==open), `mark_escalated`. Fingerprint is `"<file> | <normalized-title>"`.
- Invariant 2 (reviewer-declares) is inviolate: `STATUS: CONVERGED` still exits before any stalemate/judge code runs. The judge rules on findings, never on convergence.
- Invariant 3 (deterministic enforcement, fail-open): every new path fails **open**. If the judge template is missing, a finding cannot be extracted, or a ruling never arrives / is unreadable (after retries), the finding falls back to the Phase 2a user escalation — never a trap the user cannot escape.
- Invariant 4 (blind adjudication): the judge prompt contains ONLY the task, the diff-base instruction, and the one disputed finding. It must NEVER include prior reviews, responses, the debate, or other findings.
- Judge mechanism (from design-decisions.md Phase 2 point 3): `codex exec --sandbox read-only`, hook-generated runner, ruling file first line exactly `RULING: UPHELD` or `RULING: DISMISSED`. Routing is by tag: `[MECHANICAL]` stalemate → judge; `[DESIGN]` stalemate → user escalation (Phase 2a behavior, unchanged here).
- Judges are serialized: at most one judge pending at a time (`.claude/spar-judge-pending`). A `DISMISSED` ruling falls through so the same stop can route the next stalemate; `UPHELD` blocks for the fix.
- Registry status vocabulary after 2b: `open` (active), `escalated` (DESIGN → user), `judging` (judge dispatched), `upheld`, `dismissed`. `new_stalemates` returns only `open`, so every terminal status is excluded from re-firing.
- All new sidecar files live in `.claude/` and are removed by `cleanup()` and `/spar-cancel`. No new state-file front-matter fields.
- Ledger population, the batched design gate, and parked/blocked states are OUT OF SCOPE (Phase 2c). Model-based semantic finding matching is OUT OF SCOPE (Phase 2d).
- Known accepted limitation (document, do not fix here): if the author defies an `UPHELD` ruling and keeps rejecting the finding, the registry status stays `upheld` (not `open`) so no new stalemate re-fires; the reviewer keeps re-raising it and the round cap bounds the loop. Hard-enforcing obedience is future work.

## File Structure

```
plugins/spar/
├── hooks/stop-hook.sh                 # MODIFY: constants, registry-status helpers, extract_finding, prepare_judge, review-phase routing (replace the 2a stalemate block)
├── shared/prompts/judge.md            # CREATE: blind judge prompt template
├── shared/policy.md                   # MODIFY: judge note in protocol
└── commands/
    ├── spar.md                        # MODIFY: loop-protocol note for judge
    └── spar-cancel.md                 # MODIFY: remove judge sidecar files
tests/test_stop_hook.sh                # MODIFY: judge-flow cases (dispatch, upheld, dismissed, pending, invalid/fail-open); confirm DESIGN path unchanged
```

New hook-owned runtime files (added to `cleanup()`):
- `.claude/spar-run-judge.sh` — generated judge runner.
- `.claude/spar-judge-prompt.txt` — the judge prompt for the current dispatch.
- `.claude/spar-judge-pending` — one line `<fp><TAB><ruling_file>` while a ruling is awaited.
- `.claude/spar-judge-seq` — monotonic judge counter (unique ruling filenames).
- `.claude/spar-judge-retries` — retry counter for a missing/invalid ruling.
- Judge ruling files: `reviews/spar-<id>-judge-<K>.md` (audit artifacts, like reviews).

---

### Task 10: Blind judge flow (dispatch + ruling resolution + routing)

Branch: `task/10-blind-judge`.

**Files:**
- Create: `plugins/spar/shared/prompts/judge.md`
- Modify: `plugins/spar/hooks/stop-hook.sh`
- Modify: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: `new_stalemates`, `mark_escalated`, `review_file`, `TASK`, `BASE`, `REVIEW_ID`, `ROUND`, `block`, `log`, `cleanup` (existing).
- Produces: `registry_tag <fp>` (prints tag), `set_registry_status <fp> <status>`, `extract_finding <review-file> <fp>` (prints the finding's markdown block), `prepare_judge <fp>` (writes judge runner/prompt/pending, sets status `judging`; returns non-zero on failure). Review-phase routing that Task 11 documents.

- [ ] **Step 1: Write the judge prompt template**

Create `plugins/spar/shared/prompts/judge.md`:

```markdown
You are an independent judge. You did NOT write this code, you did NOT raise
this finding, and you must not modify anything — you are in a read-only
sandbox. You are ruling on ONE disputed finding. You are shown NO debate, NO
prior reviews, and NO author responses — only the finding, the code, and the
task. Rule on the merits alone.

## Task the author was given

{{TASK}}

## The disputed finding

{{FINDING}}

## What to decide

Inspect the code with `git diff {{DIFF_BASE}}` and by reading the cited
file(s). Decide ONE factual question: is this finding a real defect that must
be fixed for the code to meet the task above?

## Output format (STRICT — a script parses your first line)

Your FIRST line must be exactly one of:

RULING: UPHELD
RULING: DISMISSED

Then one short paragraph justifying the ruling, grounded in the code and the
task. UPHELD = the finding is a real defect the author must fix. DISMISSED =
the finding does not hold (not a real defect, or outside the task's scope).
```

- [ ] **Step 2: Write the failing tests (judge flow)**

In `tests/test_stop_hook.sh`, insert BEFORE the final `echo; echo "PASS=$PASS FAIL=$FAIL"` line. These drive two real rounds to reach a stalemate, then simulate the codex ruling by writing the ruling file the pending marker names.

```bash
# helpers for two-round stalemate scenarios
RFa="reviews/spar-20260721-120000-abc123-r1.md"
RPa="reviews/spar-20260721-120000-abc123-r1-response.md"
RFb="reviews/spar-20260721-120000-abc123-r2.md"
RPb="reviews/spar-20260721-120000-abc123-r2-response.md"
mech_stalemate() { # drive a MECHANICAL finding rejected in rounds 1 and 2; leaves state at round 2 processed
  fresh_dir; write_state review 1; mkdir -p reviews
  printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] null deref\n- file: a.py:5\n- problem: npe\n- suggestion: guard\n' > "$RFa"
  printf '### F1-1: REJECTED — not reachable\n' > "$RPa"
  run_hook >/dev/null   # fold r1 (streak 1), advance to r2
  printf 'STATUS: FINDINGS\n\n### F2-1 [MECHANICAL] null deref\n- file: a.py:5\n- problem: npe\n- suggestion: guard\n' > "$RFb"
  printf '### F2-1: REJECTED — still not reachable\n' > "$RPb"
}

# ── 18. MECHANICAL stalemate → blind judge dispatched ──
mech_stalemate
OUT=$(run_hook)   # fold r2 (streak 2) → MECHANICAL stalemate → dispatch judge
chk "mech stalemate → judge block" 'run-judge' "$OUT"
chk_file "judge runner generated" .claude/spar-run-judge.sh
chk "judge runner read-only sandbox" 'sandbox read-only' "$(cat .claude/spar-run-judge.sh)"
chk "judge pending records fingerprint" 'a.py | null deref' "$(cat .claude/spar-judge-pending)"
chk "judge prompt carries the finding" 'null deref' "$(cat .claude/spar-judge-prompt.txt)"
chk "judge prompt has no leftover placeholder" 'CLEAN' "$(grep -q '{{' .claude/spar-judge-prompt.txt && echo DIRTY || echo CLEAN)"
chk "judge prompt is blind (no response text)" "absent" \
  "$(grep -qi 'not reachable' .claude/spar-judge-prompt.txt && echo present || echo absent)"
chk "registry status judging" "$(printf 'a.py | null deref\tMECHANICAL\t2\t2\tjudging')" "$(cat .claude/spar-registry.tsv)"

# ── 19. judge UPHELD → fix-required block, status upheld, pending cleared ──
JOUT=$(cut -f2 .claude/spar-judge-pending)
printf 'RULING: UPHELD\n\nReachable via the public API.\n' > "$JOUT"
OUT=$(run_hook)
chk "upheld → block demands fix" 'UPHELD' "$OUT"
chk "upheld → status upheld" "$(printf '\t2\t2\tupheld')" "$(cat .claude/spar-registry.tsv)"
chk "upheld → pending cleared" "gone" "$([ -f .claude/spar-judge-pending ] && echo present || echo gone)"

# ── 20. judge DISMISSED → status dismissed, no judge block, round advances ──
mech_stalemate
run_hook >/dev/null                      # dispatch judge
JOUT=$(cut -f2 .claude/spar-judge-pending)
printf 'RULING: DISMISSED\n\nGuarded upstream; not a defect.\n' > "$JOUT"
run_hook >/dev/null                      # resolve dismissed → fall through → advance
chk "dismissed → status dismissed" "$(printf '\t2\t2\tdismissed')" "$(cat .claude/spar-registry.tsv)"
chk "dismissed → round advanced to 3" 'round: 3' "$(cat .claude/spar.local.md)"

# ── 21. judge ruling missing → pending block (retry) ──
mech_stalemate
run_hook >/dev/null                      # dispatch judge (ruling file not written)
OUT=$(run_hook)                          # ruling still absent
chk "ruling missing → pending block" 'judge' "$OUT"
chk "ruling missing → still pending" "kept" "$([ -f .claude/spar-judge-pending ] && echo kept || echo gone)"

# ── 22. judge ruling invalid 3× → fail open to user escalation ──
mech_stalemate
run_hook >/dev/null                      # dispatch judge
JOUT=$(cut -f2 .claude/spar-judge-pending)
printf 'codex crashed\n' > "$JOUT"; run_hook >/dev/null      # invalid 1 → set aside + re-dispatch
JOUT=$(cut -f2 .claude/spar-judge-pending)
printf 'still broken\n' > "$JOUT"; run_hook >/dev/null       # invalid 2
JOUT=$(cut -f2 .claude/spar-judge-pending)
printf 'nope\n' > "$JOUT"
OUT=$(run_hook)                                              # invalid 3 → fail open
chk "invalid ruling 3× → user escalation" 'user decision' "$OUT"
chk "invalid ruling 3× → status escalated" 'escalated' "$(cat .claude/spar-registry.tsv)"

# ── 23. DESIGN stalemate still uses Phase 2a user escalation (unchanged) ──
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFa"
printf '### F1-1: REJECTED — cohesive\n' > "$RPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFb"
printf '### F2-1: REJECTED — cohesive\n' > "$RPb"
OUT=$(run_hook)
chk "design stalemate → user escalation, not judge" "$([ -f .claude/spar-run-judge.sh ] && echo judge || echo escalation)" "escalation"
chk "design stalemate → escalated status" 'escalated' "$(cat .claude/spar-registry.tsv)"
chk "design stalemate → block mentions stalemate" 'stalemate' "$OUT"
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: cases 18–22 FAIL (no judge machinery yet — a MECHANICAL stalemate still hits the 2a escalation), case 23 still passes (DESIGN path exists). Non-zero exit.

- [ ] **Step 4: Add the judge sidecar constants**

In `plugins/spar/hooks/stop-hook.sh`, after the `REG_MARKER=...` line (currently line 14), add:

```bash
JUDGE_RUNNER=".claude/spar-run-judge.sh"
JUDGE_PROMPT_FILE=".claude/spar-judge-prompt.txt"
JUDGE_PENDING=".claude/spar-judge-pending"
JUDGE_SEQ=".claude/spar-judge-seq"
JUDGE_RETRY=".claude/spar-judge-retries"
```

- [ ] **Step 5: Add the judge sidecars to `cleanup()`**

Replace the current `cleanup()`:

```bash
cleanup() { rm -f "$STATE_FILE" "$RUNNER" "$PROMPT_FILE" "$RETRY_FILE" \
  "$LEDGER_FILE" "$REGISTRY_FILE" "$REG_MARKER"; }
```

with:

```bash
cleanup() { rm -f "$STATE_FILE" "$RUNNER" "$PROMPT_FILE" "$RETRY_FILE" \
  "$LEDGER_FILE" "$REGISTRY_FILE" "$REG_MARKER" \
  "$JUDGE_RUNNER" "$JUDGE_PROMPT_FILE" "$JUDGE_PENDING" "$JUDGE_SEQ" "$JUDGE_RETRY"; }
```

- [ ] **Step 6: Add registry-status helpers and refactor `mark_escalated`**

In `stop-hook.sh`, replace the current `mark_escalated` definition:

```bash
# Mark a fingerprint escalated so it never re-fires.
mark_escalated() { # $1=fp
  local fp="$1" tmp="${REGISTRY_FILE}.tmp.$$"
  [ -f "$REGISTRY_FILE" ] || return 0
  awk -F'\t' -v OFS='\t' -v fp="$fp" '$1==fp{$5="escalated"} {print}' \
    "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}
```

with a generic status setter plus a tag reader (and `mark_escalated` as a thin wrapper):

```bash
# Set a fingerprint's status column.
set_registry_status() { # $1=fp $2=status
  local fp="$1" st="$2" tmp="${REGISTRY_FILE}.tmp.$$"
  [ -f "$REGISTRY_FILE" ] || return 0
  awk -F'\t' -v OFS='\t' -v fp="$fp" -v st="$st" '$1==fp{$5=st} {print}' \
    "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

# Tag of a fingerprint (MECHANICAL | DESIGN | UNKNOWN).
registry_tag() { # $1=fp
  [ -f "$REGISTRY_FILE" ] || return 0
  awk -F'\t' -v fp="$1" '$1==fp{print $2; exit}' "$REGISTRY_FILE" 2>/dev/null
}

# Mark a fingerprint escalated so it never re-fires.
mark_escalated() { set_registry_status "$1" escalated; }
```

- [ ] **Step 7: Add `extract_finding` and `prepare_judge`**

In `stop-hook.sh`, insert immediately AFTER `prepare_round` (after its closing `}` and `chmod +x` block, currently around line 194) and BEFORE the `command -v codex` check:

```bash
# Extract the markdown block of the finding whose fingerprint matches $2.
extract_finding() { # $1=review file  $2=fingerprint
  awk -v target="$2" '
    function norm(s){ s=tolower(s); gsub(/[^a-z0-9]+/," ",s); gsub(/^ +| +$/,"",s); return s }
    function flush(){
      if (hdr!=""){
        f=file; sub(/:[0-9]+.*$/,"",f); gsub(/^[ ]+|[ ]+$/,"",f)
        if ((f " | " norm(title))==target) printf "%s", buf
      }
      hdr=""; title=""; file=""; buf=""
    }
    /^### F[0-9]+-[0-9]+/ {
      flush()
      hdr=$0; buf=$0 "\n"
      title=$0; sub(/^### F[0-9]+-[0-9]+[ ]*(\[[A-Z]+\][ ]*)?/,"",title)
      next
    }
    {
      if (hdr!=""){
        buf=buf $0 "\n"
        if (file=="" && $0 ~ /^-[ ]*file:/){ file=$0; sub(/^-[ ]*file:[ ]*/,"",file) }
      }
    }
    END { flush() }
  ' "$1" 2>/dev/null
}

# Dispatch a blind judge for one fingerprint: writes prompt + runner + pending,
# sets status judging. Returns non-zero (caller falls back to escalation) if the
# template is missing or the finding cannot be extracted.
prepare_judge() { # $1=fingerprint
  local fp="$1"
  local tpl_dir="${CLAUDE_PLUGIN_ROOT:-}/shared/prompts"
  [ -f "$tpl_dir/judge.md" ] || { log "judge template missing"; return 1; }
  local finding; finding=$(extract_finding "$(review_file "$ROUND")" "$fp")
  [ -n "$finding" ] || { log "cannot extract finding for judge: $fp"; return 1; }
  local prompt; prompt=$(cat "$tpl_dir/judge.md")
  prompt=${prompt//\{\{TASK\}\}/$TASK}
  prompt=${prompt//\{\{DIFF_BASE\}\}/$BASE}
  prompt=${prompt//\{\{FINDING\}\}/$finding}
  mkdir -p reviews .claude
  printf '%s' "$prompt" > "$JUDGE_PROMPT_FILE"
  local k; k=$(cat "$JUDGE_SEQ" 2>/dev/null || echo 0)
  case "$k" in ''|*[!0-9]*) k=0;; esac; k=$((k+1)); echo "$k" > "$JUDGE_SEQ"
  local out="reviews/spar-${REVIEW_ID}-judge-${k}.md"
  cat > "$JUDGE_RUNNER" <<EOF
#!/usr/bin/env bash
# sparring judge runner (generated; do not edit)
set -uo pipefail
mkdir -p reviews
codex exec --sandbox read-only --skip-git-repo-check \\
  --output-last-message "${out}" < "${JUDGE_PROMPT_FILE}"
EOF
  chmod +x "$JUDGE_RUNNER"
  printf '%s\t%s\n' "$fp" "$out" > "$JUDGE_PENDING"
  set_registry_status "$fp" judging
  return 0
}
```

- [ ] **Step 8: Replace the Phase 2a stalemate block with judge routing**

In the `review)` case of `stop-hook.sh`, replace the entire current stalemate block (from `STALE=$(new_stalemates)` through its closing `fi`, currently lines 270–286) with:

```bash
    # (A) A judge ruling is pending → resolve it before routing anything new.
    if [ -f "$JUDGE_PENDING" ]; then
      jfp=$(cut -f1 "$JUDGE_PENDING"); jout=$(cut -f2 "$JUDGE_PENDING")
      if [ ! -f "$jout" ]; then
        jn=$(cat "$JUDGE_RETRY" 2>/dev/null || echo 0); jn=$((jn+1))
        if [ "$jn" -ge 3 ]; then
          log "judge never produced $jout — fail open to user escalation"
          rm -f "$JUDGE_PENDING" "$JUDGE_RUNNER" "$JUDGE_RETRY"
          set_registry_status "$jfp" escalated
          block "The independent judge produced no ruling. Surface finding
'${jfp}' to the user for a decision, apply it, then stop." \
            "sparring [${REVIEW_ID}]: judge failed — user decision needed"
        fi
        echo "$jn" > "$JUDGE_RETRY"
        block "A judge ruling is pending. Run:
\`\`\`
bash ${JUDGE_RUNNER}
\`\`\`
Then stop again." "sparring [${REVIEW_ID}]: judge pending"
      fi
      JRULING=$(head -1 "$jout" | tr -d '\r')
      if [ "$JRULING" = "RULING: UPHELD" ]; then
        rm -f "$JUDGE_PENDING" "$JUDGE_RUNNER" "$JUDGE_RETRY"
        set_registry_status "$jfp" upheld
        block "The independent judge UPHELD finding '${jfp}': it is a real
defect. You may no longer reject it — FIX it now. The next round's review
verifies the fix. Then stop again." \
          "sparring [${REVIEW_ID}]: judge upheld — fix required"
      elif [ "$JRULING" = "RULING: DISMISSED" ]; then
        rm -f "$JUDGE_PENDING" "$JUDGE_RUNNER" "$JUDGE_RETRY"
        set_registry_status "$jfp" dismissed
        log "judge dismissed $jfp"
        # fall through — this same stop routes any remaining stalemate
      else
        jn=$(cat "$JUDGE_RETRY" 2>/dev/null || echo 0); jn=$((jn+1))
        if [ "$jn" -ge 3 ]; then
          log "judge ruling invalid ${jn}x — fail open to user escalation"
          rm -f "$JUDGE_PENDING" "$JUDGE_RUNNER" "$JUDGE_RETRY"
          set_registry_status "$jfp" escalated
          block "The judge ruling was unreadable three times. Surface finding
'${jfp}' to the user for a decision, apply it, then stop." \
            "sparring [${REVIEW_ID}]: judge unreadable — user decision needed"
        fi
        echo "$jn" > "$JUDGE_RETRY"
        mv "$jout" "${jout}.invalid-${jn}" 2>/dev/null
        if prepare_judge "$jfp"; then
          block "The judge output was invalid (first line was neither
'RULING: UPHELD' nor 'RULING: DISMISSED'; set aside). Re-run:
\`\`\`
bash ${JUDGE_RUNNER}
\`\`\`
Then stop again." "sparring [${REVIEW_ID}]: judge invalid — rerun"
        else
          rm -f "$JUDGE_PENDING"
          set_registry_status "$jfp" escalated
          block "The judge could not be re-dispatched. Surface finding
'${jfp}' to the user for a decision, apply it, then stop." \
            "sparring [${REVIEW_ID}]: judge unavailable — user decision needed"
        fi
      fi
    fi

    # (B) Route new stalemates: [MECHANICAL] → blind judge, [DESIGN] → user escalation.
    STALE=$(new_stalemates)
    if [ -n "$STALE" ]; then
      mech_fp=""; design_fps=""
      while IFS= read -r fp; do
        [ -n "$fp" ] || continue
        if [ "$(registry_tag "$fp")" = "MECHANICAL" ]; then
          [ -z "$mech_fp" ] && mech_fp="$fp"
        else
          design_fps="${design_fps}${fp}
"
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
          design_fps="${design_fps}${mech_fp}
"
        fi
      fi

      if [ -n "$design_fps" ]; then
        while IFS= read -r fp; do [ -n "$fp" ] && mark_escalated "$fp"; done <<D_EOF
$design_fps
D_EOF
        block "Stalemate: the following design finding(s) were raised AND
rejected for 2 consecutive rounds:

${design_fps}
Automated design adjudication (batched user gate) lands in Phase 2c. For now,
surface each to the user — give the reviewer's problem and your rejection
reason — let them rule, apply it, and stop again. The loop continues on
everything else (these will not be raised again)." \
          "sparring [${REVIEW_ID}] round ${ROUND}: design stalemate — user decision needed"
      fi
    fi
```

- [ ] **Step 9: Run tests — all pass**

Run: `bash tests/test_stop_hook.sh`
Expected: all cases PASS (1–17 unchanged, 18–23 new), `FAIL=0`, exit 0.

- [ ] **Step 10: Commit**

```bash
git add plugins/spar/shared/prompts/judge.md plugins/spar/hooks/stop-hook.sh tests/test_stop_hook.sh
git commit -m "feat: blind judge for factual (MECHANICAL) stalemates — codex runner, UPHELD/DISMISSED"
```

---

### Task 11: Cancel cleanup, docs, and verification

Branch: `task/11-judge-docs`.

**Files:**
- Modify: `plugins/spar/commands/spar-cancel.md`
- Modify: `plugins/spar/shared/policy.md`
- Modify: `plugins/spar/commands/spar.md`

**Interfaces:**
- Consumes: the judge sidecar filenames from Task 10.
- Produces: user-facing docs describing the judge; a clean `/spar-cancel`.

- [ ] **Step 1: Extend `/spar-cancel` to remove judge sidecars**

In `plugins/spar/commands/spar-cancel.md`, replace the `rm -f` line so it also removes the judge sidecars. The line currently ends with `.claude/spar-registry.tsv .claude/spar-registry-round`; append:

```
.claude/spar-run-judge.sh .claude/spar-judge-prompt.txt .claude/spar-judge-pending .claude/spar-judge-seq .claude/spar-judge-retries
```

so the full command becomes (single line):

```bash
rm -f .claude/spar.local.md .claude/spar-run-reviewer.sh .claude/spar-reviewer-prompt.txt .claude/spar-retries .claude/spar-ledger.md .claude/spar-registry.tsv .claude/spar-registry-round .claude/spar-run-judge.sh .claude/spar-judge-prompt.txt .claude/spar-judge-pending .claude/spar-judge-seq .claude/spar-judge-retries
```

- [ ] **Step 2: Add the judge note to `policy.md`**

In `plugins/spar/shared/policy.md`, in the `## Protocol` section, replace the Phase 2a stalemate step (step 6, the one that begins "Stalemate — a finding the reviewer raises AND the author rejects…") with:

```
6. Stalemate — a finding the reviewer raises AND the author rejects for 2
   consecutive rounds. Routing is by tag. A [MECHANICAL] stalemate goes to a
   blind judge: the hook generates a `codex exec --sandbox read-only` judge
   runner that sees only the finding, the code, and the task (never the
   debate); its first-line ruling `RULING: UPHELD` (author must fix, may no
   longer reject) or `RULING: DISMISSED` (finding dropped) is binding. The
   author only runs the judge — it cannot author the ruling. A [DESIGN]
   stalemate escalates once to the user for a decision. (The batched
   end-of-loop design gate and the decision ledger are Phase 2c.)
```

- [ ] **Step 3: Add the judge note to `/spar`**

In `plugins/spar/commands/spar.md`, in the `## Loop protocol` list, replace the Phase 2a stalemate item (item 5, "If the hook reports a **stalemate**…") with:

```
5. If the hook dispatches a **blind judge** (factual stalemate on a
   `[MECHANICAL]` finding), run `bash .claude/spar-run-judge.sh` with a
   600000ms timeout, then stop again. The judge's ruling is binding: on
   `UPHELD` you must fix the finding (you may not reject it again); on
   `DISMISSED` it is dropped. If the hook reports a **design stalemate**
   (`[DESIGN]`), present the reviewer's problem and your rejection reason to
   the user, apply their ruling, and stop again.
```

- [ ] **Step 4: Full suite + reinstall + honest status**

Run:

```bash
bash tests/test_stop_hook.sh && echo "ALL PASS"
```

Expected: `ALL PASS` (all cases, `FAIL=0`). Phase 2b delivers the factual-stalemate judge only. The README roadmap row for Phase 2 stays `planned` — the design gate, decision ledger, parked/blocked states (Phase 2c) and semantic matching (Phase 2d) are not done. Do not mark Phase 2 complete.

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/commands/spar-cancel.md plugins/spar/shared/policy.md plugins/spar/commands/spar.md
git commit -m "docs: policy + /spar + /spar-cancel cover the blind judge"
```

---

## Self-Review Notes

- **Spec coverage (design-decisions.md Phase 2 point 3):** blind judge via a hook-generated `codex exec --sandbox read-only` runner the author only executes (Task 10 Step 7); blind by construction — the prompt carries only task + diff-base + the one finding, never the debate (Task 10 Step 1, asserted by case 18's "blind" check); binding `RULING: UPHELD`/`DISMISSED` acted on (Step 8: upheld forces a fix, dismissed drops); routing by tag with `[DESIGN]` unchanged (Step 8 section B, case 23). Out of scope and intentionally deferred: batched gate, decision-ledger population, parked/blocked (Phase 2c), semantic matching (Phase 2d).
- **Invariant checks:** reviewer-declares — `STATUS: CONVERGED` still exits at the top of the review case, untouched, before any judge code. Fail-open — missing template / unextractable finding → `prepare_judge` returns non-zero → user escalation; missing ruling ×3 → user escalation; invalid ruling ×3 → user escalation; any uncaught error → the existing top-level ERR trap approves. Blind adjudication — the judge prompt is built only from `TASK`, `BASE`, and `extract_finding` output. Serialized — one `JUDGE_PENDING` at a time; `DISMISSED` falls through to route the next stalemate, `UPHELD`/dispatch block.
- **Ordering correctness:** classification in section B collects `mech_fp`/`design_fps` WITHOUT mutating, then acts — so a DESIGN finding is never silently marked `escalated` before the user is told, even when a MECHANICAL finding in the same batch blocks first (that MECHANICAL is dispatched and blocks; the DESIGN ones remain `open` and are handled on a later stop). Verified against the case where mixed tags stalemate together.
- **Type/name consistency:** `set_registry_status`/`registry_tag`/`extract_finding`/`prepare_judge` defined in Task 10 and used in the same task's routing; `mark_escalated` refactored to call `set_registry_status`. Registry row shape unchanged (`fp,tag,last_rejected_round,rejected_streak,status`); only the `status` value vocabulary grows (`judging`/`upheld`/`dismissed`). `JUDGE_*` constants declared (Step 4), cleaned in `cleanup()` (Step 5) and `/spar-cancel` (Task 11 Step 1). Ruling filename `reviews/spar-<id>-judge-<K>.md` written by `prepare_judge` and read back via the `JUDGE_PENDING` marker's second field.
- **Placeholder scan:** none — every step carries full file contents or exact commands.
- **Known limitation (documented, not fixed):** an author defying an `UPHELD` ruling keeps the finding at status `upheld` (not `open`), so it will not re-trigger a stalemate; the reviewer keeps re-raising it and the round cap bounds the loop. Hard obedience enforcement is future work.
