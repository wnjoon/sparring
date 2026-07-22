#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/spar/commands/spar-resolve-family.sh"
chk() { if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
# fake PATH: control which CLIs "exist"
mkbin() { d=$(mktemp -d); for n in "$@"; do printf '#!/bin/sh\n' > "$d/$n"; chmod +x "$d/$n"; done; echo "$d"; }

BOTH=$(mkbin codex claude); ONLYCLAUDE=$(mkbin claude); NEITHER=$(mkbin true)

chk "codex present → codex" "codex	do the thing" "$(PATH="$BOTH:$PATH" bash "$R" "do the thing")"
chk "codex absent → claude" "claude	do the thing" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "do the thing")"
chk "override claude (codex present)" "claude	fix bug" "$(PATH="$BOTH:$PATH" bash "$R" -- --reviewer claude -- fix bug)"
chk "override codex, codex absent → error" "error" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" --reviewer codex -- x 2>&1; echo)"
chk "task after -- preserved incl leading dashes" "claude	--do --not --strip" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" -- --do --not --strip)"
chk "neither CLI → error" "error" "$(PATH="$NEITHER:/usr/bin:/bin" bash "$R" x 2>&1; echo)"
chk "invalid --reviewer value → error" "error" "$(PATH="$BOTH:$PATH" bash "$R" --reviewer bogus -- do it 2>&1; echo)"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
