---
description: "Sparring loop: implement the task, then iterate independent Codex reviews until the reviewer declares CONVERGED"
argument-hint: "<task description>"
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
command -v codex >/dev/null 2>&1 || { echo "Error: Codex CLI not installed. Run: npm install -g @openai/codex"; exit 1; }
if [ -f .claude/spar.local.md ]; then echo "Error: a sparring loop is already active. Use /spar-cancel first."; exit 1; fi
mkdir -p .claude reviews
SPAR_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SPAR_BASE="$(git rev-parse HEAD 2>/dev/null || echo none)"
cat > .claude/spar.local.md << STATE_EOF
---
active: true
phase: task
round: 0
review_id: ${SPAR_ID}
base_sha: ${SPAR_BASE}
reviewer: codex
max_rounds: 5
---

$ARGUMENTS
STATE_EOF
echo "Sparring loop activated (${SPAR_ID})"
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
   - First line `STATUS: FINDINGS` → handle EVERY finding:
     - `[MECHANICAL]` → fix it now. Do not ask the user.
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

## Hard rules

- Never edit, rewrite, or delete reviewer output files (`reviews/spar-*-r*.md`) or
  judge ruling files (`reviews/spar-*-judge-*.md`). You may only *run* the judge
  runner (`bash .claude/spar-run-judge.sh`) — never write, edit, or fabricate a
  `RULING:` line yourself.
- Never write `STATUS: CONVERGED` anywhere yourself. Convergence is the
  reviewer's call alone.
- Never edit `.claude/spar.local.md` by hand; cancellation is `/spar-cancel`.
- If the hook reports the round cap was reached, summarize the unresolved
  findings to the user honestly — do not present the work as fully converged.
