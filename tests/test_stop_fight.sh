#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/plugins/spar/hooks/stop-fight.sh"
chk(){ if echo "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want~:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
nchk(){ if echo "$3" | grep -qF -- "$2"; then echo "FAIL: $1 (unexpected)"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }

# Each case runs in its own temp git repo. spar's stop-hook is stubbed via
# SPAR_FIGHT_SPAR_HOOK so we test the weigh-in logic in isolation.
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
  export SPAR_FIGHT_SPAR_HOOK="$TMP/spar-approve.sh"
}
teardown(){ cd /; rm -rf "$TMP"; unset SPAR_FIGHT_SPAR_HOOK; }
wstate(){ printf -- '---\nactive: true\nphase: %s\nmode: %s\nreviewer: codex\nplan_path: %s\nbranch: %s\ntasks: %s\ncurrent: %s\ncurrent_review_id: %s\n---\n' "$1" "$2" "$3" "$TMP" "$4" "$5" "$6"; }
outcome(){ printf -- '---\nreason: %s\nreview_id: %s\nrounds: 2\nreviewer: codex\nsweep: not-triggered\nrecorded_at: x\n---\n' "$1" "$2"; }

# A: no weigh-in, spar approves → pass through approve
setup
chk "A passthrough approve" '"approve"' "$(echo '{}' | bash "$HOOK")"
teardown

# A2: no weigh-in, spar blocks → pass through block (spar-only unchanged)
setup
export SPAR_FIGHT_SPAR_HOOK="$TMP/spar-block.sh"
OUT="$(echo '{}' | bash "$HOOK")"
chk "A2 passthrough block" '"block"' "$OUT"
chk "A2 keeps spar reason" "spar mid-round" "$OUT"
teardown

# B: weigh-in active, spar blocks (mid-round) → pass through, do NOT advance
setup
export SPAR_FIGHT_SPAR_HOOK="$TMP/spar-block.sh"
wstate running per-task docs/p.md 2 1 20260724-101010-aaaaaa > .claude/spar-plan.local.md
printf '1\tpending\tT1\n2\tpending\tT2\n' >> .claude/spar-plan.local.md
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
wstate running per-task docs/p.md 2 1 20260724-101010-aaaaaa > .claude/spar-plan.local.md
printf '1\tpending\tTask 1: Alpha\n2\tpending\tTask 2: Beta\n' >> .claude/spar-plan.local.md
outcome converged 20260724-101010-aaaaaa > reviews/spar-20260724-101010-aaaaaa-outcome.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "C blocks" '"block"' "$OUT"
chk "C task1 checkbox flipped" "- [x] a" "$(sed -n '2p' docs/p.md)"
chk "C launched task2 spar" "review_id" "$(cat .claude/spar.local.md 2>/dev/null)"
# atomicity/consistency: plan current_review_id must equal the NEWLY launched
# spar id (never a stale one), and current must have advanced to 2 together.
NEWID="$(grep '^review_id:' .claude/spar.local.md | sed 's/^review_id: //')"
chk "C plan id matches launched spar id" "$NEWID" "$(cat .claude/spar-plan.local.md)"
chk "C current advanced to 2" "current: 2" "$(cat .claude/spar-plan.local.md)"
teardown

# D: last task converged → finish (block to summarize, phase done)
setup
printf '### Task 1: Alpha\n- [ ] a\n' > docs/p.md
git add docs/p.md; git commit -q -m plan
wstate running per-task docs/p.md 1 1 20260724-101010-bbbbbb > .claude/spar-plan.local.md
printf '1\tpending\tTask 1: Alpha\n' >> .claude/spar-plan.local.md
outcome converged 20260724-101010-bbbbbb > reviews/spar-20260724-101010-bbbbbb-outcome.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "D blocks with summary" '"block"' "$OUT"
chk "D phase done" "phase: done" "$(cat .claude/spar-plan.local.md)"
teardown

# E: task hit cap → stop and report honestly
setup
printf '### Task 1: Alpha\n- [ ] a\n### Task 2: Beta\n- [ ] b\n' > docs/p.md
git add docs/p.md; git commit -q -m plan
wstate running per-task docs/p.md 2 1 20260724-101010-cccccc > .claude/spar-plan.local.md
printf '1\tpending\tTask 1: Alpha\n2\tpending\tTask 2: Beta\n' >> .claude/spar-plan.local.md
outcome cap 20260724-101010-cccccc > reviews/spar-20260724-101010-cccccc-outcome.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "E blocks" '"block"' "$OUT"
chk "E does not converge" "did not converge" "$OUT"
chk "E phase done" "phase: done" "$(cat .claude/spar-plan.local.md)"
nchk "E task2 not launched" "review_id" "$(cat .claude/spar.local.md 2>/dev/null)"
teardown

# F: fail-open — an internal error (corrupt lib) while a weigh-in is active AND
# spar BLOCKED must NOT release spar's enforced loop. The ERR trap emits the
# captured spar decision (block), never a hardcoded approve.
setup
export SPAR_FIGHT_SPAR_HOOK="$TMP/spar-block.sh"
mkdir -p "$TMP/fakeplugin/commands"
printf 'not valid bash ((((\n' > "$TMP/fakeplugin/commands/spar-plan-lib.sh"
export CLAUDE_PLUGIN_ROOT="$TMP/fakeplugin"
wstate running per-task docs/p.md 2 1 20260724-101010-ffffff > .claude/spar-plan.local.md
printf '1\tpending\tT1\n2\tpending\tT2\n' >> .claude/spar-plan.local.md
OUT="$(echo '{}' | bash "$HOOK" 2>/dev/null)"
chk "F fail-open preserves spar block" '"block"' "$OUT"
chk "F keeps spar reason on internal error" "spar mid-round" "$OUT"
teardown

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
