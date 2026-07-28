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
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "missing result refuses" "1" "$RC"
chk "and names the runner" "spar-run-plan-review.sh" "$OUT"

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

# ── clean ───────────────────────────────────────────────────────────────────
mkstate required; mkresult CLEAN ''
eqchk "CLEAN proceeds" "0" "$(bash "$C" p.md "$ST" >/dev/null 2>&1; echo $?)"

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

# ── a malformed result is quarantined, not left to block forever ────────────
# The generated runner exits 0 the moment a regular result exists, so "re-run the
# runner" against a bad file is telling the author to run something that does
# nothing. Only the checker can clear the way.
mkstate required; printf 'STATUS: CONVERGED\n' > "$RES"
bash "$C" p.md "$ST" >/dev/null 2>&1
eqchk "a bad result is moved aside" "absent" "$([ -f "$RES" ] && echo present || echo absent)"
eqchk "and kept under .invalid-1" "present" \
  "$([ -f "${RES}.invalid-1" ] && echo present || echo absent)"
printf 'STATUS: CONVERGED\n' > "$RES"
bash "$C" p.md "$ST" >/dev/null 2>&1
eqchk "a second bad result does not overwrite the first" "present" \
  "$([ -f "${RES}.invalid-2" ] && echo present || echo absent)"
rm -f "${RES}".invalid-*

# ── a plan edited after the review is reported, not refused ─────────────────
mkstate required; mkresult CLEAN ''
printf 'deadbeef\n' > .claude/spar-plan-review-hash
OUT="$(bash "$C" p.md "$ST" 2>&1)"; RC=$?
eqchk "a changed plan still proceeds" "0" "$RC"
chk "and the change is reported" "changed since it was reviewed" "$OUT"
git hash-object p.md > .claude/spar-plan-review-hash
chk_absent "an unchanged plan is not reported" "changed since it was reviewed" \
  "$(bash "$C" p.md "$ST" 2>&1)"

# ── the checker never writes state ──────────────────────────────────────────
# It is a precondition, not a step: /spar:fight owns every transition, and a
# checker that edited state would make a refused run indistinguishable from one
# that never started.
BEFORE="$(cat "$ST")"
bash "$C" p.md "$ST" >/dev/null 2>&1
eqchk "the checker leaves the state alone" "$BEFORE" "$(cat "$ST")"

cd /; rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
