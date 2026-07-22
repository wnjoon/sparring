# sparring Phase 1 (Core Loop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Claude Code plugin (`spar`) where Claude implements a task, Codex reviews it read-only, and a Stop hook forces fix→re-review rounds until Codex declares `STATUS: CONVERGED`.

**Architecture:** A deterministic bash Stop hook is the gatekeeper: it tracks phase/round in `.claude/spar.local.md`, generates per-round reviewer prompts from shared templates, and blocks session exit until the reviewer converges (or a round cap is hit). Claude (author) is the only writer of code; Codex (reviewer, `--sandbox read-only`) is the only party allowed to declare convergence. The author must write a per-finding response file each round — the hook checks it exists before allowing the next round.

**Tech Stack:** Bash (hook + tests), Claude Code plugin system (commands + Stop hook), Codex CLI (`codex exec`, verified v0.144.1: supports `-o/--output-last-message`, `-s/--sandbox`, `--skip-git-repo-check`), `jq` (with printf fallback).

## Global Constraints

- Plugin name: `spar`. Marketplace name: `sparring`. Repo root: `~/Workspace/sparring`.
- Invariant 1 (single-writer): only the author edits code. Reviewer runs with `--sandbox read-only`.
- Invariant 2 (reviewer declares): convergence = reviewer's review file whose **first line** is exactly `STATUS: CONVERGED`. The author must never write that string.
- Invariant 3 (deterministic enforcement): the Stop hook, not prompt discipline, blocks exit. Hook fails **open** on any internal error (never trap the user).
- Invariant 4 (respond-before-next-round): round N+1 is not prepared until `reviews/spar-<id>-r<N>-response.md` exists.
- Round cap: `max_rounds: 5` (stored in state file; hook defaults to 5 if unparsable).
- State file: `.claude/spar.local.md`. Review files: `reviews/spar-<id>-r<N>.md`. Response files: `reviews/spar-<id>-r<N>-response.md`. Runner: `.claude/spar-run-reviewer.sh`. Prompt: `.claude/spar-reviewer-prompt.txt`.
- `review_id` format: `YYYYmmdd-HHMMSS-<6 hex>` (regex-validated by hook to prevent path traversal).
- Finding tags: `[MECHANICAL]` (objectively fixable) / `[DESIGN]` (choice among valid alternatives). Phase 1: author decides DESIGN on the merits; Gate/judge UX is Phase 2.
- Out of scope for Phase 1: sweep, deadlock judge, unattended mode, skip conditions, issue-number entry, `--existing`, Codex-side port, same-model fallback, config.toml.

---

## File Structure

```
sparring/
├── .claude-plugin/marketplace.json          # marketplace manifest (install source)
├── .gitignore
├── README.md
├── plugins/spar/
│   ├── .claude-plugin/plugin.json
│   ├── commands/
│   │   ├── spar.md                          # /spar — entry point + loop protocol
│   │   └── spar-cancel.md                   # /spar-cancel — cleanup
│   ├── hooks/
│   │   ├── hooks.json                       # Stop hook registration
│   │   └── stop-hook.sh                     # deterministic gatekeeper
│   └── shared/
│       ├── policy.md                        # loop policy SoT (tags, protocol, invariants)
│       └── prompts/
│           ├── reviewer.md                  # reviewer prompt template
│           └── reviewer-prev-context.md     # round≥2 addendum template
├── tests/test_stop_hook.sh                  # pure-bash hook tests
└── docs/superpowers/plans/                  # this plan
```

`shared/` lives **inside** `plugins/spar/` (not repo root) because plugin installation copies only the plugin directory; the hook resolves templates via `${CLAUDE_PLUGIN_ROOT}/shared/prompts/`. The future Codex adapter (Phase 5) will reference the same files.

---

### Task 1: Repo scaffold + manifests

**Files:**
- Create: `.claude-plugin/marketplace.json`
- Create: `plugins/spar/.claude-plugin/plugin.json`
- Create: `plugins/spar/hooks/hooks.json`
- Create: `.gitignore`
- (README.md and LICENSE already exist on `dev` — update README's install section only if it changes)

**Interfaces:**
- Produces: `${CLAUDE_PLUGIN_ROOT}` will point at `plugins/spar` when installed; `hooks.json` wires `Stop` → `hooks/stop-hook.sh` (Task 3 creates it).

- [ ] **Step 1: Write manifests**

`.claude-plugin/marketplace.json`:

```json
{
  "name": "sparring",
  "owner": {
    "name": "wnjoon"
  },
  "metadata": {
    "description": "Cross-model review sparring loop: author implements, an independent reviewer iterates findings until it declares convergence"
  },
  "plugins": [
    {
      "name": "spar",
      "source": "./plugins/spar",
      "description": "Sparring loop: Claude implements, Codex reviews read-only, Stop hook forces rounds until the reviewer declares CONVERGED",
      "license": "MIT",
      "keywords": ["code-review", "codex", "convergence", "quality"]
    }
  ]
}
```

`plugins/spar/.claude-plugin/plugin.json`:

```json
{
  "name": "spar",
  "version": "0.1.0",
  "description": "Sparring loop: Claude implements, Codex reviews read-only, Stop hook forces rounds until the reviewer declares CONVERGED",
  "author": {
    "name": "wnjoon"
  },
  "license": "MIT",
  "keywords": ["code-review", "codex", "convergence", "quality"]
}
```

`plugins/spar/hooks/hooks.json`:

```json
{
  "description": "Sparring loop stop hook: blocks exit until the independent reviewer declares CONVERGED",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh",
            "timeout": 30,
            "statusMessage": "sparring: checking loop phase..."
          }
        ]
      }
    ]
  }
}
```

`.gitignore`:

```
.DS_Store
*.log
```

- [ ] **Step 2: Validate JSON**

Run: `cd ~/Workspace/sparring && jq . .claude-plugin/marketplace.json plugins/spar/.claude-plugin/plugin.json plugins/spar/hooks/hooks.json >/dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: scaffold sparring repo — spar plugin manifests, marketplace, README"
```

---

### Task 2: Reviewer prompt templates + policy SoT

**Files:**
- Create: `plugins/spar/shared/prompts/reviewer.md`
- Create: `plugins/spar/shared/prompts/reviewer-prev-context.md`
- Create: `plugins/spar/shared/policy.md`

**Interfaces:**
- Produces: templates with placeholders `{{TASK}}`, `{{ROUND}}`, `{{PREV_CONTEXT}}` (reviewer.md) and `{{PREV_REVIEW}}`, `{{PREV_RESPONSE}}` (reviewer-prev-context.md). Task 3/4's hook substitutes them with bash `${var//pat/repl}`.
- Produces: output protocol consumed by hook — first line `STATUS: CONVERGED` or `STATUS: FINDINGS`; findings as `### F<round>-<n> [MECHANICAL|DESIGN] <title>`.

- [ ] **Step 1: Write `reviewer.md`**

```markdown
You are an independent code reviewer. You did NOT write this code and you must
not modify anything — you are running in a read-only sandbox. This is review
round {{ROUND}}.

## Task the author was given

{{TASK}}

## What to review

Run `git status` and `git diff HEAD` in this repository to see the author's
uncommitted changes (if the diff is empty, review `git diff HEAD~1`). Review
ONLY the changed code and files it directly touches.

{{PREV_CONTEXT}}

## Review criteria (in priority order)

1. Requirement fit — does the change actually accomplish the task above?
   Missing or misunderstood requirements are findings.
2. Correctness — bugs, unhandled edge cases, broken error paths.
3. Tests — changed behavior without a covering test is a finding.
4. Security — injection, secrets in code, unsafe input handling.

Do NOT report style nits a linter would catch, and do not restate the same
finding twice.

## Output format (STRICT — a script parses your first line)

Your FIRST line must be exactly one of:

STATUS: CONVERGED
STATUS: FINDINGS

If CONVERGED: follow with one short paragraph stating what you checked.
Declare CONVERGED only when nothing worth fixing remains — never out of
politeness, and never because the author pushed back confidently.

If FINDINGS: list every finding as:

### F{{ROUND}}-<n> [MECHANICAL|DESIGN] <one-line title>
- file: <path>:<line>
- problem: <what is wrong, concretely>
- suggestion: <concrete fix>

Tag meaning: [MECHANICAL] = objectively fixable (bug, typo, missing check,
missing test). [DESIGN] = a choice among valid alternatives (structure, API
shape, tradeoffs) — state the alternatives.
```

- [ ] **Step 2: Write `reviewer-prev-context.md`**

```markdown
## Previous round

Read `{{PREV_REVIEW}}` (your previous findings) and `{{PREV_RESPONSE}}` (the
author's per-finding response), then verify against the current diff:

- For each finding marked FIXED: confirm the fix is real and complete.
  Re-raise it (same ID, new number) if it is not.
- For each finding marked REJECTED: judge the stated reason on its merits
  against the code and the task requirements. Do not cave to confident
  wording. Re-raise if the reason does not hold; otherwise accept and drop it.
```

- [ ] **Step 3: Write `policy.md`**

```markdown
# sparring loop policy (SoT)

Both adapters (Claude-hosted, Codex-hosted) implement exactly this policy.

## Roles
- **Author** — the model the user is working with. Sole writer of code.
  Never declares convergence.
- **Reviewer** — the opposite model, invoked read-only, stateless per round.
  Sole authority on `STATUS: CONVERGED`.

## Protocol
1. Author implements the task, then tries to stop; a deterministic hook
   blocks exit and prepares round 1.
2. Reviewer receives: task description + instruction to inspect the diff
   itself (+ from round 2: previous review and author response files).
3. Reviewer output: first line `STATUS: CONVERGED` or `STATUS: FINDINGS`;
   findings tagged `[MECHANICAL]` or `[DESIGN]` with file/problem/suggestion.
4. Author must fix every MECHANICAL finding, decide DESIGN findings on the
   merits, and write a response file (`FIXED — ...` / `REJECTED — <grounded
   reason>` per finding) before the hook prepares the next round.
5. Exit is released only by reviewer convergence, the round cap (default 5,
   exits with an honest "unconverged" summary), or explicit cancel.

## Invariants
- Single-writer: reviewer sandbox is read-only.
- Reviewer-declares: author never writes the convergence marker.
- Deterministic enforcement: hooks block exit; prompts alone are not trusted.
- Fail-open: any hook-internal error approves exit; never trap the user.
- Review artifacts (`reviews/spar-*.md`) are append-only for the author:
  never edited or deleted (except via explicit user cleanup).

## Phase roadmap
Phase 1 (this): core loop. Phase 2: Gate + deadlock judge. Phase 3: sweep +
skip conditions. Phase 4: unattended mode + final report. Phase 5: Codex-side
adapter (git pre-commit enforcement). Phase 6: same-model fallback + config.
```

- [ ] **Step 4: Verify placeholders**

Run: `grep -o '{{[A-Z_]*}}' plugins/spar/shared/prompts/*.md | sort -u`
Expected exactly:

```
plugins/spar/shared/prompts/reviewer-prev-context.md:{{PREV_RESPONSE}}
plugins/spar/shared/prompts/reviewer-prev-context.md:{{PREV_REVIEW}}
plugins/spar/shared/prompts/reviewer.md:{{PREV_CONTEXT}}
plugins/spar/shared/prompts/reviewer.md:{{ROUND}}
plugins/spar/shared/prompts/reviewer.md:{{TASK}}
```

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/shared && git commit -m "feat: reviewer prompt templates + loop policy SoT"
```

---

### Task 3: Stop hook — skeleton + task phase (TDD)

**Files:**
- Create: `tests/test_stop_hook.sh`
- Create: `plugins/spar/hooks/stop-hook.sh`

**Interfaces:**
- Consumes: templates from Task 2 via `${CLAUDE_PLUGIN_ROOT}/shared/prompts/`.
- Produces: hook stdout JSON `{"decision":"approve"}` or `{"decision":"block","reason":...,"systemMessage":...}`; state file mutations (`phase`, `round`); generated `.claude/spar-run-reviewer.sh` + `.claude/spar-reviewer-prompt.txt`. Function names used by Task 4: `field`, `approve`, `block`, `cleanup`, `set_state`, `prepare_round`, `review_file`, `response_file`.

- [ ] **Step 1: Write the failing tests (cases 1–4)**

`tests/test_stop_hook.sh`:

```bash
#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/hooks/stop-hook.sh
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/plugins/spar/hooks/stop-hook.sh"
export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/spar"

chk() { # $1=desc $2=expected-substring $3=actual
  if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "   want: $2"; echo "   got : $3"; FAIL=$((FAIL+1)); fi
}
chk_file() { # $1=desc $2=path
  if [ -f "$2" ]; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1 ($2 missing)"; FAIL=$((FAIL+1)); fi
}

fresh_dir() { d=$(mktemp -d); cd "$d" || exit 1; git init -q; mkdir -p .claude; }

write_state() { # $1=phase $2=round
  cat > .claude/spar.local.md <<EOF
---
active: true
phase: $1
round: $2
review_id: 20260721-120000-abc123
reviewer: codex
max_rounds: 5
---

Add a fizzbuzz function with tests
EOF
}

run_hook() { echo '{}' | bash "$HOOK"; }

# ── 1. no state file → approve ──
fresh_dir
chk "no state → approve" '"decision":"approve"' "$(run_hook)"

# ── 2. active:false → approve + state removed ──
fresh_dir; write_state task 0
sed -i '' 's/^active: true/active: false/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^active: true/active: false/' .claude/spar.local.md
run_hook >/dev/null
chk "inactive → state removed" "gone" "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# ── 3. bad review_id → fail-open approve ──
fresh_dir; write_state task 0
sed -i '' 's/^review_id: .*/review_id: ..\/..\/evil/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^review_id: .*/review_id: ..\/..\/evil/' .claude/spar.local.md
chk "bad review_id → approve" '"decision":"approve"' "$(run_hook)"

# ── 4. phase=task → block, artifacts prepared, state advanced ──
fresh_dir; write_state task 0
OUT=$(run_hook)
chk "task → block" '"decision":"block"' "$OUT"
chk "task → mentions runner" 'spar-run-reviewer.sh' "$OUT"
chk_file "runner generated" .claude/spar-run-reviewer.sh
chk_file "prompt generated" .claude/spar-reviewer-prompt.txt
chk "prompt has task text" 'fizzbuzz' "$(cat .claude/spar-reviewer-prompt.txt)"
chk "prompt has round 1" 'round 1' "$(cat .claude/spar-reviewer-prompt.txt)"
chk "prompt: no leftover placeholder" 'CLEAN' "$(grep -q '{{' .claude/spar-reviewer-prompt.txt && echo DIRTY || echo CLEAN)"
chk "state → phase review" 'phase: review' "$(cat .claude/spar.local.md)"
chk "state → round 1" 'round: 1' "$(cat .claude/spar.local.md)"
chk "runner targets r1 review file" 'reviews/spar-20260721-120000-abc123-r1.md' "$(cat .claude/spar-run-reviewer.sh)"
chk "runner is read-only sandbox" 'sandbox read-only' "$(cat .claude/spar-run-reviewer.sh)"

echo; echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: FAILs (hook file does not exist yet), non-zero exit.

- [ ] **Step 3: Implement the hook (skeleton + `task` phase)**

`plugins/spar/hooks/stop-hook.sh`:

```bash
#!/usr/bin/env bash
# sparring — Stop hook. Deterministic gatekeeper for the review loop.
#   task   : author finished implementing → prepare round 1, block exit
#   review : a round is in flight → converged / respond / next round / cap
# On any internal error: fail OPEN (approve). Never trap the user.

LOG_FILE=".claude/spar.log"
STATE_FILE=".claude/spar.local.md"
RUNNER=".claude/spar-run-reviewer.sh"
PROMPT_FILE=".claude/spar-reviewer-prompt.txt"
RETRY_FILE=".claude/spar-retries"

log() { mkdir -p "$(dirname "$LOG_FILE")"; echo "[$(date -u +%FT%TZ)] $*" >> "$LOG_FILE"; }
approve() { printf '{"decision":"approve"}\n'; exit 0; }
block() { # $1=reason $2=statusMessage
  jq -n --arg r "$1" --arg s "${2:-sparring}" \
    '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
    || printf '{"decision":"block","reason":"sparring: %s"}\n' "$(echo "$1" | head -1)"
  exit 0
}
cleanup() { rm -f "$STATE_FILE" "$RUNNER" "$PROMPT_FILE" "$RETRY_FILE"; }

trap 'log "ERR trap line $LINENO"; cleanup; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

HOOK_INPUT=$(cat) # consume stdin (hook JSON)

[ -f "$STATE_FILE" ] || approve

field() { sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1; }

ACTIVE=$(field active); PHASE=$(field phase); ROUND=$(field round)
REVIEW_ID=$(field review_id); MAX_ROUNDS=$(field max_rounds)

[ "$ACTIVE" = "true" ] || { cleanup; approve; }
echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' \
  || { log "invalid review_id: $REVIEW_ID"; cleanup; approve; }
case "$ROUND" in ''|*[!0-9]*) log "invalid round: $ROUND"; cleanup; approve;; esac
case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=5;; esac

TASK=$(awk '/^---$/{c++; next} c>=2{print}' "$STATE_FILE")

review_file() { echo "reviews/spar-${REVIEW_ID}-r${1}.md"; }
response_file() { echo "reviews/spar-${REVIEW_ID}-r${1}-response.md"; }

set_state() { # $1=phase $2=round
  local tmp="${STATE_FILE}.tmp.$$"
  awk -v p="$1" -v r="$2" '
    /^phase:/ { print "phase: " p; next }
    /^round:/ { print "round: " r; next }
    { print }' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

prepare_round() { # $1=round number → writes PROMPT_FILE + RUNNER
  local n="$1"
  local tpl_dir="${CLAUDE_PLUGIN_ROOT:-}/shared/prompts"
  [ -f "$tpl_dir/reviewer.md" ] \
    || { log "template missing: $tpl_dir/reviewer.md"; cleanup; approve; }

  local prompt prev_ctx=""
  prompt=$(cat "$tpl_dir/reviewer.md")
  if [ "$n" -gt 1 ]; then
    prev_ctx=$(cat "$tpl_dir/reviewer-prev-context.md")
    prev_ctx=${prev_ctx//\{\{PREV_REVIEW\}\}/$(review_file $((n-1)))}
    prev_ctx=${prev_ctx//\{\{PREV_RESPONSE\}\}/$(response_file $((n-1)))}
  fi
  prompt=${prompt//\{\{TASK\}\}/$TASK}
  prompt=${prompt//\{\{ROUND\}\}/$n}
  prompt=${prompt//\{\{PREV_CONTEXT\}\}/$prev_ctx}

  mkdir -p reviews .claude
  printf '%s' "$prompt" > "$PROMPT_FILE"

  local out; out=$(review_file "$n")
  cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
# sparring reviewer runner — round ${n} (generated; do not edit)
set -uo pipefail
mkdir -p reviews
codex exec --sandbox read-only --skip-git-repo-check \\
  --output-last-message "${out}" "\$(cat "${PROMPT_FILE}")"
EOF
  chmod +x "$RUNNER"
}

command -v codex >/dev/null 2>&1 || {
  log "codex CLI not found"; cleanup
  block "ERROR: Codex CLI not found. Install it (npm install -g @openai/codex), then run /spar again." \
        "sparring: codex missing"
}

case "$PHASE" in
  task)
    prepare_round 1
    set_state review 1
    rm -f "$RETRY_FILE"
    block "Implementation phase done. Round 1 independent review is required.

Run (use a 600000ms timeout — reviews take minutes):
\`\`\`
bash ${RUNNER}
\`\`\`

Then read $(review_file 1):
- STATUS: CONVERGED → simply stop again; the loop will release.
- STATUS: FINDINGS → fix every [MECHANICAL] finding; decide each [DESIGN]
  finding on the merits; then write $(response_file 1) with one section per
  finding ID: 'FIXED — <what you did>' or 'REJECTED — <reason grounded in
  code/requirements>'. Then stop again." \
      "sparring [${REVIEW_ID}] round 1: run reviewer"
    ;;
  *)
    log "unknown phase: $PHASE"; cleanup; approve
    ;;
esac
```

- [ ] **Step 4: Run tests — cases 1–4 pass**

Run: `bash tests/test_stop_hook.sh`
Expected: all PASS, `exit 0`. (`codex` is on PATH in the dev machine; the codex-missing branch is exercised implicitly and not unit-tested — it mirrors the proven upstream pattern.)

- [ ] **Step 5: Commit**

```bash
git add tests/test_stop_hook.sh plugins/spar/hooks/stop-hook.sh
git commit -m "feat: stop hook skeleton + task phase (TDD)"
```

---

### Task 4: Stop hook — review phase (convergence / response gate / rounds / cap)

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` (replace the `*)` fallthrough — add `review)` case before it)
- Modify: `tests/test_stop_hook.sh` (append cases 5–10 before the final summary lines)

**Interfaces:**
- Consumes: `field/approve/block/cleanup/set_state/prepare_round/review_file/response_file` from Task 3.
- Produces: full loop behavior consumed by the `/spar` command (Task 5).

- [ ] **Step 1: Append failing tests (cases 5–10)**

Insert into `tests/test_stop_hook.sh` immediately before the `echo; echo "PASS=$PASS FAIL=$FAIL"` line:

```bash
# helper: enter review phase for round $1
in_review() { fresh_dir; write_state review "$1"; mkdir -p reviews; }
RF1="reviews/spar-20260721-120000-abc123-r1.md"
RP1="reviews/spar-20260721-120000-abc123-r1-response.md"

# ── 5. review file missing → block (retry), 3rd miss → fail-open ──
in_review 1
chk "review missing → block" '"decision":"block"' "$(run_hook)"
run_hook >/dev/null
chk "review missing 3rd → approve" '"decision":"approve"' "$(run_hook)"

# ── 6. CONVERGED → approve + cleanup ──
in_review 1
printf 'STATUS: CONVERGED\n\nChecked diff, tests, security.\n' > "$RF1"
chk "converged → approve" '"decision":"approve"' "$(run_hook)"
chk "converged → state removed" "gone" "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# ── 7. FINDINGS + no response → block asking for response file ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] missing null check\n' > "$RF1"
OUT=$(run_hook)
chk "findings no response → block" '"decision":"block"' "$OUT"
chk "block names response file" "$RP1" "$OUT"

# ── 8. FINDINGS + response → next round prepared ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] missing null check\n' > "$RF1"
printf '### F1-1: FIXED — added guard\n' > "$RP1"
OUT=$(run_hook)
chk "responded → block for round 2" '"decision":"block"' "$OUT"
chk "state advanced to round 2" 'round: 2' "$(cat .claude/spar.local.md)"
chk "r2 prompt references r1 review" "$RF1" "$(cat .claude/spar-reviewer-prompt.txt)"
chk "r2 prompt references r1 response" "$RP1" "$(cat .claude/spar-reviewer-prompt.txt)"
chk "r2 prompt: no leftover placeholder" 'CLEAN' "$(grep -q '{{' .claude/spar-reviewer-prompt.txt && echo DIRTY || echo CLEAN)"
chk "runner targets r2" 'r2.md' "$(cat .claude/spar-run-reviewer.sh)"

# ── 9. round cap → deactivate + final block, then approve ──
in_review 5
RF5="reviews/spar-20260721-120000-abc123-r5.md"
RP5="reviews/spar-20260721-120000-abc123-r5-response.md"
printf 'STATUS: FINDINGS\n\n### F5-1 [DESIGN] split module\n' > "$RF5"
printf '### F5-1: REJECTED — out of scope for this task\n' > "$RP5"
OUT=$(run_hook)
chk "cap → block with unconverged notice" 'unconverged' "$OUT"
chk "cap → deactivated" 'active: false' "$(cat .claude/spar.local.md)"
chk "cap → next stop approves" '"decision":"approve"' "$(run_hook)"

# ── 10. CRLF status line tolerated ──
in_review 1
printf 'STATUS: CONVERGED\r\n' > "$RF1"
chk "CRLF converged → approve" '"decision":"approve"' "$(run_hook)"
```

- [ ] **Step 2: Run tests to verify new cases fail**

Run: `bash tests/test_stop_hook.sh`
Expected: cases 1–4 PASS; cases 5–10 FAIL (hook approves via unknown-phase fallthrough), non-zero exit.

- [ ] **Step 3: Implement the `review` phase**

In `plugins/spar/hooks/stop-hook.sh`, insert this case above the `*)` branch:

```bash
  review)
    RF=$(review_file "$ROUND"); RESP=$(response_file "$ROUND")

    if [ ! -f "$RF" ]; then
      n=$(cat "$RETRY_FILE" 2>/dev/null || echo 0); n=$((n+1))
      if [ "$n" -ge 3 ]; then
        log "reviewer never produced $RF — fail open"; cleanup; approve
      fi
      echo "$n" > "$RETRY_FILE"
      block "Round ${ROUND} review has not been produced yet. Run:
\`\`\`
bash ${RUNNER}
\`\`\`" "sparring [${REVIEW_ID}] round ${ROUND}: reviewer pending"
    fi
    rm -f "$RETRY_FILE"

    STATUS=$(head -1 "$RF" | tr -d '\r')
    if [ "$STATUS" = "STATUS: CONVERGED" ]; then
      log "converged at round $ROUND"; cleanup; approve
    fi

    if [ ! -f "$RESP" ]; then
      block "Round ${ROUND} review has findings you have not responded to.

Read ${RF}. Fix every [MECHANICAL] finding. Decide each [DESIGN] finding on
the merits. Then write ${RESP} with one section per finding ID:
'FIXED — <what you did>' or 'REJECTED — <reason grounded in code or the task
requirements>'. Then stop again." \
        "sparring [${REVIEW_ID}] round ${ROUND}: respond to findings"
    fi

    if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
      log "round cap ${MAX_ROUNDS} reached — unconverged exit"
      tmp="${STATE_FILE}.tmp.$$"
      awk '/^active:/{print "active: false"; next}{print}' "$STATE_FILE" > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
      block "Round cap (${MAX_ROUNDS}) reached and the reviewer has NOT
converged. Do not keep fixing. Report to the user: the loop ended
unconverged — summarize the unresolved findings from ${RF} honestly, then
stop. The loop is now deactivated; your next stop will be released." \
        "sparring [${REVIEW_ID}]: round cap — unconverged"
    fi

    NEXT=$((ROUND + 1))
    prepare_round "$NEXT"
    set_state review "$NEXT"
    block "Response recorded. Round ${NEXT} verification review is required. Run:
\`\`\`
bash ${RUNNER}
\`\`\`
Then handle $(review_file "$NEXT") exactly as before (fix / respond / stop)." \
      "sparring [${REVIEW_ID}] round ${NEXT}: run reviewer"
    ;;
```

- [ ] **Step 4: Run tests — all pass**

Run: `bash tests/test_stop_hook.sh`
Expected: all cases PASS, `PASS=… FAIL=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/test_stop_hook.sh plugins/spar/hooks/stop-hook.sh
git commit -m "feat: stop hook review phase — convergence, response gate, rounds, cap"
```

---

### Task 5: Commands + local install + E2E smoke

**Files:**
- Create: `plugins/spar/commands/spar.md`
- Create: `plugins/spar/commands/spar-cancel.md`

**Interfaces:**
- Consumes: state-file format read by the hook (`active/phase/round/review_id/reviewer/max_rounds` + task body after second `---`); loop protocol from Task 4's block messages.

- [ ] **Step 1: Write `/spar` command**

`plugins/spar/commands/spar.md`:

````markdown
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
cat > .claude/spar.local.md << STATE_EOF
---
active: true
phase: task
round: 0
review_id: ${SPAR_ID}
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

## Hard rules

- Never edit, rewrite, or delete reviewer output files (`reviews/spar-*-r*.md`).
- Never write `STATUS: CONVERGED` anywhere yourself. Convergence is the
  reviewer's call alone.
- Never edit `.claude/spar.local.md` by hand; cancellation is `/spar-cancel`.
- If the hook reports the round cap was reached, summarize the unresolved
  findings to the user honestly — do not present the work as fully converged.
````

- [ ] **Step 2: Write `/spar-cancel` command**

`plugins/spar/commands/spar-cancel.md`:

````markdown
---
description: "Cancel the active sparring loop and clean up its state"
---

Run this cleanup command, then confirm cancellation to the user:

```bash
rm -f .claude/spar.local.md .claude/spar-run-reviewer.sh .claude/spar-reviewer-prompt.txt .claude/spar-retries
echo "Sparring loop cancelled. Review artifacts in reviews/ were kept."
```
````

- [ ] **Step 3: Commit**

```bash
git add plugins/spar/commands && git commit -m "feat: /spar and /spar-cancel commands"
```

- [ ] **Step 4: Install plugin locally**

```bash
claude plugin marketplace add ~/Workspace/sparring
claude plugin install spar@sparring
```

Expected: install succeeds; `claude plugin list` (or `/plugin` in a session) shows `spar`.

- [ ] **Step 5: E2E smoke — real mini task through the full loop**

```bash
mkdir -p /tmp/spar-smoke && cd /tmp/spar-smoke && git init -q
claude "/spar Add fizzbuzz.py with a fizzbuzz(n) function returning 'Fizz'/'Buzz'/'FizzBuzz'/str(n), plus a test_fizzbuzz.py runnable with python3 -m unittest, and run the tests"
```

Manual verification checklist (all must hold):
- [ ] Setup prints `Sparring loop activated (...)`.
- [ ] After implementation, the hook blocks and Claude runs the runner (Codex output visible).
- [ ] `reviews/spar-<id>-r1.md` exists, first line is `STATUS: FINDINGS` or `STATUS: CONVERGED`.
- [ ] If findings: fixes applied, `...-r1-response.md` written with FIXED/REJECTED sections, round 2 runs.
- [ ] Session ends only after a review file whose first line is `STATUS: CONVERGED` (or explicit cap notice).
- [ ] `.claude/spar.local.md` is gone after exit; `reviews/` artifacts remain.
- [ ] `git -C /tmp/spar-smoke status` shows only intended files (fizzbuzz, tests, reviews/).

- [ ] **Step 6: Record smoke result + commit any fixes**

If the smoke run surfaced hook/command bugs, fix them, re-run `bash tests/test_stop_hook.sh`, and commit with `fix:` messages. Then tag the phase:

```bash
git add -A && git commit -m "chore: phase 1 smoke verified" --allow-empty
```
</br>

---

## Self-Review Notes

- Spec coverage: forced review (hooks.json+stop-hook), requirement-aware review (TASK in template), convergence loop (round machinery), respond-before-next-round (RESP gate), round cap with honest unconverged exit, read-only reviewer, fail-open, single-writer + reviewer-declares (command hard rules + policy.md). Phase 2+ items intentionally out of scope (Global Constraints).
- Type/name consistency: `field/approve/block/cleanup/set_state/prepare_round/review_file/response_file` defined in Task 3, consumed in Task 4; file paths identical across tasks (`spar-<id>-r<N>[-response].md`).
- Placeholder scan: none — all steps carry full file contents/commands.
