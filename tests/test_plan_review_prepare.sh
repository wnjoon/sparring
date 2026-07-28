#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/commands/spar-plan-review-prepare.sh.
# No reviewer CLI is required: every dispatch goes through a stub on PATH.
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/plugins/spar/commands/spar-plan-review-prepare.sh"
chk(){ if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent(){ if printf '%s' "$3" | grep -qF -- "$2"; then echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }
eqchk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); cd "$TMP" || exit 1
# Physical cwd: on macOS mktemp hands back /var/…, where /var is a symlink, and
# the runner's own symlink checks are easier to reason about without one.
cd "$(pwd -P)" || exit 1
git init -q; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p .claude reviews
ST=".claude/spar-plan.local.md"
PRID=20260728-120000-abc123
RES="reviews/spar-plan-${PRID}.md"
STUBS=$(mktemp -d)
PATH="$STUBS:$PATH"

mkstate() { # $1=plan_review value  [$2=reviewer]  [$3=plan path]
  printf -- '---\nactive: true\nphase: planned\nmode: per-task\nreviewer: %s\nplan_review: %s\nplan_review_id: %s\nplan_path: %s\ntasks: 1\ncurrent: 1\n---\n1\tpending\tTask 1: Alpha\n' \
    "${2:-codex}" "$1" "$PRID" "${3:-p.md}" > "$ST"
}
printf '# Plan\n\n### Task 1: Alpha\n\ndo it\n' > p.md
printf 'the spec text\n' > .claude/spar-plan-spec.txt

# ── the scripts ship executable ─────────────────────────────────────────────
# A missing mode bit fails only at the moment someone needs it, and the wiring
# in /spar:fight invokes these directly.
eqchk "the prepare script is executable" "yes" "$([ -x "$P" ] && echo yes || echo no)"

# ── preparation writes a prompt and a runner ────────────────────────────────
printf '#!/bin/sh\nexit 0\n' > "$STUBS/codex"; chmod +x "$STUBS/codex"
mkstate required
bash "$P" p.md "$ST"
chk "prompt written" "PLAN-REVIEW" "$(cat .claude/spar-plan-review-prompt.txt 2>/dev/null)"
chk "prompt carries the plan" "Task 1: Alpha" "$(cat .claude/spar-plan-review-prompt.txt 2>/dev/null)"
chk "prompt carries the captured spec" "the spec text" "$(cat .claude/spar-plan-review-prompt.txt 2>/dev/null)"
chk "prompt names the invariants file question 6 needs" "policy.md" \
  "$(cat .claude/spar-plan-review-prompt.txt 2>/dev/null)"
chk_absent "no placeholder survives substitution" "{{" \
  "$(cat .claude/spar-plan-review-prompt.txt 2>/dev/null)"
chk "runner is read-only" "sandbox read-only" "$(cat .claude/spar-run-plan-review.sh 2>/dev/null)"

# ── the runner is EXECUTED, not grepped ─────────────────────────────────────
# A generated script carrying "sandbox read-only" or "mktemp" only in a comment
# satisfies a substring check and does nothing; this suite has been bitten by
# exactly that shape before.
runner_with() { # $1=stub body → run the generated runner with that CLI on PATH
  printf '%s\n' '#!/bin/sh' "$1" > "$STUBS/codex"; chmod +x "$STUBS/codex"
  ( PATH="$STUBS:$PATH"; bash .claude/spar-run-plan-review.sh >/dev/null 2>&1 )
}
WRITE_OK='prev=""; for a in "$@"; do case "$prev" in --output-last-message) printf "PLAN-REVIEW: CLEAN\n" > "$a";; esac; prev="$a"; done'

rm -f "$RES"
runner_with "$WRITE_OK"
chk "the runner publishes a result" "PLAN-REVIEW: CLEAN" "$(cat "$RES" 2>/dev/null)"
eqchk "and records the plan hash" "$(git hash-object p.md)" \
  "$(cat .claude/spar-plan-review-hash 2>/dev/null)"

# A CLI that fails must publish nothing, even if it wrote bytes first.
rm -f "$RES"
runner_with "$WRITE_OK
exit 1"
eqchk "a failing CLI publishes nothing" "absent" "$([ -f "$RES" ] && echo present || echo absent)"

# An existing regular result is final — that is what makes the runner idempotent,
# and it is why the CHECKER, not the runner, must quarantine a malformed one.
printf 'PLAN-REVIEW: CLEAN\n' > "$RES"
runner_with 'exit 1'
chk "an existing result is left alone" "PLAN-REVIEW: CLEAN" "$(cat "$RES")"

# A symlinked output path is refused outright rather than followed.
rm -f "$RES"; ln -s /dev/null "$RES"
runner_with "$WRITE_OK"
eqchk "a symlinked result path is refused" "yes" "$([ -L "$RES" ] && echo yes || echo no)"
rm -f "$RES"

# ── the claude family ───────────────────────────────────────────────────────
printf '#!/bin/sh\nprintf "PLAN-REVIEW: CLEAN\\n"\n' > "$STUBS/claude"; chmod +x "$STUBS/claude"
mkstate required claude
rm -f .claude/spar-run-plan-review.sh
bash "$P" p.md "$ST"
chk "the claude runner is isolated" "safe-mode" "$(cat .claude/spar-run-plan-review.sh 2>/dev/null)"
chk "and reads only" "Read Grep Glob" "$(cat .claude/spar-run-plan-review.sh 2>/dev/null)"
rm -f "$RES"
( PATH="$STUBS:$PATH"; bash .claude/spar-run-plan-review.sh >/dev/null 2>&1 )
chk "the claude family publishes a result too" "PLAN-REVIEW: CLEAN" "$(cat "$RES" 2>/dev/null)"

# ── a plan path with a space and a $ is embedded safely ─────────────────────
# The path reaches the generated runner from the state file, so it is not a
# fixed string; unquoted it would word-split and expand.
printf '#!/bin/sh\nexit 0\n' > "$STUBS/codex"; chmod +x "$STUBS/codex"
mkdir -p 'odd dir'
printf '# Plan\n\n### Task 1: Alpha\n\ndo it\n' > 'odd dir/p $x.md'
mkstate required codex 'odd dir/p $x.md'
rm -f .claude/spar-run-plan-review.sh .claude/spar-plan-review-hash "$RES"
bash "$P" 'odd dir/p $x.md' "$ST"
runner_with "$WRITE_OK"
chk "an awkward plan path still publishes" "PLAN-REVIEW: CLEAN" "$(cat "$RES" 2>/dev/null)"
eqchk "and hashes the right file" "$(git hash-object 'odd dir/p $x.md')" \
  "$(cat .claude/spar-plan-review-hash 2>/dev/null)"

# ── an absent reviewer CLI prepares nothing either ──────────────────────────
# A PATH without the stub directory: both real CLIs live in ~/.local/bin, so
# /usr/bin:/bin has git, sed and mktemp but no reviewer. Preparing a runner that
# cannot dispatch would leave /spar:ready to fail at the point of running it.
rm -f .claude/spar-run-plan-review.sh .claude/spar-plan-review-prompt.txt
mkstate required
( PATH=/usr/bin:/bin; bash "$P" p.md "$ST" ); RC=$?
eqchk "absent CLI → non-zero" "1" "$RC"
eqchk "absent CLI → no runner" "absent" \
  "$([ -f .claude/spar-run-plan-review.sh ] && echo present || echo absent)"
eqchk "absent CLI → no prompt either" "absent" \
  "$([ -f .claude/spar-plan-review-prompt.txt ] && echo present || echo absent)"

# ── skipped means prepare nothing at all ────────────────────────────────────
rm -f .claude/spar-run-plan-review.sh .claude/spar-plan-review-prompt.txt
mkstate skipped
bash "$P" p.md "$ST"; RC=$?
eqchk "skipped → non-zero" "1" "$RC"
eqchk "skipped → no runner" "absent" "$([ -f .claude/spar-run-plan-review.sh ] && echo present || echo absent)"
eqchk "skipped → no prompt either" "absent" "$([ -f .claude/spar-plan-review-prompt.txt ] && echo present || echo absent)"

cd /; rm -rf "$TMP" "$STUBS"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
