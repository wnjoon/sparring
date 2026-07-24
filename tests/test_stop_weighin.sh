#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/plugins/spar/hooks/stop-weighin.sh"
chk(){ if echo "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want~:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
nchk(){ if echo "$3" | grep -qF -- "$2"; then echo "FAIL: $1 (unexpected)"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }

# Each case runs in its own temp git repo. spar's stop-hook is stubbed via
# SPAR_WEIGHIN_SPAR_HOOK so we test the weigh-in logic in isolation.
setup(){
  TMP=$(mktemp -d); cd "$TMP"; git init -q; git config user.email a@b.c; git config user.name t
  git commit -q --allow-empty -m init; mkdir -p .claude reviews docs
  export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/spar"
  # mirror the real command's excludes so git add -A stays clean
  EX="$(git rev-parse --git-common-dir)/info/exclude"; printf 'reviews/spar-*\n.claude/spar*\n' >> "$EX"
  cat > "$TMP/spar-approve.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo '{"decision":"approve"}'
STUB
  cat > "$TMP/spar-block.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo '{"decision":"block","reason":"spar mid-round"}'
STUB
  chmod +x "$TMP"/spar-*.sh
  export SPAR_WEIGHIN_SPAR_HOOK="$TMP/spar-approve.sh"
}
teardown(){ cd /; rm -rf "$TMP"; unset SPAR_WEIGHIN_SPAR_HOOK; }
wstate(){ printf -- '---\nactive: true\nphase: %s\nmode: %s\nreviewer: codex\nplan_path: %s\nworktree: %s\ntasks: %s\ncurrent: %s\ncurrent_review_id: %s\n---\n' "$1" "$2" "$3" "$TMP" "$4" "$5" "$6"; }
outcome(){ printf -- '---\nreason: %s\nreview_id: %s\nrounds: 2\nreviewer: codex\nsweep: not-triggered\nrecorded_at: x\n---\n' "$1" "$2"; }

# A: no weigh-in, spar approves → pass through approve
setup
chk "A passthrough approve" '"approve"' "$(echo '{}' | bash "$HOOK")"
teardown

# A2: no weigh-in, spar blocks → pass through block (spar-only unchanged)
setup
export SPAR_WEIGHIN_SPAR_HOOK="$TMP/spar-block.sh"
OUT="$(echo '{}' | bash "$HOOK")"
chk "A2 passthrough block" '"block"' "$OUT"
chk "A2 keeps spar reason" "spar mid-round" "$OUT"
teardown

# B: weigh-in active, spar blocks (mid-round) → pass through, do NOT advance
setup
export SPAR_WEIGHIN_SPAR_HOOK="$TMP/spar-block.sh"
wstate running per-task docs/p.md 2 1 20260724-101010-aaaaaa > .claude/spar-weighin.local.md
printf '1\tpending\tT1\n2\tpending\tT2\n' >> .claude/spar-weighin.local.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "B passthrough block" '"block"' "$OUT"
nchk "B no task launched" "review_id" "$(cat .claude/spar.local.md 2>/dev/null)"
teardown

# C: weigh-in active, spar approved, task1 converged, task2 remains → block+advance+checkbox+launch
setup
cat > docs/p.md <<'EOF'
### Task 1: Alpha
- [ ] a
### Task 2: Beta
- [ ] b
EOF
git add docs/p.md; git commit -q -m plan
wstate running per-task docs/p.md 2 1 20260724-101010-aaaaaa > .claude/spar-weighin.local.md
printf '1\tpending\tTask 1: Alpha\n2\tpending\tTask 2: Beta\n' >> .claude/spar-weighin.local.md
outcome converged 20260724-101010-aaaaaa > reviews/spar-20260724-101010-aaaaaa-outcome.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "C blocks" '"block"' "$OUT"
chk "C task1 checkbox flipped" "- [x] a" "$(sed -n '2p' docs/p.md)"
chk "C launched task2 spar" "review_id" "$(cat .claude/spar.local.md 2>/dev/null)"
teardown

# D: last task converged → finish (block to summarize, phase done)
setup
printf '### Task 1: Alpha\n- [ ] a\n' > docs/p.md
git add docs/p.md; git commit -q -m plan
wstate running per-task docs/p.md 1 1 20260724-101010-bbbbbb > .claude/spar-weighin.local.md
printf '1\tpending\tTask 1: Alpha\n' >> .claude/spar-weighin.local.md
outcome converged 20260724-101010-bbbbbb > reviews/spar-20260724-101010-bbbbbb-outcome.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "D blocks with summary" '"block"' "$OUT"
chk "D phase done" "phase: done" "$(cat .claude/spar-weighin.local.md)"
teardown

# E: task hit cap → stop and report honestly
setup
printf '### Task 1: Alpha\n- [ ] a\n### Task 2: Beta\n- [ ] b\n' > docs/p.md
git add docs/p.md; git commit -q -m plan
wstate running per-task docs/p.md 2 1 20260724-101010-cccccc > .claude/spar-weighin.local.md
printf '1\tpending\tTask 1: Alpha\n2\tpending\tTask 2: Beta\n' >> .claude/spar-weighin.local.md
outcome cap 20260724-101010-cccccc > reviews/spar-20260724-101010-cccccc-outcome.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "E blocks" '"block"' "$OUT"
chk "E does not converge" "did not converge" "$OUT"
chk "E phase done" "phase: done" "$(cat .claude/spar-weighin.local.md)"
nchk "E task2 not launched" "review_id" "$(cat .claude/spar.local.md 2>/dev/null)"
teardown

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
