#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/spar/commands/spar-resolve-family.sh"
chk() { if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
# fake PATH: control which CLIs "exist"
mkbin() { d=$(mktemp -d); for n in "$@"; do printf '#!/bin/sh\n' > "$d/$n"; chmod +x "$d/$n"; done; echo "$d"; }

BOTH=$(mkbin codex claude); ONLYCLAUDE=$(mkbin claude); NEITHER=$(mkbin true)

# The resolver takes the ENTIRE /spar argument text as a single positional
# string (never argv-split) — every call below passes exactly one arg.

chk "codex present → codex" "codex	false	false	do the thing" "$(PATH="$BOTH:$PATH" bash "$R" "do the thing")"
chk "codex absent → claude" "claude	false	false	do the thing" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "do the thing")"
chk "override claude (codex present)" "claude	false	false	fix bug" "$(PATH="$BOTH:$PATH" bash "$R" "-- --reviewer claude -- fix bug")"
chk "override codex, codex absent → error" "error" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "--reviewer codex -- x" 2>&1; echo)"
chk "task after -- preserved incl leading dashes" "claude	false	false	--do --not --strip" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "-- --do --not --strip")"
chk "neither CLI → error" "error" "$(PATH="$NEITHER:/usr/bin:/bin" bash "$R" x 2>&1; echo)"
chk "invalid --reviewer value → error" "error" "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer bogus -- do it" 2>&1; echo)"

# --- new cases for the single-string reinterface (Fix 2) -------------------

# (a) internal whitespace/tabs in the task must be preserved verbatim,
# including multiple spaces and literal tab characters.
TASK_WS=$'do   the    thing\twith a\ttab'
chk "internal whitespace/tabs preserved" "$(printf 'claude\tfalse\tfalse\t%s' "$TASK_WS")" \
  "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "$TASK_WS")"

# (b) a task containing command substitution / backticks must survive
# LITERALLY — never executed — because it is passed as one already-expanded
# string argument, not spliced unquoted into a shell command.
TASK_CMDSUB='refactor $(echo pwned) the parser'
chk "cmd-substitution task not executed" "$(printf 'claude\tfalse\tfalse\t%s' "$TASK_CMDSUB")" \
  "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "$TASK_CMDSUB")"
chk "cmd-substitution task does not leak 'pwned' output" "" \
  "$(echo "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "$TASK_CMDSUB")" | grep -o '^pwned$' || true)"

TASK_BACKTICK='refactor `echo pwned` the parser'
chk "backtick task not executed" "$(printf 'claude\tfalse\tfalse\t%s' "$TASK_BACKTICK")" \
  "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "$TASK_BACKTICK")"

# (c) invalid --reviewer value still errors when passed as one string.
chk "invalid --reviewer value (single string) → error" "error" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer bogus -- do it" 2>&1; echo)"

# Phase 4: --include-dirty composes with reviewer override in either order and
# is removed from the task text.
chk "include-dirty before reviewer" "claude	true	false	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--include-dirty --reviewer claude -- fix bug")"
chk "include-dirty after reviewer" "claude	true	false	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer claude --include-dirty -- fix bug")"
chk "include-dirty without override" "codex	true	false	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--include-dirty -- fix bug")"
chk "duplicate include-dirty → error" "error" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--include-dirty --include-dirty x" 2>&1; echo)"
chk "duplicate reviewer → error" "error" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer codex --reviewer claude x" 2>&1; echo)"

# Phase 5: --unattended composes in any order and is stripped from the task.
chk "unattended default false" "codex	false	false	do it" \
  "$(PATH="$BOTH:$PATH" bash "$R" "do it")"
chk "unattended alone" "codex	false	true	do it" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--unattended -- do it")"
chk "unattended with reviewer + include-dirty" "claude	true	true	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--include-dirty --unattended --reviewer claude -- fix bug")"
chk "unattended after reviewer" "claude	false	true	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer claude --unattended -- fix bug")"
chk "duplicate unattended → error" "error" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--unattended --unattended x" 2>&1; echo)"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
