#!/usr/bin/env bash
# The branch-slug recipe /spar:ready builds its branch name from, in both seats.
# The recipe is inline shell inside two markdown documents, so this suite
# EXTRACTS it from each document and runs it. A test carrying its own copy would
# pass while the document it stands in for stayed broken.
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
eqchk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); cd "$TMP" || exit 1

recipe() { # $1=document path → the slug lines, verbatim
  awk '/^# Basename and extension stripping/,/^\[ -n "\$RDY_SLUG" \]/' "$1"
}
slug() { # $1=document  $2=spec → the slug that document computes
  local src; src="$(recipe "$ROOT/$1")"
  [ -n "$src" ] || { echo "(no recipe found in $1)"; return 1; }
  RDY_SPEC="$2" bash -c "$src"'; printf "%s" "$RDY_SLUG"'
}

for doc in plugins/spar/commands/ready.md adapters/codex/skills/spar-ready/SKILL.md; do
  # A real file: basename and extension still stripped.
  mkdir -p docs/superpowers/specs
  : > docs/superpowers/specs/2026-07-29-a-design.md
  eqchk "$doc — a spec path keeps its stem" "2026-07-29-a-design" \
    "$(slug "$doc" docs/superpowers/specs/2026-07-29-a-design.md)"

  # Inline prose that mentions a path: NOT basename-stripped. This is the
  # observed defect — the name used to start at the last path component.
  # The retained ASCII filter DELETES '/' rather than dashing it, so the words
  # run together. That is the existing filter's behaviour and this task does not
  # change it; the point of the check is that the name still starts at "fix".
  eqchk "$doc — inline prose is not basename-stripped" \
    "fix-docssuperpowersspecs-and-the-slug" \
    "$(slug "$doc" 'Fix docs/superpowers/specs and the slug')"

  # Dash runs collapse. Non-ASCII is deleted between the dashes that spaces
  # became, so without a squeeze this leaves a run of them.
  eqchk "$doc — dash runs collapse" "spar-report-reviewer" \
    "$(slug "$doc" 'spar-report 의 reviewer 폴백')"

  # Nothing usable at all still yields a usable branch name.
  eqchk "$doc — an all-non-ascii spec falls back" "run" \
    "$(slug "$doc" '한글로만 쓴 설명')"

  # An inline description whose tail is a word with a dot must not lose that word
  # to the extension strip, since it is not a file. The '.' is deleted by the
  # ASCII filter, not turned into a dash — so "sh" survives, joined.
  eqchk "$doc — a trailing dotted word survives inline" "fix-spar-reportsh" \
    "$(slug "$doc" 'Fix spar-report.sh')"
done

# The two documents must agree. A mirror that drifts is the failure this repo has
# had twice, and the checks above would both pass on two different recipes.
eqchk "both documents compute the same slug" \
  "$(slug plugins/spar/commands/ready.md 'Fix docs/a and b')" \
  "$(slug adapters/codex/skills/spar-ready/SKILL.md 'Fix docs/a and b')"

cd /; rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
