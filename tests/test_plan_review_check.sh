#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/commands/spar-plan-review-check.sh — the
# precondition /spar:fight puts in front of plan activation.
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/plugins/spar/commands/spar-plan-review-check.sh"
chk(){ if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent(){ if printf '%s' "$3" | grep -qF -- "$2"; then echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }
eqchk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); cd "$TMP" || exit 1
cd "$(pwd -P)" || exit 1
git init -q; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p .claude reviews
ST=".claude/spar-plan.local.md"
PRID=20260728-120000-abc123
RES="reviews/spar-plan-${PRID}.md"
printf '# Plan\n\ndo it\n' > p.md
git hash-object p.md > .claude/spar-plan-review-hash

mkstate() { # $1=plan_review value (empty → omit the key entirely)
  { printf -- '---\nactive: true\nphase: planned\nmode: per-task\nreviewer: codex\n'
    [ -n "$1" ] && printf 'plan_review: %s\n' "$1"
    printf 'plan_review_id: %s\nplan_path: p.md\ntasks: 1\ncurrent: 1\n---\n1\tpending\tTask 1: Alpha\n' "$PRID"
  } > "$ST"
}
mkresult() { printf 'PLAN-REVIEW: %s\n%s' "$1" "$2" > "$RES"; }
# Built with printf on one line ON PURPOSE. A heredoc or a quoted multi-line
# string would put `### PR1` at the start of a line in THIS FILE, and the
# extractor that hands one task to an implementer splits on exactly that.
F2="$(printf '### PR1 [BLOCKER] first\n- file: a.py:1\n- problem: p\n- suggestion: s\n\n### PR2 [SHOULD-FIX] second\n- file: b.py:2\n- problem: q\n- suggestion: t\n')"

eqchk "the check script is executable" "yes" "$([ -x "$C" ] && echo yes || echo no)"

# ── nothing to enforce ──────────────────────────────────────────────────────
mkstate skipped
eqchk "skipped proceeds" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"
# A plan prepared before this phase carries no plan_review line at all. Absent
# means "this plan was never offered a review", not "a review is outstanding".
mkstate ""
eqchk "a state without the field proceeds" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

# ── the result must exist and be a plan review ──────────────────────────────
mkstate required; rm -f "$RES"
printf '#!/bin/sh\nexit 0\n' > .claude/spar-run-plan-review.sh
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "missing result refuses" "1" "$RC"
chk "and names the runner" "spar-run-plan-review.sh" "$OUT"

# Naming the runner is only useful when there is one. /spar:ready prepares and
# runs it in the same step, so a prepare that failed — a mistyped plan path, the
# CLI absent from that session — leaves `required` with no runner at all. Sending
# the author to a file that does not exist is the unclearable gate again.
rm -f .claude/spar-run-plan-review.sh
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "an unprepared review also refuses" "1" "$RC"
chk "and names the preparation step" "spar-plan-review-prepare.sh" "$OUT"
chk "with the plan and state it needs" "\"p.md\" \"$ST\"" "$OUT"
chk "and names the recorded escape" "--no-plan-review" "$OUT"
chk_absent "and does not tell you to run a file that is not there" "Run it with:" "$OUT"
printf '#!/bin/sh\nexit 0\n' > .claude/spar-run-plan-review.sh

mkstate required; printf 'STATUS: CONVERGED\n' > "$RES"
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "a foreign marker refuses" "1" "$RC"
# The loop's own marker must not be mistaken for this pass's. Convergence is the
# reviewer's word inside a task loop and nothing outside one may claim it.
chk "and names the runner too" "spar-run-plan-review.sh" "$OUT"
# Quoting what it found, so the refusal is not resting on a coincidence: without
# the marker check the file falls into the FINDINGS branch and is refused anyway,
# for a reason that tells the author nothing about what is actually wrong.
chk "and says what it found instead" "found: STATUS: CONVERGED" "$OUT"

# ── the result path must be a real file in a real directory ─────────────────
# The runner refuses to publish into a symlinked reviews/ or over a non-regular
# result path. A checker that read through either would clear a gate the runner
# could never have written past — the "review" would be whatever the link points
# at. And a dangling symlink or directory left in place makes the runner exit
# with "invalid pre-existing artifact", so the refusal has to clear the path too.
mkstate required
printf 'PLAN-REVIEW: CLEAN\n' > elsewhere.md
rm -f "$RES"; ln -s "$PWD/elsewhere.md" "$RES"
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "a symlinked CLEAN result does not clear the gate" "1" "$RC"
eqchk "and the link is moved off the result path" "absent" \
  "$([ -e "$RES" ] || [ -L "$RES" ] && echo present || echo absent)"
chk "and its target is left alone" "PLAN-REVIEW: CLEAN" "$(cat elsewhere.md)"
rm -f "${RES}".invalid-*

rm -f "$RES"; ln -s /nonexistent-target "$RES"
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "a dangling symlink on the result path refuses" "1" "$RC"
eqchk "and is cleared so the runner can publish" "absent" \
  "$([ -e "$RES" ] || [ -L "$RES" ] && echo present || echo absent)"
rm -f "${RES}".invalid-*

rm -rf "$RES"; mkdir -p "$RES"
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "a directory on the result path refuses" "1" "$RC"
eqchk "and is cleared too" "absent" \
  "$([ -e "$RES" ] || [ -L "$RES" ] && echo present || echo absent)"
rm -rf "${RES}".invalid-*

# reviews/ itself. Not quarantined — moving the whole directory aside is not this
# script's call, so it says what to do instead.
mkresult CLEAN ''
mv reviews reviews.real; ln -s reviews.real reviews
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
rm -f reviews; mv reviews.real reviews
eqchk "a symlinked reviews directory refuses" "1" "$RC"
chk "and says what to do about it" "Move or delete it" "$OUT"

# ── clean ───────────────────────────────────────────────────────────────────
mkstate required; mkresult CLEAN ''
eqchk "CLEAN proceeds" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

# A CRLF result is a valid result. Getting this wrong is not a plain refusal:
# the marker mismatch quarantines a correct review and asks for a fresh one,
# which a CLI that emits CRLF would produce again — clearable only by the
# override, on a review that was right all along.
mkstate required
printf 'PLAN-REVIEW: CLEAN\r\n' > "$RES"
eqchk "a CRLF result proceeds" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"
eqchk "and is not quarantined" "present" "$([ -f "$RES" ] && echo present || echo absent)"
# …and its findings and dispositions parse through the same normalisation.
printf 'PLAN-REVIEW: FINDINGS\r\n### PR1 [BLOCKER] x\r\n- file: a.py:1\r\n' > "$RES"
printf -- '### PR1: ACCEPTED — fixed\r\n' > .claude/spar-plan-review-response.md
eqchk "a CRLF finding is cleared by a CRLF disposition" "0" \
  "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"
rm -f .claude/spar-plan-review-response.md "${RES}".invalid-*

# ── findings need a disposition each ────────────────────────────────────────
mkstate required; mkresult FINDINGS "$F2"; rm -f .claude/spar-plan-review-response.md
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "findings without a response refuse" "1" "$RC"
chk "and name the response path" "spar-plan-review-response.md" "$OUT"
chk "and the first id" "PR1" "$OUT"
chk "and the second" "PR2" "$OUT"

printf -- '### PR1: ACCEPTED — fixed the plan\n' > .claude/spar-plan-review-response.md
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "a partial response still refuses" "1" "$RC"
chk "and names the outstanding id" "PR2" "$OUT"
chk_absent "and not the answered one" "PR1" "$OUT"

printf -- '### PR1: ACCEPTED — fixed\n### PR2: REJECTED — the cited line is a comment\n' \
  > .claude/spar-plan-review-response.md
eqchk "a grounded rejection clears a finding" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

# The verdict and the reason are part of the shape. Matching `^### PR<n>:` alone
# would let a disposition that says nothing clear a finding — the ritual this
# requirement exists to avoid.
printf -- '### PR1: ACCEPTED — fixed\n### PR2: BANANA\n' > .claude/spar-plan-review-response.md
eqchk "a malformed verdict does not clear" "1" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"
printf -- '### PR1: ACCEPTED — fixed\n### PR2: REJECTED — \n' > .claude/spar-plan-review-response.md
eqchk "an empty reason does not clear" "1" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"
# The separator is the em dash every document prints, and only that. Accepting a
# hyphen "to be kind" would mean enforcing a shape no document states.
printf -- '### PR1: ACCEPTED — fixed\n### PR2: REJECTED - a hyphen\n' > .claude/spar-plan-review-response.md
eqchk "a hyphen separator does not clear" "1" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"
printf -- '### PR1: ACCEPTED — fixed\n### PR2: REJECTED – an en dash\n' > .claude/spar-plan-review-response.md
eqchk "an en dash does not clear" "1" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"
printf -- '### PR1: ACCEPTED — fixed\n### PR2: REJECTED—no space\n' > .claude/spar-plan-review-response.md
eqchk "a separator with no spaces does not clear" "1" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"
printf -- '### PR1: ACCEPTED — fixed\n### PR2: ACCEPTED-glued\n' > .claude/spar-plan-review-response.md
eqchk "a verdict glued to its reason does not clear" "1" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

# ── a heading with junk after the digits is still answerable ────────────────
# `### PR1foo` once yielded the id `PR1foo`, which no response section can match
# — the response parser requires PR, digits, colon. An id nothing can answer is a
# permanent refusal, the same failure the quarantine rules out.
mkstate required
mkresult FINDINGS "$(printf '### PR1foo [BLOCKER] junk after the digits\n- file: a.py:1\n')"
rm -f .claude/spar-plan-review-response.md
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "a junk-suffixed heading still refuses" "1" "$RC"
chk "and asks for the exact id" "PR1" "$OUT"
chk_absent "not the junk-suffixed one" "PR1foo" "$OUT"
printf -- '### PR1: ACCEPTED — answered\n' > .claude/spar-plan-review-response.md
eqchk "and that id can actually be answered" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

# ── a malformed result is quarantined, not left to block forever ────────────
# The generated runner exits 0 the moment a regular result exists, so "re-run the
# runner" against a bad file is telling the author to run something that does
# nothing. Only the checker can clear the way.
# Start from a clean slate: the foreign-marker case above already quarantined
# one file, and against that leftover a `.invalid-1` assertion passes without
# this section having created anything. The two bodies differ so each assertion
# names which invocation produced the file it is looking at.
rm -f "${RES}".invalid-*
mkstate required; printf 'STATUS: CONVERGED\nfirst\n' > "$RES"
bash "$C" p.md "$ST" >/dev/null 2>&1
eqchk "a bad result is moved aside" "absent" "$([ -f "$RES" ] && echo present || echo absent)"
chk "and kept under .invalid-1" "first" "$(cat "${RES}.invalid-1" 2>/dev/null)"
printf 'STATUS: CONVERGED\nsecond\n' > "$RES"
bash "$C" p.md "$ST" >/dev/null 2>&1
chk "a second bad result lands on .invalid-2" "second" "$(cat "${RES}.invalid-2" 2>/dev/null)"
chk "and does not overwrite the first" "first" "$(cat "${RES}.invalid-1" 2>/dev/null)"
rm -f "${RES}".invalid-*

# A FINDINGS result with no parseable finding is unusable for the same reason and
# must clear the way for the same next action. Left in place, "rerun the runner"
# is again an instruction that does nothing.
mkstate required; mkresult FINDINGS 'prose with no finding heading at all'
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "FINDINGS with no parseable id refuses" "1" "$RC"
chk "and names the runner" "spar-run-plan-review.sh" "$OUT"
eqchk "and clears the path for it" "absent" "$([ -f "$RES" ] && echo present || echo absent)"
eqchk "keeping the unusable result" "present" \
  "$([ -f "${RES}.invalid-1" ] && echo present || echo absent)"
rm -f "${RES}".invalid-*

# A dangling symlink is not -e, so a suffix holding one looks free. Picking it
# would destroy a previously quarantined artifact instead of parking beside it.
mkstate required; printf 'STATUS: CONVERGED\n' > "$RES"
ln -s /nonexistent-target "${RES}.invalid-1"
bash "$C" p.md "$ST" >/dev/null 2>&1
eqchk "a dangling symlink counts as taken" "yes" \
  "$([ -L "${RES}.invalid-1" ] && echo yes || echo no)"
eqchk "so the quarantine parks beside it" "present" \
  "$([ -f "${RES}.invalid-2" ] && echo present || echo absent)"
rm -f "${RES}".invalid-*

# A quarantine that cannot happen must say so. Claiming "moved aside" when the
# rename failed is the unclearable gate one layer down: the author reruns an
# idempotent runner that still sees the bad file and exits 0.
mkstate required; printf 'STATUS: CONVERGED\n' > "$RES"
chmod a-w reviews
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
chmod u+w reviews
eqchk "an unmovable bad result still refuses" "1" "$RC"
chk "and says the move failed" "could not be moved aside" "$OUT"
chk "and names what to do by hand" "Move or delete" "$OUT"
chk_absent "and does not claim it was moved" "Moved aside as" "$OUT"
rm -f "$RES" "${RES}".invalid-*

# ── a plan edited after the review is reported, not refused ─────────────────
# Streams kept apart on purpose: the note is a stdout contract, and merging with
# 2>&1 would stay green if it moved to stderr, where a caller that only shows
# errors on failure would never print it on this exit-0 path.
mkstate required; mkresult CLEAN ''
printf 'deadbeef\n' > .claude/spar-plan-review-hash
ERRF="$(mktemp)"
OUT="$(bash "$C" p.md "$ST" 2>"$ERRF")"; RC=$?
ERR="$(cat "$ERRF")"
eqchk "a changed plan still proceeds" "0" "$RC"
chk "and the change is reported on stdout" "changed since it was reviewed" "$OUT"
chk_absent "and not on stderr" "changed since it was reviewed" "$ERR"
git hash-object p.md > .claude/spar-plan-review-hash
OUT="$(bash "$C" p.md "$ST" 2>"$ERRF")"
chk_absent "an unchanged plan is not reported" "changed since it was reviewed" "$OUT"
rm -f "$ERRF"

# ── the checker never writes state ──────────────────────────────────────────
# It is a precondition, not a step: /spar:fight owns every transition, and a
# checker that edited state would make a refused run indistinguishable from one
# that never started.
BEFORE="$(cat "$ST")"
bash "$C" p.md "$ST" >/dev/null 2>&1
eqchk "the checker leaves the state alone" "$BEFORE" "$(cat "$ST")"

cd /; rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
