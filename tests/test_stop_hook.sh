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

# helper: enter review phase for round $1
in_review() { fresh_dir; write_state review "$1"; mkdir -p reviews; }
RF1="reviews/spar-20260721-120000-abc123-r1.md"
RP1="reviews/spar-20260721-120000-abc123-r1-response.md"

# ── 5. review file missing → block (retry), 3rd miss → fail-open ──
in_review 1
chk "review missing → block" '"decision":"block"' "$(run_hook)"
run_hook >/dev/null
chk "review missing 3rd → approve" '"decision":"approve"' "$(run_hook)"

# ── 6. CONVERGED → approve + cleanup ──
in_review 1
printf 'STATUS: CONVERGED\n\nChecked diff, tests, security.\n' > "$RF1"
chk "converged → approve" '"decision":"approve"' "$(run_hook)"
chk "converged → state removed" "gone" "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

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
chk "cap → next stop approves" '"decision":"approve"' "$(run_hook)"

# ── 10. CRLF status line tolerated ──
in_review 1
printf 'STATUS: CONVERGED\r\n' > "$RF1"
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
chk "consecutive rejection → streak 2" "$(printf 'mod.py | split the module\tDESIGN\t2\t2\tescalated')" "$(cat .claude/spar-registry.tsv)"

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

echo; echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
