#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRITER="$ROOT/plugins/spar/commands/spar-record-outcome.sh"

chk() {
  if printf '%s' "$3" | grep -qF "$2"; then
    echo "PASS: $1"; PASS=$((PASS+1))
  else
    echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1))
  fi
}

fresh() {
  d=$(mktemp -d)
  cd "$d" || exit 1
  mkdir -p .claude
  cat > .claude/spar.local.md <<'EOF'
---
active: true
phase: review
round: 3
review_id: 20260723-120000-abc123
base_sha: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
reviewer: codex
max_rounds: 5
---
task
EOF
}

fresh
bash "$WRITER" converged .claude/spar.local.md clean
OUT=reviews/spar-20260723-120000-abc123-outcome.md
chk "outcome file created" "present" "$([ -f "$OUT" ] && echo present || echo absent)"
chk "reason persisted" "reason: converged" "$(cat "$OUT")"
chk "round persisted" "rounds: 3" "$(cat "$OUT")"
chk "reviewer persisted" "reviewer: codex" "$(cat "$OUT")"
chk "sweep result persisted" "sweep: clean" "$(cat "$OUT")"

# Immutable/idempotent: a second terminal call cannot rewrite the first reason.
bash "$WRITER" cap .claude/spar.local.md findings
chk "existing outcome is not rewritten" "reason: converged" "$(cat "$OUT")"
chk "existing outcome keeps first sweep result" "sweep: clean" "$(cat "$OUT")"

fresh
mkdir -p reviews/spar-20260723-120000-abc123-outcome.md
if bash "$WRITER" converged .claude/spar.local.md clean >/dev/null 2>&1; then RC=zero; else RC=nonzero; fi
chk "pre-created outcome directory is rejected" "nonzero" "$RC"

fresh
outside=$(mktemp -d)
ln -s "$outside" reviews
if bash "$WRITER" converged .claude/spar.local.md clean >/dev/null 2>&1; then RC=zero; else RC=nonzero; fi
chk "symlinked reviews directory is rejected" "nonzero" "$RC"
chk "symlink target receives no outcome" "0" "$(find "$outside" -type f | wc -l | tr -d ' ')"

fresh
sed -i '' 's/^review_id:.*/review_id: ..\/evil/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^review_id:.*/review_id: ..\/evil/' .claude/spar.local.md
bash "$WRITER" error-bypass .claude/spar.local.md error
chk "invalid id cannot escape reviews directory" "1" "$(find reviews -type f | wc -l | tr -d ' ')"
chk "invalid id recorded safely" "review_id: invalid" "$(cat reviews/*-outcome.md)"

fresh
bash "$WRITER" cancelled .claude/spar.local.md not-run
chk "cancelled reason accepted" "reason: cancelled" "$(cat reviews/*-outcome.md)"

fresh
bash "$WRITER" bogus .claude/spar.local.md not-run >/dev/null 2>&1
chk "invalid reason rejected" "nonzero" "$([ "$?" -ne 0 ] && echo nonzero || echo zero)"

echo
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
