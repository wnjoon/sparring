#!/usr/bin/env bash
# The precondition /spar:fight puts in front of plan activation.
# Usage: spar-plan-review-check.sh <plan-path> <state-file>
#
# Exit 0 when activation may proceed. Exit 1, with a message on stderr naming the
# exact next action, when it may not. A precondition that says only "not allowed"
# is a lock without a key even when a key exists.
#
# It never modifies the state file — /spar:fight owns every transition. It does
# move a malformed result aside, because nothing else can: the generated runner
# exits 0 the moment a regular result exists, so telling the author to re-run it
# over a bad file is telling them to run something that will do nothing.
set -uo pipefail

plan="${1-}"
state="${2-.claude/spar-plan.local.md}"
RESPONSE=".claude/spar-plan-review-response.md"
HASHFILE=".claude/spar-plan-review-hash"
RUNNER=".claude/spar-run-plan-review.sh"

field() { sed -n "s/^${1}: *//p" "$state" 2>/dev/null | head -1; }
die() { printf '%s\n' "$@" >&2; exit 1; }

# Absent means this plan was never offered a review — a plan prepared before this
# phase existed, not a review left outstanding. `skipped` and `overridden` are
# both recorded decisions. Only `required` gates.
[ "$(field plan_review)" = required ] || exit 0

prid="$(field plan_review_id)"
printf '%s' "$prid" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' || die \
  "Error: the plan state says a review is required but carries no usable plan_review_id." \
  "       Clear this plan with /spar:cancel and run /spar:ready again."
res="reviews/spar-plan-${prid}.md"

need_runner() { # $1.. = the reason, then the standing instruction
  die "$@" "" \
    "       Run it with:  bash ${RUNNER}" \
    "       Then answer any findings in ${RESPONSE} and start again."
}

[ -f "$res" ] || need_runner \
  "Error: this plan has not been reviewed yet — ${res} does not exist."

marker="$(head -1 "$res")"
case "$marker" in
  "PLAN-REVIEW: CLEAN"|"PLAN-REVIEW: FINDINGS") ;;
  *)
    # Quarantined rather than deleted: it is evidence of what went wrong, and
    # moving it is what lets the runner produce a fresh one at all.
    n=1
    while [ -e "${res}.invalid-${n}" ]; do n=$((n+1)); done
    mv "$res" "${res}.invalid-${n}" 2>/dev/null
    need_runner \
      "Error: ${res} does not start with a PLAN-REVIEW marker (found: ${marker})." \
      "       Moved aside as ${res}.invalid-${n} so the reviewer can be run again."
    ;;
esac

report_hash() {
  local recorded current
  recorded="$(head -1 "$HASHFILE" 2>/dev/null)"
  current="$(git hash-object "$plan" 2>/dev/null)"
  [ -n "$recorded" ] && [ -n "$current" ] && [ "$recorded" != "$current" ] || return 0
  # Reported, not re-reviewed. The author edited the plan after the review, which
  # is usually because the review asked them to; re-reviewing on every edit would
  # make an accepted finding cost a second full pass.
  printf '%s\n' \
    "Note: ${plan} has changed since it was reviewed. The review below describes" \
    "      an earlier revision of it."
}

if [ "$marker" = "PLAN-REVIEW: CLEAN" ]; then
  report_hash
  exit 0
fi

# One pass, POSIX awk only — gawk's three-argument match() is a syntax error on
# the awk macOS ships. Deduplicated, so a result that repeats an id does not ask
# for the same disposition twice.
ids="$(awk '/^### PR[0-9]+/ {
             id = $0; sub(/^### /, "", id); sub(/[^0-9A-Za-z].*$/, "", id)
             if (!(id in seen)) { seen[id] = 1; print id }
           }' "$res")"
[ -n "$ids" ] || need_runner \
  "Error: ${res} says FINDINGS but contains no '### PR<n>' finding."

# The verdict and a non-empty reason are part of the shape. Matching
# '^### PR<n>:' alone would let '### PR1: BANANA', or an ACCEPTED with nothing
# after the dash, clear a finding — a disposition that says nothing is exactly
# the ritual this requirement exists to avoid. The separator is permissive (em
# dash, en dash or hyphen); the reason is not.
# awk, not sed: BSD sed's basic regex has no `\|`, so an alternation written for
# GNU sed matches nothing on macOS and every disposition reads as missing. The
# separators are spelled out rather than bracketed for the same portability
# reason — a bracket expression over multibyte dashes matches single bytes.
answered=""
[ -f "$RESPONSE" ] && answered="$(awk \
  '/^### PR[0-9]+: (ACCEPTED|REJECTED) (—|–|-)[[:space:]]*[^[:space:]]/ {
     id = $0; sub(/^### /, "", id); sub(/:.*$/, "", id); print id
   }' "$RESPONSE")"

outstanding=""
for id in $ids; do
  printf '%s\n' $answered | grep -qx "$id" || outstanding="$outstanding $id"
done

if [ -n "$outstanding" ]; then
  die "Error: the plan review raised findings that have no disposition:${outstanding}" \
      "" \
      "       Answer each one in ${RESPONSE}, one section per finding:" \
      "         ### PR<n>: ACCEPTED — <what you changed in the plan>" \
      "         ### PR<n>: REJECTED — <reason grounded in the plan, spec or code>" \
      "" \
      "       A grounded rejection clears a finding exactly as an acceptance does." \
      "       Read the findings in ${res}."
fi

report_hash
exit 0
