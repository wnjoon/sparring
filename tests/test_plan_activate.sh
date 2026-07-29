#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/commands/spar-plan-activate.sh — the shared
# activation sequence both fight entry points invoke.
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/plugins/spar/commands/spar-plan-activate.sh"
chk(){ if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent(){ if printf '%s' "$3" | grep -qF -- "$2"; then echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }
eqchk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); cd "$TMP" || exit 1; cd "$(pwd -P)" || exit 1
git init -q; git config user.email t@t; git config user.name t
mkdir -p .claude reviews
ST=".claude/spar-plan.local.md"
PRID=20260729-120000-abc123
# spar-fight-launch.sh asks the reviewer CLI for the build a run starts with. A
# stub keeps that off the network; reviewer: codex below matches it.
STUBS=$(mktemp -d); printf '#!/bin/sh\necho 1.0.0\n' > "$STUBS/codex"; chmod +x "$STUBS/codex"
PATH="$STUBS:$PATH"

mkplan() { printf '# Plan\n\n### Task 1: Alpha\n\nfirst\n\n### Task 2: Beta\n\nsecond\n' > p.md; }
mkstate() { # $1=phase  $2=mode  $3=extra frontmatter lines (may be empty)
  { printf -- '---\nactive: true\nphase: %s\nmode: %s\nreviewer: codex\nunattended: false\n' "$1" "$2"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf 'plan_path: p.md\nbranch: b\ntasks: 2\ncurrent: 1\ncurrent_review_id:\n---\n1\tpending\tTask 1: Alpha\n2\tpending\tTask 2: Beta\n'
  } > "$ST"
}
reset() { rm -f .claude/spar.local.md .claude/spar-fight-task.txt reviews/spar-plan-*.md; mkplan; }
# Every refusal must leave the state byte-for-byte as it was. Substring checks
# like "phase: planned" cannot see a stamp or a plan_review line written before
# the refusal, which is exactly the ordering defect this refactor exists to make
# impossible in one place instead of two.
#
# Called as a plain command, never as "$(refuses …)": a command substitution runs
# it in a subshell, where its PASS/FAIL increments are discarded and its
# diagnostics are captured instead of printed — a check that cannot be counted
# and cannot be read. The helper's own output goes to $REFUSE_OUT for the caller.
REFUSE_OUT=""
refuses() { # $1=label  $2..=args to the helper
  local label="$1"; shift
  local before; before="$(cat "$ST")"
  local rc
  REFUSE_OUT="$(bash "$A" "$@" 2>&1)"; rc=$?
  eqchk "$label — refuses" "1" "$rc"
  eqchk "$label — leaves the state untouched" "$before" "$(cat "$ST")"
  eqchk "$label — starts no loop" "absent" \
    "$([ -f .claude/spar.local.md ] && echo present || echo absent)"
}

eqchk "the helper is executable" "yes" "$([ -x "$A" ] && echo yes || echo no)"

# ── preconditions, each refusing before anything is written ─────────────────
reset; mkstate running per-task ''
refuses "a running plan" "$ST" true claude; OUT="$REFUSE_OUT"
chk "and says so" "already being fought" "$OUT"
chk "in Claude's words" "/spar:cancel" "$OUT"

reset; mkstate running per-task ''
refuses "a running plan, codex seat" "$ST" true codex sess1; OUT="$REFUSE_OUT"
chk "in Codex's words for that seat" "spar-cancel" "$OUT"
chk_absent "and not Claude's" "/spar:cancel" "$OUT"

reset; mkstate done per-task ''
refuses "any other phase" "$ST" true claude

reset; mkstate planned per-task ''; printf 'x\n' > .claude/spar.local.md
BEFORE="$(cat "$ST")"
# Streams kept apart: this one refusal went to STDOUT in fight.md's plan branch
# while every other one went to stderr, and 2>&1 cannot see the difference. It is
# an odd place for it, which is exactly why a refactor would quietly tidy it.
ERRF="$(mktemp)"
OUT="$(bash "$A" "$ST" true claude 2>"$ERRF")"; RC=$?
ERR="$(cat "$ERRF")"; rm -f "$ERRF"
eqchk "an active loop blocks activation" "1" "$RC"
chk "and says a loop is active, on stdout" "already active" "$OUT"
chk_absent "and not on stderr" "already active" "$ERR"
eqchk "leaving the state untouched" "$BEFORE" "$(cat "$ST")"
rm -f .claude/spar.local.md

reset; mkstate planned per-task ''; rm -f p.md
refuses "a missing plan file" "$ST" true claude; OUT="$REFUSE_OUT"
chk "naming the path" "p.md" "$OUT"

reset; mkstate planned per-task ''
refuses "an unknown seat" "$ST" true banana

# The session id is required for the codex seat: without it the run activates
# with an empty owner_session and the ownership the seat exists to record is
# gone. Rejected before any state write, and on the same character class
# spar-fight-launch.sh:22-25 rejects — a newline there injects a frontmatter field.
reset; mkstate planned per-task ''
refuses "a codex seat with no session" "$ST" true codex
reset; mkstate planned per-task ''
refuses "a codex session with a newline" "$ST" true codex "$(printf 'a\nb: c')"
reset; mkstate planned per-task ''
refuses "a codex session with a space" "$ST" true codex "bad id"

# ── the plan-review gate ────────────────────────────────────────────────────
# required with no result: refused, and NOTHING may have been written — not the
# phase, not a stamp. A refusal that already flipped the phase leaves cancel as
# the only way out; a refusal that stamped first is the ordering defect this
# refactor exists to make impossible in one place instead of two.
reset; mkstate planned per-task "$(printf 'plan_review: required\nplan_review_id: %s' "$PRID")"
refuses "an unreviewed plan" "$ST" true claude
chk "and the refusal is in Claude's words" "/spar:fight --no-plan-review" "$REFUSE_OUT"
reset; mkstate planned per-task "$(printf 'plan_review: required\nplan_review_id: %s' "$PRID")"
refuses "an unreviewed plan, codex seat" "$ST" true codex sess-1
# The seat argument exists so a refusal names a command the reader can actually
# run. The gate's message comes from a delegated script, which is exactly where
# that guarantee is easiest to lose.
chk "and the gate's refusal is in Codex's words" "spar-fight --no-plan-review" "$REFUSE_OUT"
chk_absent "with no slash-prefixed variant" "/spar:fight" "$REFUSE_OUT"
chk_absent "and no slash-prefixed cancel" "/spar:cancel" "$REFUSE_OUT"

# a CLEAN review clears it
reset; mkstate planned per-task "$(printf 'plan_review: required\nplan_review_id: %s' "$PRID")"
printf 'PLAN-REVIEW: CLEAN\n' > "reviews/spar-plan-${PRID}.md"
eqchk "a reviewed plan activates" "0" "$(bash "$A" "$ST" true claude >/dev/null 2>&1; echo $?)"
chk "and the phase moved" "phase: running" "$(cat "$ST")"

# the override, on a state with NO plan_review key — the case plan_set_field gets wrong
reset; mkstate planned per-task ''
OUT="$(bash "$A" "$ST" false claude 2>&1)"; RC=$?
eqchk "the override activates" "0" "$RC"
chk "and is recorded on a state that lacked the field" "plan_review: overridden" "$(cat "$ST")"
chk "and it says the review was skipped" "--no-plan-review" "$OUT"
chk "and the task table survived the append" "Task 2: Beta" "$(tail -1 "$ST")"

# ── a write that fails stops the sequence ───────────────────────────────────
# The entry points run under `set -e` and this used to run under theirs; in a
# child shell it does not, so every write is checked by hand. Forced by making
# .claude unwritable — plan_set_field/plan_put_field write a sibling temp file
# there before renaming, so the write fails while every read still works.
reset; mkstate planned per-task ''
chmod a-w .claude
OUT="$(bash "$A" "$ST" false claude 2>&1)"; RC=$?
chmod u+w .claude
eqchk "a failed override write refuses" "1" "$RC"
# Where it stopped, not just that it stopped. Unchecked, the sequence runs on and
# fails again at the task-file redirect, whose diagnostic names that path — with
# .claude unwritable every later step fails too, so which failure surfaces is the
# only observable difference. No message of our own to assert: the helper adds
# none, so that a failed activation still says what the shell said it said.
chk_absent "and not at the task file" "spar-fight-task.txt" "$OUT"
chk "and the phase never moved" "phase: planned" "$(cat "$ST")"
eqchk "and no loop was launched" "absent" \
  "$([ -f .claude/spar.local.md ] && echo present || echo absent)"

# The same for the phase write, reached only when the gate is cleared rather than
# overridden — a different branch, and the one that runs on a normal activation.
reset; mkstate planned per-task "$(printf 'plan_review: required\nplan_review_id: %s' "$PRID")"
printf 'PLAN-REVIEW: CLEAN\n' > "reviews/spar-plan-${PRID}.md"
chmod a-w .claude
OUT="$(bash "$A" "$ST" true claude 2>&1)"; RC=$?
chmod u+w .claude
eqchk "a failed phase write refuses" "1" "$RC"
chk_absent "and not blaming the task file" "spar-fight-task.txt" "$OUT"
chk "and the phase is still planned" "phase: planned" "$(cat "$ST")"
eqchk "and still no loop" "absent" \
  "$([ -f .claude/spar.local.md ] && echo present || echo absent)"

# ── seat-specific stamps ────────────────────────────────────────────────────
reset; mkstate planned per-task ''
bash "$A" "$ST" false codex sess-1 >/dev/null 2>&1
chk "the codex seat stamps the author" "author: codex" "$(cat "$ST")"
chk "and the owning session" "owner_session: sess-1" "$(cat "$ST")"

reset; mkstate planned per-task ''
bash "$A" "$ST" false claude >/dev/null 2>&1
chk_absent "the claude seat stamps no author" "author:" "$(cat "$ST")"
chk_absent "and no session" "owner_session:" "$(cat "$ST")"

# ── task extraction ─────────────────────────────────────────────────────────
reset; mkstate planned per-task ''
bash "$A" "$ST" false claude >/dev/null 2>&1
chk "per-task mode extracts task 1" "first" "$(cat .claude/spar-fight-task.txt)"
chk_absent "and not task 2" "second" "$(cat .claude/spar-fight-task.txt)"

reset; mkstate planned whole ''
bash "$A" "$ST" false claude >/dev/null 2>&1
chk "whole mode hands over the entire plan" "second" "$(cat .claude/spar-fight-task.txt)"

# ── it launched a real loop, and said the right thing about it ──────────────
# The success line is the third thing the seat argument decides, and the two
# tails are not interchangeable: Claude's promises an automatic reviewer, which
# on the Codex seat is a different mechanism the user installs separately.
reset; mkstate planned per-task ''
OUT="$(bash "$A" "$ST" false claude 2>&1)"
chk "a loop state exists afterwards" "phase: task" "$(cat .claude/spar.local.md)"
chk "and the success line names the task count" "task 1/2" "$OUT"
chk "and names the plan to follow" "its steps in p.md" "$OUT"
chk "the claude tail is the full sentence" \
  "then stop — the sparring reviewer engages automatically and the fight advances task-by-task on convergence." "$OUT"

reset; mkstate planned per-task ''
OUT="$(bash "$A" "$ST" false codex sess-1 2>&1)"
chk "the codex seat also reports success" "task 1/2" "$OUT"
chk "with its own short tail" "then stop." "$OUT"
chk_absent "and not Claude's sentence" "sparring reviewer engages automatically" "$OUT"

cd /; rm -rf "$TMP" "$STUBS"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
