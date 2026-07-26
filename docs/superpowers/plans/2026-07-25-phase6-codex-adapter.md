# Phase 6 — Codex-hosted Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Codex CLI session author under the same enforced review loop — Codex authors, `claude -p` reviews, and Codex's own `Stop` hook makes the loop non-optional.

**Architecture:** No second gatekeeper. Codex registers the *same two scripts* the Claude adapter registers (`stop-fight.sh` on `Stop`, `session-start.sh` on `SessionStart`) through a `hooks.json`, and gets its command surface as Codex skills. Three small, default-safe changes to the shared engine make it seat-aware; everything else is reused untouched.

**Tech Stack:** POSIX-ish bash (plugin scripts + hooks), Codex CLI 0.144.1 hooks and skills, pure-bash test scripts under `tests/`.

**Source spec:** `docs/superpowers/specs/2026-07-25-phase6-codex-adapter-design.md` (design-complete, blind cross-verified). Evidence for the enforcement premise: `docs/superpowers/notes/codex-hooks-spike.md`.

---

## Global Constraints

- **Claude-side behavior must not change.** Every engine change here is gated on a state field that is *absent* in existing runs, so the default path is bit-identical to today. All 19 existing suites must stay green after every task.
- **Fail-open stays.** A broken or missing hook must never trap a session. Task 1 makes one silent failure loud; it must not make it trapping.
- **Never claim unobserved enforcement.** If the hook cannot be confirmed live, the skill says so plainly rather than implying the loop is enforced (spec §6).
- **Do not touch the change-surface code** in `spar-report.sh` (`changed_files`, `dir_prefix`, `dir_is_cwd`, `untracked_files`, `CWD_REV`/`CWD_STATE`). Finished in an earlier phase; out of scope.
- **No risky-path change.** The spec's first revision claimed `.codex/hooks.json` escapes `spar-classify-change.sh`; that was **measured false** and retracted (spec §2.1d). Do not "fix" it. If a reviewer raises it, quote the measurement: `touched_risk: true, touched_reasons: hooks-enforcement`.
- **Test harness detail:** `tests/test_stop_hook.sh`'s `chk` uses `grep -qF "$2"` **without** `--`, so no expectation there may start with `-`. It also stubs `codex`/`claude` on `PATH` via `STUB_BIN` — new tests that depend on a CLI being absent must use `SYS_PATH`.
- **No version bump.** `plugin.json` stays at `0.6.0`; release is separate.

---

### Task 1: Make the engine self-locating

`stop-hook.sh` resolves five sibling scripts and four template dirs from `CLAUDE_PLUGIN_ROOT`. With it unset the engine cannot find `shared/prompts/reviewer.md`, takes `finish_approve error-bypass`, and — because the outcome writer path is broken the same way — records **no durable outcome**. The author sees a session that merely ended. Deriving the root from the script's own location removes the failure class for both hosts.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` (the path block at lines 40-45; templates at 503, 548, 652, 686)
- Modify: `plugins/spar/hooks/stop-fight.sh` (same treatment, lines 10 and 15)
- Test: `tests/test_stop_hook.sh`, `tests/test_stop_fight.sh`

**Interfaces:**
- Produces: `PLUGIN_ROOT` — an absolute path resolved as `${CLAUDE_PLUGIN_ROOT:-<dir of this script>/..}`. Every later task and both hooks read this instead of `CLAUDE_PLUGIN_ROOT` directly.
- The env var keeps priority when set, so the Claude host and every existing test are unaffected.

- [x] **Step 1: Write the failing test**

Append to `tests/test_stop_hook.sh`, before the final PASS/FAIL lines:

```bash
# ── self-location: the engine must work without CLAUDE_PLUGIN_ROOT ──
# With the var unset the engine used to fail open SILENTLY: no round dispatched,
# no outcome recorded, state deleted. It must instead behave exactly as it does
# with the var set, by locating its siblings from its own path.
fresh_dir; write_state task 0; mkdir -p reviews
OUT=$(env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" <<< '{}')
chk "no plugin root → still dispatches round 1" "spar-run-reviewer.sh" "$OUT"
chk_file "no plugin root → runner written" ".claude/spar-run-reviewer.sh"
chk "no plugin root → prompt carries the task" "fizzbuzz" \
  "$(cat .claude/spar-reviewer-prompt.txt 2>/dev/null)"
chk "no plugin root → state advanced" "phase: review" "$(cat .claude/spar.local.md 2>/dev/null)"

# And the terminal path still records a durable outcome without the var.
fresh_dir; write_state review 1; mkdir -p reviews
converged_no_sweep
env -u CLAUDE_PLUGIN_ROOT bash "$HOOK" <<< '{}' >/dev/null
chk "no plugin root → outcome still recorded" "reason: converged" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
```

Append to `tests/test_stop_fight.sh`, before its final PASS/FAIL lines (match that file's own helper names when wiring the fixture — read the top of the file first):

A grep-only assertion is not enough here — it would stay green if `PLUGIN_ROOT`
resolved to the wrong directory. Add a **behavioral** case instead: `setup`, then
`unset SPAR_FIGHT_SPAR_HOOK` so no engine stub is interposed, stub `codex`/`claude`
on `PATH` (the engine refuses to dispatch without a reviewer CLI, and this suite
must stay hermetic), write a real `phase: task` spar state, and invoke the
dispatcher with `env -u CLAUDE_PLUGIN_ROOT`. Assert effects, not text: round 1
dispatched, runner written, the prompt contains the task string (which proves the
*templates* resolved too), and the state advanced to `phase: review`. See
`tests/test_stop_fight.sh` for the landed version.

- [x] **Step 2: Run the tests to verify they fail**

```bash
bash tests/test_stop_hook.sh
```
Expected: the four `no plugin root` checks FAIL — currently the engine dispatches nothing and writes no outcome when the variable is unset.

- [x] **Step 3: Resolve the root from the script's own location**

In `plugins/spar/hooks/stop-hook.sh`, immediately above the `OUTCOME_WRITER=` line (currently 40), insert:

```bash
# Resolve the plugin root from this script's own location so the engine works
# under any host that does not export CLAUDE_PLUGIN_ROOT (Codex registers hooks
# from a project/user hooks.json, which has no env field). The env var still wins
# when set, so the Claude host and existing tests are unaffected. Without this the
# engine failed open SILENTLY — it could not find its templates, and the outcome
# writer was broken by the same missing root, so nothing was recorded.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || PLUGIN_ROOT=""
fi
```

Then replace `${CLAUDE_PLUGIN_ROOT:-}` with `${PLUGIN_ROOT}` in all nine places: the five path variables (lines 40-45) and **all four** `tpl_dir` assignments (503, 548, 652, and `build_matcher`'s at 686 — missing that one silently disables semantic matching).

In `plugins/spar/hooks/stop-fight.sh`, apply the same pattern above its line 10:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || PLUGIN_ROOT=""
fi
```

and use it for `DIR` and for the `SPAR_HOOK` default, keeping the `SPAR_FIGHT_SPAR_HOOK` override first.

- [x] **Step 4: Run the tests to verify they pass**

```bash
bash tests/test_stop_hook.sh
bash tests/test_stop_fight.sh
```
Expected: `FAIL=0` for both.

- [x] **Step 5: Run the whole suite**

```bash
for t in tests/test_*.sh; do printf '%-34s ' "$t"; bash "$t" >/dev/null 2>&1 && echo OK || echo FAILED; done
```
Expected: every line `OK`.

- [x] **Step 6: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh plugins/spar/hooks/stop-fight.sh tests/test_stop_hook.sh tests/test_stop_fight.sh
git commit -m "fix: resolve the plugin root from the script's own path (was a silent fail-open)"
```

---

### Task 2: `author` field — the sweep follows the author family

The final sweep is meant to be a *fresh author-family* instance, but it is hardcoded to `claude`: `emit_sweep_runner` writes a runner calling `claude -p --safe-mode` and the dispatch guard checks `command -v claude`. With the seats swapped the author is Codex, so the sweep must be `codex exec --sandbox read-only` — otherwise the "same family, no context" property the sweep exists for is lost.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` (state parsing near 133-152; `emit_sweep_runner` 440-500; the guard at 894-895; the reviewer notice at 844-845)
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: `PLUGIN_ROOT` (Task 1).
- Produces: state field `author: claude|codex`, defaulting to `claude` when absent or empty; an invalid value is an internal-state error (`error-bypass`), matching how `unattended`, `include_dirty`, and `reviewer` are validated. Later tasks write this field at activation.

- [x] **Step 1: Write the failing test**

Append to `tests/test_stop_hook.sh`, before the final PASS/FAIL lines:

```bash
# ── author family: the sweep must follow the AUTHOR, not always claude ──
add_author() { # $1=value
  sed -i '' "s/^reviewer: /author: $1\nreviewer: /" .claude/spar.local.md 2>/dev/null \
    || sed -i "s/^reviewer: /author: $1\nreviewer: /" .claude/spar.local.md
}
sweep_fixture() { # a converged round that triggers the sweep (3+ rounds does it)
  fresh_dir; write_state review 3; mkdir -p reviews
  printf 'STATUS: CONVERGED\n\nAll good.\n' > reviews/spar-20260721-120000-abc123-r3.md
}

# default (no author field) → claude sweep runner, exactly as today
sweep_fixture
run_hook >/dev/null
chk "no author field → claude sweep runner" "claude -p --safe-mode" \
  "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"

# author: codex → codex sweep runner
sweep_fixture; add_author codex
run_hook >/dev/null
chk "author codex → codex sweep runner" "codex exec" "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"
chk "author codex → sweep stays read-only" "read-only" "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"
# codex writes its own output file from inside the snapshot subshell, so the path
# must be absolute — a relative $tmp would land in the throwaway snapshot.
chk "author codex → absolute output path" 'output-last-message "$source_root/$tmp"' \
  "$(cat .claude/spar-run-sweep.sh 2>/dev/null)"
chk_absent_hook() { if printf '%s' "$2" | grep -qF "$1"; then echo "FAIL: $3"; FAIL=$((FAIL+1)); else echo "PASS: $3"; PASS=$((PASS+1)); fi; }
chk_absent_hook "claude -p" "$(cat .claude/spar-run-sweep.sh 2>/dev/null)" "author codex → no claude in the sweep runner"

# invalid author → internal-state error, fail open, never silently claude
sweep_fixture; add_author bogus
chk "invalid author → approve (fail open)" '"decision":"approve"' "$(run_hook)"
chk "invalid author → error-bypass outcome" "reason: error-bypass" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"

# the cross-model notice must key off the pairing, not the reviewer alone
fresh_dir; write_state task 0; mkdir -p reviews; add_author codex
sed -i '' 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md
OUT=$(run_hook)
chk_absent_hook "same-model review" "$OUT" "codex author + claude reviewer → not called same-model"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_stop_hook.sh`
Expected: `author codex → codex sweep runner`, the no-claude check, the invalid-author checks, and the notice check FAIL. The default-path check should already PASS.

- [x] **Step 3: Parse and validate the field**

In `plugins/spar/hooks/stop-hook.sh`, next to the other field reads (after the `UNATTENDED` block around line 152), add:

```bash
AUTHOR=$(field author)
case "$AUTHOR" in
  ''|claude) AUTHOR=claude ;;
  codex) ;;
  *) log "invalid author: $AUTHOR"; finish_approve error-bypass ;;
esac
```

- [x] **Step 4: Resolve the sweep from it**

In `emit_sweep_runner`, the whole **invocation line** must branch by family, not
just the command name — the two CLIs deliver their output differently. `claude -p`
writes to stdout, so the generated runner redirects `> "$tmp"` *outside* the
`(cd "$snapshot" && …)` subshell, which is why the relative `$tmp` resolves against
the original cwd. `codex exec` instead writes the file itself via
`--output-last-message`, evaluated **inside** the subshell after the `cd`, so a
relative `$tmp` would land in the throwaway snapshot. It must be absolute — and
the runner already captures `source_root=$(pwd -P)` for exactly this kind of use.

Add this immediately before the `cat > "$SWEEP_RUNNER" <<EOF` line:

```bash
  # The generated runner receives this verbatim. Single quotes keep $snapshot,
  # $tmp and $source_root as literal text for the runner's own runtime.
  local sweep_invoke
  if [ "$AUTHOR" = codex ]; then
    sweep_invoke='(cd "$snapshot" && codex exec --sandbox read-only --skip-git-repo-check --output-last-message "$source_root/$tmp")'
  else
    sweep_invoke='(cd "$snapshot" && claude -p --safe-mode --tools Read Grep Glob) > "$tmp"'
  fi
```

Then replace the final two lines of the heredoc's pipeline

```
  (cd "\$snapshot" && claude -p --safe-mode --tools Read Grep Glob) > "\$tmp"
```

with

```
  ${sweep_invoke}
```

Leave the snapshot construction, the lock, the manifest, and the `ln` publish
untouched. Update the function's comment and the generated banner — "fresh Claude
author-family instance" → "fresh author-family instance" — since either family can
now fill the seat.

Then make the dispatch guard follow the same field (currently `command -v claude` at 894-895):

```bash
        command -v "$AUTHOR" >/dev/null 2>&1 \
          || { log "author-family CLI not found for sweep: $AUTHOR"; finish_approve error-bypass error; }
```

- [x] **Step 5: Fix the pairing notice**

Replace the notice at 844-845 so it describes the *pairing*, not the reviewer alone:

```bash
    NOTE=""
    [ "$REVIEWER" = "$AUTHOR" ] && NOTE="
NOTE: same-model review — reduced cross-vendor blind-spot coverage. Install the other vendor's CLI for cross-model review."
```

- [x] **Step 6: Run the tests to verify they pass**

```bash
bash tests/test_stop_hook.sh
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAILED: $t"; done
```
Expected: `FAIL=0`, and no suite reports `FAILED`.

- [x] **Step 7: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh tests/test_stop_hook.sh
git commit -m "feat: resolve the final sweep from an author family field (default claude)"
```

---

### Task 3: Owner-session gating

A user-scope Codex registration means the hook runs in **every** Codex session on the machine. The engine joins whenever a state file exists and then mutates it, so an unrelated Codex session opened in a repo with an active loop would be pulled into that run and advance its state machine. The state file must name its owner.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` (read the payload's `session_id`; gate right after the state file is confirmed)
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: `PLUGIN_ROOT` (Task 1), `AUTHOR` (Task 2).
- Produces: optional state field `owner_session: <id>`. Absent → no gating (today's behavior, and every Claude run until an activation writes it). Present → the engine approves immediately unless the payload's `session_id` matches.
- This is the first time the engine reads stdin. Ownership is decided **only** from a strict `jq` parse — no regex path, because a regex reads a session id out of a truncated payload such as `{"session_id":"x"`. Everything unverified (malformed, non-object, non-string id, or `jq` unavailable) resolves to "no session id", which with a present `owner_session` means *not the owner* → approve, mutating nothing. It must never block, and must never terminate the run: the session it cannot identify may not own it, so recording an outcome or running `cleanup()` there would destroy a live loop from a stranger.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_stop_hook.sh`, before the final PASS/FAIL lines:

```bash
# ── owner gating: a foreign session must not join someone else's run ──
add_owner() { # $1=session id
  sed -i '' "s/^reviewer: /owner_session: $1\nreviewer: /" .claude/spar.local.md 2>/dev/null \
    || sed -i "s/^reviewer: /owner_session: $1\nreviewer: /" .claude/spar.local.md
}
payload() { printf '{"session_id":"%s","hook_event_name":"Stop"}' "$1"; }

# matching session → the loop runs normally
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
OUT=$(payload sess-aaa | bash "$HOOK")
chk "owner match → round dispatched" "spar-run-reviewer.sh" "$OUT"

# foreign session → approve, and the run is left untouched
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
OUT=$(payload sess-zzz | bash "$HOOK")
chk "foreign session → approve" '"decision":"approve"' "$OUT"
chk "foreign session → state untouched" "phase: task" "$(cat .claude/spar.local.md 2>/dev/null)"
chk "foreign session → no runner written" "absent" \
  "$([ -f .claude/spar-run-reviewer.sh ] && echo present || echo absent)"
chk "foreign session → no outcome recorded" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-outcome.md ] && echo present || echo absent)"

# no owner field → unchanged behavior, whatever the payload says
fresh_dir; write_state task 0; mkdir -p reviews
OUT=$(payload sess-zzz | bash "$HOOK")
chk "no owner field → round dispatched" "spar-run-reviewer.sh" "$OUT"

# owner set but payload has no session id → treated as foreign, approve
fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
chk "no session id in payload → approve" '"decision":"approve"' "$(run_hook)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_stop_hook.sh`
Expected: the four foreign/no-id checks FAIL — the engine currently ignores the payload entirely and dispatches for any session.

- [ ] **Step 3: Gate on the owner**

In `plugins/spar/hooks/stop-hook.sh`, the payload is already captured as `HOOK_INPUT` (line 140) and discarded. Directly after the `field()` definition and the state reads, add:

```bash
# A user-scope hook registration fires in EVERY session of that host, so a run
# claims its session and the engine ignores everyone else. Absent field → no
# gating, which is every pre-existing run. Parsing is best-effort: no id while an
# owner is set means "not the owner", and the answer is always approve — this
# gate never blocks.
OWNER_SESSION=$(field owner_session)
if [ -n "$OWNER_SESSION" ]; then
  THIS_SESSION=$(printf '%s' "$HOOK_INPUT" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  if [ "$THIS_SESSION" != "$OWNER_SESSION" ]; then
    log "foreign session (${THIS_SESSION:-none}) — this run belongs to ${OWNER_SESSION}"
    approve
  fi
fi
```

**Placement — this is the part that cost Task 3 its round budget.** The original
instruction here said "after the `ACTIVE`/`REVIEW_ID` validation … and before any
state mutation", which is **unsatisfiable**: the `active != true` branch *is* a
mutation (`record_outcome cap; cleanup; approve`). Three of five rounds were spent
oscillating between the two halves. The order that satisfies both, and the one now
in the code, is:

```
read fields
  → validate review_id / round / include_dirty / unattended / author / sweep_* / reviewer
  → OWNER GATE (approve if the session cannot prove ownership)
  → `active != true` teardown
  → BASE, TASK, and the state machine
```

Two different rules, for two genuinely different cases:

- **After the validations.** A state file we cannot parse cannot be trusted to name
  its owner either, so gating on an `owner_session` read out of it would mean
  trusting a field from a file we just declared unparseable — and it would leave a
  broken run inert until someone ran `/spar:cancel`. Corruption is handled by
  whoever observes it.
- **Before the teardown.** There the file is well-formed and *does* name an owner,
  and finishing someone else's run is not a stranger's business.

Both directions are pinned by tests (`foreign session + inactive run → state NOT
cleaned up` and `foreign session + corrupt state → corruption still handled`);
moving the gate either way turns one pair red.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bash tests/test_stop_hook.sh
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAILED: $t"; done
```
Expected: `FAIL=0`, no suite `FAILED`.

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh tests/test_stop_hook.sh
git commit -m "feat: gate the loop on an owning session id (no-op when unset)"
```

---

### Task 4: The Codex adapter — hooks.json and installer

**Files:**
- Create: `adapters/codex/hooks.json.template`
- Create: `adapters/codex/install.sh`
- Test: `tests/test_codex_adapter.sh`

**Interfaces:**
- Consumes: the two registered scripts (`hooks/stop-fight.sh`, `hooks/session-start.sh`) and `PLUGIN_ROOT` self-location from Task 1.
- Produces: `install.sh [--scope user|project] [--target <hooks.json>]`, defaulting to user scope (`~/.codex/hooks.json`). Idempotent: a second run with the same plugin path leaves the file byte-identical, so Codex's hook trust is not reset. Exit `0` installed or already current; `2` usage; `3` unsafe path or I/O failure.

- [ ] **Step 1: Write the failing test**

Create `tests/test_codex_adapter.sh`:

```bash
#!/usr/bin/env bash
# Pure-bash tests for adapters/codex/install.sh and its hooks.json output.
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/adapters/codex/install.sh"

chk() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent() { if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }

fresh() { d=$(mktemp -d); cd "$d" || exit 1; cd "$(pwd -P)" || exit 1; }

# 1. fresh install registers both events at absolute paths
fresh
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
OUT="$(cat hooks.json 2>/dev/null)"
chk "valid json" "hooks" "$OUT"
python3 -c "import json;json.load(open('hooks.json'))" 2>/dev/null \
  && { echo "PASS: parses as json"; PASS=$((PASS+1)); } \
  || { echo "FAIL: parses as json"; FAIL=$((FAIL+1)); }
chk "Stop registered" '"Stop"' "$OUT"
chk "Stop runs the dispatcher, not the engine" "stop-fight.sh" "$OUT"
chk_absent "Stop does not run the inner engine directly" "hooks/stop-hook.sh" "$OUT"
chk "SessionStart registered" "session-start.sh" "$OUT"
chk "absolute plugin path" "$ROOT/plugins/spar" "$OUT"

# 2. idempotent — a second run must not change a byte (hook trust would reset)
BEFORE=$(cat hooks.json)
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
chk "second run changes nothing" "$BEFORE" "$(cat hooks.json)"

# 3. merges into an existing hooks.json without dropping other events
fresh
cat > hooks.json <<'EOF'
{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }
EOF
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
OUT="$(cat hooks.json)"
chk "pre-existing event preserved" "echo mine" "$OUT"
chk "our Stop added alongside" "stop-fight.sh" "$OUT"

# 4. refuses to write through a symlink
fresh
outside=$(mktemp); printf '{}\n' > "$outside"
ln -s "$outside" hooks.json
bash "$INSTALL" --target ./hooks.json >/dev/null 2>&1
chk "symlink target → exit 3" "3" "$?"
chk "symlink target untouched" "{}" "$(cat "$outside")"

# 5. the installer tells the user about the one-time trust prompt
fresh
OUT="$(bash "$INSTALL" --target ./hooks.json 2>&1)"
chk "mentions the trust prompt" "trust" "$OUT"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_codex_adapter.sh`
Expected: everything fails — `adapters/codex/install.sh` does not exist.

- [ ] **Step 3: Write the template and installer**

Create `adapters/codex/hooks.json.template` (the installer substitutes `@@PLUGIN_ROOT@@`):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "CLAUDE_PLUGIN_ROOT='@@PLUGIN_ROOT@@' '@@PLUGIN_ROOT@@/hooks/stop-fight.sh'",
            "timeout": 60,
            "statusMessage": "sparring: checking loop phase..."
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "CLAUDE_PLUGIN_ROOT='@@PLUGIN_ROOT@@' '@@PLUGIN_ROOT@@/hooks/session-start.sh'",
            "timeout": 10,
            "statusMessage": "sparring: checking for pending design decisions..."
          }
        ]
      }
    ]
  }
}
```

Create `adapters/codex/install.sh`:

```bash
#!/usr/bin/env bash
# Register sparring's two hooks with Codex. Installed ONCE: Codex pins hook trust
# to a content hash, so rewriting this file per run would re-prompt every loop.
# The hooks self-disable when no loop is active, so an idle registration is free.
# Usage: install.sh [--scope user|project] [--target <hooks.json>]
# Exit: 0 installed or already current; 2 usage; 3 unsafe path or I/O failure.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF_DIR/../../plugins/spar" && pwd)" || {
  echo "error: cannot locate plugins/spar next to this installer" >&2; exit 3; }

scope=user; target=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scope) scope="${2-}"; shift 2 || exit 2 ;;
    --target) target="${2-}"; shift 2 || exit 2 ;;
    *) echo "usage: install.sh [--scope user|project] [--target <hooks.json>]" >&2; exit 2 ;;
  esac
done
if [ -z "$target" ]; then
  case "$scope" in
    user)    target="${CODEX_HOME:-$HOME/.codex}/hooks.json" ;;
    project) target=".codex/hooks.json" ;;
    *) echo "error: --scope must be user or project" >&2; exit 2 ;;
  esac
fi
case "$target" in -*) target="./$target" ;; esac

[ -L "$target" ] && { echo "error: target is a symlink: $target" >&2; exit 3; }
[ -e "$target" ] && [ ! -f "$target" ] \
  && { echo "error: target is not a regular file: $target" >&2; exit 3; }
mkdir -p "$(dirname "$target")" || exit 3

command -v python3 >/dev/null 2>&1 \
  || { echo "error: python3 is required to merge hooks.json safely" >&2; exit 3; }

TEMPLATE="$SELF_DIR/hooks.json.template"
[ -f "$TEMPLATE" ] || { echo "error: missing $TEMPLATE" >&2; exit 3; }

PLUGIN_ROOT="$PLUGIN_ROOT" TEMPLATE="$TEMPLATE" TARGET="$target" python3 - <<'PY' || exit 3
import json, os, sys

root = os.environ["PLUGIN_ROOT"]
target = os.environ["TARGET"]
ours = json.loads(open(os.environ["TEMPLATE"]).read().replace("@@PLUGIN_ROOT@@", root))

existing = {"hooks": {}}
if os.path.exists(target):
    try:
        existing = json.load(open(target))
    except Exception:
        print(f"error: {target} exists but is not valid JSON; refusing to overwrite", file=sys.stderr)
        sys.exit(3)
    if not isinstance(existing, dict):
        print(f"error: {target} is not a JSON object", file=sys.stderr); sys.exit(3)
existing.setdefault("hooks", {})

def is_ours(group):
    return any(root in (h.get("command") or "") for h in group.get("hooks", []))

changed = False
for event, groups in ours["hooks"].items():
    kept = [g for g in existing["hooks"].get(event, []) if not is_ours(g)]
    merged = kept + groups
    if existing["hooks"].get(event) != merged:
        existing["hooks"][event] = merged
        changed = True

if not changed:
    print(f"sparring hooks already current in {target}")
    sys.exit(0)

tmp = target + ".tmp"
with open(tmp, "w") as fh:
    json.dump(existing, fh, indent=2)
    fh.write("\n")
os.replace(tmp, target)
print(f"sparring hooks installed in {target}")
PY

cat <<EOF
Codex asks you to trust a hook the first time it runs after a change. Accept it
once; the registration is not rewritten per run, so it will not ask again.
Choosing "Continue without trusting" means the hooks do not run and the review
loop is NOT enforced for that session.
EOF
```

Then `chmod +x adapters/codex/install.sh`.

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_codex_adapter.sh
```
Expected: `PASS=… FAIL=0`.

- [ ] **Step 5: Run the whole suite**

```bash
for t in tests/test_*.sh; do printf '%-34s ' "$t"; bash "$t" >/dev/null 2>&1 && echo OK || echo FAILED; done
```
Expected: every line `OK` (20 suites now).

- [ ] **Step 6: Commit**

```bash
git add adapters/codex/hooks.json.template adapters/codex/install.sh tests/test_codex_adapter.sh
git commit -m "feat: codex adapter — register both hooks via an idempotent installer"
```

---

### Task 5: Codex skills, the liveness marker, and docs

The author seat needs its command surface as Codex skills, and activation must refuse to start a loop it cannot confirm is enforced. Liveness cannot be checked statically — hook trust is a per-session choice and no CLI reports hook state — so the `SessionStart` hook leaves a marker keyed by `session_id`, and activation looks for it.

**Files:**
- Modify: `plugins/spar/hooks/session-start.sh` (write the liveness marker)
- Create: `adapters/codex/skills/spar-fight/SKILL.md`, `spar-ready/SKILL.md`, `spar-cancel/SKILL.md`, `spar-report/SKILL.md`
- Modify: `adapters/codex/install.sh` (place the skills)
- Modify: `tests/test_session_start.sh`, `tests/test_codex_adapter.sh`
- Modify: `README.md` (seat table: Codex column becomes real), `docs/design-decisions.md` (§Phase 6 → implemented)

**Already done in Task 2** (the sweep's family resolution created the drift, so it
was corrected there rather than left for this pass): `policy.md` §Protocol 8 and
`README.md`'s feature bullet no longer call the sweep a *Claude* instance, and
`spar-report.sh` now derives the pairing label from both seats instead of assuming
a claude author — otherwise a codex↔codex run would have been reported as
cross-model. `tests/test_spar_report.sh` covers all four pairings.

**Interfaces:**
- Consumes: `install.sh` (Task 4), the `author` and `owner_session` fields (Tasks 2-3).
- Produces: marker file `reviews/.spar-hook-live` containing the current `session_id`, written by `session-start.sh` on every session start; the skills' activation step requires it and writes `author: codex` plus `owner_session: <id>` into the state file.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_session_start.sh`, before its final PASS/FAIL lines:

```bash
# 6. the hook leaves a liveness marker so activation can prove it ran
fresh
run '{"source":"startup","session_id":"sess-live-1"}' >/dev/null
chk "marker written" "sess-live-1" "$(cat reviews/.spar-hook-live 2>/dev/null)"

# 7. a second session overwrites it — the marker names the CURRENT session only
run '{"source":"startup","session_id":"sess-live-2"}' >/dev/null
chk "marker names the current session" "sess-live-2" "$(cat reviews/.spar-hook-live 2>/dev/null)"

# 8. no session id → no marker, and still silent
fresh
OUT="$(run '{"source":"startup"}')"
chk_empty "no session id → still silent" "" "$OUT"
chk "no session id → no marker" "absent" \
  "$([ -f reviews/.spar-hook-live ] && echo present || echo absent)"
```

Append to `tests/test_codex_adapter.sh`, before its final PASS/FAIL lines:

```bash
# 6. the skills exist and carry the load-bearing loop rules
for s in spar-fight spar-ready spar-cancel spar-report; do
  F="$ROOT/adapters/codex/skills/$s/SKILL.md"
  chk "$s skill exists" "present" "$([ -f "$F" ] && echo present || echo absent)"
done
FIGHT="$(cat "$ROOT/adapters/codex/skills/spar-fight/SKILL.md" 2>/dev/null)"
chk "fight skill forbids self-declared convergence" "Never write" "$FIGHT"
chk "fight skill states the response format" "FIXED" "$FIGHT"
chk "fight skill requires the liveness check" ".spar-hook-live" "$FIGHT"
chk "fight skill claims the session" "owner_session" "$FIGHT"
chk "fight skill sets the author seat" "author: codex" "$FIGHT"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash tests/test_session_start.sh
bash tests/test_codex_adapter.sh
```
Expected: the marker checks and every skill check FAIL.

- [ ] **Step 3: Write the marker from `session-start.sh`**

In `plugins/spar/hooks/session-start.sh`, the hook currently consumes stdin with
`cat >/dev/null`. Capture it instead and record the marker before the existing
pending-queue logic — the hook must stay fail-open and silent on error:

```bash
IN=$(cat 2>/dev/null || true)   # replaces: cat >/dev/null 2>&1 || true

# Liveness marker: the only way an activation step can prove this session's hooks
# actually run. Trust is a per-session choice in Codex ("Continue without
# trusting (hooks won't run)") and no CLI reports hook state, so configuration
# cannot answer it — only the hook having fired can.
SESSION_ID=$(printf '%s' "$IN" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$SESSION_ID" ] && [ -d reviews ] && [ ! -L reviews ]; then
  printf '%s\n' "$SESSION_ID" > reviews/.spar-hook-live 2>/dev/null || true
fi
```

- [ ] **Step 4: Write the skills**

Create `adapters/codex/skills/spar-fight/SKILL.md`. Mirror
`plugins/spar/commands/fight.md` — same activation shape, same loop protocol, same
hard rules — with three Codex-specific changes to the activation block:

1. **Refuse without proof of enforcement**, before writing any state:

```bash
SPAR_SESSION="${CODEX_SESSION_ID:-}"
if [ ! -f reviews/.spar-hook-live ]; then
  echo "Error: sparring's Codex hooks did not run in this session, so the review"
  echo "loop would NOT be enforced. Install them with adapters/codex/install.sh,"
  echo "then start a new session and accept the trust prompt." >&2
  exit 1
fi
```

2. **Claim the session and the seat** in the state file: add `author: codex` and
   `owner_session: $(cat reviews/.spar-hook-live)` alongside the existing fields.
3. **Say what is enforced**: the skill text states that the loop is enforced by
   Codex's `Stop` hook and that `--no-verify`-style bypasses do not apply, because
   there is no commit gate involved.

Create the other three skills as thin mirrors of `ready.md`, `cancel.md`, and
`report.md`, pointing at the same `plugins/spar/commands/*.sh` helpers.

Extend `install.sh` to copy `adapters/codex/skills/*` into
`${CODEX_HOME:-$HOME/.codex}/skills/` (project scope: `.codex/skills/`), skipping
files that are already identical so the run stays idempotent.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash tests/test_session_start.sh
bash tests/test_codex_adapter.sh
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAILED: $t"; done
```
Expected: `FAIL=0` everywhere.

- [ ] **Step 6: Update the docs**

In `README.md`, the seat table's Codex column stops being hypothetical — change the
`Codex-hosted (planned)` header to `Codex-hosted` and the Enforcement cell to
`Codex \`Stop\` hook blocks exit — same guarantee, same gatekeeper script`. Change
the Roadmap Phase 6 row's status to `✅ done` and its scope text to name the skills
entry point and `adapters/codex/install.sh`.

In `docs/design-decisions.md` §Phase 6, append one line recording that the phase
shipped, naming this plan and the spec.

Add a line to the README's Repository layout block:

```
adapters/codex/         Codex-hosted seat: hooks.json template, installer, skills
```

- [ ] **Step 7: Run the whole suite and commit**

```bash
for t in tests/test_*.sh; do printf '%-34s ' "$t"; bash "$t" >/dev/null 2>&1 && echo OK || echo FAILED; done
git add plugins/spar/hooks/session-start.sh adapters/codex tests/test_session_start.sh \
  tests/test_codex_adapter.sh README.md docs/design-decisions.md
git commit -m "feat: codex skills, hook-liveness marker, and Phase 6 docs"
```

---

## Non-goals

- **A git pre-commit hook** (spec §1).
- **Renaming `.claude/` state paths** (spec §5) — 320 references across 15 files, several of which must *not* be renamed.
- **Risky-path changes** — `.codex/hooks.json` is already covered; measured, not assumed (spec §2.1d).
- **Codex-Codex same-family sparring** — falls out of the `author` field but is not designed or tested here.
- **Version bump, release, or plugin reinstall.**

## Task 3 status (2026-07-26)

Task 3 shipped in commit `41009b7` but its loop **ended at the round cap, not on
convergence** — the reviewer never re-checked the final fix. All five findings were
fixed and none rejected; the five rounds were spent on one question, the gate's
payload parsing and its placement, and the unsatisfiable placement instruction that
used to be in this task is what set that up (corrected above).

What is unverified is specifically the **last** change: moving the gate to sit
between the validations and the `active != true` teardown. 287 checks and all 19
suites pass locally, and both directions of the ordering are pinned by tests, but
that is the author's word, not an independent review. Re-run Task 3 through a fresh
loop before treating it as done.

## Verification this plan cannot do

Four things need a real Codex session with model credentials and are therefore a
release gate, not tests (spec §7):

1. The **trust path** — both spikes used `--dangerously-bypass-hook-trust`.
2. **Hook scope** — this spec's spike fired a project-scope hook; the cross-review
   could only make user scope fire. Settle by measurement, prefer user scope.
3. **`SessionStart` ordering** — whether it fires before the skill's first action.
   If it does not, the liveness marker cannot gate activation, and the fallback in
   spec §6 applies: treat the first `Stop` as the proof and say up front that
   enforcement is unconfirmed until then.
4. **End-to-end**: a planted-bug task authored by Codex, reviewed by `claude -p`,
   going FINDINGS → fix → re-review → CONVERGED.

Task 5 must not claim Phase 6 is done in the docs until item 4 has been run once.

## Self-Review notes

**Pre-verified (2026-07-25, before hand-off):** Tasks 1-3 were applied to a scratch
copy of the engine exactly as written above, and all three behaviors were exercised
directly: with `CLAUDE_PLUGIN_ROOT` unset the engine still dispatches round 1 and
writes a prompt carrying the task; `author: codex` emits a `codex exec` sweep runner
with the absolute `--output-last-message "$source_root/$tmp"` path and no `claude -p`
left in it; a foreign `session_id` approves and leaves the state file at
`phase: task`, while the owning session proceeds. The 18 other suites pass unchanged
against the patched engine (`test_ci_workflow.sh` fails only because the scratch copy
omits `.github/`). The Task 2 invocation code was corrected during this pass — the
first draft substituted only the command name, which would have written the sweep
output into the throwaway snapshot. Tasks 4-5 were not executed.

**Spec coverage:** §2.1(a) → Task 2; §2.1(b) → Task 1; §2.1(c) → Task 3; §2.1(d) →
Non-goals (retracted, with the measurement); §2 registration table → Task 4; §3
skills → Task 5; §4 install-once/idempotent/merge/symlink → Task 4; §5 → Non-goals;
§6 liveness marker → Task 5; §7 test plan → the suites in Tasks 1-5 plus the
release gate above.

**Default-safety:** every engine change is inert without a new state field —
`author` absent → claude (Task 2), `owner_session` absent → no gating (Task 3), and
`CLAUDE_PLUGIN_ROOT` still wins when set (Task 1). That is what lets "all 19 suites
stay green" be a real check rather than a hope.

**Ordering:** Task 1 before 2 and 3 because both consume `PLUGIN_ROOT`; Task 4
before 5 because the skills are installed by the same installer; Task 5 last
because it writes the docs that claim the phase works.

**Known fixture detail:** `tests/test_stop_hook.sh` stubs `codex` and `claude` on
`PATH`, so Task 2's `command -v "$AUTHOR"` guard passes for both families in tests;
the absent-CLI branch is exercised separately through `SYS_PATH`.
