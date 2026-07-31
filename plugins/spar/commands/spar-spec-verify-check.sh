#!/usr/bin/env bash
# Cross-check the two durable spec verification reports.
# Usage: spar-spec-verify-check.sh <verify-id>
set -uo pipefail

vid="${1-}"
case "$vid" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "Error: unsafe or missing spec verification id." >&2; exit 2 ;;
esac

mkdir -p .claude || exit 1
summary=".claude/spar-spec-verify.md"
tmp="$(mktemp .claude/spar-spec-verify.md.tmp.XXXXXX)" || exit 1
trap 'rm -f "$tmp"' EXIT

status_for() {
  file="$1"
  [ -e "$file" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 3
  first="$(head -1 "$file" | tr -d '\r')"
  case "$first" in
    "SPEC-VERIFY: CLEAN") return 0 ;;
    "SPEC-VERIFY: FINDINGS") return 1 ;;
    "SPEC-VERIFY: BLOCKED") return 2 ;;
    *) return 4 ;;
  esac
}

overall=0
{
  printf '# Spec Verification\n\n'
  printf 'id: %s\n\n' "$vid"
  for family in claude codex; do
    file="reviews/spar-spec-verify-${vid}-${family}.md"
    status_for "$file"
    rc=$?
    case "$rc" in
      0) label=CLEAN ;;
      1) label=FINDINGS ;;
      2) label=BLOCKED; overall=1 ;;
      3) label=MISSING_OR_UNSAFE; overall=1 ;;
      *) label=INVALID; overall=1 ;;
    esac
    printf '## %s\n\n' "$family"
    printf 'status: %s\n\n' "$label"
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      sed '1d' "$file"
      printf '\n'
    else
      printf 'No usable verifier report at `%s`.\n\n' "$file"
    fi
  done
} > "$tmp"

mv "$tmp" "$summary"
trap - EXIT

if [ "$overall" -ne 0 ]; then
  echo "Error: spec verification found blockers. See .claude/spar-spec-verify.md." >&2
  exit 1
fi

printf 'spec-verify=passed\nsummary=%s\n' "$summary"
