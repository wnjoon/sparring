---
description: "Fight: run the sparring review loop — a single task, or a plan prepared by /spar:ready"
argument-hint: "[--reviewer codex|claude] [--include-dirty] [--unattended] [--no-plan-review] [--] <task description>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

First, activate the loop by running this setup command:

```bash
set -e
if [ -f .claude/spar.local.md ]; then echo "Error: a fight loop is already active. Use /spar:cancel first."; exit 1; fi
SPAR_RAW="$(cat <<'SPAR_ARGS_EOF'
$ARGUMENTS
SPAR_ARGS_EOF
)"
RESOLVED="$("${CLAUDE_PLUGIN_ROOT}/commands/spar-fight-resolve.sh" "$SPAR_RAW")" || { printf '%s\n' "$RESOLVED" >&2; exit 1; }
SPAR_REVIEWER="${RESOLVED%%$'\t'*}"
SPAR_REST="${RESOLVED#*$'\t'}"
SPAR_INCLUDE_DIRTY="${SPAR_REST%%$'\t'*}"
SPAR_REST2="${SPAR_REST#*$'\t'}"
SPAR_UNATTENDED="${SPAR_REST2%%$'\t'*}"
SPAR_REST3="${SPAR_REST2#*$'\t'}"
SPAR_PLAN_REVIEW="${SPAR_REST3%%$'\t'*}"
SPAR_TASK="${SPAR_REST3#*$'\t'}"
# ── Dispatch: plan-aware vs single-task ──────────────────────────────────────
# A plan prepared by /spar:ready lives in .claude/spar-plan.local.md. With one
# pending, `fight` (no task) drives it task-by-task; a task arg is refused so a
# prepared plan is never silently skipped. With no plan, a task arg starts a
# single loop; no task at all is an error.
PLAN_STATE=".claude/spar-plan.local.md"
if [ -f "$PLAN_STATE" ]; then
  if [ -n "$SPAR_TASK" ]; then
    echo "Error: a plan is ready — run /spar:fight with no task to execute it, or clear it with /spar:cancel." >&2
    exit 1
  fi
  # Activation — the phase checks, the plan-review gate, the phase flip, task 1
  # and the launch — lives in one helper both seats call. It used to be copied
  # here and in the Codex skill, and the copies drifted: the gate landed in each
  # by hand and ended up in a different place in the two. The seat argument is
  # the only thing this entry point still decides.
  bash "${CLAUDE_PLUGIN_ROOT}/commands/spar-plan-activate.sh" "$PLAN_STATE" "$SPAR_PLAN_REVIEW" claude || exit 1
  exit 0
fi
if [ -z "$SPAR_TASK" ]; then
  echo "Error: nothing to fight. Give a task description, or run /spar:ready <spec> first." >&2
  exit 1
fi
# No pending plan + a task arg → single-task loop (setup continues below).
"${CLAUDE_PLUGIN_ROOT}/commands/spar-check-worktree.sh" "$SPAR_INCLUDE_DIRTY" || exit 1
for SPAR_DIR in .claude reviews; do
  if [ -e "$SPAR_DIR" ] || [ -L "$SPAR_DIR" ]; then
    [ -d "$SPAR_DIR" ] && [ ! -L "$SPAR_DIR" ] || {
      echo "Error: $SPAR_DIR must be a real directory."; exit 1;
    }
  else
    mkdir "$SPAR_DIR"
  fi
done
# Keep the review surface to real code: hide sparring's own loop artifacts from
# git's untracked listing (both reviewer families inspect that listing, and the
# author's response files are debate content — reviewers must stay blind to them).
# Local-only via .git/info/exclude; never touches the user's tracked .gitignore.
if git rev-parse --git-dir >/dev/null 2>&1; then
  SPAR_EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
  for pat in 'reviews/spar-*' '.claude/spar*'; do
    grep -qxF "$pat" "$SPAR_EXCLUDE" 2>/dev/null || printf '%s\n' "$pat" >> "$SPAR_EXCLUDE"
  done
fi
SPAR_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SPAR_BASE="$(git rev-parse HEAD 2>/dev/null || echo none)"
# Best-effort and one call per run: a CLI that will not report a version must not
# stop a run, and this is the version the run STARTED with — a CLI that updates
# mid-run will have done some rounds under a build this does not name. Normalised
# to one bounded printable line so it cannot forge a frontmatter field.
SPAR_REVIEWER_VERSION="$("$SPAR_REVIEWER" --version 2>/dev/null | head -1 \
  | tr -d '\000-\037\177' | LC_ALL=C tr -cd '\040-\176' | cut -c1-120)"
[ -n "$SPAR_REVIEWER_VERSION" ] || SPAR_REVIEWER_VERSION=unknown
SPAR_STATE_TMP="$(mktemp .claude/spar.local.md.tmp.XXXXXX)"
trap 'rm -f "$SPAR_STATE_TMP"' EXIT
{
  cat << STATE_EOF
---
active: true
phase: task
round: 0
review_id: ${SPAR_ID}
base_sha: ${SPAR_BASE}
reviewer: ${SPAR_REVIEWER}
reviewer_version: ${SPAR_REVIEWER_VERSION}
include_dirty: ${SPAR_INCLUDE_DIRTY}
unattended: ${SPAR_UNATTENDED}
max_rounds: 5
sweep_done: false
sweep_result: not-run
---

STATE_EOF
  printf '%s\n' "$SPAR_TASK"
} > "$SPAR_STATE_TMP"
mv "$SPAR_STATE_TMP" .claude/spar.local.md
trap - EXIT
echo "Fight (single task) activated (${SPAR_ID}, reviewer=${SPAR_REVIEWER}, unattended=${SPAR_UNATTENDED})"
```

Then implement the task described in the arguments — completely and cleanly,
with tests where behavior changes. When you believe it is done, stop. The
sparring Stop hook takes over from there.

## Loop protocol (the hook enforces the sequencing; follow the content rules)

1. When the hook blocks you with "run reviewer": run
   `bash .claude/spar-run-reviewer.sh` with a 600000ms timeout. The review
   lands in `reviews/spar-<id>-r<N>.md`.
2. Read the review file.
   - First line `STATUS: CONVERGED` → stop again; the hook releases the session.
     A summary of the whole run is written to `reviews/spar-<id>-report.md` —
     mention it, or run `/spar:report` to show it. Non-converged endings (round
     cap, sweep findings at the hard cap, safe skip) get the same report; use it
     when you report an unconverged result honestly.
   - First line `STATUS: FINDINGS` → handle EVERY finding:
     - `[MECHANICAL]` → fix it now. Do not ask the user. If
       `.claude/spar-fix-brief.md` exists, the hook has written a self-contained
       brief for the findings that can be handed off — one section each, with a
       recommended writer tier. The hook cannot dispatch anything; you may run a
       fresh cheaper-tier subagent per section, and you must read what it
       produced before you respond. The response file is your statement either
       way, and the next round re-reviews the fix regardless. Findings the brief
       leaves out — design calls, findings missing a location, a basis or a
       fix direction, and anything the previous round already raised — are yours
       to write.
     - `[DESIGN]` → decide on the merits; implement it if you agree.
     - You may reject a finding ONLY with a reason grounded in the code or
       the task requirements — never because it is inconvenient or you are
       confident without evidence.
3. Write `reviews/spar-<id>-r<N>-response.md`: one section per finding ID —
   `### F<N>-<n>: FIXED — <what you did>` or
   `### F<N>-<n>: REJECTED — <grounded reason>`.
4. Stop again. The hook verifies your response file and prepares the next
   round automatically.
5. If the hook dispatches a **blind judge** (factual `[MECHANICAL]`
   stalemate), run `bash .claude/spar-run-judge.sh` (600000ms timeout), then
   stop; the ruling is binding (`UPHELD` = you must fix, `DISMISSED` = dropped).
   If the hook fires a **design gate**, read `.claude/spar-gate.md`, present
   the batched parked questions to the user (cluster by shared disposition;
   give the analysis before the question; skip any whose options all lead to
   the same outcome), then record each ruling in `.claude/spar-ledger.md` as
   `### P<k>: <decision + basis>` and stop again. Never invent a ruling — the
   ledger records the user's decision.
6. If the hook dispatches a **finding matcher**, run
   `bash .claude/spar-run-matcher.sh` (600000ms timeout), then stop again. It
   is an independent pass that decides whether re-worded findings are the same
   defect — you only run it, you do not author its result.
7. If the hook dispatches a **final sweep**, run
   `bash .claude/spar-run-sweep.sh` (600000ms timeout), then stop. The sweep
   is a fresh read-only author-family closure check and uses
   `SWEEP: CLEAN|FINDINGS`, never the reviewer's convergence marker. For
   findings, handle every item and write the requested sweep response before
   stopping; the hook routes fixes through the next normal reviewer round.

## Hard rules

- Never edit, rewrite, or delete reviewer output files (`reviews/spar-*-r*.md`) or
  judge ruling files (`reviews/spar-*-judge-*.md`). You may only *run* the judge
  runner (`bash .claude/spar-run-judge.sh`) — never write, edit, or fabricate a
  `RULING:` line yourself.
- Never write `STATUS: CONVERGED` anywhere yourself. Convergence is the
  reviewer's call alone.
- Never edit `.claude/spar.local.md` by hand; cancellation is `/spar:cancel`.
- If the hook reports the round cap was reached, summarize the unresolved
  findings to the user honestly — do not present the work as fully converged.
