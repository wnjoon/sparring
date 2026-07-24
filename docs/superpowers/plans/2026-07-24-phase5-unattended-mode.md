# Phase 5 — Unattended Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a `/spar` loop (and, through it, `/spar-weighin`) run without a human at the design gate — continuing mechanical progress, but deferring every essential design decision honestly as `blocked-pending-user` instead of hanging or fabricating completion.

**Architecture:** An explicit `--unattended` flag is persisted to `.claude/spar.local.md` as `unattended: true|false`. The Stop hook validates that field and, at the one place the loop would otherwise **hold at the batched design gate** (`only_parked_this_round`), takes a terminal path instead: it writes every pending finding to a durable queue under `reviews/` (survives `cleanup()`), records the `blocked-pending-user` outcome, makes a fail-open call to the (separately-specified) report generator, cleans up, and releases. A fail-open `SessionStart` hook announces the pending count next session. `/spar-weighin` just threads the flag into each task's launched state; its existing "non-converged → stop honestly" path already handles a `blocked-pending-user` task.

**Tech Stack:** POSIX-ish bash (Claude Code plugin scripts + hooks), `jq` for hook JSON, `git`, pure-bash test scripts under `tests/`.

**Source spec:** `docs/superpowers/specs/2026-07-24-phase5-unattended-mode-design.md` (design-complete; three open questions settled by cross-verification). The final-report half is a *separate* spec (`2026-07-24-spar-report-design.md`) and is **out of scope** here — this plan only adds the fail-open *call site* to a `spar-report.sh` that may not exist yet.

## Global Constraints

- **Backward-compatible / default-safe:** a missing or empty `unattended` field MUST behave exactly as attended mode (`unattended=false`). This is non-negotiable — this plan is executed *through* a live weigh-in that keeps invoking `stop-hook.sh` and `spar-weighin-launch.sh` while they are being edited. Any change that alters attended behavior would break the loop implementing it.
- **Malformed value fails open:** an `unattended` value that is neither empty, `true`, nor `false` is an internal-state error → `stop-hook.sh` records `error-bypass` and approves (never silently selects unattended behavior). Matches spec §1.
- **Fail-open everywhere new:** the pending-queue writer, the report call, and the SessionStart hook are all best-effort. A failure in any of them logs and continues; it never blocks a session or changes an outcome. Matches spec §4 and "Invariants respected".
- **Never report incomplete as done:** an unresolved essential design decision forces the `blocked-pending-user` terminal, never `converged`. The round cap stays a circuit breaker; it must not relabel parked findings as complete.
- **The durable queue lives under `reviews/`** (default `reviews/spar-pending.md`) because `cleanup()` deletes only `.claude/…` state and touches no `reviews/` path. Verified in `stop-hook.sh` `cleanup()` (lines 49-57).
- **No new reviewer marker, parser, or prompt contract** (spec §3, option b): every unattended `[DESIGN]` stalemate is treated as essential. Reuse the existing `blocked-pending-user` outcome reason — already valid in `spar-record-outcome.sh`.
- **Style:** match existing scripts — `set -uo pipefail` (no `set -e`), hard-link/`mktemp` atomic publish, regular-file-vs-symlink guards, `.lock` dirs. Tests are pure-bash `tests/test_*.sh` with the `chk`/`chk_file` PASS/FAIL harness.

---

### Task 1: Durable pending-queue writer

Create the standalone script the unattended terminal calls to persist one pending design decision. It is independent of the hook, so it is built and tested first.

**Files:**
- Create: `plugins/spar/commands/spar-queue-pending.sh`
- Test: `tests/test_queue_pending.sh`

**Interfaces:**
- Produces (later tasks rely on this exact contract):
  - Invocation: `spar-queue-pending.sh <review-id> <fingerprint> <finding-text-file> [queue-file]`
  - Default `queue-file`: `reviews/spar-pending.md`
  - Dedup key: the exact heading line `## <review-id> :: <fingerprint>`. A duplicate key is a no-op (merge, never overwrite, never duplicate).
  - Exit 0 on success or duplicate; exit 2 on usage error; exit 3 on unsafe path (symlinked queue/dir, non-regular file, mkdir failure).

- [x] **Step 1: Write the failing test**

Create `tests/test_queue_pending.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/plugins/spar/commands/spar-queue-pending.sh"
chk() { if printf '%s' "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }

fresh() { d=$(mktemp -d); cd "$d" || exit 1; mkdir -p reviews; }

# 1. first append creates the queue and records the keyed heading + finding text
fresh
printf '### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n' > finding.txt
bash "$W" 20260721-120000-abc123 'mod.py | split the module' finding.txt
Q=reviews/spar-pending.md
chk "queue created" "present" "$([ -f "$Q" ] && echo present || echo absent)"
chk "keyed heading written" "## 20260721-120000-abc123 :: mod.py | split the module" "$(cat "$Q")"
chk "finding text carried" "split the module" "$(cat "$Q")"

# 2. duplicate key is a no-op (merge, never duplicate)
bash "$W" 20260721-120000-abc123 'mod.py | split the module' finding.txt
chk "duplicate key not duplicated" "1" "$(grep -c '^## 20260721-120000-abc123 :: mod.py | split the module$' "$Q")"

# 3. a second distinct key from another run merges in
printf '### F1-1 [DESIGN] rename thing\n' > finding2.txt
bash "$W" 20260722-090000-def456 'x.py | rename thing' finding2.txt
chk "second run merged" "2" "$(grep -c '^## ' "$Q")"

# 4. a symlinked queue path is rejected, target untouched
fresh
outside=$(mktemp)
ln -s "$outside" reviews/spar-pending.md
printf 'x\n' > finding.txt
if bash "$W" 20260721-120000-abc123 'a | b' finding.txt >/dev/null 2>&1; then RC=zero; else RC=nonzero; fi
chk "symlinked queue rejected" "nonzero" "$RC"
chk "symlink target untouched" "0" "$(wc -c < "$outside" | tr -d ' ')"

# 5. missing finding-text file is a usage error
fresh
if bash "$W" 20260721-120000-abc123 'a | b' /nonexistent.txt >/dev/null 2>&1; then RC=zero; else RC=nonzero; fi
chk "missing finding file → error" "nonzero" "$RC"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_queue_pending.sh`
Expected: FAIL — the script does not exist yet (every `bash "$W" …` errors; `queue created` fails).

- [x] **Step 3: Write the script**

Create `plugins/spar/commands/spar-queue-pending.sh`:

```bash
#!/usr/bin/env bash
# Append one unattended pending design decision to a durable queue that
# survives stop-hook.sh cleanup() (cleanup touches no reviews/ path). Entries
# are keyed by "## <review-id> :: <fingerprint>" so repeated runs merge and a
# duplicate key is a no-op. Regular-file-vs-symlink safe. Best-effort: the
# caller ignores failures.
# Usage: spar-queue-pending.sh <review-id> <fingerprint> <finding-text-file> [queue-file]
set -uo pipefail

review_id="${1-}"; fp="${2-}"; txt="${3-}"; queue="${4:-reviews/spar-pending.md}"
if [ -z "$review_id" ] || [ -z "$fp" ] || [ ! -f "$txt" ]; then
  echo "usage: spar-queue-pending.sh <review-id> <fingerprint> <finding-text-file> [queue-file]" >&2
  exit 2
fi

dir=$(dirname "$queue")
if [ -e "$dir" ] || [ -L "$dir" ]; then
  [ -d "$dir" ] && [ ! -L "$dir" ] || { echo "error: $dir must be a real directory" >&2; exit 3; }
else
  mkdir -p "$dir" || exit 3
fi
if [ -L "$queue" ]; then echo "error: queue path is a symlink" >&2; exit 3; fi
if [ -e "$queue" ] && [ ! -f "$queue" ]; then echo "error: queue path is not a regular file" >&2; exit 3; fi

heading="## ${review_id} :: ${fp}"

# Serialize the dedup read + append with a lock dir (bounded wait; best-effort).
lock="${queue}.lock"
i=0
while ! mkdir "$lock" 2>/dev/null; do
  i=$((i+1)); [ "$i" -ge 50 ] && { echo "error: could not lock queue" >&2; exit 3; }
  sleep 0.1
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

if [ -f "$queue" ] && grep -qxF "$heading" "$queue"; then
  exit 0   # already queued — merge, never duplicate
fi
if [ ! -f "$queue" ]; then
  printf '# sparring — pending design decisions (unattended runs)\n\nEach entry below is an essential design decision an unattended run could not make.\nResolve it, then delete its section.\n\n' >> "$queue" || exit 3
fi
{
  printf '%s\n\n' "$heading"
  cat "$txt"
  printf '\n'
} >> "$queue" || exit 3
exit 0
```

- [x] **Step 4: Make it executable**

Run: `chmod +x plugins/spar/commands/spar-queue-pending.sh`

- [x] **Step 5: Run the test to verify it passes**

Run: `bash tests/test_queue_pending.sh`
Expected: `PASS=… FAIL=0` (exit 0).

- [x] **Step 6: Commit**

```bash
git add plugins/spar/commands/spar-queue-pending.sh tests/test_queue_pending.sh
git commit -m "feat: durable pending-queue writer for unattended mode"
```

---

### Task 2: `--unattended` flag in `/spar` activation

Parse `--unattended` in the family resolver and persist `unattended:` into the state file `/spar` writes. This is what the hook reads in Task 3.

**Files:**
- Modify: `plugins/spar/commands/spar-resolve-family.sh`
- Modify: `plugins/spar/commands/spar.md`
- Test: `tests/test_resolve_family.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `spar-resolve-family.sh` output gains a field: `<family>\t<include-dirty>\t<unattended>\t<task>` (unattended ∈ `true|false`, default `false`). The task remains the trailing field (may itself contain tabs).
  - `.claude/spar.local.md` frontmatter gains a line `unattended: true|false` (Task 3 reads it).

- [x] **Step 1: Update the resolver test (make it fail)**

In `tests/test_resolve_family.sh`, the output now has a `<unattended>` field before the task. Update every existing expectation that spells out the tab-joined output, and add `--unattended` cases. Replace the assertion block from the line `chk "codex present → codex" …` through the final `chk "duplicate reviewer → error" …` with:

```bash
chk "codex present → codex" "codex	false	false	do the thing" "$(PATH="$BOTH:$PATH" bash "$R" "do the thing")"
chk "codex absent → claude" "claude	false	false	do the thing" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "do the thing")"
chk "override claude (codex present)" "claude	false	false	fix bug" "$(PATH="$BOTH:$PATH" bash "$R" "-- --reviewer claude -- fix bug")"
chk "override codex, codex absent → error" "error" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "--reviewer codex -- x" 2>&1; echo)"
chk "task after -- preserved incl leading dashes" "claude	false	false	--do --not --strip" "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "-- --do --not --strip")"
chk "neither CLI → error" "error" "$(PATH="$NEITHER:/usr/bin:/bin" bash "$R" x 2>&1; echo)"
chk "invalid --reviewer value → error" "error" "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer bogus -- do it" 2>&1; echo)"

# --- single-string reinterface (Fix 2) ---
TASK_WS=$'do   the    thing\twith a\ttab'
chk "internal whitespace/tabs preserved" "$(printf 'claude\tfalse\tfalse\t%s' "$TASK_WS")" \
  "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "$TASK_WS")"

TASK_CMDSUB='refactor $(echo pwned) the parser'
chk "cmd-substitution task not executed" "$(printf 'claude\tfalse\tfalse\t%s' "$TASK_CMDSUB")" \
  "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "$TASK_CMDSUB")"
chk "cmd-substitution task does not leak 'pwned' output" "" \
  "$(echo "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "$TASK_CMDSUB")" | grep -o '^pwned$' || true)"

TASK_BACKTICK='refactor `echo pwned` the parser'
chk "backtick task not executed" "$(printf 'claude\tfalse\tfalse\t%s' "$TASK_BACKTICK")" \
  "$(PATH="$ONLYCLAUDE:/usr/bin:/bin" bash "$R" "$TASK_BACKTICK")"

chk "invalid --reviewer value (single string) → error" "error" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer bogus -- do it" 2>&1; echo)"

# Phase 4: --include-dirty composes with reviewer override in either order.
chk "include-dirty before reviewer" "claude	true	false	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--include-dirty --reviewer claude -- fix bug")"
chk "include-dirty after reviewer" "claude	true	false	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer claude --include-dirty -- fix bug")"
chk "include-dirty without override" "codex	true	false	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--include-dirty -- fix bug")"
chk "duplicate include-dirty → error" "error" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--include-dirty --include-dirty x" 2>&1; echo)"
chk "duplicate reviewer → error" "error" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer codex --reviewer claude x" 2>&1; echo)"

# Phase 5: --unattended composes in any order and is stripped from the task.
chk "unattended default false" "codex	false	false	do it" \
  "$(PATH="$BOTH:$PATH" bash "$R" "do it")"
chk "unattended alone" "codex	false	true	do it" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--unattended -- do it")"
chk "unattended with reviewer + include-dirty" "claude	true	true	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--include-dirty --unattended --reviewer claude -- fix bug")"
chk "unattended after reviewer" "claude	false	true	fix bug" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--reviewer claude --unattended -- fix bug")"
chk "duplicate unattended → error" "error" \
  "$(PATH="$BOTH:$PATH" bash "$R" "--unattended --unattended x" 2>&1; echo)"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_resolve_family.sh`
Expected: FAIL — current output has only 3 fields (`codex\tfalse\t…`), so the new `\tfalse\t` expectations and all `--unattended` cases fail.

- [x] **Step 3: Add `--unattended` parsing to the resolver**

In `plugins/spar/commands/spar-resolve-family.sh`:

First add a state variable next to the existing ones. Replace:

```bash
family=""
include_dirty=false
seen_reviewer=false
seen_include_dirty=false
task=""
```

with:

```bash
family=""
include_dirty=false
unattended=false
seen_reviewer=false
seen_include_dirty=false
seen_unattended=false
task=""
```

Then add two `--unattended` clauses inside the `while :; do` flag loop, immediately after the two `--include-dirty` clauses (after the block ending `remainder="${remainder#--include-dirty }"`), before the `--reviewer` clauses:

```bash
  elif [ "$remainder" = "--unattended" ]; then
    [ "$seen_unattended" = false ] \
      || { echo "error: --unattended specified more than once" >&2; exit 2; }
    seen_unattended=true
    unattended=true
    remainder=""
  elif [ "${remainder#--unattended }" != "$remainder" ]; then
    [ "$seen_unattended" = false ] \
      || { echo "error: --unattended specified more than once" >&2; exit 2; }
    seen_unattended=true
    unattended=true
    remainder="${remainder#--unattended }"
```

Finally, change the output line. Replace:

```bash
printf '%s\t%s\t%s\n' "$family" "$include_dirty" "$task"
```

with:

```bash
printf '%s\t%s\t%s\t%s\n' "$family" "$include_dirty" "$unattended" "$task"
```

- [x] **Step 4: Run the resolver test to verify it passes**

Run: `bash tests/test_resolve_family.sh`
Expected: `PASS=… FAIL=0`.

- [x] **Step 5: Thread `unattended` through `/spar` setup**

In `plugins/spar/commands/spar.md`:

Update the `argument-hint` line to advertise the flag. Replace:

```
argument-hint: "[--reviewer codex|claude] [--include-dirty] [--] <task description>"
```

with:

```
argument-hint: "[--reviewer codex|claude] [--include-dirty] [--unattended] [--] <task description>"
```

Update the resolver-output parsing. Replace:

```bash
SPAR_REVIEWER="${RESOLVED%%$'\t'*}"
SPAR_REST="${RESOLVED#*$'\t'}"
SPAR_INCLUDE_DIRTY="${SPAR_REST%%$'\t'*}"
SPAR_TASK="${SPAR_REST#*$'\t'}"
```

with:

```bash
SPAR_REVIEWER="${RESOLVED%%$'\t'*}"
SPAR_REST="${RESOLVED#*$'\t'}"
SPAR_INCLUDE_DIRTY="${SPAR_REST%%$'\t'*}"
SPAR_REST2="${SPAR_REST#*$'\t'}"
SPAR_UNATTENDED="${SPAR_REST2%%$'\t'*}"
SPAR_TASK="${SPAR_REST2#*$'\t'}"
```

Add the `unattended` line to the written state frontmatter. Replace:

```bash
reviewer: ${SPAR_REVIEWER}
include_dirty: ${SPAR_INCLUDE_DIRTY}
max_rounds: 5
```

with:

```bash
reviewer: ${SPAR_REVIEWER}
include_dirty: ${SPAR_INCLUDE_DIRTY}
unattended: ${SPAR_UNATTENDED}
max_rounds: 5
```

Update the final activation echo. Replace:

```bash
echo "Sparring loop activated (${SPAR_ID}, reviewer=${SPAR_REVIEWER})"
```

with:

```bash
echo "Sparring loop activated (${SPAR_ID}, reviewer=${SPAR_REVIEWER}, unattended=${SPAR_UNATTENDED})"
```

- [x] **Step 6: Verify the state block is well-formed**

Run: `sed -n '/STATE_EOF/,/STATE_EOF/p' plugins/spar/commands/spar.md | grep -n 'unattended\|include_dirty\|max_rounds'`
Expected: `unattended: ${SPAR_UNATTENDED}` appears once, between `include_dirty:` and `max_rounds:`.

- [x] **Step 7: Commit**

```bash
git add plugins/spar/commands/spar-resolve-family.sh plugins/spar/commands/spar.md tests/test_resolve_family.sh
git commit -m "feat: --unattended flag threads into /spar state"
```

---

### Task 3: Stop-hook unattended gate terminal

The core change. Validate the `unattended` field, and at the batched-gate branch (`only_parked_this_round`) take an honest terminal path in unattended mode instead of holding.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh`
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: `unattended: true|false` from `.claude/spar.local.md` (Task 2); `spar-queue-pending.sh` (Task 1); optionally `spar-report.sh` (separate spec — call is fail-open and guarded, so absence is fine).
- Produces: at the unattended terminal, `reviews/spar-pending.md` (one keyed section per parked finding), `reviews/spar-<id>-outcome.md` with `reason: blocked-pending-user`, cleaned-up `.claude/` state, and a bare `{"decision":"approve"}`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_stop_hook.sh`, just before its final `echo; echo "PASS=$PASS FAIL=$FAIL"` / `exit "$FAIL"` lines:

```bash
# ── Phase 5: unattended terminal at the design gate ──
# helper: mark the active state file unattended
add_unattended() {
  sed -i '' 's/^sweep_result: not-run/sweep_result: not-run\nunattended: true/' .claude/spar.local.md 2>/dev/null \
    || sed -i 's/^sweep_result: not-run/sweep_result: not-run\nunattended: true/' .claude/spar.local.md
}

# U1. unattended + parked DESIGN stalemate → NO gate; blocked-pending-user terminal
fresh_dir; write_state review 1; add_unattended; mkdir -p reviews
UFa="reviews/spar-20260721-120000-abc123-r1.md"
UPa="reviews/spar-20260721-120000-abc123-r1-response.md"
UFb="reviews/spar-20260721-120000-abc123-r2.md"
UPb="reviews/spar-20260721-120000-abc123-r2-response.md"
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$UFa"
printf '### F1-1: REJECTED — cohesive on purpose\n' > "$UPa"
run_hook >/dev/null   # fold r1 (streak 1), advance to r2
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$UFb"
printf '### F2-1: REJECTED — still cohesive\n' > "$UPb"
OUT=$(run_hook)       # fold r2 (streak 2) → parked → unattended terminal
chk "unattended parked → approve (no gate hold)" '"decision":"approve"' "$OUT"
chk "unattended → no gate manifest" "gone" "$([ -f .claude/spar-gate-manifest.tsv ] && echo present || echo gone)"
chk "unattended → pending queue written" "present" "$([ -f reviews/spar-pending.md ] && echo present || echo gone)"
chk "queue keyed by review-id + fingerprint" "## 20260721-120000-abc123 :: mod.py | split the module" "$(cat reviews/spar-pending.md)"
chk "queue carries the finding text" "split the module" "$(cat reviews/spar-pending.md)"
chk "unattended → blocked-pending-user outcome" "reason: blocked-pending-user" "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"
chk "unattended → state cleaned up" "gone" "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# U2. attended (unattended:false / absent) still fires the gate — default-safety
fresh_dir; write_state review 1; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$UFa"
printf '### F1-1: REJECTED — cohesive\n' > "$UPa"
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' > "$UFb"
printf '### F2-1: REJECTED — still cohesive\n' > "$UPb"
OUT=$(run_hook)
chk "attended default → gate still fires" 'gate' "$OUT"
chk "attended default → no pending queue" "gone" "$([ -f reviews/spar-pending.md ] && echo present || echo gone)"

# U3. malformed unattended value → fail-open approve (never silently unattended)
fresh_dir; write_state task 0
sed -i '' 's/^sweep_result: not-run/sweep_result: not-run\nunattended: maybe/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^sweep_result: not-run/sweep_result: not-run\nunattended: maybe/' .claude/spar.local.md
chk "malformed unattended → approve" '"decision":"approve"' "$(run_hook)"
chk "malformed unattended → error-bypass outcome" "reason: error-bypass" "$(cat reviews/spar-20260721-120000-abc123-outcome.md)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: FAIL on the U1 asserts (`unattended parked → approve` gets a gate block; no pending queue; no blocked-pending-user outcome) and U3 (`unattended: maybe` is currently ignored, so it does not error-bypass). U2 passes already.

- [ ] **Step 3: Declare the new script paths**

In `plugins/spar/hooks/stop-hook.sh`, next to the other `${CLAUDE_PLUGIN_ROOT}`-based paths (after the `INTENT_HARVESTER=` line, ~line 42), add:

```bash
QUEUE_WRITER="${CLAUDE_PLUGIN_ROOT:-}/commands/spar-queue-pending.sh"
REPORT_GEN="${CLAUDE_PLUGIN_ROOT:-}/commands/spar-report.sh"
```

- [ ] **Step 4: Validate the `unattended` field**

In the field-validation block, right after the `include_dirty` `case` (the block ending at the `esac` after `*) log "invalid include_dirty: $INCLUDE_DIRTY"; finish_approve error-bypass;;`), add:

```bash
UNATTENDED=$(field unattended)
case "$UNATTENDED" in
  ''|false) UNATTENDED=false ;;
  true) ;;
  *) log "invalid unattended: $UNATTENDED"; finish_approve error-bypass;;
esac
```

(Empty → `false` keeps old state files and attended runs unchanged; a malformed value fails open — Global Constraints.)

- [ ] **Step 5: Add the unattended terminal helper**

In `plugins/spar/hooks/stop-hook.sh`, add a function near the other terminal helpers (right after the `finish_approve()` definition, ~line 73):

```bash
# Unattended terminal: every parked design stalemate is essential (spec §3).
# Persist each pending finding to the durable queue (survives cleanup), record
# the honest blocked-pending-user outcome, make a fail-open report call while
# the ledger/registry still exist, then clean up and release. Never a gate.
unattended_block_terminal() { # $1=round
  local n="$1" pfp ptxt
  while IFS= read -r pfp; do
    [ -n "$pfp" ] || continue
    ptxt=$(mktemp) || continue
    gate_finding_text "$(review_file "$n")" "$pfp" > "$ptxt"
    if [ -x "$QUEUE_WRITER" ]; then
      "$QUEUE_WRITER" "$REVIEW_ID" "$pfp" "$ptxt" 2>>"$LOG_FILE" \
        || log "could not queue pending finding: $pfp"
    else
      log "queue writer missing: $QUEUE_WRITER"
    fi
    rm -f "$ptxt"
  done < <(parked_fingerprints)
  record_outcome blocked-pending-user
  if [ -x "$REPORT_GEN" ]; then
    "$REPORT_GEN" "$REVIEW_ID" "$BASE" 2>>"$LOG_FILE" || log "report generation failed"
  fi
  cleanup
  approve
}
```

- [ ] **Step 6: Branch to the terminal at the batched gate**

In the `review)` case, at the C2 block, change the guard so unattended mode diverts before the gate is built. Replace:

```bash
    # (C2) Stuck on parked findings → fire the single batched gate.
    if only_parked_this_round "$ROUND"; then
      : > "$GATE_MANIFEST"
```

with:

```bash
    # (C2) Stuck on parked findings → attended: fire the single batched gate;
    # unattended: take the honest blocked-pending-user terminal (spec §2/§3).
    if only_parked_this_round "$ROUND"; then
      if [ "$UNATTENDED" = true ]; then
        log "unattended: parked design stalemate → blocked-pending-user at round $ROUND"
        unattended_block_terminal "$ROUND"
      fi
      : > "$GATE_MANIFEST"
```

(`unattended_block_terminal` ends in `approve`/`exit 0`, so the gate code below never runs in unattended mode.)

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bash tests/test_stop_hook.sh`
Expected: `PASS=… FAIL=0` (U1, U2, U3 all pass; all prior tests still pass).

- [ ] **Step 8: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh tests/test_stop_hook.sh
git commit -m "feat: unattended terminal defers essential design decisions honestly"
```

---

### Task 4: SessionStart hook — surface the pending count

A fail-open `SessionStart` hook announces how many pending decisions sit in the queue and where to look. It never blocks or alters anything.

**Files:**
- Create: `plugins/spar/hooks/session-start.sh`
- Modify: `plugins/spar/hooks/hooks.json`
- Test: `tests/test_session_start.sh`

**Interfaces:**
- Consumes: `reviews/spar-pending.md` (Task 1 / Task 3 write it) — counts `^## ` headings.
- Produces: on stdout, either nothing (queue absent/empty/unsafe) or a single JSON object `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}`. Always exits 0.

- [ ] **Step 1: Write the failing test**

Create `tests/test_session_start.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/plugins/spar/hooks/session-start.sh"
J="$ROOT/plugins/spar/hooks/hooks.json"
chk() { if printf '%s' "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_empty() { if [ -z "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1"; echo "  want:(empty)"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
run() { printf '%s' "$1" | bash "$H"; }
fresh() { d=$(mktemp -d); cd "$d" || exit 1; mkdir -p reviews; }

# 1. no queue → silent, exit 0
fresh
OUT="$(run '{"source":"startup"}')"; RC=$?
chk_empty "no queue → no output" "" "$OUT"
chk "no queue → exit 0" "0" "$RC"

# 2. queue with two entries → announces the count and the path
fresh
printf '# sparring — pending\n\n## id-a :: f | one\ntext\n\n## id-b :: g | two\ntext\n' > reviews/spar-pending.md
OUT="$(run '{"source":"startup"}')"
chk "announces additionalContext" "additionalContext" "$OUT"
chk "announces count 2" "2 design decision" "$OUT"
chk "points to the queue file" "reviews/spar-pending.md" "$OUT"
chk "valid json emitted" "hookSpecificOutput" "$OUT"

# 3. empty queue (no ## headings) → silent
fresh
printf '# sparring — pending\n\n(nothing pending)\n' > reviews/spar-pending.md
chk_empty "empty queue → no output" "" "$(run '{"source":"resume"}')"

# 4. symlinked queue → silent, never followed
fresh
outside=$(mktemp); printf '## x :: y\n' > "$outside"
ln -s "$outside" reviews/spar-pending.md
chk_empty "symlinked queue → no output" "" "$(run '{"source":"startup"}')"

# 5. hooks.json registers the SessionStart hook and stays valid json
jq -e . "$J" >/dev/null && { echo "PASS: hooks.json valid"; PASS=$((PASS+1)); } \
  || { echo "FAIL: hooks.json valid"; FAIL=$((FAIL+1)); }
chk "SessionStart command registered" "session-start.sh" "$(jq -r '.hooks.SessionStart[].hooks[].command' "$J")"
chk "Stop hook untouched" "stop-weighin.sh" "$(jq -r '.hooks.Stop[].hooks[].command' "$J")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_session_start.sh`
Expected: FAIL — the hook script and the `SessionStart` registration do not exist yet.

- [ ] **Step 3: Write the SessionStart hook**

Create `plugins/spar/hooks/session-start.sh`:

```bash
#!/usr/bin/env bash
# sparring — SessionStart hook. Best-effort: announce how many unattended
# design decisions are pending. Never blocks, never errors out a session.
set -uo pipefail
QUEUE="reviews/spar-pending.md"

trap 'exit 0' ERR      # any failure → stay silent, fail open
cat >/dev/null 2>&1 || true   # consume the hook JSON on stdin

# Only read a real regular file (never follow a symlink).
[ -f "$QUEUE" ] && [ ! -L "$QUEUE" ] || exit 0

n=$(grep -c '^## ' "$QUEUE" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) exit 0 ;; esac
[ "$n" -gt 0 ] || exit 0

msg="sparring: ${n} design decision(s) are pending from unattended run(s). See ${QUEUE} (and the matching reviews/spar-*-report.md) to resolve them."
jq -nc --arg c "$msg" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null \
  || printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s design decisions pending — see %s"}}\n' "$n" "$QUEUE"
exit 0
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x plugins/spar/hooks/session-start.sh`

- [ ] **Step 5: Register the hook in hooks.json**

Replace the entire contents of `plugins/spar/hooks/hooks.json` with:

```json
{
  "description": "Sparring loop stop hook: blocks exit until the independent reviewer declares CONVERGED (weigh-in dispatcher wraps spar's own hook). SessionStart hook surfaces pending unattended design decisions.",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh",
            "timeout": 10,
            "statusMessage": "sparring: checking for pending design decisions..."
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop-weighin.sh",
            "timeout": 60,
            "statusMessage": "sparring: checking loop phase..."
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 6: Run the new test and the hooks-json test to verify they pass**

Run: `bash tests/test_session_start.sh && bash tests/test_weighin_hooks_json.sh`
Expected: both `PASS=… FAIL=0` (the existing hooks-json test only inspects `.hooks.Stop`, which is unchanged).

- [ ] **Step 7: Commit**

```bash
git add plugins/spar/hooks/session-start.sh plugins/spar/hooks/hooks.json tests/test_session_start.sh
git commit -m "feat: SessionStart hook surfaces pending unattended decisions"
```

---

### Task 5: Thread `--unattended` through `/spar-weighin`

An unattended weigh-in runs each task's `/spar` unattended. Parse the flag in the weigh-in resolver, store it in weigh-in state, and have the launcher write it into each task's `.claude/spar.local.md`. No new terminal logic — a `blocked-pending-user` task already routes through `stop-weighin.sh`'s existing "stop honestly" path (spec §5).

**Files:**
- Modify: `plugins/spar/commands/spar-weighin-resolve.sh`
- Modify: `plugins/spar/commands/spar-weighin.md`
- Modify: `plugins/spar/commands/spar-weighin-launch.sh`
- Test: `tests/test_weighin_resolve.sh`
- Test: `tests/test_weighin_launch.sh`

**Interfaces:**
- Consumes: `spar-resolve-family.sh`'s state schema (Task 2) for the `unattended:` line format.
- Produces:
  - `spar-weighin-resolve.sh` output gains a field: `<mode>\t<reviewer|empty>\t<unattended>\t<spec>` (unattended ∈ `true|false`, default `false`).
  - Weigh-in state file frontmatter carries `unattended: true|false`.
  - `spar-weighin-launch.sh` writes `unattended: <val>` into each launched task's `.claude/spar.local.md` (missing in weigh-in state → `false`, keeping older weigh-ins working).

- [ ] **Step 1: Update the weigh-in resolver test (make it fail)**

Read the current expectations first: `sed -n '1,40p' tests/test_weighin_resolve.sh`. The output now has a `<unattended>` field before the spec. For every assertion that spells out the tab-joined resolver output, insert the extra field (default `false`, or `true` for the new `--unattended` cases). Add these `--unattended` cases near the other flag cases (adapt the exact `chk` helper name / invocation to match that file's harness):

```bash
# Phase 5: --unattended threads through the weigh-in resolver.
chk "weighin unattended default false" "per-task		false	spec.md" \
  "$(bash "$R" "spec.md")"
chk "weighin --unattended" "per-task		true	spec.md" \
  "$(bash "$R" "--unattended -- spec.md")"
chk "weighin --unattended with --whole + reviewer" "whole	codex	true	spec.md" \
  "$(bash "$R" "--whole --unattended --reviewer codex -- spec.md")"
chk "weighin duplicate --unattended → error" "error" \
  "$(bash "$R" "--unattended --unattended spec.md" 2>&1; echo)"
```

(The existing `<mode>\t<reviewer>\t<spec>` expectations become `<mode>\t<reviewer>\t<unattended>\t<spec>` — insert `false` before the spec in each.)

- [ ] **Step 2: Run the resolver test to verify it fails**

Run: `bash tests/test_weighin_resolve.sh`
Expected: FAIL — output still has 3 fields; the new field and `--unattended` cases fail.

- [ ] **Step 3: Add `--unattended` to the weigh-in resolver**

In `plugins/spar/commands/spar-weighin-resolve.sh`:

Replace the state-variable line:

```bash
mode="per-task"; reviewer=""; seen_mode=false; seen_rev=false
```

with:

```bash
mode="per-task"; reviewer=""; unattended=false; seen_mode=false; seen_rev=false; seen_unatt=false
```

Add two `--unattended` clauses inside the `while :; do` loop, immediately after the two `--whole` clauses (after the line `seen_mode=true; mode="whole"; remainder="${remainder#--whole }"`), before the `--reviewer` clauses:

```bash
  elif [ "$remainder" = "--unattended" ]; then
    [ "$seen_unatt" = false ] || { echo "error: --unattended specified more than once" >&2; exit 2; }
    seen_unatt=true; unattended=true; remainder=""
  elif [ "${remainder#--unattended }" != "$remainder" ]; then
    [ "$seen_unatt" = false ] || { echo "error: --unattended specified more than once" >&2; exit 2; }
    seen_unatt=true; unattended=true; remainder="${remainder#--unattended }"
```

Change the output line. Replace:

```bash
printf '%s\t%s\t%s\n' "$mode" "$reviewer" "$spec"
```

with:

```bash
printf '%s\t%s\t%s\t%s\n' "$mode" "$reviewer" "$unattended" "$spec"
```

- [ ] **Step 4: Run the resolver test to verify it passes**

Run: `bash tests/test_weighin_resolve.sh`
Expected: `PASS=… FAIL=0`.

- [ ] **Step 5: Store `unattended` in weigh-in state (the command)**

In `plugins/spar/commands/spar-weighin.md`, in the top setup `bash` block:

Update the resolver-output parsing. Replace:

```bash
WGN_MODE="${RESOLVED%%$'\t'*}"
WGN_REST="${RESOLVED#*$'\t'}"
WGN_REVIEWER="${WGN_REST%%$'\t'*}"
WGN_SPEC="${WGN_REST#*$'\t'}"
```

with:

```bash
WGN_MODE="${RESOLVED%%$'\t'*}"
WGN_REST="${RESOLVED#*$'\t'}"
WGN_REVIEWER="${WGN_REST%%$'\t'*}"
WGN_REST2="${WGN_REST#*$'\t'}"
WGN_UNATTENDED="${WGN_REST2%%$'\t'*}"
WGN_SPEC="${WGN_REST2#*$'\t'}"
```

Add the `unattended` line to the weigh-in state frontmatter written via the `cat > "$TMP"` heredoc. Replace:

```bash
mode: ${WGN_MODE}
reviewer: ${WGN_REVIEWER}
plan_path:
```

with:

```bash
mode: ${WGN_MODE}
reviewer: ${WGN_REVIEWER}
unattended: ${WGN_UNATTENDED}
plan_path:
```

Update the activation printf to report it. Replace:

```bash
printf 'Weigh-in activated (mode=%s, reviewer=%s, branch=%s)\nSPEC=%s\n' "$WGN_MODE" "$WGN_REVIEWER" "$WGN_BRANCH" "$WGN_SPEC"
```

with:

```bash
printf 'Weigh-in activated (mode=%s, reviewer=%s, unattended=%s, branch=%s)\nSPEC=%s\n' "$WGN_MODE" "$WGN_REVIEWER" "$WGN_UNATTENDED" "$WGN_BRANCH" "$WGN_SPEC"
```

- [ ] **Step 6: Write the failing launcher test**

Read the current launcher test harness first: `sed -n '1,60p' tests/test_weighin_launch.sh` (note how it builds a weigh-in state file and calls the launcher). Then append a case, adapting to that file's helper names and fixture setup:

```bash
# Phase 5: the launcher propagates unattended from weigh-in state into the task state.
# (Assumes the test's existing setup created a weigh-in state file $STATE with a
# reviewer and a task-text file $TASKFILE, as the earlier cases in this file do.)
wgn_set_field unattended true "$STATE" 2>/dev/null \
  || sed -i '' 's/^reviewer: .*/&\nunattended: true/' "$STATE" 2>/dev/null \
  || sed -i 's/^reviewer: .*/&\nunattended: true/' "$STATE"
bash "$LAUNCH" "$STATE" "$TASKFILE"
chk "task state marked unattended" "unattended: true" "$(cat .claude/spar.local.md)"

# default: weigh-in state without the field → task state defaults to unattended:false
: > "$STATE.noflag"; grep -v '^unattended:' "$STATE" > "$STATE.noflag"; mv "$STATE.noflag" "$STATE"
rm -f .claude/spar.local.md
bash "$LAUNCH" "$STATE" "$TASKFILE"
chk "missing weigh-in flag → task state unattended false" "unattended: false" "$(cat .claude/spar.local.md)"
```

- [ ] **Step 7: Run the launcher test to verify it fails**

Run: `bash tests/test_weighin_launch.sh`
Expected: FAIL — the launcher does not yet write an `unattended:` line into `.claude/spar.local.md`.

- [ ] **Step 8: Propagate `unattended` in the launcher**

In `plugins/spar/commands/spar-weighin-launch.sh`:

Read the flag from weigh-in state (default `false` when absent or malformed). After the `reviewer=` / reviewer `case` block (after the line ending `*) echo "error: bad reviewer in weighin state" >&2; exit 2 ;; esac`), add:

```bash
unattended="$(wgn_field unattended "$state")"
case "$unattended" in true) ;; ''|false) unattended=false ;; *) unattended=false ;; esac
```

Add the `unattended` line to the task-state heredoc. Replace:

```bash
reviewer: ${reviewer}
include_dirty: false
max_rounds: 5
```

with:

```bash
reviewer: ${reviewer}
include_dirty: false
unattended: ${unattended}
max_rounds: 5
```

- [ ] **Step 9: Run the launcher test to verify it passes**

Run: `bash tests/test_weighin_launch.sh`
Expected: `PASS=… FAIL=0`.

- [ ] **Step 10: Commit**

```bash
git add plugins/spar/commands/spar-weighin-resolve.sh plugins/spar/commands/spar-weighin.md plugins/spar/commands/spar-weighin-launch.sh tests/test_weighin_resolve.sh tests/test_weighin_launch.sh
git commit -m "feat: --unattended threads through /spar-weighin into each task"
```

- [ ] **Step 11: Run the full test suite**

Run: `for t in tests/test_*.sh; do echo "== $t =="; bash "$t" || echo "FAILED: $t"; done`
Expected: every test file ends `FAIL=0`; no `FAILED:` line printed.

---

## Self-Review notes

- **Spec §1 (activation)** → Tasks 2 + 5 (`--unattended` in both resolvers, persisted to state; no auto-detection).
- **Spec §2 (gate behavior)** → Task 3 (`unattended_block_terminal` fires at `only_parked_this_round`, before the round-cap check, in the exact order: queue → record `blocked-pending-user` → report → cleanup → approve).
- **Spec §3 (essential-by-default)** → Task 3 (every parked finding is queued and forces `blocked-pending-user`; no new marker/parser; missing/malformed classification never converges).
- **Spec §4 (cross-session surfacing)** → Task 1 (durable queue under `reviews/`, keyed by review-id + fingerprint, dedup, symlink-safe) + Task 4 (fail-open SessionStart hook announcing the count).
- **Spec §5 (weigh-in)** → Task 5 (flag threading only; the existing `stop-weighin.sh` `*)` branch already stops honestly on `blocked-pending-user`).
- **Malformed-value / fail-open invariants** → Task 3 Step 4 (error-bypass) + the best-effort guards in Tasks 1, 3, 4.
- **Report half of Phase 5** → intentionally NOT implemented here; Task 3 only adds the guarded fail-open call site (`REPORT_GEN`), which no-ops until `spar-report.sh` lands under its own spec.
- **Residual (round cap)** → left identical per the spec's default; no task changes the cap.
