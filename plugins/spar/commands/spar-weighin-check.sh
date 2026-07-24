#!/usr/bin/env bash
# Flip '- [ ]' to '- [x]' within one task section (or all, when index=0).
# Usage: spar-weighin-check.sh <plan-path> <task-index>
set -uo pipefail
plan="${1:?plan path}"; idx="${2:?task index}"
[ -f "$plan" ] || { echo "error: plan not found: $plan" >&2; exit 2; }
tmp="${plan}.tmp.$$"
awk -v idx="$idx" '
  function flip(line){ sub(/- \[ \]/, "- [x]", line); return line }
  idx==0 { print flip($0); next }
  /^### Task [0-9]+:/ {
    n=$3; gsub(/[^0-9]/, "", n) # "### Task N:" -> field 3 "N:" -> bare integer
    inzone = (n==idx)
    print; next
  }
  /^### / { inzone=0; print; next }
  { print inzone ? flip($0) : $0 }
' "$plan" > "$tmp" && mv "$tmp" "$plan"
