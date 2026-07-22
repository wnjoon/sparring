#!/usr/bin/env bash
# Resolve the reviewer family and strip any leading override token.
# Usage: spar-resolve-family.sh <raw /spar args...>
# Prints: "<family>\t<task text>"  (family ∈ codex|claude)
# Exits non-zero with "error: …" on an unusable resolution.
set -uo pipefail

family=""
# Optional leading override: [--] --reviewer <codex|claude> --  <task…>
args=("$@"); i=0
[ "${args[0]:-}" = "--" ] && i=1        # tolerate a leading -- before the flag
if [ "${args[$i]:-}" = "--reviewer" ]; then
  family="${args[$((i+1))]:-}"
  case "$family" in codex|claude) ;; *) echo "error: --reviewer must be codex|claude" >&2; exit 2;; esac
  i=$((i+2))
  [ "${args[$i]:-}" = "--" ] && i=$((i+1))   # require/allow -- separator
fi
task="${*:$((i+1))}"

if [ -z "$family" ]; then
  if command -v codex >/dev/null 2>&1; then family=codex; else family=claude; fi
fi
command -v "$family" >/dev/null 2>&1 || { echo "error: '$family' CLI not on PATH" >&2; exit 3; }

printf '%s\t%s\n' "$family" "$task"
