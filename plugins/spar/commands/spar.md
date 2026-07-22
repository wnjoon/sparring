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
5. If the hook reports a **stalemate**, do not keep re-deciding the finding
   yourself. Present the reviewer's problem and your rejection reason to the
   user, apply their ruling, and stop again — the loop continues on the rest.

## Hard rules

- Never edit, rewrite, or delete reviewer output files (`reviews/spar-*-r*.md`).
- Never write `STATUS: CONVERGED` anywhere yourself. Convergence is the
  reviewer's call alone.
- Never edit `.claude/spar.local.md` by hand; cancellation is `/spar-cancel`.
- If the hook reports the round cap was reached, summarize the unresolved
  findings to the user honestly — do not present the work as fully converged.
