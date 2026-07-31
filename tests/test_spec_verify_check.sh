#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/plugins/spar/commands/spar-spec-verify-check.sh"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
mkdir reviews
VID=20260731-120000-abcdef

write_pair() {
  printf '%s\n\n%s\n' "$1" "${3-ok}" > "reviews/spar-spec-verify-${VID}-claude.md"
  printf '%s\n\n%s\n' "$2" "${4-ok}" > "reviews/spar-spec-verify-${VID}-codex.md"
}

write_pair "SPEC-VERIFY: CLEAN" "SPEC-VERIFY: CLEAN"
bash "$C" "$VID" >/dev/null 2>&1
chk "clean pair passes" "0" "$?"
chk "summary written on pass" "present" "$([ -f .claude/spar-spec-verify.md ] && echo present || echo absent)"

rm -rf .claude reviews; mkdir reviews
write_pair "SPEC-VERIFY: FINDINGS" "SPEC-VERIFY: CLEAN" "- non-blocking ordering note" "- ok"
bash "$C" "$VID" >/dev/null 2>&1
chk "non-blocking findings pass" "0" "$?"
chk "summary records findings family" "yes" "$(grep -qF 'status: FINDINGS' .claude/spar-spec-verify.md && echo yes || echo no)"

rm -rf .claude reviews; mkdir reviews
write_pair "SPEC-VERIFY: BLOCKED" "SPEC-VERIFY: CLEAN"
bash "$C" "$VID" >/dev/null 2>&1
chk "blocked report fails" "1" "$?"

rm -rf .claude reviews; mkdir reviews
printf 'SPEC-VERIFY: CLEAN\n' > "reviews/spar-spec-verify-${VID}-claude.md"
bash "$C" "$VID" >/dev/null 2>&1
chk "missing report fails" "1" "$?"

rm -rf .claude reviews; mkdir reviews
write_pair "NOPE" "SPEC-VERIFY: CLEAN"
bash "$C" "$VID" >/dev/null 2>&1
chk "invalid marker fails" "1" "$?"

rm -rf .claude reviews; mkdir reviews
ln -s /tmp/nope "reviews/spar-spec-verify-${VID}-claude.md"
printf 'SPEC-VERIFY: CLEAN\n' > "reviews/spar-spec-verify-${VID}-codex.md"
bash "$C" "$VID" >/dev/null 2>&1
chk "symlink artifact fails" "1" "$?"

rm -rf .claude reviews; mkdir reviews
write_pair "SPEC-VERIFY: FINDINGS" "SPEC-VERIFY: CLEAN" "- missing oracle for done"
bash "$C" "$VID" >/dev/null 2>&1
chk "blocking findings fail" "1" "$?"

bash "$C" "../bad" >/dev/null 2>&1
chk "unsafe id is usage error" "2" "$?"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
