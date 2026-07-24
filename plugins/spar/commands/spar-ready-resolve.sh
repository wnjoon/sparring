#!/usr/bin/env bash
# Resolve /spar:ready flags from the ONE-string argument, strip them, and
# print: "<mode>\t<reviewer|empty>\t<unattended>\t<spec>" (unattended ∈
# true|false). Never argv-split the input.
set -uo pipefail
raw="${1-}"
stripped="$raw"
if [ "$stripped" = "--" ]; then stripped=""
elif [ "${stripped#-- }" != "$stripped" ]; then stripped="${stripped#-- }"; fi

mode="per-task"; reviewer=""; unattended=false; seen_mode=false; seen_rev=false; seen_unatt=false
remainder="$stripped"
while :; do
  if [ "$remainder" = "--" ]; then remainder=""; break
  elif [ "${remainder#-- }" != "$remainder" ]; then remainder="${remainder#-- }"; break
  elif [ "$remainder" = "--whole" ]; then
    [ "$seen_mode" = false ] || { echo "error: --whole specified more than once" >&2; exit 2; }
    seen_mode=true; mode="whole"; remainder=""
  elif [ "${remainder#--whole }" != "$remainder" ]; then
    [ "$seen_mode" = false ] || { echo "error: --whole specified more than once" >&2; exit 2; }
    seen_mode=true; mode="whole"; remainder="${remainder#--whole }"
  elif [ "$remainder" = "--unattended" ]; then
    [ "$seen_unatt" = false ] || { echo "error: --unattended specified more than once" >&2; exit 2; }
    seen_unatt=true; unattended=true; remainder=""
  elif [ "${remainder#--unattended }" != "$remainder" ]; then
    [ "$seen_unatt" = false ] || { echo "error: --unattended specified more than once" >&2; exit 2; }
    seen_unatt=true; unattended=true; remainder="${remainder#--unattended }"
  elif [ "$remainder" = "--reviewer" ]; then echo "error: --reviewer must be codex|claude" >&2; exit 2
  elif [ "${remainder#--reviewer }" != "$remainder" ]; then
    [ "$seen_rev" = false ] || { echo "error: --reviewer specified more than once" >&2; exit 2; }
    seen_rev=true; after="${remainder#--reviewer }"; value="${after%% *}"
    if [ "$value" = "$after" ]; then remainder=""; else remainder="${after#* }"; fi
    case "$value" in codex|claude) reviewer="$value" ;; *) echo "error: --reviewer must be codex|claude" >&2; exit 2 ;; esac
  else break; fi
done
spec="${remainder%$'\n'}"
[ -n "$spec" ] || { echo "error: no spec path or description given" >&2; exit 2; }
printf '%s\t%s\t%s\t%s\n' "$mode" "$reviewer" "$unattended" "$spec"
