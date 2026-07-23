#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/plugins/spar/commands/spar-harvest-intent.sh"
chk() {
  if printf '%s' "$3" | grep -qF "$2"; then
    echo "PASS: $1"; PASS=$((PASS+1))
  else
    echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1))
  fi
}

d=$(mktemp -d); cd "$d" || exit 1
git init -q
git config user.email sparring@example.invalid
git config user.name sparring-test
mkdir -p src/api src/web .claude/rules
cat > .claude/rules/api.md <<'EOF'
---
paths:
  - "src/api/**/*.ts"
---
# API rationale
EOF
cat > .claude/rules/web.md <<'EOF'
---
paths:
  - "src/web/**/*.tsx"
---
# Web rationale
EOF
cat > AGENTS.md <<'EOF'
# Commands
Run tests.

## Architecture rationale
Keep boundaries narrow.
EOF
printf 'export const x = 1;\n' > src/api/base.ts
git add . && git commit -qm base
BASE=$(git rev-parse HEAD)

cat > src/api/new.ts <<'EOF'
// This is intentional because the legacy client requires the shape.
export const value = 1;
EOF
bash "$H" "$BASE" .claude/intent.txt
OUT=$(cat .claude/intent.txt)
chk "matching path-scoped rule included" "rule: .claude/rules/api.md:1" "$OUT"
chk "unrelated rule excluded" "absent" "$(grep -q 'web.md' .claude/intent.txt && echo present || echo absent)"
chk "ancestor guide rationale pointer included" "guide: AGENTS.md:4" "$OUT"
chk "intentional comment pointer included" "comment: src/api/new.ts:1" "$OUT"
chk "comment content is not copied" "absent" "$(grep -q 'legacy client' .claude/intent.txt && echo present || echo absent)"

mkdir -p src/web
printf 'export const Web = 1;\n' > src/web/new.tsx
bash "$H" "$BASE" .claude/intent.txt
chk "re-harvest sees grown surface" "rule: .claude/rules/web.md:1" "$(cat .claude/intent.txt)"

printf 'odd\n' > $'src/api/control\nname.ts'
bash "$H" "$BASE" .claude/intent.txt
chk "control-character path does not corrupt pointer lines" "absent" \
  "$(grep -q 'control' .claude/intent.txt && echo present || echo absent)"

echo
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
