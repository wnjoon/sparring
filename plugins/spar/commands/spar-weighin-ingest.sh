#!/usr/bin/env bash
# Parse a writing-plans plan into the weighin task table.
# Usage: spar-weighin-ingest.sh <plan-path> <mode> <state-file>
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/spar-weighin-lib.sh"
plan="${1:?plan path}"; mode="${2:?mode}"; state="${3:?state file}"
[ -f "$plan" ] || { echo "error: plan not found: $plan" >&2; exit 2; }

rows=""; count=0
if [ "$mode" = "whole" ]; then
  count=1; rows="1	pending	WHOLE PLAN"
else
  while IFS= read -r heading; do
    count=$((count+1))
    rows="${rows}${count}	pending	${heading}
"
  done < <(sed -n 's/^### \(Task [0-9][0-9]*:.*\)$/\1/p' "$plan")
  [ "$count" -gt 0 ] || { echo "error: no '### Task N:' sections found in $plan" >&2; exit 2; }
fi

# Replace everything after the second '---' with the task table.
tmp="${state}.tmp.$$"
awk '/^---$/{c++} c<2{print} c==2 && !done{print; done=1}' "$state" > "$tmp"
printf '%s\n' "$rows" | sed '/^$/d' >> "$tmp"
mv "$tmp" "$state"
wgn_set_field tasks "$count" "$state"
wgn_set_field phase running "$state"
