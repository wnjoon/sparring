#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/hooks/stop-hook.sh
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/plugins/spar/hooks/stop-hook.sh"
export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/spar"

# The hook refuses to dispatch a round when the reviewer CLI is missing
# (stop-hook.sh:803-807), so every reviewed path below needs `codex` and
# `claude` to merely exist. Provide no-op stubs and put them first on PATH: the
# suite must not depend on what the developer happens to have installed, and CI
# must never need a real reviewer CLI. Tests that drive a runner script build
# their own fake CLI and prepend it, so they still win over these.
STUB_BIN=$(mktemp -d)
for stub_cli in codex claude; do
  printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$stub_cli"
  chmod +x "$STUB_BIN/$stub_cli"
done
# A PATH with system tools but neither reviewer CLI, for the absent-CLI test.
SYS_PATH="/usr/bin:/bin"
PATH="$STUB_BIN:$PATH"
export PATH
trap 'rm -rf "$STUB_BIN"' EXIT

chk() { # $1=desc $2=expected-substring $3=actual
  # -- so a needle beginning with a dash is a pattern, not an option. Without it
  # any assertion about a flag (--model, --effort) fails no matter what the
  # haystack holds, which is a false failure that looks like a real one.
  if echo "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "   want: $2"; echo "   got : $3"; FAIL=$((FAIL+1)); fi
}
chk_file() { # $1=desc $2=path
  if [ -f "$2" ]; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1 ($2 missing)"; FAIL=$((FAIL+1)); fi
}

# The excludes match what /spar:fight's setup writes. Without them a test tree's
# own state files show up as untracked, which real runs never see — and the
# effort ladder, which sizes the untracked half of the review surface, would be
# measuring the harness.
fresh_dir() { d=$(mktemp -d); cd "$d" || exit 1; git init -q; mkdir -p .claude
  printf 'reviews/spar-*\n.claude/spar*\n' >> "$(git rev-parse --git-common-dir)/info/exclude"; }

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

# These effort-ladder fixtures are deliberately tiny, which is exactly what the
# heuristic small-change skip ends before any runner is written. include_dirty is
# the supported switch for that skip and changes nothing about `git diff $BASE`,
# so it isolates the fixture to the thing under test. Before untracked files were
# counted, the fixtures' own config file happened to defeat the skip — an
# accident, not a guarantee.
no_skip() {
  sed -i '' 's/^reviewer: codex$/reviewer: codex\ninclude_dirty: true/' .claude/spar.local.md 2>/dev/null \
    || sed -i 's/^reviewer: codex$/reviewer: codex\ninclude_dirty: true/' .claude/spar.local.md
}

# Most tests must not read the repository's own shared/config.toml: it is the file
# README tells users to edit, and a developer uncommenting a model would fail
# assertions about family resolution with a message pointing at the wrong thing.
# The one test that DOES exercise the shipped file names it explicitly.
export SPAR_CONFIG_FILE=/nonexistent

run_hook() { echo '{}' | bash "$HOOK"; }

# ── 1. no state file → approve ──
fresh_dir
chk "no state → approve" '{}' "$(run_hook)"

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
chk "bad review_id → approve" '{}' "$(run_hook)"

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
  "$(cat "$CLAUDE_PLUGIN_ROOT/commands/fight.md")"
chk "/spar atomically publishes initial state" 'mv "$SPAR_STATE_TMP" .claude/spar.local.md' \
  "$(cat "$CLAUDE_PLUGIN_ROOT/commands/fight.md")"

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
chk "skip → next stop approves" '{}' "$(run_hook)"

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
RF5X="reviews/spar-20260721-120000-abc123-r5.md"
RP5X="reviews/spar-20260721-120000-abc123-r5-response.md"

# ── 5. review file missing → block (retry), 3rd miss → fail-open ──
in_review 1
chk "review missing → block" '"decision":"block"' "$(run_hook)"
run_hook >/dev/null
chk "review missing 3rd → approve" '{}' "$(run_hook)"

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
chk "converged → approve" '{}' "$(run_hook)"
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
chk "cap → next stop approves" '{}' "$(run_hook)"

# ── 10. CRLF status line tolerated ──
in_review 1
printf 'STATUS: CONVERGED\r\n' > "$RF1"
sed -i '' 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' .claude/spar.local.md
chk "CRLF converged → approve" '{}' "$(run_hook)"

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
chk "invalid 3rd → fail open" '{}' "$(run_hook)"
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
# The WHOLE row, including the round column. Matching only the two-column prefix
# would keep passing if apply_matches stopped recording the round — and the
# recurrence tests below hand-write their own files, so nothing else covers the
# write side.
chk "alias recorded with its round" \
  "$(printf 'mod.py | break up mod py into parts\tmod.py | split the module\t2')" \
  "$(cat .claude/spar-aliases.tsv)"
chk "alias row is exactly three fields" "3" \
  "$(awk -F'\t' 'NR==1{print NF}' .claude/spar-aliases.tsv)"
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
chk "garbage reviewer → approve" '{}' "$(run_hook)"

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
chk "no risk signal → convergence without sweep" '{}' "$OUT"
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
chk "clean sweep → approve" '{}' "$OUT"
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
chk "post-sweep reviewer convergence → approve" '{}' "$OUT"
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
chk "invalid sweep 3x → fail-open approve" '{}' "$OUT"
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
  "$(cat "$CLAUDE_PLUGIN_ROOT/commands/cancel.md")"

# ── Phase 5: unattended terminal at the design gate ──
# helper: mark the active state file unattended
add_unattended() {
  sed -i '' 's/^sweep_result: not-run/sweep_result: not-run\nunattended: true/' .claude/spar.local.md 2>/dev/null \
    || sed -i 's/^sweep_result: not-run/sweep_result: not-run\nunattended: true/' .claude/spar.local.md
}

# U1. unattended + parked DESIGN stalemate → NO gate; blocked-pending-user terminal
fresh_dir; write_state review 1; add_unattended; mkdir -p reviews
UFa="reviews/spar-20260721-120000-abc123-r1.md"
UPa="reviews/spar-20260721-120000-abc123-r1-response.md"
UFb="reviews/spar-20260721-120000-abc123-r2.md"
UPb="reviews/spar-20260721-120000-abc123-r2-response.md"
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$UFa"
printf '### F1-1: REJECTED — cohesive on purpose\n' > "$UPa"
run_hook >/dev/null   # fold r1 (streak 1), advance to r2
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$UFb"
printf '### F2-1: REJECTED — still cohesive\n' > "$UPb"
OUT=$(run_hook)       # fold r2 (streak 2) → parked → unattended terminal
chk "unattended parked → approve (no gate hold)" '{}' "$OUT"
chk "unattended → no gate manifest" "gone" "$([ -f .claude/spar-gate-manifest.tsv ] && echo present || echo gone)"
chk "unattended → pending queue written" "present" "$([ -f reviews/spar-pending.md ] && echo present || echo gone)"
chk "queue keyed by review-id + fingerprint" "## 20260721-120000-abc123 :: mod.py | split the module" "$(cat reviews/spar-pending.md)"
chk "queue carries the finding text" "split the module" "$(cat reviews/spar-pending.md)"
chk "unattended → blocked-pending-user outcome" "reason: blocked-pending-user" "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"
chk "unattended → state cleaned up" "gone" "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# U2. attended (unattended:false / absent) still fires the gate — default-safety
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$UFa"
printf '### F1-1: REJECTED — cohesive\n' > "$UPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$UFb"
printf '### F2-1: REJECTED — still cohesive\n' > "$UPb"
OUT=$(run_hook)
chk "attended default → gate still fires" 'gate' "$OUT"
chk "attended default → no pending queue" "gone" "$([ -f reviews/spar-pending.md ] && echo present || echo gone)"

# U3. malformed unattended value → fail-open approve (never silently unattended)
fresh_dir; write_state task 0
sed -i '' 's/^sweep_result: not-run/sweep_result: not-run\nunattended: maybe/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^sweep_result: not-run/sweep_result: not-run\nunattended: maybe/' .claude/spar.local.md
chk "malformed unattended → approve" '{}' "$(run_hook)"
chk "malformed unattended → error-bypass outcome" "reason: error-bypass" "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"

# U4. a finding parked in an EARLIER round (absent from the terminal round's
# review) must still reach the queue WITH its original body — recovered from the
# round that raised it — alongside a finding parked in the terminal round.
fresh_dir; write_state review 1; add_unattended; mkdir -p reviews
U4r1="reviews/spar-20260721-120000-abc123-r1.md"; U4p1="reviews/spar-20260721-120000-abc123-r1-response.md"
U4r2="reviews/spar-20260721-120000-abc123-r2.md"; U4p2="reviews/spar-20260721-120000-abc123-r2-response.md"
U4r3="reviews/spar-20260721-120000-abc123-r3.md"; U4p3="reviews/spar-20260721-120000-abc123-r3-response.md"
# R1: finding A only (mod.py) rejected → streak 1
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: A-BODY-BIG\n- suggestion: split\n' > "$U4r1"
printf '### F1-1: REJECTED — cohesive\n' > "$U4p1"
run_hook >/dev/null   # A streak 1; advance r2
# R2: A rejected again (→ parked) AND B (x.py) rejected (streak 1) → not only-parked
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: A-BODY-BIG\n- suggestion: split\n### F2-2 [DESIGN] rename thing\n- file: x.py:2\n- problem: B-BODY-UNCLEAR\n- suggestion: rename\n' > "$U4r2"
printf '### F2-1: REJECTED — cohesive\n### F2-2: REJECTED — clear enough\n' > "$U4p2"
run_hook >/dev/null   # A parked, B streak 1; only_parked false → advance r3
# R3: B ONLY, rejected (→ parked). A is absent from this round entirely.
printf 'STATUS: FINDINGS\n\n### F3-1 [DESIGN] rename thing\n- file: x.py:2\n- problem: B-BODY-UNCLEAR\n- suggestion: rename\n' > "$U4r3"
printf '### F3-1: REJECTED — clear enough\n' > "$U4p3"
OUT=$(run_hook)   # B parked; only_parked(r3) true → unattended terminal
chk "multi-round unattended → approve" '{}' "$OUT"
chk "terminal-round finding B body preserved" "B-BODY-UNCLEAR" "$(cat reviews/spar-pending.md)"
chk "earlier-round finding A body preserved (not empty)" "A-BODY-BIG" "$(cat reviews/spar-pending.md)"
chk "both parked findings queued" "2" "$(grep -c '^## ' reviews/spar-pending.md)"

# ── Phase 5: final report at the terminal path ──
RPT="reviews/spar-20260721-120000-abc123-report.md"

# Converge with the sweep already accounted for, so these tests exercise the
# terminal path itself instead of the sweep dispatch (mirrors test 6 above —
# without this, should_sweep() fires and the hook blocks for the sweep first).
converged_no_sweep() {
  printf 'STATUS: CONVERGED\n\nAll good.\n' > reviews/spar-20260721-120000-abc123-r1.md
  sed -i '' 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' \
    .claude/spar.local.md 2>/dev/null \
    || sed -i 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' \
      .claude/spar.local.md
}

# R1. converged → report generated before cleanup
fresh_dir; write_state review 1; mkdir -p reviews
converged_no_sweep
OUT=$(run_hook)
chk "converged → approve" '{}' "$OUT"
chk_file "converged → report generated" "$RPT"
chk "report records the converged outcome" "outcome: converged" "$(cat "$RPT" 2>/dev/null)"
chk "report has the result section" "## Result" "$(cat "$RPT" 2>/dev/null)"
chk "report has the findings section" "## Findings" "$(cat "$RPT" 2>/dev/null)"
chk "report has the changed-files section" "## Changed files" "$(cat "$RPT" 2>/dev/null)"
chk "report survives cleanup" "gone" "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# R2. the report reads the ledger, which cleanup() would have deleted
fresh_dir; write_state review 1; mkdir -p reviews
printf '# decisions\n\n### P1: keep it cohesive — splitting duplicates the parser\n' \
  > .claude/spar-ledger.md
converged_no_sweep
run_hook >/dev/null
chk "ledger decision captured before cleanup" "#### P1: keep it cohesive" "$(cat "$RPT" 2>/dev/null)"
chk "ledger itself was cleaned up" "gone" "$([ -f .claude/spar-ledger.md ] && echo present || echo gone)"

# R4. unattended blocked-pending-user terminal → report generated too
fresh_dir; write_state review 1; add_unattended; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' \
  > reviews/spar-20260721-120000-abc123-r1.md
printf '### F1-1: REJECTED — cohesive on purpose\n' \
  > reviews/spar-20260721-120000-abc123-r1-response.md
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' \
  > reviews/spar-20260721-120000-abc123-r2.md
printf '### F2-1: REJECTED — still cohesive\n' \
  > reviews/spar-20260721-120000-abc123-r2-response.md
run_hook >/dev/null
chk_file "unattended terminal → report generated" "$RPT"
chk "report is honest about the blocked outcome" "outcome: blocked-pending-user" \
  "$(cat "$RPT" 2>/dev/null)"
chk "report lists the parked decision" "mod.py | split the module" "$(cat "$RPT" 2>/dev/null)"

# R5. fail-open: a failing generator (symlinked report path) never traps the session
fresh_dir; write_state review 1; mkdir -p reviews
ln -s /dev/null "$RPT"
converged_no_sweep
OUT=$(run_hook)
chk "failing generator → still approve" '{}' "$OUT"
chk "failing generator → outcome still recorded" "reason: converged" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
chk "failing generator → still cleaned up" "gone" \
  "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# R6. fail-open: a missing generator never traps the session
fresh_dir; write_state review 1; mkdir -p reviews
FAKE_ROOT=$(mktemp -d)
cp -R "$ROOT/plugins/spar/." "$FAKE_ROOT/"
rm -f "$FAKE_ROOT/commands/spar-report.sh"
converged_no_sweep
OUT=$(CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" bash "$HOOK" <<< '{}')
chk "missing generator → still approve" '{}' "$OUT"
chk "missing generator → outcome still recorded" "reason: converged" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
chk "missing generator → no report" "absent" "$([ -f "$RPT" ] && echo present || echo absent)"

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

# T6. error-bypass gets NO report, by design: an internal-error bailout has no run
# story worth summarizing, and its state is exactly what could not be trusted.
# This pins the finish_approve gate — widening it past `converged` would make the
# documented behavior (policy.md item 10, the spec, the README) false.
fresh_dir; write_state review 1; mkdir -p reviews
sed -i '' 's/^reviewer: codex/reviewer: bogus/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: bogus/' .claude/spar.local.md
OUT=$(run_hook)
chk "invalid reviewer → fail-open approve" '{}' "$OUT"
chk "error-bypass → outcome still recorded" "reason: error-bypass" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
chk "error-bypass → no report by design" "absent" \
  "$([ -f "$RPT" ] && echo present || echo absent)"

# ── CLI presence: the hook refuses to start a round without the reviewer CLI ──
# This branch (stop-hook.sh:803-807) had no coverage — the suite reached the
# reviewed paths only because the developer happened to have codex installed.
# SYS_PATH deliberately excludes STUB_BIN so the CLI really is missing. jq may
# also be absent there, which is fine: block() falls back to a printf JSON that
# still carries the first line of the reason.
fresh_dir; write_state task 0; mkdir -p reviews
OUT=$(PATH="$SYS_PATH" bash "$HOOK" <<< '{}')
chk "reviewer CLI absent → block" '"decision":"block"' "$OUT"
chk "reviewer CLI absent → says which CLI and why" "not on PATH" "$OUT"
chk "reviewer CLI absent → honest error-bypass outcome" "reason: error-bypass" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
chk "reviewer CLI absent → loop state cleaned up" "gone" \
  "$([ -f .claude/spar.local.md ] && echo present || echo gone)"
chk "reviewer CLI absent → no report (error-bypass never reports)" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-report.md ] && echo present || echo absent)"

# With the stubs on PATH the same state starts a round instead — this is what
# every other test in this file has been relying on, now made explicit.
fresh_dir; write_state task 0; mkdir -p reviews
OUT=$(run_hook)
chk "reviewer CLI present → round 1 dispatched" "spar-run-reviewer.sh" "$OUT"

# ── self-location: the engine must work without CLAUDE_PLUGIN_ROOT ──
# With the var unset the engine used to fail open SILENTLY: no round dispatched,
# no outcome recorded, state deleted. It must instead behave exactly as it does
# with the var set, by locating its siblings from its own path.
fresh_dir; write_state task 0; mkdir -p reviews
OUT=$(env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" <<< '{}')
chk "no plugin root → still dispatches round 1" "spar-run-reviewer.sh" "$OUT"
chk_file "no plugin root → runner written" ".claude/spar-run-reviewer.sh"
chk "no plugin root → prompt carries the task" "fizzbuzz" \
  "$(cat .claude/spar-reviewer-prompt.txt 2>/dev/null)"
chk "no plugin root → state advanced" "phase: review" "$(cat .claude/spar.local.md 2>/dev/null)"

# And the terminal path still records a durable outcome without the var.
fresh_dir; write_state review 1; mkdir -p reviews
converged_no_sweep
env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" <<< '{}' >/dev/null
chk "no plugin root → outcome still recorded" "reason: converged" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"

# ── author family: the sweep must follow the AUTHOR, not always claude ──
add_author() { # $1=value
  sed -i '' "s/^reviewer: /author: $1\nreviewer: /" .claude/spar.local.md 2>/dev/null \
    || sed -i "s/^reviewer: /author: $1\nreviewer: /" .claude/spar.local.md
}
sweep_fixture() { # a converged round that triggers the sweep (3+ rounds does it)
  fresh_dir; write_state review 3; mkdir -p reviews
  printf 'STATUS: CONVERGED\n\nAll good.\n' > reviews/spar-20260721-120000-abc123-r3.md
}
chk_absent_hook() { # $1=unwanted $2=haystack $3=desc
  if printf '%s' "$2" | grep -qF "$1"; then echo "FAIL: $3"; FAIL=$((FAIL+1))
  else echo "PASS: $3"; PASS=$((PASS+1)); fi
}

# default (no author field) → claude sweep runner, exactly as today
sweep_fixture
run_hook >/dev/null
chk "no author field → claude sweep runner" "claude -p --safe-mode" \
  "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"

# author: codex → codex sweep runner
sweep_fixture; add_author codex
run_hook >/dev/null
chk "author codex → codex sweep runner" "codex exec" "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"
chk "author codex → sweep stays read-only" "read-only" "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"
# codex writes its own output file from inside the snapshot subshell, so the path
# must be absolute — a relative $tmp would land in the throwaway snapshot.
chk "author codex → absolute output path" 'output-last-message "$source_root/$tmp"' \
  "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"
chk_absent_hook "claude -p" "$(cat .claude/spar-run-sweep.sh 2>/dev/null)" \
  "author codex → no claude in the sweep runner"

# invalid author → internal-state error, fail open, never silently claude
sweep_fixture; add_author bogus
chk "invalid author → approve (fail open)" '{}' "$(run_hook)"
chk "invalid author → error-bypass outcome" "reason: error-bypass" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"

# the cross-model notice must key off the pairing, not the reviewer alone
fresh_dir; write_state task 0; mkdir -p reviews; add_author codex
sed -i '' 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md
OUT=$(run_hook)
chk_absent_hook "same-model review" "$OUT" \
  "codex author + claude reviewer → not called same-model"

# and a genuinely same-family pairing still gets the notice
fresh_dir; write_state task 0; mkdir -p reviews; add_author claude
sed -i '' 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md
chk "claude author + claude reviewer → same-model notice" "same-model review" "$(run_hook)"

# ── owner gating: a foreign session must not join someone else's run ──
# A user-scope hook registration fires in EVERY session of that host, so without
# this an unrelated Codex session opened in a repo with an active loop would be
# pulled in and would advance the state machine.
add_owner() { # $1=session id
  sed -i '' "s/^reviewer: /owner_session: $1\nreviewer: /" .claude/spar.local.md 2>/dev/null \
    || sed -i "s/^reviewer: /owner_session: $1\nreviewer: /" .claude/spar.local.md
}
payload() { printf '{"session_id":"%s","hook_event_name":"Stop"}' "$1"; }

# matching session → the loop runs normally
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
OUT=$(payload sess-aaa | bash "$HOOK")
chk "owner match → round dispatched" "spar-run-reviewer.sh" "$OUT"

# foreign session → approve, and the run is left completely untouched
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
OUT=$(payload sess-zzz | bash "$HOOK")
chk "foreign session → approve" '{}' "$OUT"
chk "foreign session → state untouched" "phase: task" "$(cat .claude/spar.local.md 2>/dev/null)"
chk "foreign session → no runner written" "absent" \
  "$([ -f .claude/spar-run-reviewer.sh ] && echo present || echo absent)"
chk "foreign session → no outcome recorded" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-outcome.md ] && echo present || echo absent)"

# no owner field → unchanged behavior, whatever the payload says
fresh_dir; write_state task 0; mkdir -p reviews
OUT=$(payload sess-zzz | bash "$HOOK")
chk "no owner field → round dispatched" "spar-run-reviewer.sh" "$OUT"

# owner set but payload carries no session id → treated as foreign, approve
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
chk "no session id in payload → approve" '{}' "$(run_hook)"
chk "no session id in payload → state untouched" "phase: task" \
  "$(cat .claude/spar.local.md 2>/dev/null)"

# malformed JSON is NOT a session claim, even when the owner's id appears in it
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
OUT=$(printf '{"session_id":"sess-aaa"' | bash "$HOOK")
chk "truncated payload → approve" '{}' "$OUT"
chk "truncated payload → state untouched" "phase: task" "$(cat .claude/spar.local.md 2>/dev/null)"
chk "truncated payload → no runner written" "absent" \
  "$([ -f .claude/spar-run-reviewer.sh ] && echo present || echo absent)"

# a non-object payload carrying the id is not a claim either
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
chk "array payload → approve" '{}' "$(printf '["sess-aaa"]' | bash "$HOOK")"
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
chk "non-string session_id → approve" '{}' \
  "$(printf '{"session_id":123}' | bash "$HOOK")"

# with jq unavailable, ownership is unverifiable → treated as foreign: approve and
# mutate NOTHING. Terminating here would delete a live run's state from a session
# that may not own it, which is what the gate exists to prevent. A malformed
# payload carrying the owner's id must not impersonate it either.
nojq_path() { # → a PATH with everything except jq
  local d; d=$(mktemp -d) || return 1
  local dir f b
  for dir in /bin /usr/bin; do
    for f in "$dir"/*; do
      b=${f##*/}; [ "$b" = jq ] && continue
      [ -e "$d/$b" ] || ln -sf "$f" "$d/$b" 2>/dev/null
    done
  done
  for b in codex claude; do printf '#!/bin/sh\nexit 0\n' > "$d/$b"; chmod +x "$d/$b"; done
  printf '%s' "$d"
}
NOJQ=$(nojq_path)
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
OUT=$(printf '{"session_id":"sess-aaa"' \
  | env -i PATH="$NOJQ" HOME="$HOME" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" bash "$HOOK")
chk "no jq + malformed owner payload → approve" '{}' "$OUT"
chk "no jq → no round dispatched" "absent" \
  "$([ -f .claude/spar-run-reviewer.sh ] && echo present || echo absent)"
chk "no jq → the run survives, state untouched" "phase: task" \
  "$(cat .claude/spar.local.md 2>/dev/null)"
chk "no jq → nothing recorded as an outcome" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-outcome.md ] && echo present || echo absent)"

# a well-formed owning payload is treated the same while jq is missing —
# unverifiable is unverifiable — but still without destroying the run
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
OUT=$(printf '{"session_id":"sess-aaa"}' \
  | env -i PATH="$NOJQ" HOME="$HOME" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" bash "$HOOK")
chk "no jq + valid owner payload → approve" '{}' "$OUT"
chk "no jq + valid owner payload → state survives" "phase: task" \
  "$(cat .claude/spar.local.md 2>/dev/null)"
chk "no jq + valid owner payload → no outcome written" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-outcome.md ] && echo present || echo absent)"

# a run WITHOUT owner gating never needs jq — existing Claude-hosted runs.
# Assert on effects, not on the block text: with jq missing, block() falls back to
# a printf JSON that carries only the reason's first line, so the runner path is
# not in stdout even though the round was dispatched.
fresh_dir; write_state task 0; mkdir -p reviews
OUT=$(printf '{}' | env -i PATH="$NOJQ" HOME="$HOME" CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" bash "$HOOK")
chk "no owner field + no jq → still blocks for the review" '"decision":"block"' "$OUT"
chk_file "no owner field + no jq → runner written" ".claude/spar-run-reviewer.sh"
chk "no owner field + no jq → state advanced" "phase: review" "$(cat .claude/spar.local.md 2>/dev/null)"
rm -rf "$NOJQ"

# a DEACTIVATED owner-scoped run must survive a foreign session too. The
# `active != true` path records an outcome and runs cleanup(), so the gate has to
# sit ahead of it — otherwise a session that cannot prove ownership performs the
# owner's teardown.
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
sed -i '' 's/^active: true/active: false/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^active: true/active: false/' .claude/spar.local.md
OUT=$(payload sess-zzz | bash "$HOOK")
chk "foreign session + inactive run → approve" '{}' "$OUT"
chk "foreign session + inactive run → state NOT cleaned up" "present" \
  "$([ -f .claude/spar.local.md ] && echo present || echo absent)"
chk "foreign session + inactive run → no outcome written" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-outcome.md ] && echo present || echo absent)"

# the owner still gets its own teardown when it stops
OUT=$(payload sess-aaa | bash "$HOOK")
chk "owner + inactive run → approve" '{}' "$OUT"
chk "owner + inactive run → state cleaned up" "gone" \
  "$([ -f .claude/spar.local.md ] && echo present || echo gone)"
chk "owner + inactive run → outcome recorded" "reason: cap" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"

# corruption, unlike teardown, is handled by whoever observes it: a state file we
# cannot parse cannot be trusted to name its owner, so the gate must not run first
# and leave a broken run inert until someone runs /spar:cancel.
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
sed -i '' 's/^review_id: .*/review_id: ..\/..\/evil/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^review_id: .*/review_id: ..\/..\/evil/' .claude/spar.local.md
OUT=$(payload sess-zzz | bash "$HOOK")
chk "foreign session + corrupt state → approve (fail open)" '{}' "$OUT"
chk "foreign session + corrupt state → corruption still handled" "gone" \
  "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# the gate must never block — a foreign session is released, not trapped
fresh_dir; write_state review 1; mkdir -p reviews; add_owner sess-aaa
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] x\n- file: a.py:1\n- problem: p\n- suggestion: s\n' \
  > reviews/spar-20260721-120000-abc123-r1.md
OUT=$(payload sess-zzz | bash "$HOOK")
chk_absent_hook '"decision":"block"' "$OUT" "foreign session mid-round → never blocks"

# ── the gate's full ordering contract, in one place ──
# fields → validations → gate → teardown. Each row below fails if the gate moves
# in one direction, and the pair together pins it from both sides. The separate
# cases above check each rule alone, which is how a self-contradictory placement
# instruction ("after the validations AND before any mutation" — the `active`
# branch IS a mutation) survived three review rounds.
owner_state() { # $1=extra sed expression applied to the state file
  fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
  [ -n "${1:-}" ] && { sed -i '' "$1" .claude/spar.local.md 2>/dev/null \
    || sed -i "$1" .claude/spar.local.md; }
  return 0
}

# 1. healthy + foreign → untouched (gate is before the teardown)
owner_state
OUT=$(payload sess-zzz | bash "$HOOK")
chk "contract: healthy+foreign → approve" '{}' "$OUT"
chk "contract: healthy+foreign → state kept" "present" \
  "$([ -f .claude/spar.local.md ] && echo present || echo absent)"

# 2. inactive + foreign → untouched (the teardown is a mutation; strangers skip it)
owner_state 's/^active: true/active: false/'
payload sess-zzz | bash "$HOOK" >/dev/null
chk "contract: inactive+foreign → state kept" "present" \
  "$([ -f .claude/spar.local.md ] && echo present || echo absent)"
chk "contract: inactive+foreign → no outcome" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-outcome.md ] && echo present || echo absent)"

# 3. corrupt + foreign → HANDLED (validations run first; a file we cannot parse
#    cannot be trusted to name its owner, and must not sit inert)
owner_state 's/^review_id: .*/review_id: ..\/..\/evil/'
payload sess-zzz | bash "$HOOK" >/dev/null
chk "contract: corrupt+foreign → cleaned up" "gone" \
  "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# 4. healthy + owner → proceeds normally
owner_state
OUT=$(payload sess-aaa | bash "$HOOK")
chk "contract: healthy+owner → round dispatched" "spar-run-reviewer.sh" "$OUT"

# ── X. the soft cap extends while rounds stay PRODUCTIVE ─────────────────────
# The cap counts elapsed rounds, which conflates a deadlock with a review that is
# still finding real work. A round where nothing was rejected and nothing
# escalated is the second case; it must not end the run.
set_field() { # $1=key $2=value
  sed -i '' "s/^$1: .*/$1: $2/" .claude/spar.local.md 2>/dev/null \
    || sed -i "s/^$1: .*/$1: $2/" .claude/spar.local.md
}
round_files() { # $1=round  → writes a FINDINGS review + an all-FIXED response
  printf 'STATUS: FINDINGS\n\n### F%s-1 [MECHANICAL] a real defect\n' "$1" \
    > "reviews/spar-20260721-120000-abc123-r$1.md"
  printf '### F%s-1: FIXED — corrected it\n' "$1" \
    > "reviews/spar-20260721-120000-abc123-r$1-response.md"
}

in_review 5
round_files 5
OUT=$(run_hook)
chk "productive round 5 → extends instead of capping" 'Round 6 verification review' "$OUT"
chk "productive round 5 → still active" 'active: true' "$(cat .claude/spar.local.md)"
chk "productive round 5 → round advanced" 'round: 6' "$(cat .claude/spar.local.md)"
chk "productive round 5 → no cap outcome recorded" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-outcome.md ] && echo present || echo absent)"

# A rejection is a dispute, and a dispute is exactly what the soft cap is for.
in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] a real defect\n' > "$RF5X"
printf '### F5-1: REJECTED — grounded reason\n' > "$RP5X"
OUT=$(run_hook)
chk "rejection at the soft cap → caps, does not extend" 'Round cap (5) reached' "$OUT"
chk "rejection at the soft cap → deactivated" 'active: false' "$(cat .claude/spar.local.md)"

# An ambiguous response is treated as dispute, never as progress.
in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] a real defect\n' > "$RF5X"
printf '### F5-1: looked at it\n' > "$RP5X"
OUT=$(run_hook)
chk "ambiguous response at the soft cap → caps" 'Round cap (5) reached' "$OUT"

# The hard cap terminates a run that stays productive forever.
in_review 10
round_files 10
OUT=$(run_hook)
chk "hard cap → stops even on a productive round" 'Hard round cap (10) reached' "$OUT"
chk "hard cap → deactivated" 'active: false' "$(cat .claude/spar.local.md)"
chk "hard cap → durable cap outcome" "reason: cap" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
chk "hard cap → report carries the real round count" "rounds: 10" \
  "$(cat reviews/spar-20260721-120000-abc123-report.md 2>/dev/null)"

# Rounds between the two caps keep extending.
in_review 8
round_files 8
OUT=$(run_hook)
chk "productive round 8 → still extends below the hard cap" 'Round 9 verification review' "$OUT"

# The hard cap is proportional to the budget the run asked for, not a constant:
# max_rounds 3 doubles to 6, so a deliberately cheap run stays cheap.
in_review 3
set_field max_rounds 3
round_files 3
OUT=$(run_hook)
chk "max_rounds 3 → extends past 3" 'Round 4 verification review' "$OUT"
in_review 6
set_field max_rounds 3
round_files 6
OUT=$(run_hook)
chk "max_rounds 3 → hard cap is 6, not 10" 'Hard round cap (6) reached' "$OUT"

# An explicit hard_cap overrides the doubling.
in_review 5
set_field max_rounds 5
printf 'hard_cap: 5\n' >> /dev/null
sed -i '' 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 5/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 5/' .claude/spar.local.md
round_files 5
OUT=$(run_hook)
chk "explicit hard_cap 5 → no extension at all" 'Hard round cap (5) reached' "$OUT"

# A response that omits a finding is silence, not agreement. The gate before the
# productivity test only checks that a response FILE exists, so these reach it.
in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] one\n\n### F5-2 [MECHANICAL] two\n' > "$RF5X"
printf '### F5-1: FIXED — did it\n' > "$RP5X"
OUT=$(run_hook)
chk "omitted response at the soft cap → caps, does not extend" 'Round cap (5) reached' "$OUT"

in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] one\n' > "$RF5X"
printf 'I looked at everything and it is fine.\n' > "$RP5X"
OUT=$(run_hook)
chk "unrecognised response at the soft cap → caps" 'Round cap (5) reached' "$OUT"

in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] one\n' > "$RF5X"
: > "$RP5X"
OUT=$(run_hook)
chk "empty response at the soft cap → caps" 'Round cap (5) reached' "$OUT"

# A FINDINGS review with nothing parseable is not evidence of progress either.
in_review 5
printf 'STATUS: FINDINGS\n\nno structured findings here\n' > "$RF5X"
printf '### F5-1: FIXED — did it\n' > "$RP5X"
OUT=$(run_hook)
chk "unparseable review at the soft cap → caps" 'Round cap (5) reached' "$OUT"

# Several findings, all answered FIXED, still extends.
in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] one\n\n### F5-2 [MECHANICAL] two\n' > "$RF5X"
printf '### F5-1: FIXED — a\n\n### F5-2: FIXED — b\n' > "$RP5X"
OUT=$(run_hook)
chk "all findings answered FIXED → extends" 'Round 6 verification review' "$OUT"

# Digit-only is not the same as usable. A leading zero is octal to bash's
# arithmetic, and a twenty-digit value wraps — doubling it can come out negative.
# Neither may reach a comparison that decides whether the loop keeps running.
in_review 5
set_field max_rounds 08
round_files 5
OUT=$(run_hook 2>&1)
chk "leading-zero max_rounds → no arithmetic error on stderr" "clean" \
  "$(printf '%s' "$OUT" | grep -q 'value too great for base' && echo dirty || echo clean)"
chk "leading-zero max_rounds → read as decimal 8, so round 5 extends" \
  'Round 6 verification review' "$OUT"

in_review 8
set_field max_rounds 08
round_files 8
OUT=$(run_hook 2>&1)
chk "leading-zero max_rounds → 8 means 8, so round 8 still extends" \
  'Round 9 verification review' "$OUT"
in_review 16
set_field max_rounds 08
round_files 16
OUT=$(run_hook 2>&1)
chk "leading-zero max_rounds → hard cap is 16, not 0 or a wrap" \
  'Hard round cap (16) reached' "$OUT"

in_review 5
set_field max_rounds 99999999999999999999
round_files 5
OUT=$(run_hook 2>&1)
chk "absurd max_rounds → falls back to the default, no wraparound" \
  'Round 6 verification review' "$OUT"
chk "absurd max_rounds → recorded in the log" 'max_rounds unusable' "$(cat .claude/spar.log 2>/dev/null)"

in_review 10
set_field max_rounds 99999999999999999999
round_files 10
OUT=$(run_hook 2>&1)
chk "absurd max_rounds → the run still terminates" 'Hard round cap (10) reached' "$OUT"

in_review 5
sed -i '' 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 99999999999999999999/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 99999999999999999999/' .claude/spar.local.md
round_files 5
OUT=$(run_hook 2>&1)
chk "absurd hard_cap → falls back to 2x max_rounds" 'Round 6 verification review' "$OUT"
in_review 10
sed -i '' 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 99999999999999999999/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 99999999999999999999/' .claude/spar.local.md
round_files 10
OUT=$(run_hook 2>&1)
chk "absurd hard_cap → the run still terminates at 2x" 'Hard round cap (10) reached' "$OUT"

in_review 5
set_field max_rounds 0
round_files 5
OUT=$(run_hook 2>&1)
chk "max_rounds 0 → treated as invalid, default applies" 'Round 6 verification review' "$OUT"

# Bash wraps at 64 bits, so an absurd value can arrive looking ordinary:
# 2^64+1 = 18446744073709551617 evaluates to 1. A range check after the conversion
# cannot tell that from a genuine "1", so the bound must hold on the digit string.
WRAP1=18446744073709551617      # wraps to 1
WRAP7=18446744073709551623      # wraps to 7
in_review 5
set_field max_rounds $WRAP1
round_files 5
OUT=$(run_hook 2>&1)
chk "max_rounds wrapping to a small value → rejected, not accepted as 1" \
  'Round 6 verification review' "$OUT"
chk "max_rounds wrapping to a small value → logged as unusable" 'max_rounds unusable' \
  "$(cat .claude/spar.log 2>/dev/null)"

in_review 5
sed -i '' "s/^max_rounds: 5/max_rounds: 5\nhard_cap: $WRAP1/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^max_rounds: 5/max_rounds: 5\nhard_cap: $WRAP1/" .claude/spar.local.md
round_files 5
OUT=$(run_hook 2>&1)
chk "hard_cap wrapping to a small value → rejected, falls back to 2x" \
  'Round 6 verification review' "$OUT"

# A corrupt round must fail OPEN, not silently consume another round's artifacts.
in_review 5
set_field round $WRAP7
printf 'STATUS: FINDINGS\n\n### F7-1 [MECHANICAL] planted\n' \
  > reviews/spar-20260721-120000-abc123-r7.md
chk "round wrapping to a small value → fails open, does not adopt round 7" \
  '{}' "$(run_hook 2>&1)"

# The hard cap's bound is twice the soft cap's, so doubling holds at every legal
# max_rounds and an explicit override in that range is honoured, not shrunk.
in_review 100
set_field max_rounds 60
round_files 100
OUT=$(run_hook 2>&1)
chk "max_rounds 60 → hard cap is 120, so round 100 extends" \
  'Round 101 verification review' "$OUT"
in_review 120
set_field max_rounds 60
round_files 120
OUT=$(run_hook 2>&1)
chk "max_rounds 60 → hard cap really is 120" 'Hard round cap (120) reached' "$OUT"

in_review 100
sed -i '' 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 120/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 120/' .claude/spar.local.md
round_files 100
OUT=$(run_hook 2>&1)
chk "explicit hard_cap 120 → honoured, not shrunk to 100" \
  'Round 101 verification review' "$OUT"

# The soft cap is a budget, not a policy about sensible budgets. A value the user
# stated plainly is honoured; only values arithmetic cannot carry are rejected.
in_review 101
set_field max_rounds 101
round_files 101
OUT=$(run_hook 2>&1)
chk "max_rounds 101 → honoured, not shrunk to a built-in limit" \
  'Round 102 verification review' "$OUT"
in_review 202
set_field max_rounds 101
round_files 202
OUT=$(run_hook 2>&1)
chk "max_rounds 101 → its hard cap really is 202" 'Hard round cap (202) reached' "$OUT"
in_review 240
sed -i '' 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 250/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 250/' .claude/spar.local.md
round_files 240
OUT=$(run_hook 2>&1)
chk "explicit hard_cap 250 → honoured" 'Round 241 verification review' "$OUT"

# Only an UNAMBIGUOUS FIXED buys extra rounds. The shared response parser is
# permissive by design; permissive is wrong for the one disposition that extends.
in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] one\n' > "$RF5X"
printf '### F5-1: FIXEDLY — a word that merely starts with it\n' > "$RP5X"
OUT=$(run_hook 2>&1)
chk "FIXEDLY is not FIXED → caps" 'Round cap (5) reached' "$OUT"

in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] one\n' > "$RF5X"
printf '### F5-1: FIXED — did it\n\n### F5-1: REJECTED — actually no\n' > "$RP5X"
OUT=$(run_hook 2>&1)
chk "a finding answered twice is a conflict → caps" 'Round cap (5) reached' "$OUT"

in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] one\n' > "$RF5X"
printf '### F5-1: FIXED\n' > "$RP5X"
OUT=$(run_hook 2>&1)
chk "bare FIXED with no prose still counts → extends" 'Round 6 verification review' "$OUT"

# A hedge is not an answer. Anything other than whitespace or end-of-line after
# FIXED is a different word or a qualification, and both mean "not sure" — which
# is the state the soft cap exists to stop on.
for hedge in 'FIXED?' 'FIXED/REJECTED' 'FIXED-ish' 'FIXED.REJECTED'; do
  in_review 5
  printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] one\n' > "$RF5X"
  printf '### F5-1: %s — not committing to it\n' "$hedge" > "$RP5X"
  chk "hedged disposition '$hedge' → caps" 'Round cap (5) reached' "$(run_hook 2>&1)"
done
# ...while the documented grammar keeps working.
in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] one\n' > "$RF5X"
printf '### F5-1: FIXED — did the thing\n' > "$RP5X"
chk "the documented 'FIXED — prose' form still extends" \
  'Round 6 verification review' "$(run_hook 2>&1)"

# Requirement (2) names judged and parked explicitly. A round carrying either is
# a dispute, so the soft cap must behave exactly as it did before this change.
in_review 5
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] a.py fixed one\n\n### F5-2 [DESIGN] mod.py split it\n' > "$RF5X"
printf '### F5-1: FIXED — did it\n\n### F5-2: REJECTED — cohesive on purpose\n' > "$RP5X"
printf 'mod.py | split it\tDESIGN\t4\t2\tparked\n' > .claude/spar-registry.tsv
OUT=$(run_hook 2>&1)
chk "a parked finding in a mixed round → caps, never extends" 'Round cap (5) reached' "$OUT"
chk "parked at the cap → deactivated" 'active: false' "$(cat .claude/spar.local.md)"
chk "parked at the cap → durable cap outcome" "reason: cap" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
chk_file "parked at the cap → report generated" \
  reviews/spar-20260721-120000-abc123-report.md

# The parked guard must bite on its own. Here THIS round is spotless — every
# finding answered FIXED — but a design question parked in an earlier round is
# still outstanding, and an unresolved parked decision is not a converging run.
in_review 5
round_files 5
printf 'mod.py | split it\tDESIGN\t3\t2\tparked\n' > .claude/spar-registry.tsv
OUT=$(run_hook 2>&1)
chk "an earlier parked finding blocks extension even on a clean round" \
  'Round cap (5) reached' "$OUT"

# A re-raised defect is the reviewer having to say the same thing twice. That is
# the clearest "not converging" signal short of an outright rejection, and the
# soft cap is what it should hit — even though every finding this round was fixed.
in_review 5
round_files 5
printf 'a.py | old wording\tb.py | canonical\t5\n' > .claude/spar-aliases.tsv
OUT=$(run_hook 2>&1)
chk "a recurrence this round → caps despite everything being fixed" \
  'Round cap (5) reached' "$OUT"
chk "recurrence at the cap → deactivated" 'active: false' "$(cat .claude/spar.local.md)"

# Attributed per round: an earlier round's match must not condemn this one.
in_review 5
round_files 5
printf 'a.py | old wording\tb.py | canonical\t3\n' > .claude/spar-aliases.tsv
OUT=$(run_hook 2>&1)
chk "a recurrence from an EARLIER round → still extends" \
  'Round 6 verification review' "$OUT"

# An aliases file written before the round column existed must not read as a
# recurrence in every round.
in_review 5
round_files 5
printf 'a.py | old wording\tb.py | canonical\n' > .claude/spar-aliases.tsv
OUT=$(run_hook 2>&1)
chk "a column-less legacy alias row → not attributed to this round" \
  'Round 6 verification review' "$OUT"

# An IDENTICAL re-raise never reaches the matcher — build_matcher skips findings
# already in the registry — so without a second source the plainest repeat would
# be the one form that scores as progress.
in_review 5
printf 'STATUS: FINDINGS\n\n### F3-1 [MECHANICAL] a.py the same defect\n' \
  > reviews/spar-20260721-120000-abc123-r3.md
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] a.py the same defect\n' > "$RF5X"
printf '### F5-1: FIXED — did it again\n' > "$RP5X"
OUT=$(run_hook 2>&1)
chk "an identical re-raise → caps, with no matcher involved" \
  'Round cap (5) reached' "$OUT"
chk "identical re-raise → no alias was needed to detect it" "absent" \
  "$([ -s .claude/spar-aliases.tsv ] && echo present || echo absent)"

# A different defect in the same file is not a repeat.
in_review 5
printf 'STATUS: FINDINGS\n\n### F3-1 [MECHANICAL] a.py one defect\n' \
  > reviews/spar-20260721-120000-abc123-r3.md
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] a.py a different defect\n' > "$RF5X"
printf '### F5-1: FIXED — did it\n' > "$RP5X"
OUT=$(run_hook 2>&1)
chk "a new defect in a file seen before → still extends" \
  'Round 6 verification review' "$OUT"

# Title wording is normalised, so punctuation and case do not hide a repeat.
in_review 5
printf 'STATUS: FINDINGS\n\n### F3-1 [MECHANICAL] a.py The Same Defect!\n' \
  > reviews/spar-20260721-120000-abc123-r3.md
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] a.py the same defect\n' > "$RF5X"
printf '### F5-1: FIXED — did it again\n' > "$RP5X"
OUT=$(run_hook 2>&1)
chk "a re-raise differing only in case and punctuation → caps" \
  'Round cap (5) reached' "$OUT"

# A pending judge dispatch must never be scored as progress. The judge branch
# runs first, so assert what matters: the run does not advance past the cap.
in_review 5
round_files 5
printf 'a.py | fixed one\treviews/spar-20260721-120000-abc123-judge-1.md\n' > .claude/spar-judge-pending
OUT=$(run_hook 2>&1)
chk "judge pending at the soft cap → does not extend" "absent" \
  "$(printf '%s' "$OUT" | grep -q 'Round 6 verification review' && echo present || echo absent)"

# The cap message must not send the user down the commit-and-re-run path: a new
# run re-bases on the commit, so its reviewer would be handed an empty diff.
in_review 5
round_files 5
sed -i '' 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 5/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^max_rounds: 5/max_rounds: 5\nhard_cap: 5/' .claude/spar.local.md
CAPOUT=$(run_hook)
chk "cap message warns against commit-and-re-run" 'empty diff' "$CAPOUT"
chk "cap message asks what was never re-reviewed" 'never re-reviewed' "$CAPOUT"

# ── Economics: reviewer model and effort on the generated runners ────────────
# This suite has no chk_absent; absence is asserted as
# chk "…" "absent" "$(grep -q … && echo present || echo absent)".

fresh_dir; write_state task 0; mkdir -p reviews
printf '[reviewer.codex]\nmodel = "gpt-5.6-sol"\n[effort]\nladder = [[0, "low"]]\n' > .claude/spar-cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "configured model reaches the codex runner" "--model 'gpt-5.6-sol'" "$(cat .claude/spar-run-reviewer.sh)"
chk "configured effort reaches the codex runner" "model_reasoning_effort='\"low\"'" "$(cat .claude/spar-run-reviewer.sh)"

# The judge comes from the same emitter, so it must carry the flags too. A judge
# runner only exists after a stalemate, so this uses the suite's own fixture
# rather than a round-1 tree where the file would never exist.
mech_stalemate
printf '[reviewer.codex]\nmodel = "gpt-5.6-sol"\n' > .claude/spar-cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "the judge runner carries the same flags" "--model 'gpt-5.6-sol'" \
  "$(cat .claude/spar-run-judge.sh 2>/dev/null)"

# The sweep must NOT carry the reviewer's model — it runs author-family. A
# cross-model tree, so the two families differ; and round 3, because should_sweep
# only fires from there. At round 1 no sweep runner exists and the absence check
# would pass without proving anything.
in_review 3
printf 'author: claude\n' >> .claude/spar.local.md
printf '[reviewer.codex]\nmodel = "gpt-5.6-sol"\n[reviewer.claude]\nmodel = "claude-sonnet-5"\n' > .claude/spar-cfg.toml
printf 'STATUS: CONVERGED\n' > reviews/spar-20260721-120000-abc123-r3.md
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "the sweep runner was actually generated" "present" \
  "$([ -f .claude/spar-run-sweep.sh ] && echo present || echo absent)"
chk "the sweep does not take the reviewer's model" "absent" \
  "$(grep -qF 'gpt-5.6-sol' .claude/spar-run-sweep.sh 2>/dev/null && echo present || echo absent)"
chk "the sweep takes the author's model instead" "--model 'claude-sonnet-5'" \
  "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"

# The ladder must see the size of THIS change. A real commit and a real edit, with
# a threshold above zero — every other economics fixture uses [[0, …]], which
# selects the same tier whatever the count is and so cannot detect a wrong one.
fresh_dir; mkdir -p reviews
printf 'one\n' > f.txt
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
write_state task 0
sed -i '' "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md
no_skip
printf 'one\ntwo\nthree\nfour\nfive\n' > f.txt
printf '[effort]\nladder = [[0, "low"], [1, "high"]]\n' > .claude/spar-cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "a nonempty change picks the higher rung" "model_reasoning_effort='\"high\"'" \
  "$(cat .claude/spar-run-reviewer.sh)"
chk "and not the zero rung" "absent" \
  "$(grep -qF "model_reasoning_effort='\"low\"'" .claude/spar-run-reviewer.sh && echo present || echo absent)"

# The unit is CHANGED lines, not diff output lines. A three-line file rewritten
# whole is 6 changed lines and 11 lines of diff output, so a rung boundary at 8
# separates the two: counting output would pick the higher rung for a change the
# documentation calls smaller than the threshold.
fresh_dir; mkdir -p reviews
printf 'a\nb\nc\n' > f.txt
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
write_state task 0
sed -i '' "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md
no_skip
printf 'x\ny\nz\n' > f.txt
printf '[effort]\nladder = [[0, "low"], [8, "high"]]\n' > .claude/spar-cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "6 changed lines stay below a threshold of 8" "model_reasoning_effort='\"low\"'" \
  "$(cat .claude/spar-run-reviewer.sh)"
chk "counting diff output lines instead would have crossed it" "absent" \
  "$(grep -qF "model_reasoning_effort='\"high\"'" .claude/spar-run-reviewer.sh && echo present || echo absent)"

# Untracked files are part of the surface both families read, so they are part of
# the size. A task that only adds files has a zero tracked diff, which is the case
# where handing it the cheapest tier is most wrong.
fresh_dir; mkdir -p reviews
printf 'one\n' > f.txt
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
write_state task 0
sed -i '' "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md
no_skip
# Nothing tracked is touched; the whole change is one new 12-line file.
printf 'l\nl\nl\nl\nl\nl\nl\nl\nl\nl\nl\nl\n' > added.txt
printf '[effort]\nladder = [[0, "low"], [8, "high"]]\n' > .claude/spar-cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "a new untracked file counts toward the rung" "model_reasoning_effort='\"high\"'" \
  "$(cat .claude/spar-run-reviewer.sh)"
chk "counting only the tracked diff would have read it as empty" "absent" \
  "$(grep -qF "model_reasoning_effort='\"low\"'" .claude/spar-run-reviewer.sh && echo present || echo absent)"

# A file whose last line has no trailing newline still has that line. Eight lines
# written with seven newlines sits exactly on the rung boundary: counting newline
# characters gives seven and picks the lower rung, which is also the number git
# would not agree with — numstat calls an unterminated final line 1 on the tracked
# side of this same total.
fresh_dir; mkdir -p reviews
printf 'one\n' > f.txt
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
write_state task 0
sed -i '' "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md
no_skip
printf 'l\nl\nl\nl\nl\nl\nl\nl' > added.txt   # 8 lines, 7 newlines
printf '[effort]\nladder = [[0, "low"], [8, "high"]]\n' > .claude/spar-cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "an unterminated final line still counts" "model_reasoning_effort='\"high\"'" \
  "$(cat .claude/spar-run-reviewer.sh)"
chk "counting newline characters would have missed it" "absent" \
  "$(grep -qF "model_reasoning_effort='\"low\"'" .claude/spar-run-reviewer.sh && echo present || echo absent)"

# ...but the loop's own artifacts are not. Setup excludes them from the surface
# listing, and --exclude-standard is what keeps the same files out of the count.
# A fresh tree: the run above left state behind, and a second dispatch into it
# would take a different branch and leave the previous runner in place.
fresh_dir; mkdir -p reviews
printf 'one\n' > f.txt
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
write_state task 0
sed -i '' "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md
no_skip
# Same 12 lines as the file above, in a path the loop excludes.
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'noise\n'; done > reviews/spar-x-r1.md
printf '[effort]\nladder = [[0, "low"], [8, "high"]]\n' > .claude/spar-cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "an excluded review artifact does not inflate the count" "model_reasoning_effort='\"low\"'" \
  "$(cat .claude/spar-run-reviewer.sh)"

# An empty change takes the zero rung, so the check above is about the count and
# not about the ladder always returning its last row.
fresh_dir; mkdir -p reviews
printf 'one\n' > f.txt
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
write_state task 0
sed -i '' "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md 2>/dev/null \
  || sed -i "s/^base_sha: .*/base_sha: $BASE_SHA/" .claude/spar.local.md
no_skip
printf '[effort]\nladder = [[0, "low"], [1, "high"]]\n' > .claude/spar-cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "no change takes the zero rung" "model_reasoning_effort='\"low\"'" \
  "$(cat .claude/spar-run-reviewer.sh)"

# The shipped config must add nothing. This is the end-to-end half of the same
# claim tests/test_config.sh makes about the reader, and it is the only test here
# that reads the repository's real file.
fresh_dir; write_state task 0; mkdir -p reviews
SPAR_CONFIG_FILE="$ROOT/plugins/spar/shared/config.toml" run_hook >/dev/null
chk "shipped config → no model flag on the runner" "absent" \
  "$(grep -qF -- '--model' .claude/spar-run-reviewer.sh && echo present || echo absent)"
chk "shipped config → no effort flag on the runner" "absent" \
  "$(grep -qF 'model_reasoning_effort' .claude/spar-run-reviewer.sh && echo present || echo absent)"

# The reader's documented signal is source=, so the hook must honour it even when
# the values disagree. A stub reader is the only way to produce that combination:
# the real one never emits a value under source=default, which is exactly why
# relying on emptiness instead would be untestable.
fresh_dir; write_state task 0; mkdir -p reviews
cat > .claude/fake-reader.sh <<'READER'
#!/bin/sh
printf 'model=should-not-appear\neffort=high\nwriter=\nsource=default\n'
READER
chmod +x .claude/fake-reader.sh
SPAR_CONFIG_READER="$PWD/.claude/fake-reader.sh" run_hook >/dev/null
chk "source=default → values are ignored, whatever they say" "absent" \
  "$(grep -qF -- 'should-not-appear' .claude/spar-run-reviewer.sh && echo present || echo absent)"
chk "source=default → no effort flag either" "absent" \
  "$(grep -qF 'model_reasoning_effort' .claude/spar-run-reviewer.sh && echo present || echo absent)"

# And the same stub with source=config must be honoured, so the check above
# cannot pass by ignoring the reader altogether.
fresh_dir; write_state task 0; mkdir -p reviews
cat > .claude/fake-reader.sh <<'READER'
#!/bin/sh
printf 'model=stub-model\neffort=\nwriter=\nsource=config\n'
READER
chmod +x .claude/fake-reader.sh
SPAR_CONFIG_READER="$PWD/.claude/fake-reader.sh" run_hook >/dev/null
chk "source=config → the value is used" "--model 'stub-model'" "$(cat .claude/spar-run-reviewer.sh)"

# The claude branch has its own flag spelling (--effort, not -c …), and nothing
# above exercises it: the codex checks would pass with the claude branch missing
# or misspelled entirely. Driven through the sweep, which is the claude-family
# path in a cross-model tree.
in_review 3
printf 'author: claude\n' >> .claude/spar.local.md
printf '[reviewer.claude]\nmodel = "claude-sonnet-5"\n[effort]\nladder = [[0, "xhigh"]]\n' > .claude/spar-cfg.toml
printf 'STATUS: CONVERGED\n' > reviews/spar-20260721-120000-abc123-r3.md
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
chk "claude effort becomes --effort, not -c" "--effort 'xhigh'" \
  "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"
chk "claude branch does not borrow the codex spelling" "absent" \
  "$(grep -qF 'model_reasoning_effort' .claude/spar-run-sweep.sh 2>/dev/null && echo present || echo absent)"

# With no config the runner is what it was before Phase 7.
fresh_dir; write_state task 0; mkdir -p reviews
SPAR_CONFIG_FILE=/nonexistent run_hook >/dev/null
chk "no config → no model flag" "absent" \
  "$(grep -qF -- '--model' .claude/spar-run-reviewer.sh && echo present || echo absent)"
chk "no config → no effort flag" "absent" \
  "$(grep -qF 'model_reasoning_effort' .claude/spar-run-reviewer.sh && echo present || echo absent)"

# An unreadable config must not stop a review being dispatched.
fresh_dir; write_state task 0; mkdir -p reviews
printf 'not = = toml\n' > .claude/spar-cfg.toml
OUT=$(SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook)
chk "broken config → the round is still dispatched" 'spar-run-reviewer.sh' "$OUT"
chk "broken config → no half-written flag" "absent" \
  "$(grep -qF -- '--model ' .claude/spar-run-reviewer.sh && echo present || echo absent)"

# A model whose name carries shell metacharacters must not become shell.
fresh_dir; write_state task 0; mkdir -p reviews
printf '[reviewer.codex]\nmodel = "a$(touch pwned)b"\n' > .claude/spar-cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/spar-cfg.toml" run_hook >/dev/null
if bash -n .claude/spar-run-reviewer.sh 2>/dev/null; then SYN=ok; else SYN=unparseable; fi
chk "metacharacter model → runner is valid shell" "ok" "$SYN"
chk "metacharacter model → the value is quoted, not interpolated" \
  "--model 'a\$(touch pwned)b'" "$(cat .claude/spar-run-reviewer.sh)"
bash .claude/spar-run-reviewer.sh >/dev/null 2>&1 || true
chk "metacharacter model → nothing executed" "absent" \
  "$([ -e pwned ] && echo present || echo absent)"

echo; echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
