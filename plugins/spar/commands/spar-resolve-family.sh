#!/usr/bin/env bash
# Resolve the reviewer family and strip any leading override token.
# Usage: spar-resolve-family.sh "<raw /spar args as ONE string>"
# The whole /spar argument text is passed as a single positional string (not
# argv-split) so whitespace/newlines/tabs and shell-metacharacters in the task
# survive verbatim — the caller must NOT word-split before invoking this.
# Prints: "<family>\t<task text>"  (family ∈ codex|claude)
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
task=""

# Step 2: optional override "--reviewer <codex|claude>" possibly followed by
# a "--" separator and exactly one space before the task text.
if [ "$stripped" = "--reviewer" ]; then
  echo "error: --reviewer must be codex|claude" >&2
  exit 2
elif [ "${stripped#--reviewer }" != "$stripped" ]; then
  after="${stripped#--reviewer }"
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
  if [ "$remainder" = "--" ]; then
    remainder=""
  elif [ "${remainder#-- }" != "$remainder" ]; then
    remainder="${remainder#-- }"
  fi
  task="$remainder"
else
  task="$stripped"
fi

# Trim a single trailing newline (heredoc/command-substitution callers may
# leave one); internal whitespace of the task is otherwise left untouched.
task="${task%$'\n'}"

if [ -z "$family" ]; then
  if command -v codex >/dev/null 2>&1; then family=codex; else family=claude; fi
fi
command -v "$family" >/dev/null 2>&1 || { echo "error: '$family' CLI not on PATH" >&2; exit 3; }

printf '%s\t%s\n' "$family" "$task"
