#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/commands/spar-report-show.sh
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOW="$ROOT/plugins/spar/commands/spar-report-show.sh"
CMD="$ROOT/plugins/spar/commands/report.md"

# `--` is required: several expectations start with "- " (see test_spar_report.sh).
chk() { # $1=desc $2=expected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi
}
chk_absent() { # $1=desc $2=unexpected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; echo "  unwanted:$2"; FAIL=$((FAIL+1))
  else echo "PASS: $1"; PASS=$((PASS+1)); fi
}

fresh() { d=$(mktemp -d); cd "$d" || exit 1; mkdir -p reviews; }

plant() { # $1=id $2=marker
  printf '# sparring run report — %s\n\n## Result\n\n- outcome: %s\n' "$1" "$2" \
    > "reviews/spar-$1-report.md"
}

# 1. no reports at all → plain message, exit 1
fresh
OUT="$(bash "$SHOW" 2>&1)"; RC=$?
chk "no reports → message" "No sparring report found" "$OUT"
chk "no reports → exit 1" "1" "$RC"

# 2. one report, no id → printed with its path
fresh; plant 20260721-120000-abc123 converged
OUT="$(bash "$SHOW")"; RC=$?
chk "prints the report path" "reviews/spar-20260721-120000-abc123-report.md" "$OUT"
chk "prints the report body" "- outcome: converged" "$OUT"
chk "success exit 0" "0" "$RC"

# 3. two reports, no id → the most recent one
fresh
plant 20260721-120000-abc123 converged
sleep 1
plant 20260722-090000-def456 blocked-pending-user
OUT="$(bash "$SHOW")"
chk "newest report selected" "20260722-090000-def456" "$OUT"
chk "newest report body" "- outcome: blocked-pending-user" "$OUT"

# 4. explicit id → that report, not the newest
OUT="$(bash "$SHOW" 20260721-120000-abc123)"
chk "explicit id honored" "spar-20260721-120000-abc123-report.md" "$OUT"

# 5. explicit id with no report → plain message, exit 1
OUT="$(bash "$SHOW" 20260101-000000-aaaaaa 2>&1)"; RC=$?
chk "missing id → message" "No readable report" "$OUT"
chk "missing id → exit 1" "1" "$RC"

# 6. invalid id → usage error, exit 2
OUT="$(bash "$SHOW" '../../etc/passwd' 2>&1)"; RC=$?
chk "invalid id → error" "invalid review id" "$OUT"
chk "invalid id → exit 2" "2" "$RC"

# 7. symlinked report → refused, never followed
fresh
outside=$(mktemp); printf 'SECRET\n' > "$outside"
ln -s "$outside" reviews/spar-20260721-120000-abc123-report.md
OUT="$(bash "$SHOW" 20260721-120000-abc123 2>&1)"
chk "symlink refused" "No readable report" "$OUT"
chk_absent "symlink content never printed" "SECRET" "$OUT"

# 8. the command file exists and declares itself
chk "command file has a description" "description:" "$(cat "$CMD")"
chk "command file calls the resolver" "spar-report-show.sh" "$(cat "$CMD")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
