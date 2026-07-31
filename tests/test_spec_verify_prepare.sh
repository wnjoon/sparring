#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/plugins/spar/commands/spar-spec-verify-prepare.sh"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
mkdir bin
cat > bin/claude <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'SPEC-VERIFY: CLEAN\n\n- claude read it\n'
EOF
cat > bin/codex <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then out="$2"; shift 2; continue; fi
  shift
done
cat >/dev/null
[ -n "$out" ] || exit 9
printf 'SPEC-VERIFY: CLEAN\n\n- codex read it\n' > "$out"
EOF
chmod +x bin/claude bin/codex
PATH="$TMP/bin:/usr/bin:/bin"

bash "$P" "ship --verify-spec safely" claude codex >/dev/null
id="$(cat .claude/spar-spec-verify-id)"
chk "verify id is usable" "yes" "$(printf '%s' "$id" | grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' && echo yes || echo no)"
for family in claude codex; do
  chk "$family runner exists" "yes" "$([ -x ".claude/spar-run-spec-verify-${family}.sh" ] && echo yes || echo no)"
  chk "$family prompt embeds inline spec" "yes" \
    "$(grep -qF 'ship --verify-spec safely' ".claude/spar-spec-verify-prompt-${family}.txt" && echo yes || echo no)"
done

bash .claude/spar-run-spec-verify-claude.sh >/dev/null 2>&1
bash .claude/spar-run-spec-verify-codex.sh >/dev/null 2>&1
chk "claude result published" "SPEC-VERIFY: CLEAN" "$(head -1 "reviews/spar-spec-verify-${id}-claude.md")"
chk "codex result published" "SPEC-VERIFY: CLEAN" "$(head -1 "reviews/spar-spec-verify-${id}-codex.md")"

rm -rf .claude reviews
printf 'file spec body\n' > spec.md
bash "$P" spec.md claude codex >/dev/null
chk "file spec is embedded" "yes" "$(grep -qF 'file spec body' .claude/spar-spec-verify-prompt-codex.txt && echo yes || echo no)"

rm -rf .claude reviews
bash "$P" "second run" claude codex >/dev/null
id="$(cat .claude/spar-spec-verify-id)"
ln -s /tmp/nope "reviews/spar-spec-verify-${id}-claude.md"
bash .claude/spar-run-spec-verify-claude.sh >/dev/null 2>&1
chk "runner refuses a symlink result" "1" "$?"

rm -rf .claude reviews
cat > bin/codex <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x bin/codex
bash "$P" "failing codex" claude codex >/dev/null
id="$(cat .claude/spar-spec-verify-id)"
bash .claude/spar-run-spec-verify-codex.sh >/dev/null 2>&1
chk "failing CLI exits nonzero" "1" "$?"
chk "failing CLI publishes nothing" "no" "$([ -e "reviews/spar-spec-verify-${id}-codex.md" ] && echo yes || echo no)"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
