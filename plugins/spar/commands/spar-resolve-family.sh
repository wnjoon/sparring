#!/usr/bin/env bash
# Resolve setup flags and strip them from the task text.
# Usage: spar-resolve-family.sh "<raw /spar args as ONE string>"
# The whole /spar argument text is passed as a single positional string (not
# argv-split) so whitespace/newlines/tabs and shell-metacharacters in the task
# survive verbatim — the caller must NOT word-split before invoking this.
# Prints: "<family>\t<include-dirty>\t<unattended>\t<task text>"
#   family ∈ codex|claude; include-dirty ∈ true|false; unattended ∈ true|false
# Exits non-zero with "error: …" on an unusable resolution.
set -uo pipefail

raw="${1-}"

# Step 1: tolerate one leading "-- " (or a bare "--") before the rest, even
# when it is not followed by --reviewer. This lets a task that itself starts
# with dashes be disambiguated from a flag.
stripped="$raw"
if [ "$stripped" = "--" ]; then
  stripped=""
elif [ "${stripped#-- }" != "$stripped" ]; then
  stripped="${stripped#-- }"
fi

family=""
include_dirty=false
unattended=false
seen_reviewer=false
seen_include_dirty=false
seen_unattended=false
task=""

# Step 2: consume known leading flags in either order. A "--" after flags
# ends option parsing; everything after it is task text.
remainder="$stripped"
while :; do
  if [ "$remainder" = "--" ]; then
    remainder=""
    break
  elif [ "${remainder#-- }" != "$remainder" ]; then
    remainder="${remainder#-- }"
    break
  elif [ "$remainder" = "--include-dirty" ]; then
    [ "$seen_include_dirty" = false ] \
      || { echo "error: --include-dirty specified more than once" >&2; exit 2; }
    seen_include_dirty=true
    include_dirty=true
    remainder=""
  elif [ "${remainder#--include-dirty }" != "$remainder" ]; then
    [ "$seen_include_dirty" = false ] \
      || { echo "error: --include-dirty specified more than once" >&2; exit 2; }
    seen_include_dirty=true
    include_dirty=true
    remainder="${remainder#--include-dirty }"
  elif [ "$remainder" = "--unattended" ]; then
    [ "$seen_unattended" = false ] \
      || { echo "error: --unattended specified more than once" >&2; exit 2; }
    seen_unattended=true
    unattended=true
    remainder=""
  elif [ "${remainder#--unattended }" != "$remainder" ]; then
    [ "$seen_unattended" = false ] \
      || { echo "error: --unattended specified more than once" >&2; exit 2; }
    seen_unattended=true
    unattended=true
    remainder="${remainder#--unattended }"
  elif [ "$remainder" = "--reviewer" ]; then
    echo "error: --reviewer must be codex|claude" >&2
    exit 2
  elif [ "${remainder#--reviewer }" != "$remainder" ]; then
    [ "$seen_reviewer" = false ] \
      || { echo "error: --reviewer specified more than once" >&2; exit 2; }
    seen_reviewer=true
    after="${remainder#--reviewer }"
    value="${after%% *}"
    if [ "$value" = "$after" ]; then
      remainder=""
    else
      remainder="${after#* }"
    fi
    case "$value" in
      codex|claude) family="$value" ;;
      *) echo "error: --reviewer must be codex|claude" >&2; exit 2 ;;
    esac
  else
    break
  fi
done
task="$remainder"

# Trim a single trailing newline (heredoc/command-substitution callers may
# leave one); internal whitespace of the task is otherwise left untouched.
task="${task%$'\n'}"

if [ -z "$family" ]; then
  if command -v codex >/dev/null 2>&1; then family=codex; else family=claude; fi
fi
command -v "$family" >/dev/null 2>&1 || { echo "error: '$family' CLI not on PATH" >&2; exit 3; }

printf '%s\t%s\t%s\t%s\n' "$family" "$include_dirty" "$unattended" "$task"
