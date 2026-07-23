#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/hooks/stop-hook.sh
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/plugins/spar/hooks/stop-hook.sh"
export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/spar"

chk() { # $1=desc $2=expected-substring $3=actual
  if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "   want: $2"; echo "   got : $3"; FAIL=$((FAIL+1)); fi
}
chk_file() { # $1=desc $2=path
  if [ -f "$2" ]; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1 ($2 missing)"; FAIL=$((FAIL+1)); fi
}

fresh_dir() { d=$(mktemp -d); cd "$d" || exit 1; git init -q; mkdir -p .claude; }

write_state() { # $1=phase $2=round
  cat > .claude/spar.local.md <<EOF
---
active: true
phase: $1
round: $2
review_id: 20260721-120000-abc123
base_sha: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
reviewer: codex
max_rounds: 5
sweep_done: false
sweep_result: not-run
---

Add a fizzbuzz function with tests
EOF
}

run_hook() { echo '{}' | bash "$HOOK"; }

# ── 1. no state file → approve ──
fresh_dir
chk "no state → approve" '"decision":"approve"' "$(run_hook)"

# ── 2. active:false → approve + state removed ──
fresh_dir; write_state task 0
sed -i '' 's/^active: true/active: false/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^active: true/active: false/' .claude/spar.local.md
run_hook >/dev/null
chk "inactive → state removed" "gone" "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# ── 3. bad review_id → fail-open approve ──
fresh_dir; write_state task 0
sed -i '' 's/^review_id: .*/review_id: ..\/..\/evil/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^review_id: .*/review_id: ..\/..\/evil/' .claude/spar.local.md
chk "bad review_id → approve" '"decision":"approve"' "$(run_hook)"

# ── 4. phase=task → block, artifacts prepared, state advanced ──
fresh_dir; write_state task 0
OUT=$(run_hook)
chk "task → block" '"decision":"block"' "$OUT"
chk "task → mentions runner" 'spar-run-reviewer.sh' "$OUT"
chk_file "runner generated" .claude/spar-run-reviewer.sh
chk_file "prompt generated" .claude/spar-reviewer-prompt.txt
chk "prompt has task text" 'fizzbuzz' "$(cat .claude/spar-reviewer-prompt.txt)"
chk "prompt has round 1" 'round 1' "$(cat .claude/spar-reviewer-prompt.txt)"
chk "prompt: no leftover placeholder" 'CLEAN' "$(grep -q '{{' .claude/spar-reviewer-prompt.txt && echo DIRTY || echo CLEAN)"
chk "state → phase review" 'phase: review' "$(cat .claude/spar.local.md)"
chk "state → round 1" 'round: 1' "$(cat .claude/spar.local.md)"
chk "runner targets r1 review file" 'reviews/spar-20260721-120000-abc123-r1.md' "$(cat .claude/spar-run-reviewer.sh)"
chk "runner is read-only sandbox" 'sandbox read-only' "$(cat .claude/spar-run-reviewer.sh)"
chk "reviewer runner takes an atomic lock" '.lock' "$(cat .claude/spar-run-reviewer.sh)"
chk "reviewer runner publishes from a unique temp file" 'mktemp' "$(cat .claude/spar-run-reviewer.sh)"
chk "reviewer runner never overwrites an artifact" 'ln "$tmp"' "$(cat .claude/spar-run-reviewer.sh)"
chk "prompt pins diff baseline" 'git diff aaaaaaaa' "$(cat .claude/spar-reviewer-prompt.txt)"
chk "prompt covers untracked files" 'untracked-files' "$(cat .claude/spar-reviewer-prompt.txt)"
chk "runner feeds prompt via stdin" '< ".claude/spar-reviewer-prompt.txt"' "$(cat .claude/spar-run-reviewer.sh)"

# ── 4b. state without base_sha → falls back to HEAD baseline ──
fresh_dir; write_state task 0
sed -i '' '/^base_sha:/d' .claude/spar.local.md 2>/dev/null \
  || sed -i '/^base_sha:/d' .claude/spar.local.md
run_hook >/dev/null
chk "no base_sha → HEAD fallback" 'git diff HEAD' "$(cat .claude/spar-reviewer-prompt.txt)"

# ── 4c. conveyance boundary: no {{LEDGER}} placeholder leaks; prev-context template deleted ──
fresh_dir; write_state task 0
run_hook >/dev/null
chk "prompt resolves ledger slot (no {{LEDGER}})" "absent" \
  "$(grep -qF '{{LEDGER}}' .claude/spar-reviewer-prompt.txt && echo present || echo absent)"
chk "prev-context template deleted from plugin" "absent" \
  "$([ -f "$CLAUDE_PLUGIN_ROOT/shared/prompts/reviewer-prev-context.md" ] && echo present || echo absent)"
chk "/spar creates initial state through mktemp" 'mktemp .claude/spar.local.md.tmp.XXXXXX' \
  "$(cat "$CLAUDE_PLUGIN_ROOT/commands/spar.md")"
chk "/spar atomically publishes initial state" 'mv "$SPAR_STATE_TMP" .claude/spar.local.md' \
  "$(cat "$CLAUDE_PLUGIN_ROOT/commands/spar.md")"

# ── 4d. Phase 4 skip: small + safe only, always reported and persisted ──
skip_repo() {
  fresh_dir
  git config user.email sparring@example.invalid
  git config user.name sparring-test
  printf 'base\n' > tracked.txt
  git add tracked.txt && git commit -q -m base
  BASE_REAL=$(git rev-parse HEAD)
  mkdir -p .git/info
  printf '.claude/spar*\nreviews/spar-*\n' >> .git/info/exclude
  write_state task 0
  sed -i '' "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md 2>/dev/null \
    || sed -i "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md
}

skip_repo
printf 'safe\n' >> tracked.txt
OUT=$(run_hook)
chk "small safe change → reported skip" 'skipped' "$OUT"
chk "skip → deactivated" 'active: false' "$(cat .claude/spar.local.md)"
chk "skip → durable outcome" 'reason: skipped' "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"
chk "skip → next stop approves" '"decision":"approve"' "$(run_hook)"

skip_repo
OUT=$(run_hook)
chk "zero diff → review, never skip" 'round 1' "$OUT"

skip_repo
mkdir -p src/auth
printf 'session\n' > src/auth/session.sh
OUT=$(run_hook)
chk "risky touched path → review" 'round 1' "$OUT"

skip_repo
mkdir -p auth
printf 'base auth\n' > auth/session.sh
git add auth/session.sh && git commit -q -m auth
BASE_REAL=$(git rev-parse HEAD)
sed -i '' "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md
printf 'docs\n' > README.md
OUT=$(run_hook)
chk "repo-risk only does not block skip" 'skipped' "$OUT"

skip_repo
sed -i '' '/^reviewer:/a\
include_dirty: true' .claude/spar.local.md 2>/dev/null \
  || sed -i '/^reviewer:/a include_dirty: true' .claude/spar.local.md
printf 'safe\n' >> tracked.txt
OUT=$(run_hook)
chk "include-dirty disables skip" 'round 1' "$OUT"

skip_repo
i=1
while [ "$i" -le 11 ]; do printf 'line %s\n' "$i" >> tracked.txt; i=$((i+1)); done
OUT=$(run_hook)
chk "11-line change → review" 'round 1' "$OUT"

# ── 4e. intent pointers are harvested into each reviewer prompt ──
skip_repo
mkdir -p .claude/rules src/auth
cat > .claude/rules/auth.md <<'EOF'
---
paths:
  - "src/auth/**/*.sh"
---
# Auth design
EOF
git add .claude/rules/auth.md && git commit -q -m rule
BASE_REAL=$(git rev-parse HEAD)
sed -i '' "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md
printf '# Intentional because compatibility requires it.\necho auth\n' > src/auth/new.sh
run_hook >/dev/null
chk "round 1 prompt has matched intent rule pointer" '.claude/rules/auth.md:1' "$(cat .claude/spar-reviewer-prompt.txt)"
chk "round 1 prompt has comment pointer" 'comment: src/auth/new.sh:1' "$(cat .claude/spar-reviewer-prompt.txt)"
chk "intent content not copied into prompt" "absent" \
  "$(grep -q 'compatibility requires it' .claude/spar-reviewer-prompt.txt && echo present || echo absent)"
chk "prompt resolves intent slot" "absent" \
  "$(grep -qF '{{INTENT}}' .claude/spar-reviewer-prompt.txt && echo present || echo absent)"

# helper: enter review phase for round $1
in_review() { fresh_dir; write_state review "$1"; mkdir -p reviews; }
RF1="reviews/spar-20260721-120000-abc123-r1.md"
RP1="reviews/spar-20260721-120000-abc123-r1-response.md"

# ── 5. review file missing → block (retry), 3rd miss → fail-open ──
in_review 1
chk "review missing → block" '"decision":"block"' "$(run_hook)"
run_hook >/dev/null
chk "review missing 3rd → approve" '"decision":"approve"' "$(run_hook)"

# ── 5b. symlinked reviewer output is never trusted ──
in_review 1
printf 'STATUS: CONVERGED\n' > reviews/forged-review
ln -s forged-review "$RF1"
OUT=$(run_hook)
chk "symlinked review → blocked as unsafe" 'unsafe review artifact' "$OUT"
chk "symlinked review → set aside" "present" "$([ -L "${RF1}.invalid-1" ] && echo present || echo absent)"

# ── 6. CONVERGED → approve + cleanup ──
in_review 1
printf 'STATUS: CONVERGED\n\nChecked diff, tests, security.\n' > "$RF1"
sed -i '' 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' .claude/spar.local.md
chk "converged → approve" '"decision":"approve"' "$(run_hook)"
chk "converged → state removed" "gone" "$([ -f .claude/spar.local.md ] && echo present || echo gone)"
chk "converged → durable outcome" "reason: converged" "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"

# ── 7. FINDINGS + no response → block asking for response file ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] missing null check\n' > "$RF1"
OUT=$(run_hook)
chk "findings no response → block" '"decision":"block"' "$OUT"
chk "block names response file" "$RP1" "$OUT"

# ── 8. FINDINGS + response → next round prepared ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] missing null check\n' > "$RF1"
printf '### F1-1: FIXED — added guard\n' > "$RP1"
OUT=$(run_hook)
chk "responded → block for round 2" '"decision":"block"' "$OUT"
chk "state advanced to round 2" 'round: 2' "$(cat .claude/spar.local.md)"
chk "r2 prompt does NOT reference r1 review" "absent" \
  "$(grep -qF "$RF1" .claude/spar-reviewer-prompt.txt && echo present || echo absent)"
chk "r2 prompt does NOT reference r1 response" "absent" \
  "$(grep -qF "$RP1" .claude/spar-reviewer-prompt.txt && echo present || echo absent)"
chk "r2 prompt has no Previous-round section" "absent" \
  "$(grep -qi 'Previous round' .claude/spar-reviewer-prompt.txt && echo present || echo absent)"
chk "r2 prompt: no leftover placeholder" 'CLEAN' "$(grep -q '{{' .claude/spar-reviewer-prompt.txt && echo DIRTY || echo CLEAN)"
chk "runner targets r2" 'r2.md' "$(cat .claude/spar-run-reviewer.sh)"

# ── 9. round cap → deactivate + final block, then approve ──
in_review 5
RF5="reviews/spar-20260721-120000-abc123-r5.md"
RP5="reviews/spar-20260721-120000-abc123-r5-response.md"
printf 'STATUS: FINDINGS\n\n### F5-1 [DESIGN] split module\n' > "$RF5"
printf '### F5-1: REJECTED — out of scope for this task\n' > "$RP5"
OUT=$(run_hook)
chk "cap → block with unconverged notice" 'unconverged' "$OUT"
chk "cap → deactivated" 'active: false' "$(cat .claude/spar.local.md)"
chk "cap → durable outcome before cleanup" "reason: cap" "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"
chk "cap → next stop approves" '"decision":"approve"' "$(run_hook)"

# ── 10. CRLF status line tolerated ──
in_review 1
printf 'STATUS: CONVERGED\r\n' > "$RF1"
sed -i '' 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' .claude/spar.local.md
chk "CRLF converged → approve" '"decision":"approve"' "$(run_hook)"

# ── 11. invalid reviewer output → set aside + retry, 3rd → fail-open ──
in_review 1
printf 'codex exploded mid-review\n' > "$RF1"
OUT=$(run_hook)
chk "invalid review → block" 'invalid' "$OUT"
chk "invalid review set aside" "gone" "$([ -f "$RF1" ] && echo present || echo gone)"
chk "invalid copy kept" "kept" "$([ -f "${RF1}.invalid-1" ] && echo kept || echo lost)"
printf '\n' > "$RF1"
run_hook >/dev/null
printf 'still broken\n' > "$RF1"
chk "invalid 3rd → fail open" '"decision":"approve"' "$(run_hook)"
chk "invalid 3rd → error-bypass outcome" "reason: error-bypass" "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"

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

# ── 14b. same fingerprint rejected two consecutive rounds → streak reaches 2 ──
in_review 1
RFb2="reviews/spar-20260721-120000-abc123-r2.md"
RPb2="reviews/spar-20260721-120000-abc123-r2-response.md"
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RF1"
printf '### F1-1: REJECTED — cohesive on purpose\n' > "$RP1"
run_hook >/dev/null   # folds round 1 (streak 1), advances to round 2
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: still big\n- suggestion: split\n' > "$RFb2"
printf '### F2-1: REJECTED — still cohesive\n' > "$RPb2"
run_hook >/dev/null   # folds round 2 (streak 2)
chk "consecutive rejection → streak 2, parked" "$(printf 'mod.py | split the module\tDESIGN\t2\t2\tparked')" "$(cat .claude/spar-registry.tsv)"

# ── 15. DESIGN stalemate → parked + batched gate fires ──
fresh_dir; write_state review 1; mkdir -p reviews
RFa="reviews/spar-20260721-120000-abc123-r1.md"
RPa="reviews/spar-20260721-120000-abc123-r1-response.md"
RFb="reviews/spar-20260721-120000-abc123-r2.md"
RPb="reviews/spar-20260721-120000-abc123-r2-response.md"
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

# ── 17. no stalemate when the streak is broken by a FIXED round ──
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFa"
printf '### F1-1: REJECTED — cohesive\n' > "$RPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFb"
printf '### F2-1: FIXED — split it\n' > "$RPb"
OUT=$(run_hook)
chk "fixed second round → no stalemate block" 'round: 3' "$(cat .claude/spar.local.md)"

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

# ── 24. judge template missing → fail open to user escalation (no trap) ──
mech_stalemate
OUT=$(CLAUDE_PLUGIN_ROOT="$(mktemp -d)" run_hook)   # judge.md absent → prepare_judge fails
chk "template missing → user escalation" 'user decision' "$OUT"
chk "template missing → status escalated" 'escalated' "$(cat .claude/spar-registry.tsv)"

# ── 26. multi-gate: second gate uses a fresh P-tag, not settled by stale ledger ──
fresh_dir; write_state review 1; mkdir -p reviews
# rounds 1-2: DESIGN finding A stalemates → gate 1 (P1)
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] finding A\n- file: a.py:1\n- problem: pa\n- suggestion: sa\n' > "$RFa"
printf '### F1-1: REJECTED — A rationale\n' > "$RPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] finding A\n- file: a.py:1\n- problem: pa\n- suggestion: sa\n' > "$RFb"
printf '### F2-1: REJECTED — A rationale\n' > "$RPb"
run_hook >/dev/null            # gate 1 fires (P1 -> a.py | finding a)
chk "gate 1 manifest P1" "$(printf 'P1\ta.py | finding a')" "$(cat .claude/spar-gate-manifest.tsv)"
printf '### P1: decided A — keep as is.\n' > .claude/spar-ledger.md
run_hook >/dev/null            # settle A, advance to round 3
chk "A settled" 'a.py | finding a	DESIGN	2	2	settled' "$(cat .claude/spar-registry.tsv)"
# rounds 3-4: DESIGN finding B stalemates → gate 2 must use P2, NOT reuse P1
RF3="reviews/spar-20260721-120000-abc123-r3.md"; RP3="reviews/spar-20260721-120000-abc123-r3-response.md"
RF4="reviews/spar-20260721-120000-abc123-r4.md"; RP4="reviews/spar-20260721-120000-abc123-r4-response.md"
printf 'STATUS: FINDINGS\n\n### F3-1 [DESIGN] finding B\n- file: b.py:2\n- problem: pb\n- suggestion: sb\n' > "$RF3"
printf '### F3-1: REJECTED — B rationale\n' > "$RP3"
run_hook >/dev/null            # fold r3 (B streak 1), advance r4
printf 'STATUS: FINDINGS\n\n### F4-1 [DESIGN] finding B\n- file: b.py:2\n- problem: pb\n- suggestion: sb\n' > "$RF4"
printf '### F4-1: REJECTED — B rationale\n' > "$RP4"
OUT=$(run_hook)                # fold r4 (B streak 2) → park B → gate 2
chk "gate 2 uses fresh tag P2" "$(printf 'P2\tb.py | finding b')" "$(cat .claude/spar-gate-manifest.tsv)"
chk "gate 2 blocks (B not auto-settled by stale P1)" 'gate' "$OUT"
run_hook >/dev/null            # no P2 in ledger yet → B must stay parked, gate incomplete
chk "B NOT falsely settled" 'b.py | finding b	DESIGN	4	2	parked' "$(cat .claude/spar-registry.tsv)"

# ── 27. mixed round (parked + new open finding) → no gate ──
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] finding A\n- file: a.py:1\n- problem: pa\n- suggestion: sa\n' > "$RFa"
printf '### F1-1: REJECTED — A rationale\n' > "$RPa"
run_hook >/dev/null
# round 2: A again (→ parked) PLUS a brand-new mechanical finding the author is still fixing
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] finding A\n- file: a.py:1\n- problem: pa\n- suggestion: sa\n### F2-2 [MECHANICAL] new bug\n- file: c.py:9\n- problem: pc\n- suggestion: sc\n' > "$RFb"
printf '### F2-1: REJECTED — A rationale\n### F2-2: FIXED — patched\n' > "$RPb"
OUT=$(run_hook)
chk "mixed round → A parked" 'a.py | finding a	DESIGN	2	2	parked' "$(cat .claude/spar-registry.tsv)"
chk "mixed round → no gate fired" "absent" "$([ -f .claude/spar-gate-manifest.tsv ] && echo present || echo absent)"

# helper: round-1 DESIGN finding, then a re-worded round-2 version (same file, different title)
reworded_setup() {
  fresh_dir; write_state review 1; mkdir -p reviews
  printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: too big\n- suggestion: split\n' > "$RFa"
  printf '### F1-1: REJECTED — cohesive on purpose\n' > "$RPa"
  run_hook >/dev/null   # matcher_phase(1): registry empty → skip; fold r1 (streak 1); advance r2
  printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] break up mod.py into parts\n- file: mod.py:10\n- problem: too large\n- suggestion: modularize\n' > "$RFb"
  printf '### F2-1: REJECTED — cohesive on purpose\n' > "$RPb"
}

# ── 28. re-worded finding on same file → matcher dispatched ──
reworded_setup
OUT=$(run_hook)   # matcher_phase(2): new fp not tracked, existing same-file open → dispatch
chk "matcher dispatched" 'run-matcher' "$OUT"
chk_file "matcher runner generated" .claude/spar-run-matcher.sh
chk "matcher runner read-only" 'sandbox read-only' "$(cat .claude/spar-run-matcher.sh)"
chk "manifest maps N1 to new fp" "$(printf 'N1\tmod.py | break up mod py into parts')" "$(cat .claude/spar-matcher-manifest.tsv)"
chk "manifest maps E1 to canonical fp" "$(printf 'E1\tmod.py | split the module')" "$(cat .claude/spar-matcher-manifest.tsv)"
chk "matcher prompt has the new finding text" 'break up mod.py into parts' "$(cat .claude/spar-matcher-prompt.txt)"
chk "matcher prompt is blind (no response text)" "absent" "$(grep -qi 'cohesive on purpose' .claude/spar-matcher-prompt.txt && echo present || echo absent)"

# ── 29. matcher SAME → alias recorded, re-word folds onto canonical (streak 2 → parked → gate) ──
MOUT=$(cat .claude/spar-matcher-pending)
printf 'SAME N1 E1\n' > "$MOUT"
OUT=$(run_hook)   # apply alias; fold(2) resolves variant→canonical → canonical streak 2 → DESIGN parked → gate
chk "alias recorded" "$(printf 'mod.py | break up mod py into parts\tmod.py | split the module')" "$(cat .claude/spar-aliases.tsv)"
chk "reword folded onto canonical (streak 2, parked)" "$(printf 'mod.py | split the module\tDESIGN\t2\t2\tparked')" "$(cat .claude/spar-registry.tsv)"
chk "aliased parked finding still fires the gate" 'gate' "$OUT"

# ── 30. matcher NO MATCHES → no alias, findings stay distinct (each streak 1) ──
reworded_setup
run_hook >/dev/null            # dispatch matcher
MOUT=$(cat .claude/spar-matcher-pending)
printf 'NO MATCHES\n' > "$MOUT"
run_hook >/dev/null            # apply (none); fold(2) → two distinct fps, each streak 1
chk "no alias file entries" "empty" "$([ -s .claude/spar-aliases.tsv ] && echo nonempty || echo empty)"
chk "canonical stays streak 1" "$(printf 'mod.py | split the module\tDESIGN\t1\t1\topen')" "$(cat .claude/spar-registry.tsv)"
chk "reword tracked separately streak 1" 'mod.py | break up mod py into parts	DESIGN	2	1	open' "$(cat .claude/spar-registry.tsv)"

# ── 31. new finding on a DIFFERENT file → no matcher (prefilter skips) ──
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$RFa"
printf '### F1-1: REJECTED — cohesive\n' > "$RPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [MECHANICAL] npe in other\n- file: other.py:3\n- problem: npe\n- suggestion: guard\n' > "$RFb"
printf '### F2-1: FIXED — guarded\n' > "$RPb"
run_hook >/dev/null
chk "different file → no matcher dispatched" "absent" "$([ -f .claude/spar-run-matcher.sh ] && echo present || echo absent)"
chk "matcher round marked (won't re-dispatch)" 'kept' "$([ -f .claude/spar-matcher-round ] && echo kept || echo lost)"

# ── 32. matcher output missing 3× → skip matching, loop proceeds (fail-open) ──
reworded_setup
run_hook >/dev/null            # dispatch (no output written)
run_hook >/dev/null            # miss 1
run_hook >/dev/null            # miss 2
OUT=$(run_hook)                # miss 3 → skip matching this round, fold proceeds
chk "matcher gone after 3 misses" "gone" "$([ -f .claude/spar-matcher-pending ] && echo present || echo gone)"
chk "loop proceeded without alias" "empty" "$([ -s .claude/spar-aliases.tsv ] && echo nonempty || echo empty)"

# ── 33. suffix-fp collision: new finding not wrongly dropped from matcher candidacy ──
fresh_dir; write_state review 1; mkdir -p reviews
# round 1: two DESIGN findings — one on xmod.py titled "frob", one on mod.py titled "other"
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] frob\n- file: xmod.py:1\n- problem: p\n- suggestion: s\n### F1-2 [DESIGN] other\n- file: mod.py:1\n- problem: p\n- suggestion: s\n' > "$RFa"
printf '### F1-1: REJECTED — a\n### F1-2: REJECTED — b\n' > "$RPa"
run_hook >/dev/null   # fold r1: registry has "xmod.py | frob" and "mod.py | other" (both open)
# round 2: a NEW finding "mod.py | frob" — shares file mod.py with an existing open finding → should be a matcher candidate.
# Its fp "mod.py | frob" is a tab-suffix of registry row "xmod.py | frob\t..." → the old unanchored grep wrongly skipped it.
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] frob\n- file: mod.py:1\n- problem: p\n- suggestion: s\n' > "$RFb"
printf '### F2-1: REJECTED — c\n' > "$RPb"
OUT=$(run_hook)
chk "suffix-fp finding still offered to matcher" 'run-matcher' "$OUT"

# ── 34. gate worksheet shows the variant text for an alias-reached canonical ──
reworded_setup                    # helper from the 2d tests (round 1 canonical, round 2 reworded)
run_hook >/dev/null               # matcher dispatched
MOUT=$(cat .claude/spar-matcher-pending)
printf 'SAME N1 E1\n' > "$MOUT"
run_hook >/dev/null               # alias applied, canonical parked, gate fires → worksheet written
chk "worksheet body shows variant finding text" 'break up mod.py into parts' "$(cat .claude/spar-gate.md)"

set_reviewer() { # $1 = codex|claude|<garbage>
  sed -i '' "s/^reviewer: .*/reviewer: $1/" .claude/spar.local.md 2>/dev/null \
    || sed -i "s/^reviewer: .*/reviewer: $1/" .claude/spar.local.md
}

# ── 35. reviewer: claude → runners target claude -p read-only, not codex ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] x\n- file: a.py:1\n' > "$RF1"
printf '### F1-1: FIXED — y\n' > "$RP1"
set_reviewer claude
run_hook >/dev/null   # prepares round 2 runner
chk "claude family → runner uses claude -p" 'claude -p' "$(cat .claude/spar-run-reviewer.sh)"
chk "claude family → read-only tools" 'Read Grep Glob' "$(cat .claude/spar-run-reviewer.sh)"
chk "claude family → isolated" 'safe-mode' "$(cat .claude/spar-run-reviewer.sh)"
chk "claude family → no codex exec" "absent" "$(grep -q 'codex exec' .claude/spar-run-reviewer.sh && echo present || echo absent)"

# ── 36. reviewer: codex → runner unchanged (regression) ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] x\n- file: a.py:1\n' > "$RF1"
printf '### F1-1: FIXED — y\n' > "$RP1"
run_hook >/dev/null
chk "codex family → runner uses codex exec" 'codex exec --sandbox read-only' "$(cat .claude/spar-run-reviewer.sh)"

# ── 37. garbage reviewer value → fail open (approve), no runner ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] x\n- file: a.py:1\n' > "$RF1"
printf '### F1-1: FIXED — y\n' > "$RP1"
set_reviewer bogus
chk "garbage reviewer → approve" '"decision":"approve"' "$(run_hook)"

# ── 38. same-family loop surfaces the reduced-coverage notice ──
fresh_dir; write_state task 0; set_reviewer claude
OUT=$(run_hook)
chk "same-family → coverage notice" 'reduced cross-vendor' "$OUT"

# ── 39. claude family diff-surface: real diff is captured into spar-diff.txt ──
fresh_dir                                   # git init'd scratch dir (cwd = repo)
printf 'line one\n' > tracked.txt
git add -A && git commit -q -m base
BASE_REAL=$(git rev-parse HEAD)
printf 'line one\nline two added\n' > tracked.txt   # a real tracked change vs BASE_REAL
# state: review round 1, reviewer claude, base_sha = the real commit
write_state review 1
set_reviewer claude
sed -i '' "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md
mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] x\n- file: tracked.txt:1\n' > "$RF1"
printf '### F1-1: FIXED — y\n' > "$RP1"
run_hook >/dev/null                          # prepares round 2 → emit_runner claude → writes .claude/spar-diff.txt
chk "claude diff-surface captures the real change" 'line two added' "$(cat .claude/spar-diff.txt 2>/dev/null)"
chk "claude diff-surface has git-diff header" 'diff --git' "$(cat .claude/spar-diff.txt 2>/dev/null)"

# helpers for Phase 4 final-sweep scenarios
sweep_review_repo() { # $1=round
  fresh_dir
  git config user.email sparring@example.invalid
  git config user.name sparring-test
  printf 'base\n' > tracked.txt
  git add tracked.txt && git commit -q -m base
  BASE_REAL=$(git rev-parse HEAD)
  mkdir -p .git/info reviews
  printf '.claude/spar*\nreviews/spar-*\n' >> .git/info/exclude
  write_state review "$1"
  sed -i '' "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md 2>/dev/null \
    || sed -i "s/^base_sha: .*/base_sha: ${BASE_REAL}/" .claude/spar.local.md
}

# ── 40. clean round-1 convergence with no risk → no sweep ──
sweep_review_repo 1
printf 'STATUS: CONVERGED\n' > "$RF1"
OUT=$(run_hook)
chk "no risk signal → convergence without sweep" '"decision":"approve"' "$OUT"
chk "no risk signal → outcome says sweep not triggered" 'sweep: not-triggered' \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"

# ── 41. touched risk → fresh Claude author-family sweep, blind to ledger ──
sweep_review_repo 1
mkdir -p src/auth
printf 'session\n' > src/auth/session.sh
printf '### P1: secret loop decision\n' > .claude/spar-ledger.md
ln -s "$PWD/.claude/spar-ledger.md" leak-to-ledger
printf 'STATUS: CONVERGED\n' > "$RF1"
OUT=$(run_hook)
chk "risky convergence → sweep block" 'final sweep' "$OUT"
chk "sweep phase persisted" 'phase: sweep' "$(cat .claude/spar.local.md)"
chk "sweep armed once" 'sweep_done: true' "$(cat .claude/spar.local.md)"
chk_file "sweep runner generated" .claude/spar-run-sweep.sh
chk "sweep runner always uses Claude author family" 'claude -p' "$(cat .claude/spar-run-sweep.sh)"
chk "sweep runner never uses reviewer codex" "absent" \
  "$(grep -q 'codex exec' .claude/spar-run-sweep.sh && echo present || echo absent)"
chk "sweep runner builds isolated source snapshot" 'git ls-files -z' \
  "$(cat .claude/spar-run-sweep.sh)"
chk "sweep snapshot excludes loop artifacts" '.claude/spar*|reviews/spar-*' \
  "$(cat .claude/spar-run-sweep.sh)"
chk "sweeper runs from isolated snapshot" 'cd "$snapshot"' \
  "$(cat .claude/spar-run-sweep.sh)"
chk "sweep prompt is blind to loop ledger" "absent" \
  "$(grep -q 'secret loop decision' .claude/spar-sweep-prompt.txt && echo present || echo absent)"
chk "sweep prompt forbids reviewer convergence signal" 'Never write `STATUS: CONVERGED`' \
  "$(cat .claude/spar-sweep-prompt.txt)"

FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'SWEEP: CLEAN\n'
printf 'snapshot_cwd: %s\n' "$PWD"
[ -f src/auth/session.sh ] && echo 'source: present'
[ ! -e leak-to-ledger ] && echo 'symlink: absent'
[ ! -e .claude/spar-ledger.md ] && echo 'ledger: absent'
[ ! -e reviews/spar-20260721-120000-abc123-r1.md ] && echo 'review: absent'
EOF
chmod +x "$FAKEBIN/claude"
PATH="$FAKEBIN:$PATH" bash .claude/spar-run-sweep.sh
SF="reviews/spar-20260721-120000-abc123-sweep.md"
chk "live sweep snapshot contains current source" 'source: present' "$(cat "$SF")"
chk "live sweep snapshot omits source symlinks" 'symlink: absent' "$(cat "$SF")"
chk "live sweep snapshot hides ledger" 'ledger: absent' "$(cat "$SF")"
chk "live sweep snapshot hides reviews" 'review: absent' "$(cat "$SF")"

# ── 42. clean sweep preserves reviewer convergence and records clean ──
OUT=$(run_hook)
chk "clean sweep → approve" '"decision":"approve"' "$OUT"
chk "clean sweep → converged outcome" 'reason: converged' \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"
chk "clean sweep → outcome records clean" 'sweep: clean' \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"

# ── 43. sweep findings → response → next reviewer round; never re-arm ──
sweep_review_repo 1
mkdir -p src/auth
printf 'session\n' > src/auth/session.sh
printf 'STATUS: CONVERGED\n' > "$RF1"
run_hook >/dev/null
SF="reviews/spar-20260721-120000-abc123-sweep.md"
SRESP="reviews/spar-20260721-120000-abc123-sweep-response.md"
printf 'SWEEP: FINDINGS\n\n### S-1 [MECHANICAL] missing guard\n- file: src/auth/session.sh:1\n' > "$SF"
OUT=$(run_hook)
chk "sweep findings → response required" 'sweep-response.md' "$OUT"
printf '### S-1: FIXED — added guard\n' > "$SRESP"
OUT=$(run_hook)
chk "sweep response → reviewer round 2" 'round 2' "$OUT"
chk "post-sweep state round 2" 'round: 2' "$(cat .claude/spar.local.md)"
chk "post-sweep result persisted" 'sweep_result: findings' "$(cat .claude/spar.local.md)"
RF2="reviews/spar-20260721-120000-abc123-r2.md"
printf 'STATUS: CONVERGED\n' > "$RF2"
OUT=$(run_hook)
chk "post-sweep reviewer convergence → approve" '"decision":"approve"' "$OUT"
chk "post-sweep convergence keeps findings result" 'sweep: findings' \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"

# ── 44. sweep findings at cap → honest blocked outcome, no response/fix loop ──
sweep_review_repo 5
mkdir -p src/auth
printf 'session\n' > src/auth/session.sh
RF5="reviews/spar-20260721-120000-abc123-r5.md"
printf 'STATUS: CONVERGED\n' > "$RF5"
run_hook >/dev/null
printf 'SWEEP: FINDINGS\n\n### S-1 [MECHANICAL] cap issue\n' > "$SF"
OUT=$(run_hook)
chk "sweep findings at cap → blocked report" 'at cap' "$OUT"
chk "sweep findings at cap → deactivated" 'active: false' "$(cat .claude/spar.local.md)"
chk "sweep findings at cap → durable reason" 'reason: sweep-findings-at-cap' \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"

# ── 45. history triggers: 3+ rounds and any prior design finding ──
sweep_review_repo 3
RF3="reviews/spar-20260721-120000-abc123-r3.md"
printf 'STATUS: CONVERGED\n' > "$RF3"
OUT=$(run_hook)
chk "3+ rounds → sweep" 'final sweep' "$OUT"

sweep_review_repo 2
printf 'STATUS: FINDINGS\n### F1-1 [DESIGN] prior choice\n' > "$RF1"
printf 'STATUS: CONVERGED\n' > "$RF2"
OUT=$(run_hook)
chk "prior design finding → sweep" 'final sweep' "$OUT"

# ── 46. invalid sweep output retries finitely then records error-bypass ──
sweep_review_repo 1
mkdir -p src/auth
printf 'session\n' > src/auth/session.sh
printf 'STATUS: CONVERGED\n' > "$RF1"
run_hook >/dev/null
printf 'bad sweep\n' > "$SF"; run_hook >/dev/null
printf 'still bad\n' > "$SF"; run_hook >/dev/null
printf 'nope\n' > "$SF"
OUT=$(run_hook)
chk "invalid sweep 3x → fail-open approve" '"decision":"approve"' "$OUT"
chk "invalid sweep 3x → error-bypass outcome" 'reason: error-bypass' \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"
chk "invalid sweep 3x → sweep error recorded" 'sweep: error' \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"

# ── 47. symlinked sweep output is never trusted ──
sweep_review_repo 1
mkdir -p src/auth
printf 'session\n' > src/auth/session.sh
printf 'STATUS: CONVERGED\n' > "$RF1"
run_hook >/dev/null
SF="reviews/spar-20260721-120000-abc123-sweep.md"
printf 'SWEEP: CLEAN\n' > reviews/forged-sweep
ln -s forged-sweep "$SF"
OUT=$(run_hook)
chk "symlinked sweep → blocked as unsafe" 'unsafe sweep artifact' "$OUT"
chk "symlinked sweep → set aside" "present" "$([ -L "${SF}.invalid-1" ] && echo present || echo absent)"

chk "/spar-cancel preserves state sweep result" '"$SPAR_SWEEP_RESULT"' \
  "$(cat "$CLAUDE_PLUGIN_ROOT/commands/spar-cancel.md")"

echo; echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
