#!/usr/bin/env bash
# Activate a prepared plan: check the preconditions, clear the plan-review gate,
# stamp the seat, flip the phase, hand task 1 over and launch the loop.
# Usage: spar-plan-activate.sh <state-file> <plan-review-flag> <seat> [session-id]
#
# <plan-review-flag> is `false` when --no-plan-review was given, else `true`.
# <seat> is claude or codex, and decides three things and nothing else: the
# command names used in messages, whether the author/owner stamps are written,
# and the trailing sentence of the success line.
#
# Both fight entry points call this instead of carrying their own copy. The two
# copies drifted — the plan-review gate landed in each by hand and ended up in a
# different place in the two — and only one of them was ever executed by a test.
#
# Every refusal leaves the plan state exactly as it found it.
# Not `set -e`. Both entry points use it, and this used to run under theirs, so
# every write below is checked explicitly instead — the same fail-fast, stated
# rather than inherited. errexit is the wrong tool here: plan_field is
# `sed … | head -1`, and with pipefail a sed that outlives the head it feeds
# takes SIGPIPE, which would abort activation on a reader that worked.
set -uo pipefail
# No message of its own: under the entry points' `set -e` the shell's own
# diagnostic was the last thing printed, and adding prose here would change what
# a failed activation says.
must() { # $1.. = command; propagate its failure
  "$@" || exit 1
}
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/spar-plan-lib.sh"

PLAN_STATE="${1:?plan state}"
NO_REVIEW_FLAG="${2:-true}"
SEAT="${3:?seat}"
SESSION="${4:-}"

case "$SEAT" in
  claude) CANCEL_CMD="/spar:cancel" ;;
  codex)  CANCEL_CMD="spar-cancel"  ;;
  *) echo "error: unknown seat: $SEAT" >&2; exit 1 ;;
esac

# Validated here, before any check that could write: the codex seat's whole point
# is that the plan is owned by a named session, and an empty value would activate
# with that ownership silently absent. Same character class spar-fight-launch.sh
# rejects at :22-25 — a newline would inject an arbitrary frontmatter field.
if [ "$SEAT" = codex ]; then
  [ -n "$SESSION" ] || { echo "error: the codex seat requires a session id" >&2; exit 1; }
  case "$SESSION" in *[!A-Za-z0-9_.-]*)
    echo "error: session id has unexpected characters" >&2; exit 1 ;;
  esac
fi

PHASE="$(plan_field phase "$PLAN_STATE")"
if [ "$PHASE" = "running" ]; then
  echo "Error: this plan is already being fought. Continue by stopping, or ${CANCEL_CMD} to abandon it." >&2
  exit 1
fi
[ "$PHASE" = "planned" ] || { echo "Error: plan state is not ready to fight (phase: $PHASE)." >&2; exit 1; }

if [ -f .claude/spar.local.md ]; then
  # stdout, not stderr. Every other refusal here goes to stderr; this one did not
  # in fight.md's plan branch, and moving it would be an observable change this
  # refactor is not allowed to make. Preserved deliberately, not by accident.
  echo "Error: a fight loop is already active. Use ${CANCEL_CMD} first."
  exit 1
fi

PLAN="$(plan_field plan_path "$PLAN_STATE")"
MODE="$(plan_field mode "$PLAN_STATE")"
[ -f "$PLAN" ] || { echo "Error: plan file not found: $PLAN" >&2; exit 1; }

# The plan review is a precondition of activation, checked after the phase and
# plan-file checks so its message is never the first thing a user sees when the
# real problem is a missing plan — and before the stamps below, so a refusal
# writes nothing at all. The Claude seat has no stamps, so that ordering is
# invisible there; which is exactly why it belongs here and not in one copy.
#
# plan_put_field, not plan_set_field: the latter is a pure replace and does
# nothing on a state written before the field existed (spar-plan-lib.sh:31-35),
# and a plan prepared by an older version carries no plan_review line.
#
# No [ -x ] guard on the checker — a missing command script is a broken install,
# and fail-open exists so a hook never holds a session hostage, which this
# deliberately is not.
if [ "$NO_REVIEW_FLAG" = false ]; then
  must plan_put_field plan_review overridden "$PLAN_STATE"
  echo "Note: starting without a plan review because --no-plan-review was given."
elif ! bash "$DIR/spar-plan-review-check.sh" "$PLAN" "$PLAN_STATE" "$SEAT"; then
  exit 1
fi

# Claim the plan for THIS seat and THIS session. Both are stamped on the plan,
# not on the task, because the hook launches every task after the first and would
# otherwise drop them at the first advance.
#
# Re-stamping a plan prepared elsewhere is correct, not a hijack: whoever fights
# the plan is the one writing the code, so this session is its author and owner.
if [ "$SEAT" = codex ]; then
  must plan_put_field author codex "$PLAN_STATE"
  must plan_put_field owner_session "$SESSION" "$PLAN_STATE"
fi

must plan_set_field phase running "$PLAN_STATE"

# Checked too: a task file that failed to write would hand the loop an empty or
# missing task while the phase already says running.
H1="$(plan_task_line 1 "$PLAN_STATE" | cut -f3)"
if [ "$MODE" = "whole" ]; then
  cp "$PLAN" .claude/spar-fight-task.txt || exit 1
else
  awk -v h="### ${H1}" '$0==h{f=1} f&&/^### /&&$0!=h&&seen{exit} $0==h{seen=1} f{print}' "$PLAN" \
    > .claude/spar-fight-task.txt || exit 1
fi

bash "$DIR/spar-fight-launch.sh" "$PLAN_STATE" .claude/spar-fight-task.txt \
  || { echo "Error: could not launch task 1." >&2; exit 1; }

if [ "$SEAT" = claude ]; then
  TAIL=" — the sparring reviewer engages automatically and the fight advances task-by-task on convergence."
else
  TAIL="."
fi
echo "Fight started on the ready plan (task 1/$(plan_field tasks "$PLAN_STATE")). Implement task 1 following its steps in ${PLAN}, then stop${TAIL}"
