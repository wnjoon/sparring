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

echo; echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
