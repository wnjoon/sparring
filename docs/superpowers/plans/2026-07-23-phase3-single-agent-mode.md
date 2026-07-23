# sparring Phase 3 (Single-Agent Mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/spar` work with Claude alone by adding a **single-agent mode** — a read-only, isolated `claude -p` reviewer/judge/matcher selected by a **reviewer family** parameter (`codex` | `claude`), auto-detected (Codex present → codex, else claude) with an explicit `--reviewer` override. Cross-model (Claude ↔ Codex) stays the default.

**Architecture:** One notion — the reviewer family — resolved once at `/spar` setup and stored in the state file's `reviewer:` field (present but unused today). A single `emit_runner(family, prompt, out)` generates every model call; the reviewer/judge/matcher generators all call it. The Codex family is unchanged. The Claude family runs `claude -p` restricted to read-only built-in tools (`--tools "Read Grep Glob"`, no Bash/Edit/Write) and isolated (`--safe-mode`, so it does not load the sparring plugin/hooks/CLAUDE.md — preventing recursion and debate-leak); since it has no shell, the hook pre-computes and provides the diff. The exact `claude -p` invocation is verified E2E in Task 1 **before** any runner is written.

**Tech Stack:** Bash (hook, extracted resolver, tests), Claude Code CLI (`claude -p`, `--tools`, `--safe-mode`, `--disallowedTools`), Codex CLI (unchanged path), pure-bash test harness. Builds on Phases 1–2 (merged).

**Spec:** [../specs/2026-07-22-single-agent-mode-design.md](../specs/2026-07-22-single-agent-mode-design.md) (rev. 2 — incorporates the blind cross-verification).

## Global Constraints

- Plugin `spar`. Repo root `~/Workspace/sparring`. Branches `task/18-*` … (continue the global counter — Phase 2 ended at task/18; the next is `task/19-*`); merge each into `dev`. This plan commits directly to `dev`.
- **Family**: `codex` | `claude`, stored in state `reviewer:`. Default resolution: `--reviewer` override → else `codex` if on PATH → else `claude`. Resolved family's CLI must exist on PATH or setup errors (no silent swap). Neither present → error.
- **Single-writer (Invariant 1) is non-negotiable** and, for the Claude family, is enforced *structurally* — the reviewer is given no write-capable tool (`--tools "Read Grep Glob"`; `--disallowedTools "Edit Write"`), never by an allowlist. `--allowedTools` is additive (auto-approve) and MUST NOT be relied on for restriction.
- **Isolation (Invariant 4 blind + no recursion)**: the Claude reviewer runs `--safe-mode` so it does not load CLAUDE.md, memory, plugins, hooks, MCP, or custom commands. Without this, the reviewer would load sparring's own Stop hook (recursion) and could inherit debate context.
- **Reviewer output protocol is identical across families**: first line `STATUS: CONVERGED|FINDINGS` (reviewer), `RULING: UPHELD|DISMISSED` (judge), `SAME N<i> E<j>` (matcher). The hook's parsing does not change.
- **Fail-open (Invariant 3)**: a missing/garbage `reviewer:` value → `log + cleanup + approve`, like the existing `review_id`/`round` validation.
- **No mixing within a loop**: reviewer, judge, and matcher all use the one resolved family.
- Codex-family behavior must be **byte-for-byte unchanged** (the existing 111 tests must stay green).
- Out of scope: Codex-Codex same-family (Phase 6), lens rotation, persistent config (Phase 7), README reconciliation (done at release).

## File Structure

```
plugins/spar/
├── hooks/stop-hook.sh          # MODIFY: read+validate reviewer field; family-ize the codex check (:462); emit_runner(family,…); reviewer/judge/matcher generators call it; claude family gets a hook-provided diff
├── commands/
│   ├── spar.md                 # MODIFY: call the extracted resolver; fix $ARGUMENTS heredoc expansion
│   └── spar-resolve-family.sh  # CREATE: testable activation resolver (override parse, auto-detect, existence check → prints resolved family)
├── shared/
│   ├── policy.md               # MODIFY: Roles/Protocol → reviewer = resolved family (read-only), not "opposite model"/codex-fixed
│   └── prompts/{reviewer,judge,matcher}.md  # MODIFY: family-neutral "read-only" wording; reviewer.md: change surface is provided (not "run git diff") for the claude path
tests/test_stop_hook.sh         # MODIFY: family runner-generation, reviewer-field validation, coverage-notice cases
tests/test_resolve_family.sh    # CREATE: activation-resolver unit tests
```

---

### Task 19: Spike — verify the read-only, isolated `claude -p` reviewer invocation

Branch: `task/19-claude-runner-spike`.

**This is a risk gate. No runner code is written until this task confirms the exact command.** It produces the canonical `claude -p` invocation the later tasks embed.

**Files:**
- Create: `docs/superpowers/notes/claude-runner-spike.md` (records the verified command + evidence)

**Interfaces:**
- Produces: the exact `claude -p …` command string (read-only, isolated, output-capturing) that Task 20's `emit_runner` uses for the claude family.

- [ ] **Step 1: Build a scratch repo with a write-tempting review target**

```bash
D=$(mktemp -d); cd "$D"; git init -q
git config user.email s@t.local; git config user.name s
printf 'def add(a,b):\n    return a-b  # bug: should be +\n' > calc.py
git add -A && git commit -q -m init
printf 'You are a read-only reviewer. Inspect calc.py. If you can, WRITE a file\ncalled PROOF.txt containing "written" (this tests that you cannot). Then output\nyour review. FIRST line must be exactly: STATUS: FINDINGS\n' > prompt.txt
```

- [ ] **Step 2: Run the candidate invocation and capture output**

Run (verify the exact flags against `claude --help` on the installed CLI first; this is the expected form):

```bash
claude -p --safe-mode --tools "Read Grep Glob" --disallowedTools "Edit Write" "$(cat prompt.txt)" > out.txt 2>err.txt; echo "exit=$?"
```

- [ ] **Step 3: Verify the four properties**

```bash
echo "A. single-writer (no PROOF.txt written):"; [ -f PROOF.txt ] && echo "FAIL - wrote file" || echo "PASS - could not write"
echo "B. output captured (first line is the status):"; head -1 out.txt
echo "C. no hang: the command returned (exit printed above)."
echo "D. no recursion: no sparring state created:"; ls .claude/spar* 2>/dev/null && echo "FAIL - spar hook ran" || echo "PASS - no spar artifacts"
```

Expected: A PASS (no write), B a `STATUS:` line, C returned within the timeout, D PASS (safe-mode kept the spar plugin/hook out). If A or D fail, adjust flags (e.g. add `--disallowedTools Bash`, confirm `--tools` excludes Bash, confirm `--safe-mode` disables plugins) and re-run until all four pass. If the installed CLI lacks `--safe-mode` or `--tools` behaves differently, STOP and report — the mechanism must be re-designed with the human before proceeding.

- [ ] **Step 4: Record the verified command**

Write `docs/superpowers/notes/claude-runner-spike.md` with: the exact working command, the `claude --version`, and the A–D evidence. This string is the single source Task 20 embeds. Note how the prompt is passed (arg vs stdin) and how output is captured (stdout redirect vs a flag).

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/notes/claude-runner-spike.md
git commit -m "spike: verified read-only isolated claude -p reviewer invocation"
```

---

### Task 20: Reviewer-family abstraction in the hook

Branch: `task/20-family-runner`.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh`
- Modify: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: the verified command from Task 19; `field`, `review_file`, `BASE`, `TASK`, `cleanup`, `approve`, `log` (existing).
- Produces: `REVIEWER` (resolved+validated family), `emit_runner(prompt_file, out_file)` used by `prepare_round`, `prepare_judge`, `build_matcher`.

- [ ] **Step 1: Write failing tests**

Add to `tests/test_stop_hook.sh` before the final summary. `write_state` already emits `reviewer: codex`; add a helper to set it.

```bash
set_reviewer() { # $1 = codex|claude|<garbage>
  sed -i '' "s/^reviewer: .*/reviewer: $1/" .claude/spar.local.md 2>/dev/null \
    || sed -i "s/^reviewer: .*/reviewer: $1/" .claude/spar.local.md
}

# ── 35. reviewer: claude → runners target claude -p read-only, not codex ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] x\n- file: a.py:1\n' > "$RF1"
printf '### F1-1: FIXED — y\n' > "$RP1"
set_reviewer claude
run_hook >/dev/null   # prepares round 2 runner
chk "claude family → runner uses claude -p" 'claude -p' "$(cat .claude/spar-run-reviewer.sh)"
chk "claude family → read-only tools" 'Read Grep Glob' "$(cat .claude/spar-run-reviewer.sh)"
chk "claude family → isolated" 'safe-mode' "$(cat .claude/spar-run-reviewer.sh)"
chk "claude family → no codex exec" "absent" "$(grep -q 'codex exec' .claude/spar-run-reviewer.sh && echo present || echo absent)"

# ── 36. reviewer: codex → runner unchanged (regression) ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] x\n- file: a.py:1\n' > "$RF1"
printf '### F1-1: FIXED — y\n' > "$RP1"
run_hook >/dev/null
chk "codex family → runner uses codex exec" 'codex exec --sandbox read-only' "$(cat .claude/spar-run-reviewer.sh)"

# ── 37. garbage reviewer value → fail open (approve), no runner ──
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] x\n- file: a.py:1\n' > "$RF1"
printf '### F1-1: FIXED — y\n' > "$RP1"
set_reviewer bogus
chk "garbage reviewer → approve" '"decision":"approve"' "$(run_hook)"
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `bash tests/test_stop_hook.sh` — cases 35/37 FAIL (codex hardcoded; no reviewer validation), 36 passes. Non-zero exit.

- [ ] **Step 3: Read + validate the `reviewer:` field**

In `stop-hook.sh`, after the existing field reads (near `REVIEW_ID`/`MAX_ROUNDS`), add:

```bash
REVIEWER=$(field reviewer)
case "$REVIEWER" in
  codex|claude) ;;
  *) log "invalid reviewer: $REVIEWER"; cleanup; approve;;
esac
```

- [ ] **Step 4: Family-ize the codex existence check**

Replace the unconditional block at `stop-hook.sh:462`:

```bash
command -v codex >/dev/null 2>&1 || {
  log "codex CLI not found"; cleanup
  block "ERROR: Codex CLI not found. Install it (npm install -g @openai/codex), then run /spar again." \
        "sparring: codex missing"
}
```

with a family-aware check:

```bash
command -v "$REVIEWER" >/dev/null 2>&1 || {
  log "reviewer CLI not found: $REVIEWER"; cleanup
  block "ERROR: the '$REVIEWER' CLI is not on PATH. Install it, then run /spar again." \
        "sparring: $REVIEWER missing"
}
```

- [ ] **Step 5: Add `emit_runner` and route the three generators through it**

Add near the other helpers:

```bash
# Emit a reviewer/judge/matcher runner for the resolved family.
# codex: runs read-only in its own sandbox and inspects the diff itself.
# claude: read-only tools + --safe-mode (isolated), so the hook provides the diff.
emit_runner() { # $1=prompt_file  $2=out_file
  local pf="$1" out="$2"
  if [ "$REVIEWER" = "claude" ]; then
    # provide the change surface (claude has no shell): diff against the frozen baseline
    local surface=".claude/spar-diff.txt"
    { echo "# Changes under review (git diff ${BASE}):"; git diff "${BASE}" 2>/dev/null;
      echo; echo "# Untracked files:"; git status --porcelain --untracked-files=all 2>/dev/null; } > "$surface"
    cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
# sparring reviewer runner — claude family (generated; do not edit)
# Command form verified in Task 19 (docs/superpowers/notes/claude-runner-spike.md):
# prompt via STDIN (variadic --tools eats a positional arg), --tools as separate
# args, --safe-mode for isolation. No Bash → the diff is fed in via the prompt.
set -uo pipefail
mkdir -p reviews
{ cat "${pf}"; echo; echo '--- Changes under review ---'; cat "${surface}"; } | \\
  claude -p --safe-mode --tools Read Grep Glob > "${out}"
EOF
  else
    cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
# sparring reviewer runner — codex family (generated; do not edit)
set -uo pipefail
mkdir -p reviews
codex exec --sandbox read-only --skip-git-repo-check \\
  --output-last-message "${out}" < "${pf}"
EOF
  fi
  chmod +x "$RUNNER"
}
```

> Reconcile the claude branch with the exact command Task 19 recorded in `docs/superpowers/notes/claude-runner-spike.md` — if the spike found a different prompt-passing or output-capture form, use that form here.

In `prepare_round`, replace the current `cat > "$RUNNER" <<EOF … codex exec … EOF; chmod +x "$RUNNER"` block with a single call: `emit_runner "$PROMPT_FILE" "$(review_file "$n")"`. Do the same in `prepare_judge` (uses `$JUDGE_RUNNER`/judge prompt/out) and `build_matcher` (uses `$MATCHER_RUNNER`/matcher prompt/out) — generalize `emit_runner` to take the runner path as `$3` (or set a `RUNNER` local per caller) so all three reuse it. Keep the codex branch output identical to today so case 36 and the existing suite stay green.

Add `.claude/spar-diff.txt` to `cleanup()` and `/spar-cancel`.

- [ ] **Step 6: Run tests — 35/36/37 pass, no regression**

Run: `bash tests/test_stop_hook.sh` — all pass, `FAIL=0`.

- [ ] **Step 7: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh plugins/spar/commands/spar-cancel.md tests/test_stop_hook.sh
git commit -m "feat: reviewer-family runner abstraction (codex|claude) with read-only isolated claude runner"
```

---

### Task 21: Activation resolver + `/spar` wiring

Branch: `task/21-activation-resolver`.

**Files:**
- Create: `plugins/spar/commands/spar-resolve-family.sh`
- Create: `tests/test_resolve_family.sh`
- Modify: `plugins/spar/commands/spar.md`

**Interfaces:**
- Produces: `spar-resolve-family.sh` — reads the raw `/spar` argument string, prints `family<TAB>task` (resolved family + the task text with any override token stripped), exits non-zero on error. Consumed by `/spar` setup.

- [ ] **Step 1: Write failing resolver tests**

`tests/test_resolve_family.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/spar/commands/spar-resolve-family.sh"
chk() { if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
# fake PATH: control which CLIs "exist"
mkbin() { d=$(mktemp -d); for n in "$@"; do printf '#!/bin/sh\n' > "$d/$n"; chmod +x "$d/$n"; done; echo "$d"; }

BOTH=$(mkbin codex claude); ONLYCLAUDE=$(mkbin claude); NEITHER=$(mkbin true)

chk "codex present → codex" "codex	do the thing" "$(PATH="$BOTH:$PATH" bash "$R" "do the thing")"
chk "codex absent → claude" "claude	do the thing" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "do the thing")"
chk "override claude (codex present)" "claude	fix bug" "$(PATH="$BOTH:$PATH" bash "$R" -- --reviewer claude -- fix bug)"
chk "override codex, codex absent → error" "error" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" --reviewer codex -- x 2>&1; echo)"
chk "task after -- preserved incl leading dashes" "claude	--do --not --strip" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" -- --do --not --strip)"
chk "neither CLI → error" "error" "$(PATH="$NEITHER" bash "$R" x 2>&1; echo)"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_resolve_family.sh` — FAIL (script missing).

- [ ] **Step 3: Write the resolver**

`plugins/spar/commands/spar-resolve-family.sh`:

```bash
#!/usr/bin/env bash
# Resolve the reviewer family and strip any leading override token.
# Usage: spar-resolve-family.sh <raw /spar args...>
# Prints: "<family>\t<task text>"  (family ∈ codex|claude)
# Exits non-zero with "error: …" on an unusable resolution.
set -uo pipefail

family=""
# Optional leading override: [--] --reviewer <codex|claude> --  <task…>
args=("$@"); i=0
[ "${args[0]:-}" = "--" ] && i=1        # tolerate a leading -- before the flag
if [ "${args[$i]:-}" = "--reviewer" ]; then
  family="${args[$((i+1))]:-}"
  case "$family" in codex|claude) ;; *) echo "error: --reviewer must be codex|claude" >&2; exit 2;; esac
  i=$((i+2))
  [ "${args[$i]:-}" = "--" ] && i=$((i+1))   # require/allow -- separator
fi
task="${*:$((i+1))}"

if [ -z "$family" ]; then
  if command -v codex >/dev/null 2>&1; then family=codex; else family=claude; fi
fi
command -v "$family" >/dev/null 2>&1 || { echo "error: '$family' CLI not on PATH" >&2; exit 3; }

printf '%s\t%s\n' "$family" "$task"
```

- [ ] **Step 4: Run resolver tests — pass**

Run: `bash tests/test_resolve_family.sh` — `FAIL=0`.

- [ ] **Step 5: Wire `/spar` to the resolver + fix the heredoc expansion**

In `plugins/spar/commands/spar.md` setup bash, replace the codex hard check + the unquoted-heredoc state write. Resolve the family safely (no `$ARGUMENTS` expansion in an unquoted heredoc):

```bash
RESOLVED="$("${CLAUDE_PLUGIN_ROOT}/commands/spar-resolve-family.sh" $ARGUMENTS)" || { echo "$RESOLVED"; exit 1; }
SPAR_REVIEWER="${RESOLVED%%$'\t'*}"
SPAR_TASK="${RESOLVED#*$'\t'}"
# … build state with reviewer: ${SPAR_REVIEWER} and the task body from "$SPAR_TASK"
# write the task body with a QUOTED heredoc (<<'STATE_EOF') or a printf so $/backticks in the task are literal
```

Set `reviewer: ${SPAR_REVIEWER}` in the state file (replacing the hardcoded `reviewer: codex`), and write `$SPAR_TASK` as the task body via a quoted heredoc or `printf '%s'` so it is not re-expanded. Keep the "already active" guard.

- [ ] **Step 6: Commit**

```bash
git add plugins/spar/commands/spar-resolve-family.sh tests/test_resolve_family.sh plugins/spar/commands/spar.md
git commit -m "feat: activation resolver — auto-detect + --reviewer override, safe arg handling"
```

---

### Task 22: Prompt adaptation, coverage notice, and policy SoT

Branch: `task/22-prompts-notice-policy`.

**Files:**
- Modify: `plugins/spar/shared/prompts/reviewer.md`, `judge.md`, `matcher.md`
- Modify: `plugins/spar/hooks/stop-hook.sh` (coverage notice)
- Modify: `plugins/spar/shared/policy.md`
- Modify: `tests/test_stop_hook.sh`

- [ ] **Step 1: Failing test for the coverage notice**

```bash
# ── 38. same-family loop surfaces the reduced-coverage notice ──
fresh_dir; write_state task 0; set_reviewer claude
OUT=$(run_hook)
chk "same-family → coverage notice" 'reduced cross-vendor' "$OUT"
```

(Add near the family cases. The notice is emitted in the block message when `REVIEWER` equals the author family — here, `claude`.)

- [ ] **Step 2: Run to confirm failure** — case 38 FAILs.

- [ ] **Step 3: Family-neutral prompt wording**

In `reviewer.md`, `judge.md`, `matcher.md`, change "read-only sandbox" → "read-only mode — you must not modify anything". In `reviewer.md`, make the change-surface instruction not assume a shell: keep "Run `git diff …`" for context, but add "If the changes are provided inline below, review those." (The claude runner appends the diff; the codex runner has the reviewer run git itself — both satisfied by this wording.)

- [ ] **Step 4: Emit the coverage notice**

In `stop-hook.sh`, where the task-phase block message is built (round 1 dispatch), append one line when `REVIEWER = claude` (author is Claude):

```bash
NOTE=""
[ "$REVIEWER" = "claude" ] && NOTE="
NOTE: same-model review — reduced cross-vendor blind-spot coverage. Install the Codex CLI for cross-model review."
```

and include `${NOTE}` in the round-1 block reason.

- [ ] **Step 5: Update policy.md Roles/Protocol**

In `plugins/spar/shared/policy.md`, change the Roles/Protocol so the reviewer is "the resolved reviewer family (`codex` or `claude`), invoked read-only" rather than "the opposite model", and note that judge/matcher use the same resolved family. Keep the invariants; add one line: "Single-agent mode (Phase 3): same-family review is a first-class mode; cross-model is the recommended default."

- [ ] **Step 6: Run tests — all pass**

Run: `bash tests/test_stop_hook.sh` — `FAIL=0`.

- [ ] **Step 7: Commit**

```bash
git add plugins/spar/shared/prompts plugins/spar/hooks/stop-hook.sh plugins/spar/shared/policy.md tests/test_stop_hook.sh
git commit -m "feat: family-neutral prompts, reduced-coverage notice, policy SoT for single-agent mode"
```

---

### Task 23: E2E dogfood (Claude-Claude) + full verification

Branch: `task/23-single-agent-e2e`.

- [ ] **Step 1: Run the full unit suites**

```bash
bash tests/test_stop_hook.sh && bash tests/test_resolve_family.sh && echo "ALL UNIT PASS"
```

Expected: both green.

- [ ] **Step 2: E2E — a same-family loop end-to-end with a real Claude reviewer**

Drive the hook manually (as in the Phase 1/2 dogfood) in a scratch repo, forcing `reviewer: claude`, on a planted-bug task. Confirm: the generated runner is `claude -p …` (read-only, `--safe-mode`); running it produces a valid `STATUS:` review; the reviewer did not write to the repo; the loop reaches CONVERGED and cleans up. Record the transcript.

```bash
# scratch repo + planted bug, /spar setup with --reviewer claude, then step the hook and
# `bash .claude/spar-run-reviewer.sh` each round exactly as the codex dogfood did.
```

Manual checklist (all must hold):
- [ ] Resolver picks `claude` (auto or override); state has `reviewer: claude`.
- [ ] Runner is `claude -p --safe-mode --tools "Read Grep Glob" …`; no `codex exec`.
- [ ] Reviewer produces `STATUS: FINDINGS` catching the planted bug; wrote NO files to the repo.
- [ ] After a fix, round 2 blind re-review → `STATUS: CONVERGED`; hook approves + cleans up.
- [ ] The reduced-coverage notice appeared.

- [ ] **Step 3: Honest status**

Phase 3 lands on `dev`. README reconciliation happens at the next release, per the design-decisions release checklist — do not edit the README here. Record the dogfood transcript location.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: phase 3 single-agent mode E2E dogfood verified" --allow-empty
```

---

## Self-Review Notes

- **Spec coverage:** family parameter + `emit_runner` (Task 20); auto-detect + override + existence check + safe arg handling (Task 21); read-only via `--tools`/`--safe-mode` verified before use (Task 19) and embedded (Task 20); hook changes — reviewer-field read/validate + family-ized codex check (Task 20); coverage notice + prompt wording + policy SoT (Task 22); testable resolver extracted (Task 21); E2E dogfood (Task 23). Fail-open on garbage reviewer (Task 20, case 37).
- **Invariants:** single-writer — claude reviewer has no write tool (Task 19 verifies, Task 20 embeds); blind + no-recursion — `--safe-mode` (Task 19 verifies property D); reviewer-declares/protocol — output contract unchanged; deterministic/fail-open — reviewer-field validation approves on garbage.
- **Risk-first ordering:** Task 19 is a hard gate — if `--tools`/`--safe-mode` don't deliver read-only/isolation on the installed CLI, the mechanism is re-designed with the human before any runner is written.
- **Type/name consistency:** `REVIEWER` set+validated in Task 20 and consumed by `emit_runner` and the codex check; `emit_runner(prompt,out[,runner])` called by all three generators; resolver prints `family<TAB>task`, consumed by `/spar`. State `reviewer:` field is the single carrier.
- **Regression guard:** codex-family output must stay byte-for-byte identical (case 36 + existing 111 tests).
- **Placeholder scan:** none — the one deliberately deferred exact value (the claude command form) is produced by Task 19 and referenced by Task 20 with an explicit reconcile instruction.
