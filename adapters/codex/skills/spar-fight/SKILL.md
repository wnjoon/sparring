---
name: spar-fight
description: Run the sparring review loop in this Codex session — Codex authors, an independent claude -p reviewer declares convergence, and Codex's Stop hook makes the loop non-optional.
---

# spar-fight

You are the **author seat**. An independent reviewer decides when the work is
done; you never make that call yourself.

## 1. Activation

Run this first. It refuses to start unless sparring's hooks actually ran in this
session — otherwise the loop would not be enforced and you would be reviewing
yourself while believing otherwise.

```bash
set -e
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-$HOME/.codex/sparring/plugins/spar}"
[ -d "$SPAR_ROOT" ] || { echo "Error: set SPAR_PLUGIN_ROOT to sparring's plugins/spar." >&2; exit 1; }
if [ -f .claude/spar.local.md ]; then echo "Error: a loop is already active. Use spar-cancel first." >&2; exit 1; fi

# Enforcement proof. Codex treats hook trust as a per-session choice and offers no
# way to query it, so the ONLY evidence that this session is enforced is the
# SessionStart hook having fired and left its marker.
SPAR_LIVE="reviews/.spar-hook-live"
if [ ! -f "$SPAR_LIVE" ]; then
  echo "Error: sparring's hooks did not run in this session, so the review loop" >&2
  echo "would NOT be enforced. Install them with adapters/codex/install.sh, start a" >&2
  echo "new session, and accept the trust prompt. Refusing to start an unenforced loop." >&2
  exit 1
fi
SPAR_SESSION="$(cat "$SPAR_LIVE")"

mkdir -p .claude reviews
if git rev-parse --git-dir >/dev/null 2>&1; then
  EX="$(git rev-parse --git-common-dir)/info/exclude"
  for pat in 'reviews/spar-*' '.claude/spar*'; do
    grep -qxF "$pat" "$EX" 2>/dev/null || printf '%s\n' "$pat" >> "$EX"
  done
fi
SPAR_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SPAR_BASE="$(git rev-parse HEAD 2>/dev/null || echo none)"
cat > .claude/spar.local.md <<STATE
---
active: true
phase: task
round: 0
review_id: ${SPAR_ID}
base_sha: ${SPAR_BASE}
author: codex
reviewer: claude
owner_session: ${SPAR_SESSION}
include_dirty: false
unattended: false
max_rounds: 5
sweep_done: false
sweep_result: not-run
---

TASK_DESCRIPTION_GOES_HERE
STATE
echo "Sparring activated (${SPAR_ID}): codex author ↔ claude reviewer, session ${SPAR_SESSION}."
```

Replace `TASK_DESCRIPTION_GOES_HERE` with the user's task before running it.

`author: codex` makes the final sweep a fresh `codex exec`; `owner_session` keeps
other Codex sessions on this machine out of this run.

## 2. What is enforced

Codex's `Stop` hook blocks the session from ending until the reviewer declares
convergence. There is no commit gate involved, so `git commit --no-verify` and
friends are irrelevant — the loop holds the session itself.

## 3. Loop protocol

1. Implement the task completely, with tests where behavior changes. Then stop.
2. The hook blocks you with "run reviewer": run `bash .claude/spar-run-reviewer.sh`
   (allow ~10 minutes). The review lands in `reviews/spar-<id>-r<N>.md`.
3. Read it.
   - `STATUS: CONVERGED` → stop again; the hook releases the session. A summary is
     written to `reviews/spar-<id>-report.md`; the `spar-report` skill shows it.
   - `STATUS: FINDINGS` → handle EVERY finding. `[MECHANICAL]` → fix it now.
     `[DESIGN]` → decide on the merits and implement if you agree. Reject only with
     a reason grounded in the code or the task requirements.
4. Write `reviews/spar-<id>-r<N>-response.md`, one section per finding ID:
   `### F<N>-<n>: FIXED — <what you did>` or
   `### F<N>-<n>: REJECTED — <grounded reason>`. Then stop again.
5. If the hook dispatches a **blind judge**, run `bash .claude/spar-run-judge.sh`
   and stop; the ruling binds. If it fires a **design gate**, read
   `.claude/spar-gate.md`, put the questions to the user, and record each ruling in
   `.claude/spar-ledger.md` as `### P<k>: <decision + basis>`. Never invent one.
6. If it dispatches a **matcher**, run `bash .claude/spar-run-matcher.sh` and stop.
7. If it dispatches a **final sweep**, run `bash .claude/spar-run-sweep.sh` and
   stop. The sweep uses `SWEEP: CLEAN|FINDINGS`, never the convergence marker.

## Hard rules

- Never write `STATUS: CONVERGED` anywhere. Convergence is the reviewer's call.
- Never edit or delete reviewer output (`reviews/spar-*-r*.md`) or judge rulings
  (`reviews/spar-*-judge-*.md`). You may only run their runners.
- Never edit `.claude/spar.local.md` by hand; cancelling is the `spar-cancel` skill.
- If the round cap is reached, report the unresolved findings honestly. Do not
  present capped work as converged.
- Loop state lives under `.claude/` for historical reasons — it is shared with the
  Claude-hosted seat and is git-excluded either way.
