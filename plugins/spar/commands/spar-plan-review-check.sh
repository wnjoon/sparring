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
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE="${DIR}/spar-plan-review-prepare.sh"

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

# Naming the runner is only useful when there is one. `/spar:ready` prepares it
# and runs it in the same step, so any failure there — a mistyped plan path, the
# reviewer CLI absent from that session, the session ending early — leaves
# `plan_review: required` with no runner at all. Sending the author to a file
# that does not exist would be the unclearable gate again, reached by a likelier
# route than a malformed result.
need_runner() { # $1.. = the reason, then whatever next action actually exists
  if [ -f "$RUNNER" ]; then
    die "$@" "" \
      "       Run it with:  bash ${RUNNER}" \
      "       Then answer any findings in ${RESPONSE} and start again."
  fi
  die "$@" "" \
    "       No review has been prepared for this plan — ${RUNNER} does not exist." \
    "       Prepare one and run it:" \
    "         bash \"${PREPARE}\" \"${plan}\" \"${state}\" && bash ${RUNNER}" \
    "" \
    "       Or start without one: /spar:fight --no-plan-review, which records" \
    "       plan_review: overridden rather than skipping silently."
}

# Every "this result is unusable" path goes through here, so none of them can
# name the runner without first clearing the way for it. Quarantined rather than
# deleted: the file is evidence of what went wrong, and moving it is what lets
# the runner produce a fresh one at all.
quarantine() { # $1.. = why this result is unusable
  local n=1
  # -e is false for a dangling symlink, which would make an occupied suffix look
  # free and let mv destroy whatever is already parked there.
  while [ -e "${res}.invalid-${n}" ] || [ -L "${res}.invalid-${n}" ]; do n=$((n+1)); done
  if ! mv "$res" "${res}.invalid-${n}" 2>/dev/null; then
    # Saying "moved aside" when it was not is the unclearable gate again, one
    # layer down: the author reruns an idempotent runner that sees the bad file
    # still there and exits 0.
    die "$@" \
        "       It could not be moved aside to ${res}.invalid-${n}." \
        "" \
        "       Move or delete ${res} yourself, then run:  bash ${RUNNER}"
  fi
  need_runner "$@" \
    "       Moved aside as ${res}.invalid-${n} so the reviewer can be run again."
}

# The runner refuses to publish into a symlinked `reviews` or over a non-regular
# result path, so the checker must refuse to READ through either. Otherwise a
# symlink pointing at any file that begins `PLAN-REVIEW: CLEAN` clears a gate the
# runner could never have written past — the review would be whatever the link
# points at, not what a reviewer produced.
if [ -e reviews ] || [ -L reviews ]; then
  [ -d reviews ] && [ ! -L reviews ] || die \
    "Error: 'reviews' is not a real directory, so no plan review can be published there." \
    "" \
    "       Move or delete it, then run:  bash ${RUNNER}"
fi

# Quarantined, not merely refused: a dangling symlink or a directory sitting on
# the result path makes the runner exit with "invalid pre-existing artifact", so
# "run the runner" would be an instruction that cannot succeed until the path is
# cleared, and clearing it is this script's job.
if [ -L "$res" ] || { [ -e "$res" ] && [ ! -f "$res" ]; }; then
  quarantine "Error: ${res} is not a regular file — a symlink or directory occupies the path."
fi

[ -f "$res" ] || need_runner \
  "Error: this plan has not been reviewed yet — ${res} does not exist."

# \r stripped, matching every other first-line read in this codebase
# (stop-hook.sh:970, :1459, :1560, :1772). Without it a perfectly valid CRLF
# result fails the case below, and that failure path does not merely refuse — it
# quarantines the good review and asks for a fresh one, which a CLI that emits
# CRLF would produce again. The escape would be --no-plan-review, on a review
# that was correct all along.
marker="$(head -1 "$res" | tr -d '\r')"
case "$marker" in
  "PLAN-REVIEW: CLEAN"|"PLAN-REVIEW: FINDINGS") ;;
  *) quarantine "Error: ${res} does not start with a PLAN-REVIEW marker (found: ${marker})." ;;
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
# The EXACT PR[0-9]+ prefix, not "up to the first non-alphanumeric". A heading
# like `### PR1foo [BLOCKER]` used to yield the id `PR1foo`, which the response
# parser — which requires PR, digits, colon — can never match, so no disposition
# the author could write would clear it. An id nothing can answer is a permanent
# refusal, the same failure the quarantine exists to rule out.
ids="$(awk '/^### PR[0-9]+/ {
             id = $0; sub(/^### /, "", id)
             match(id, /^PR[0-9]+/); id = substr(id, RSTART, RLENGTH)
             if (!(id in seen)) { seen[id] = 1; print id }
           }' < <(tr -d '\r' < "$res"))"
[ -n "$ids" ] || quarantine \
  "Error: ${res} says FINDINGS but contains no '### PR<n>' finding."

# The verdict and a non-empty reason are part of the shape. Matching
# '^### PR<n>:' alone would let '### PR1: BANANA', or an ACCEPTED with nothing
# after the dash, clear a finding — a disposition that says nothing is exactly
# the ritual this requirement exists to avoid.
#
# The separator is the em dash the ready documents and the spec print, and only
# that. An earlier cut also accepted a hyphen and an en dash, meaning to be kind
# to a keyboard; the effect was a checker enforcing a shape no document states,
# which the next reader has to discover by reading the regex.
#
# awk, not sed: BSD sed's basic regex has no `\|`, so an alternation written for
# GNU sed matches nothing on macOS and every disposition reads as missing.
answered=""
[ -f "$RESPONSE" ] && answered="$(awk \
  '/^### PR[0-9]+: (ACCEPTED|REJECTED) —[[:space:]]+[^[:space:]]/ {
     id = $0; sub(/^### /, "", id); sub(/:.*$/, "", id); print id
   }' < <(tr -d '\r' < "$RESPONSE"))"

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
