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
bash "$WRITER" cancelled .claude/spar.local.md pending
chk "pending sweep state accepted for cancellation" "sweep: pending" "$(cat reviews/*-outcome.md)"

fresh
bash "$WRITER" bogus .claude/spar.local.md not-run >/dev/null 2>&1
chk "invalid reason rejected" "nonzero" "$([ "$?" -ne 0 ] && echo nonzero || echo zero)"

# ── provenance: the outcome carries the reviewer build ──────────────────────
fresh
printf -- '---\nactive: true\nphase: review\nround: 3\nreview_id: 20260728-100000-abc123\nreviewer: codex\nreviewer_version: codex-cli 9.9.9-test\n---\n' > .claude/spar.local.md
bash "$WRITER" converged .claude/spar.local.md clean
chk "outcome records the reviewer build" "reviewer_version: codex-cli 9.9.9-test" \
  "$(cat reviews/spar-20260728-100000-abc123-outcome.md)"

fresh
printf -- '---\nactive: true\nphase: review\nround: 3\nreview_id: 20260728-100001-abc124\nreviewer: codex\n---\n' > .claude/spar.local.md
bash "$WRITER" converged .claude/spar.local.md clean
chk "a missing version is recorded as unknown" "reviewer_version: unknown" \
  "$(cat reviews/spar-20260728-100001-abc124-outcome.md)"

# The writer normalises too, not only the activation sites: a state file written
# by an older version, or edited by hand, can still carry control characters.
fresh
printf -- '---\nactive: true\nphase: review\nround: 3\nreview_id: 20260728-100002-abc125\nreviewer: codex\nreviewer_version: v1\033[31m forged\n---\n' > .claude/spar.local.md
bash "$WRITER" converged .claude/spar.local.md clean
chk "an escape sequence is stripped from the outcome" "absent" \
  "$(grep -q "$(printf '\033')" reviews/spar-20260728-100002-abc125-outcome.md && echo present || echo absent)"
chk "and the printable remainder survives" "reviewer_version: v1[31m forged" \
  "$(cat reviews/spar-20260728-100002-abc125-outcome.md)"

echo

# A backslash survives the printable filter. Under xpg_echo — a shopt this script
# does not set and cannot rule out — `echo` would expand it and forge a field.
fresh
# A quoted heredoc, not printf: the file must hold a LITERAL backslash-n, and
# printf's own escape handling makes that easy to get wrong — a real newline
# there just truncates the value at `v1` and the check passes with `echo` intact.
cat > .claude/spar.local.md <<'STATE'
---
active: true
phase: review
round: 3
review_id: 20260728-100003-abc126
reviewer: codex
reviewer_version: v1\nsweep: findings
---
STATE
# bash -O, not BASHOPTS=: that variable is readonly in an already-running bash,
# so assigning it fails and the option never gets set — the check then passes
# with `echo` intact.
bash -O xpg_echo "$WRITER" converged .claude/spar.local.md clean
chk "a backslash escape cannot forge a field" "1" \
  "$(grep -c '^sweep:' reviews/spar-20260728-100003-abc126-outcome.md)"
chk "and the literal backslash is preserved" 'reviewer_version: v1\nsweep: findings' \
  "$(cat reviews/spar-20260728-100003-abc126-outcome.md)"

echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
