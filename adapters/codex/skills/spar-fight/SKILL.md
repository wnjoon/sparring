---
name: spar-fight
description: Run the sparring review loop in this Codex session — Codex authors, an independent claude -p reviewer declares convergence, and Codex's Stop hook makes the loop non-optional.
---

# spar-fight

You are the **author seat**. An independent reviewer decides when the work is
done; you never make that call yourself.

This skill mirrors the Claude-hosted `/spar:fight` command. Same states, same
helper scripts, same protocol — only the seats swap.

## 1. Activation

**Before running the block below**, write whatever the user passed — flags and
task text, byte for byte — to `.claude/spar-args.txt` with your file-writing tool,
creating `.claude` if it does not exist. Skip the file entirely when they passed
nothing. Never paste their text into the shell block: it is arbitrary prose, and
the block reads it as data instead of as source.

Do not paraphrase the task either. The reviewer is shown this text as the
requirements, so a summary silently narrows what gets reviewed.

Then run the block.

```bash
set -e
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-}"
[ -n "$SPAR_ROOT" ] || SPAR_ROOT=@@SPAR_PLUGIN_ROOT@@
[ -d "$SPAR_ROOT" ] || { echo "Error: set SPAR_PLUGIN_ROOT to sparring's plugins/spar." >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Error: spar-fight must run inside a git repository." >&2; exit 1; }
if [ -f .claude/spar.local.md ]; then echo "Error: a loop is already active. Use spar-cancel first." >&2; exit 1; fi

# ── Enforcement proof ────────────────────────────────────────────────────────
# Codex treats hook trust as a per-session choice ("Continue without trusting")
# and offers no way to query it, so the ONLY evidence that this session is
# enforced is the SessionStart hook having fired and left its marker.
#
# Existence is not enough: the marker is a plain file in the git directory, so a
# marker written by an EARLIER session survives into this one. It must name the
# session running right now. CODEX_THREAD_ID is this session's own id, and the
# Stop hook independently gates on the same identity via the hook payload's
# session_id — so a mismatch here is exactly the case where the loop would be
# owned by a session that can never advance it. Refuse instead.
SPAR_LIVE="$(git rev-parse --git-dir)/spar-hook-live"
SPAR_SESSION="${CODEX_THREAD_ID:-}"
spar_unenforced() {
  echo "Error: $1" >&2
  echo "The review loop would NOT be enforced in this session. Install the hooks with" >&2
  echo "adapters/codex/install.sh, start a NEW session, and accept the trust prompt." >&2
  echo "Refusing to start an unenforced loop." >&2
  exit 1
}
[ -n "$SPAR_SESSION" ] || spar_unenforced "CODEX_THREAD_ID is unset, so this session cannot prove its identity."
{ [ -f "$SPAR_LIVE" ] && [ ! -L "$SPAR_LIVE" ]; } || spar_unenforced "sparring's SessionStart hook left no liveness marker."
SPAR_MARKED="$(head -1 "$SPAR_LIVE" 2>/dev/null || true)"
[ "$SPAR_MARKED" = "$SPAR_SESSION" ] \
  || spar_unenforced "the liveness marker names session '${SPAR_MARKED:-(empty)}', not this one ('$SPAR_SESSION') — it is stale."

# ── Argument resolution ──────────────────────────────────────────────────────
# Arguments arrive in a FILE, never pasted into this block. Task text is
# arbitrary prose: a line matching a heredoc delimiter would close the heredoc
# early and hand the remaining lines to the shell as commands, and quoting rules
# a model has to apply by hand are exactly the kind of thing that fails on the
# one input that matters. The file is read once and removed, so a second run
# needs a fresh write rather than silently inheriting the previous task.
SPAR_ARGS_FILE=".claude/spar-args.txt"
SPAR_RAW="$(cat "$SPAR_ARGS_FILE" 2>/dev/null || true)"
rm -f "$SPAR_ARGS_FILE"
RESOLVED="$("$SPAR_ROOT/commands/spar-fight-resolve.sh" "$SPAR_RAW")" || { printf '%s\n' "$RESOLVED" >&2; exit 1; }
SPAR_REVIEWER="${RESOLVED%%$'\t'*}"
SPAR_REST="${RESOLVED#*$'\t'}"
SPAR_INCLUDE_DIRTY="${SPAR_REST%%$'\t'*}"
SPAR_REST2="${SPAR_REST#*$'\t'}"
SPAR_UNATTENDED="${SPAR_REST2%%$'\t'*}"
SPAR_REST3="${SPAR_REST2#*$'\t'}"
SPAR_PLAN_REVIEW="${SPAR_REST3%%$'\t'*}"
SPAR_TASK="${SPAR_REST3#*$'\t'}"
# Codex authors here, so the cross-model default is the mirror image of the
# Claude seat's: claude reviews when it is installed, and only a machine without
# it falls back to same-family review.
if [ -z "$SPAR_REVIEWER" ]; then
  if command -v claude >/dev/null 2>&1; then
    SPAR_REVIEWER=claude
  else
    # Falling back to same-family review is a supported mode, but it is NOT what
    # this seat is for, and a silent fallback reads as a cross-model run in the
    # report afterwards. Measured in a real session: claude lives in ~/.local/bin,
    # which a non-interactive shell does not have on PATH, so the default degraded
    # without anyone noticing until the run was over.
    SPAR_REVIEWER=codex
    echo "warning: 'claude' is not on PATH, so this run will be codex reviewing codex." >&2
    echo "         That is single-agent mode, not the cross-model pairing this seat exists for." >&2
    echo "         For cross-model review, put claude on PATH (it is often in ~/.local/bin)" >&2
    echo "         and start again, or pass --reviewer claude to fail loudly instead." >&2
  fi
fi
command -v "$SPAR_REVIEWER" >/dev/null 2>&1 || { echo "Error: '$SPAR_REVIEWER' CLI not on PATH." >&2; exit 1; }

# ── Dispatch: plan-aware vs single-task ──────────────────────────────────────
# A plan prepared by spar-ready lives in .claude/spar-plan.local.md. With one
# pending, spar-fight (no task) drives it task-by-task; a task arg is refused so
# a prepared plan is never silently skipped.
PLAN_STATE=".claude/spar-plan.local.md"
if [ -f "$PLAN_STATE" ]; then
  if [ -n "$SPAR_TASK" ]; then
    echo "Error: a plan is ready — run spar-fight with no task to execute it, or clear it with spar-cancel." >&2
    exit 1
  fi
  . "$SPAR_ROOT/commands/spar-plan-lib.sh"
  PHASE="$(plan_field phase "$PLAN_STATE")"
  if [ "$PHASE" = "running" ]; then
    echo "Error: this plan is already being fought. Continue by stopping, or spar-cancel to abandon it." >&2
    exit 1
  fi
  [ "$PHASE" = "planned" ] || { echo "Error: plan state is not ready to fight (phase: $PHASE)." >&2; exit 1; }
  PLAN="$(plan_field plan_path "$PLAN_STATE")"
  MODE="$(plan_field mode "$PLAN_STATE")"
  [ -f "$PLAN" ] || { echo "Error: plan file not found: $PLAN" >&2; exit 1; }
  # Claim the plan for THIS seat and THIS session. Both are stamped on the plan,
  # not on the task, because the hook launches every task after the first and
  # would otherwise drop them at the first advance. plan_put_field, not
  # plan_set_field: a plan prepared by the Claude command — or by an older
  # version — has neither key, and a pure replace would silently leave the run
  # ungated and attributed to the wrong author family.
  #
  # Re-stamping a plan prepared elsewhere is correct, not a hijack: whoever fights
  # the plan is the one writing the code, so this session is its author and owner.
  plan_put_field author codex "$PLAN_STATE"
  plan_put_field owner_session "$SPAR_SESSION" "$PLAN_STATE"
  plan_set_field phase running "$PLAN_STATE"
  H1="$(plan_task_line 1 "$PLAN_STATE" | cut -f3)"
  if [ "$MODE" = "whole" ]; then cp "$PLAN" .claude/spar-fight-task.txt
  else awk -v h="### ${H1}" '$0==h{f=1} f&&/^### /&&$0!=h&&seen{exit} $0==h{seen=1} f{print}' "$PLAN" > .claude/spar-fight-task.txt; fi
  bash "$SPAR_ROOT/commands/spar-fight-launch.sh" "$PLAN_STATE" .claude/spar-fight-task.txt \
    || { echo "Error: could not launch task 1." >&2; exit 1; }
  echo "Fight started on the ready plan (task 1/$(plan_field tasks "$PLAN_STATE")). Implement task 1 following its steps in ${PLAN}, then stop."
  exit 0
fi
if [ -z "$SPAR_TASK" ]; then
  echo "Error: nothing to fight. Give a task description, or run spar-ready <spec> first." >&2
  exit 1
fi

# ── Single-task loop ─────────────────────────────────────────────────────────
"$SPAR_ROOT/commands/spar-check-worktree.sh" "$SPAR_INCLUDE_DIRTY" || exit 1
for SPAR_DIR in .claude reviews; do
  if [ -e "$SPAR_DIR" ] || [ -L "$SPAR_DIR" ]; then
    [ -d "$SPAR_DIR" ] && [ ! -L "$SPAR_DIR" ] || { echo "Error: $SPAR_DIR must be a real directory." >&2; exit 1; }
  else
    mkdir "$SPAR_DIR"
  fi
done
# Keep the review surface to real code: hide sparring's own loop artifacts from
# git's untracked listing. Local-only via .git/info/exclude.
SPAR_EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
for pat in 'reviews/spar-*' '.claude/spar*'; do
  grep -qxF "$pat" "$SPAR_EXCLUDE" 2>/dev/null || printf '%s\n' "$pat" >> "$SPAR_EXCLUDE"
done
SPAR_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SPAR_BASE="$(git rev-parse HEAD 2>/dev/null || echo none)"
# Best-effort and one call per run: a CLI that will not report a version must not
# stop a run, and this is the version the run STARTED with — a CLI that updates
# mid-run will have done some rounds under a build this does not name. Normalised
# to one bounded printable line so it cannot forge a frontmatter field.
SPAR_REVIEWER_VERSION="$("$SPAR_REVIEWER" --version 2>/dev/null | head -1 \
  | tr -d '\000-\037\177' | LC_ALL=C tr -cd '\040-\176' | cut -c1-120)"
[ -n "$SPAR_REVIEWER_VERSION" ] || SPAR_REVIEWER_VERSION=unknown
SPAR_TMP="$(mktemp .claude/spar.local.md.tmp.XXXXXX)"
trap 'rm -f "$SPAR_TMP"' EXIT
{
  cat <<STATE_EOF
---
active: true
phase: task
round: 0
review_id: ${SPAR_ID}
base_sha: ${SPAR_BASE}
author: codex
reviewer: ${SPAR_REVIEWER}
reviewer_version: ${SPAR_REVIEWER_VERSION}
owner_session: ${SPAR_SESSION}
include_dirty: ${SPAR_INCLUDE_DIRTY}
unattended: ${SPAR_UNATTENDED}
max_rounds: 5
sweep_done: false
sweep_result: not-run
---

STATE_EOF
  printf '%s\n' "$SPAR_TASK"
} > "$SPAR_TMP"
mv "$SPAR_TMP" .claude/spar.local.md
trap - EXIT
echo "Fight (single task) activated (${SPAR_ID}, reviewer=${SPAR_REVIEWER}, unattended=${SPAR_UNATTENDED}, session=${SPAR_SESSION})"
```

`author: codex` makes the final sweep a fresh `codex exec`; `owner_session` keeps
other Codex sessions on this machine out of this run.

Then implement the task completely and cleanly, with tests where behavior
changes. When you believe it is done, stop. The Stop hook takes over.

## 2. What is enforced

Codex's `Stop` hook blocks the session from ending until the reviewer declares
convergence. There is no commit gate involved, so `git commit --no-verify` and
friends are irrelevant — the loop holds the session itself.

## 3. Loop protocol

1. When the hook blocks you with "run reviewer": run
   `bash .claude/spar-run-reviewer.sh` (allow ~10 minutes). The review lands in
   `reviews/spar-<id>-r<N>.md`.
2. Read it.
   - `STATUS: CONVERGED` → stop again; the hook releases the session. A summary is
     written to `reviews/spar-<id>-report.md`; the `spar-report` skill shows it.
   - `STATUS: FINDINGS` → handle EVERY finding. `[MECHANICAL]` → fix it now, do not
     ask the user. `[DESIGN]` → decide on the merits and implement if you agree.
     Reject only with a reason grounded in the code or the task requirements.
     If `.claude/spar-fix-brief.md` exists, the hook has written a self-contained
     brief for the findings that can be handed off, one section each with a
     recommended writer tier. The hook dispatches nothing; you may run a fresh
     cheaper-tier agent per section, and you must read what it produced before
     responding. The response file is your statement either way, and the next
     round re-reviews the fix. Design calls, findings missing a location, a
     basis or a fix direction, and anything the previous round already raised
     stay with you.
3. Write `reviews/spar-<id>-r<N>-response.md`, one section per finding ID:
   `### F<N>-<n>: FIXED — <what you did>` or
   `### F<N>-<n>: REJECTED — <grounded reason>`. Then stop again.
4. If the hook dispatches a **blind judge**, run `bash .claude/spar-run-judge.sh`
   and stop; the ruling binds. If it fires a **design gate**, read
   `.claude/spar-gate.md`, put the batched questions to the user, and record each
   ruling in `.claude/spar-ledger.md` as `### P<k>: <decision + basis>`. Never
   invent one.
5. If it dispatches a **matcher**, run `bash .claude/spar-run-matcher.sh` and stop.
6. If it dispatches a **final sweep**, run `bash .claude/spar-run-sweep.sh` and
   stop. The sweep uses `SWEEP: CLEAN|FINDINGS`, never the convergence marker.

On a plan run the hook advances to the next task on its own after each
convergence; keep implementing whichever task it names until it releases you.

## Hard rules

- Never write `STATUS: CONVERGED` anywhere. Convergence is the reviewer's call.
- Never edit or delete reviewer output (`reviews/spar-*-r*.md`) or judge rulings
  (`reviews/spar-*-judge-*.md`). You may only run their runners.
- Never edit `.claude/spar.local.md` by hand; cancelling is the `spar-cancel` skill.
- If the round cap is reached, report the unresolved findings honestly. Do not
  present capped work as converged.
- Loop state lives under `.claude/` for historical reasons — it is shared with the
  Claude-hosted seat and is git-excluded either way.
