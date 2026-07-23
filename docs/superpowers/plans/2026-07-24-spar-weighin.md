# `/spar-weighin` Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/spar-weighin` command that turns a spec into a checkbox plan, sets up an isolated ring, and drives the enforced `spar` loop task-by-task (or over the whole plan) to convergence.

**Architecture:** `/spar-weighin` is a **separate command in the `spar` plugin** that wraps `spar`; it never edits `spar`'s loop internals. It adds a **second Stop hook** (`stop-weighin.sh`) registered to run **after** `spar`'s existing `stop-hook.sh` in the same `hooks.json` Stop array. `spar`'s hook drives one task's review loop and, on any terminal outcome, writes `reviews/spar-<id>-outcome.md` and removes `.claude/spar.local.md`. The weighin hook keys purely on "`.claude/spar.local.md` absent + the current task's outcome file present" to advance: flip the plan's checkboxes for that task, commit, and launch the next task's `spar` — or finish. Because weighin lives in the same plugin, we control hook order, which removes the same-event race.

**Tech Stack:** POSIX/bash, `jq`, `git`, Claude Code plugin hooks. Pure-bash tests in `tests/` (no framework), matching the existing `test_*.sh` style.

## Global Constraints

- Fail **open**: any weighin-hook-internal error must approve exit (never trap the user), mirroring `spar`'s Stop hook (`plugins/spar/hooks/stop-hook.sh:75`).
- The weighin hook must be a **no-op** (approve) whenever `.claude/spar-weighin.local.md` is absent or `.claude/spar.local.md` is present — it only acts in the gap between tasks.
- Never write `spar`'s convergence marker, and never fabricate a `spar` outcome. Task success is read from `reviews/spar-<id>-outcome.md`'s `reason:` field, which only `spar` writes.
- weighin never edits `spar`'s state machine files or `stop-hook.sh`. Its only touch of existing `spar` files is: adding a second entry to `hooks.json`, and extending `/spar-cancel` to also tear down weighin state.
- State/artifact hygiene: reuse `spar`'s existing git-exclude patterns `.claude/spar*` and `reviews/spar-*` (they already match weighin's `.claude/spar-weighin*` files) so `git add -A` in weighin's per-task commit never stages loop artifacts.
- Command surface: `/spar-weighin [--whole] [--reviewer codex|claude] [--] <spec path or description>`. Default is per-task execution.
- Non-converged default: if a task's `spar` ends non-converged (`cap`, `sweep-findings-at-cap`, `cancelled`, `error-bypass`), weighin **stops and reports honestly** — it does not advance to the next task.

---

## Task 1: Hook-ordering spike

**Files:**
- Create: `docs/superpowers/notes/weighin-hook-order-spike.md`

**Interfaces:**
- Produces: a documented, verified answer to "when two Stop hooks are registered in one plugin's `hooks.json` Stop array, do they run in array order, and does a `block` from any hook override an `approve` from another?" All later tasks depend on the answer being "yes, array order; block wins."

This is a real experiment, not a code change. Everything downstream assumes `spar`'s hook runs first and the weighin hook second, and that a single `block` keeps the session alive.

- [ ] **Step 1: Register a throwaway probe pair of Stop hooks**

Temporarily add to a scratch copy of `plugins/spar/hooks/hooks.json` a second Stop hook after the existing one, both pointing at a probe script that appends `"$1 $(date +%s%N)"` to `/tmp/weighin-probe.log` and prints a decision. Run one hook printing `{"decision":"approve"}` first and one printing `{"decision":"block","reason":"probe"}` second; then swap them.

- [ ] **Step 2: Trigger Stop in a scratch session and read the log**

In a throwaway Claude Code session, cause a Stop and inspect `/tmp/weighin-probe.log`: confirm both scripts ran, confirm the append order matches the array order, and confirm the session stayed alive (blocked) whenever exactly one hook blocked, regardless of position.

- [ ] **Step 3: Record findings and the load-bearing assumption**

Write `docs/superpowers/notes/weighin-hook-order-spike.md`: the observed ordering guarantee, the block-wins semantics, and — if either does NOT hold — the fallback (fold the weighin advance into a single combined hook that calls `stop-hook.sh` as a subroutine). Commit.

```bash
git add docs/superpowers/notes/weighin-hook-order-spike.md
git commit -m "docs: verify two-hook Stop ordering for weighin"
```

If Step 2 shows order is NOT guaranteed, STOP and revise this plan to use one combined hook before continuing.

---

## Task 2: weighin state file + field readers

**Files:**
- Create: `plugins/spar/commands/spar-weighin-lib.sh`
- Test: `tests/test_weighin_lib.sh`

**Interfaces:**
- Produces:
  - State file `.claude/spar-weighin.local.md` with YAML-ish frontmatter fields: `active` (true), `phase` (plan|running|done), `mode` (per-task|whole), `reviewer` (codex|claude), `plan_path`, `worktree`, `tasks` (integer count), `current` (1-based integer), `current_review_id` (spar id or empty).
  - Sourced helpers (all read `.claude/spar-weighin.local.md` unless `$1` overrides the path):
    - `wgn_field <name> [file]` → prints the frontmatter field value.
    - `wgn_task_line <index> [file]` → prints the task-table row for a 1-based index. Task rows live after the second `---` as TSV: `<index>\t<status>\t<heading>` where status ∈ `pending|done|stopped`.
    - `wgn_set_field <name> <value> [file]` → in-place update of a frontmatter field (atomic via temp+mv).
    - `wgn_set_task_status <index> <status> [file]` → update a task row's status column.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_weighin_lib.sh
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/plugins/spar/commands/spar-weighin-lib.sh"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }
. "$LIB"

TMP=$(mktemp -d); ST="$TMP/state.md"
cat > "$ST" <<'EOF'
---
active: true
phase: running
mode: per-task
reviewer: codex
plan_path: docs/superpowers/plans/x.md
worktree: /tmp/wt
tasks: 2
current: 1
current_review_id:
---
1	pending	Task 1: Alpha
2	pending	Task 2: Beta
EOF

chk "field phase" "running" "$(wgn_field phase "$ST")"
chk "field tasks" "2" "$(wgn_field tasks "$ST")"
chk "empty review_id" "" "$(wgn_field current_review_id "$ST")"
chk "task line 2 heading" "Task 2: Beta" "$(wgn_task_line 2 "$ST" | cut -f3)"

wgn_set_field current 2 "$ST"
chk "set current" "2" "$(wgn_field current "$ST")"
wgn_set_field current_review_id 20260724-101010-abc123 "$ST"
chk "set review_id" "20260724-101010-abc123" "$(wgn_field current_review_id "$ST")"

wgn_set_task_status 1 done "$ST"
chk "task 1 done" "done" "$(wgn_task_line 1 "$ST" | cut -f2)"
chk "task 2 untouched" "pending" "$(wgn_task_line 2 "$ST" | cut -f2)"

rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_weighin_lib.sh`
Expected: FAIL — `spar-weighin-lib.sh` does not exist (source error).

- [ ] **Step 3: Implement `spar-weighin-lib.sh`**

```bash
#!/usr/bin/env bash
# Shared readers/writers for the weighin state file. Sourced, never executed.
# State file layout:
#   ---
#   <frontmatter: name: value>
#   ---
#   <task table: index<TAB>status<TAB>heading  (one row per task)>
WGN_STATE_DEFAULT=".claude/spar-weighin.local.md"

wgn_field() { # $1=name [$2=file]
  local f="${2:-$WGN_STATE_DEFAULT}"
  sed -n "s/^${1}: *//p" "$f" 2>/dev/null | head -1
}

wgn_task_line() { # $1=index [$2=file]
  local f="${2:-$WGN_STATE_DEFAULT}"
  awk -v i="$1" 'c>=2 && $1==i {print; exit}' FS='\t' \
    <(awk '/^---$/{c++} {print}' "$f" 2>/dev/null) 2>/dev/null
}

wgn_set_field() { # $1=name $2=value [$3=file]
  local f="${3:-$WGN_STATE_DEFAULT}" tmp
  tmp="${f}.tmp.$$"
  awk -v k="$1" -v v="$2" '
    BEGIN{done=0}
    /^---$/ {marks++}
    marks<2 && $0 ~ "^" k ": " && !done { print k ": " v; done=1; next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

wgn_set_task_status() { # $1=index $2=status [$3=file]
  local f="${3:-$WGN_STATE_DEFAULT}" tmp
  tmp="${f}.tmp.$$"
  awk -v i="$1" -v s="$2" '
    BEGIN{c=0}
    /^---$/ {c++; print; next}
    c>=2 && $1==i { print $1 "\t" s "\t" substr($0, index($0,$3)); next }
    { print }
  ' FS='\t' OFS='\t' "$f" > "$tmp" && mv "$tmp" "$f"
}
```

Note: `wgn_task_line`'s awk uses a nested awk to count the `---` fences and then filter on FS='\t'; keep the two-pass form shown so the fence lines (which are not tab-delimited) never match a task row.

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_weighin_lib.sh`
Expected: `PASS=8 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/commands/spar-weighin-lib.sh tests/test_weighin_lib.sh
git commit -m "feat: weighin state file readers/writers"
```

---

## Task 3: Argument resolver

**Files:**
- Create: `plugins/spar/commands/spar-weighin-resolve.sh`
- Test: `tests/test_weighin_resolve.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `spar-weighin-resolve.sh "<raw args as ONE string>"` prints `<mode>\t<reviewer-or-empty>\t<spec>` where `mode ∈ per-task|whole`, and exits non-zero with `error: …` on an unusable resolution. Reviewer, when present, must be `codex|claude`; empty means "let spar auto-detect". This mirrors the single-string, no-argv-split contract of `spar-resolve-family.sh`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_weighin_resolve.sh
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="$ROOT/plugins/spar/commands/spar-weighin-resolve.sh"
chk(){ if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }

chk "plain spec path" "per-task	 	docs/superpowers/specs/x.md" "$(bash "$R" "docs/superpowers/specs/x.md")"
chk "whole flag" "whole		build the thing" "$(bash "$R" "--whole -- build the thing")"
chk "reviewer passthrough" "per-task	claude	fix it" "$(bash "$R" "--reviewer claude -- fix it")"
chk "whole + reviewer either order" "whole	codex	go" "$(bash "$R" "--reviewer codex --whole -- go")"
chk "bad reviewer errors" "error" "$(bash "$R" "--reviewer bogus -- x" 2>&1; echo)"
chk "empty spec errors" "error" "$(bash "$R" "" 2>&1; echo)"
chk "dashed spec after --" "per-task		--weird-spec-name" "$(bash "$R" "-- --weird-spec-name")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

(The `\t` gaps above are literal tabs in the expected substrings; the resolver prints empty reviewer as an empty field between two tabs.)

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_weighin_resolve.sh`
Expected: FAIL — resolver missing.

- [ ] **Step 3: Implement `spar-weighin-resolve.sh`**

```bash
#!/usr/bin/env bash
# Resolve /spar-weighin flags from the ONE-string argument, strip them,
# and print: "<mode>\t<reviewer|empty>\t<spec>". Never argv-split the input.
set -uo pipefail
raw="${1-}"
stripped="$raw"
if [ "$stripped" = "--" ]; then stripped=""
elif [ "${stripped#-- }" != "$stripped" ]; then stripped="${stripped#-- }"; fi

mode="per-task"; reviewer=""; seen_mode=false; seen_rev=false
remainder="$stripped"
while :; do
  if [ "$remainder" = "--" ]; then remainder=""; break
  elif [ "${remainder#-- }" != "$remainder" ]; then remainder="${remainder#-- }"; break
  elif [ "$remainder" = "--whole" ]; then
    [ "$seen_mode" = false ] || { echo "error: --whole specified more than once" >&2; exit 2; }
    seen_mode=true; mode="whole"; remainder=""
  elif [ "${remainder#--whole }" != "$remainder" ]; then
    [ "$seen_mode" = false ] || { echo "error: --whole specified more than once" >&2; exit 2; }
    seen_mode=true; mode="whole"; remainder="${remainder#--whole }"
  elif [ "$remainder" = "--reviewer" ]; then echo "error: --reviewer must be codex|claude" >&2; exit 2
  elif [ "${remainder#--reviewer }" != "$remainder" ]; then
    [ "$seen_rev" = false ] || { echo "error: --reviewer specified more than once" >&2; exit 2; }
    seen_rev=true; after="${remainder#--reviewer }"; value="${after%% *}"
    if [ "$value" = "$after" ]; then remainder=""; else remainder="${after#* }"; fi
    case "$value" in codex|claude) reviewer="$value" ;; *) echo "error: --reviewer must be codex|claude" >&2; exit 2 ;; esac
  else break; fi
done
spec="${remainder%$'\n'}"
[ -n "$spec" ] || { echo "error: no spec path or description given" >&2; exit 2; }
printf '%s\t%s\t%s\n' "$mode" "$reviewer" "$spec"
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_weighin_resolve.sh`
Expected: `PASS=7 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/commands/spar-weighin-resolve.sh tests/test_weighin_resolve.sh
git commit -m "feat: weighin argument resolver"
```

---

## Task 4: Plan ingest (spec → task table)

**Files:**
- Create: `plugins/spar/commands/spar-weighin-ingest.sh`
- Test: `tests/test_weighin_ingest.sh`

**Interfaces:**
- Consumes: `spar-weighin-lib.sh` (Task 2) for `wgn_set_field`.
- Produces: `spar-weighin-ingest.sh <plan-path> <mode> <state-file>` parses the plan's `### Task N: <heading>` sections in order, appends one TSV task row per task (`<index>\tpending\t<heading>`) after the state file's second `---`, and sets `tasks:` and `phase: running`. In `whole` mode it writes a single synthetic row `1\tpending\tWHOLE PLAN` and `tasks: 1`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_weighin_ingest.sh
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/plugins/spar/commands/spar-weighin-ingest.sh"
LIB="$ROOT/plugins/spar/commands/spar-weighin-lib.sh"; . "$LIB"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); PLAN="$TMP/plan.md"; ST="$TMP/state.md"
cat > "$PLAN" <<'EOF'
# X Plan
### Task 1: Alpha
- [ ] Step 1
### Task 2: Beta component
- [ ] Step 1
### Task 3: Gamma
EOF
printf -- '---\nactive: true\nphase: plan\nmode: per-task\nreviewer: codex\nplan_path: %s\nworktree: /tmp/wt\ntasks: 0\ncurrent: 1\ncurrent_review_id:\n---\n' "$PLAN" > "$ST"

bash "$I" "$PLAN" per-task "$ST"
chk "counts 3 tasks" "3" "$(wgn_field tasks "$ST")"
chk "phase running" "running" "$(wgn_field phase "$ST")"
chk "task 2 heading" "Task 2: Beta component" "$(wgn_task_line 2 "$ST" | cut -f3)"
chk "task 3 status" "pending" "$(wgn_task_line 3 "$ST" | cut -f2)"

# whole mode → single synthetic task
printf -- '---\nactive: true\nphase: plan\nmode: whole\nreviewer: codex\nplan_path: %s\nworktree: /tmp/wt\ntasks: 0\ncurrent: 1\ncurrent_review_id:\n---\n' "$PLAN" > "$ST"
bash "$I" "$PLAN" whole "$ST"
chk "whole → 1 task" "1" "$(wgn_field tasks "$ST")"
chk "whole heading" "WHOLE PLAN" "$(wgn_task_line 1 "$ST" | cut -f3)"

rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_weighin_ingest.sh`
Expected: FAIL — ingest missing.

- [ ] **Step 3: Implement `spar-weighin-ingest.sh`**

```bash
#!/usr/bin/env bash
# Parse a writing-plans plan into the weighin task table.
# Usage: spar-weighin-ingest.sh <plan-path> <mode> <state-file>
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/spar-weighin-lib.sh"
plan="${1:?plan path}"; mode="${2:?mode}"; state="${3:?state file}"
[ -f "$plan" ] || { echo "error: plan not found: $plan" >&2; exit 2; }

rows=""; count=0
if [ "$mode" = "whole" ]; then
  count=1; rows="1	pending	WHOLE PLAN"
else
  while IFS= read -r heading; do
    count=$((count+1))
    rows="${rows}${count}	pending	${heading}
"
  done < <(sed -n 's/^### \(Task [0-9][0-9]*:.*\)$/\1/p' "$plan")
  [ "$count" -gt 0 ] || { echo "error: no '### Task N:' sections found in $plan" >&2; exit 2; }
fi

# Replace everything after the second '---' with the task table.
tmp="${state}.tmp.$$"
awk '/^---$/{c++} c<2{print} c==2 && !done{print; done=1}' "$state" > "$tmp"
printf '%s\n' "$rows" | sed '/^$/d' >> "$tmp"
mv "$tmp" "$state"
wgn_set_field tasks "$count" "$state"
wgn_set_field phase running "$state"
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_weighin_ingest.sh`
Expected: `PASS=6 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/commands/spar-weighin-ingest.sh tests/test_weighin_ingest.sh
git commit -m "feat: weighin plan ingest into task table"
```

---

## Task 5: Checkbox flipping for a task section

**Files:**
- Create: `plugins/spar/commands/spar-weighin-check.sh`
- Test: `tests/test_weighin_check.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `spar-weighin-check.sh <plan-path> <task-index>` flips every `- [ ]` to `- [x]` within the `### Task <index>:` section (from that heading up to the next `### ` heading or EOF). In `whole` callers pass index `0`, which flips **all** `- [ ]` in the file. Idempotent.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_weighin_check.sh
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/plugins/spar/commands/spar-weighin-check.sh"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); PLAN="$TMP/plan.md"
cat > "$PLAN" <<'EOF'
### Task 1: A
- [ ] step a1
- [ ] step a2
### Task 2: B
- [ ] step b1
EOF
bash "$C" "$PLAN" 1
chk "task1 line1 checked" "- [x] step a1" "$(sed -n '2p' "$PLAN")"
chk "task1 line2 checked" "- [x] step a2" "$(sed -n '3p' "$PLAN")"
chk "task2 untouched" "- [ ] step b1" "$(sed -n '5p' "$PLAN")"

# whole (index 0) flips everything
cat > "$PLAN" <<'EOF'
### Task 1: A
- [ ] step a1
### Task 2: B
- [ ] step b1
EOF
bash "$C" "$PLAN" 0
chk "whole flips a1" "- [x] step a1" "$(sed -n '2p' "$PLAN")"
chk "whole flips b1" "- [x] step b1" "$(sed -n '4p' "$PLAN")"

rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_weighin_check.sh`
Expected: FAIL — checker missing.

- [ ] **Step 3: Implement `spar-weighin-check.sh`**

```bash
#!/usr/bin/env bash
# Flip '- [ ]' to '- [x]' within one task section (or all, when index=0).
# Usage: spar-weighin-check.sh <plan-path> <task-index>
set -uo pipefail
plan="${1:?plan path}"; idx="${2:?task index}"
[ -f "$plan" ] || { echo "error: plan not found: $plan" >&2; exit 2; }
tmp="${plan}.tmp.$$"
awk -v idx="$idx" '
  function flip(line){ sub(/- \[ \]/, "- [x]", line); return line }
  idx==0 { print flip($0); next }
  /^### Task [0-9]+:/ {
    n=$3; sub(/:.*/, "", n); # "### Task N:" -> field 3 is "N:" ; strip trailing colon
    gsub(/[^0-9]/, "", n)
    inzone = (n==idx)
    print; next
  }
  /^### / { inzone=0; print; next }
  { print inzone ? flip($0) : $0 }
' "$plan" > "$tmp" && mv "$tmp" "$plan"
```

Note: `$3` on a `### Task N:` line is the number-with-colon token; `gsub(/[^0-9]/,"",n)` reduces it to the bare integer for comparison.

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_weighin_check.sh`
Expected: `PASS=5 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/commands/spar-weighin-check.sh tests/test_weighin_check.sh
git commit -m "feat: weighin checkbox flipping per task section"
```

---

## Task 6: Task launcher (activate spar for one task)

**Files:**
- Create: `plugins/spar/commands/spar-weighin-launch.sh`
- Test: `tests/test_weighin_launch.sh`

**Interfaces:**
- Consumes: `spar-weighin-lib.sh` (Task 2).
- Produces: `spar-weighin-launch.sh <state-file> <task-text-file>` writes a fresh, valid `.claude/spar.local.md` for the current task (phase `task`, round `0`, `base_sha` = current `HEAD`, `reviewer` from weighin state, `active: true`, `max_rounds: 5`, `sweep_done: false`, `sweep_result: not-run`), using a freshly generated `review_id` in `spar`'s exact format (`YYYYmmdd-HHMMSS-<6 hex>`). It records that id into weighin state's `current_review_id`. The task body is read from `<task-text-file>` verbatim. This reproduces only the state-writing portion of `/spar` setup; it deliberately does NOT run the dirty-worktree guard (weighin guarantees a clean tree by committing between tasks).

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_weighin_launch.sh
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/plugins/spar/commands/spar-weighin-launch.sh"
LIB="$ROOT/plugins/spar/commands/spar-weighin-lib.sh"; . "$LIB"
chk(){ if echo "$3" | grep -qE "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want~:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
eqchk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); cd "$TMP"; git init -q; git commit -q --allow-empty -m init
mkdir -p .claude
ST=".claude/spar-weighin.local.md"
printf -- '---\nactive: true\nphase: running\nmode: per-task\nreviewer: codex\nplan_path: p.md\nworktree: %s\ntasks: 2\ncurrent: 1\ncurrent_review_id:\n---\n1\tpending\tTask 1: Alpha\n' "$TMP" > "$ST"
printf 'Implement Task 1: Alpha\nDo the alpha thing.\n' > .claude/task.txt

bash "$L" "$ST" .claude/task.txt

SPAR=".claude/spar.local.md"
[ -f "$SPAR" ] && echo "PASS: spar state written" && PASS=$((PASS+1)) || { echo "FAIL: spar state written"; FAIL=$((FAIL+1)); }
chk "review_id format" '^review_id: [0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' "$(grep '^review_id:' "$SPAR")"
eqchk "phase task" "task" "$(sed -n 's/^phase: //p' "$SPAR" | head -1)"
eqchk "round 0" "0" "$(sed -n 's/^round: //p' "$SPAR" | head -1)"
eqchk "reviewer codex" "codex" "$(sed -n 's/^reviewer: //p' "$SPAR" | head -1)"
chk "task body carried" "Do the alpha thing" "$(cat "$SPAR")"
# weighin recorded the id
RID="$(grep '^review_id:' "$SPAR" | sed 's/^review_id: //')"
eqchk "weighin current_review_id set" "$RID" "$(wgn_field current_review_id "$ST")"

cd /; rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_weighin_launch.sh`
Expected: FAIL — launcher missing.

- [ ] **Step 3: Implement `spar-weighin-launch.sh`**

```bash
#!/usr/bin/env bash
# Activate a spar loop for the weighin current task by writing a valid
# .claude/spar.local.md, and record the generated review_id in weighin state.
# Usage: spar-weighin-launch.sh <weighin-state-file> <task-text-file>
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/spar-weighin-lib.sh"
state="${1:?weighin state}"; taskfile="${2:?task text file}"
[ -f "$taskfile" ] || { echo "error: task text file not found" >&2; exit 2; }

reviewer="$(wgn_field reviewer "$state")"
case "$reviewer" in codex|claude) ;; *) echo "error: bad reviewer in weighin state" >&2; exit 2 ;; esac

id="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
base="$(git rev-parse HEAD 2>/dev/null || echo none)"

mkdir -p .claude
tmp="$(mktemp .claude/spar.local.md.tmp.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
{
  cat <<STATE_EOF
---
active: true
phase: task
round: 0
review_id: ${id}
base_sha: ${base}
reviewer: ${reviewer}
include_dirty: false
max_rounds: 5
sweep_done: false
sweep_result: not-run
---

STATE_EOF
  cat "$taskfile"
} > "$tmp"
mv "$tmp" .claude/spar.local.md
trap - EXIT
wgn_set_field current_review_id "$id" "$state"
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_weighin_launch.sh`
Expected: `PASS=8 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/commands/spar-weighin-launch.sh tests/test_weighin_launch.sh
git commit -m "feat: weighin task launcher (activates spar per task)"
```

---

## Task 7: The weighin Stop hook

**Files:**
- Create: `plugins/spar/hooks/stop-weighin.sh`
- Test: `tests/test_stop_weighin.sh`

**Interfaces:**
- Consumes: `spar-weighin-lib.sh` (Task 2), `spar-weighin-check.sh` (Task 5), `spar-weighin-launch.sh` (Task 6), and the current task's `reviews/spar-<id>-outcome.md` (written by `spar`'s hook).
- Produces: a Stop hook that reads only weighin + `spar` state/outcome files and prints a `{"decision":...}` JSON. Advances, finishes, or stops-and-reports. Fails open on any internal error. Must be registered to run AFTER `spar`'s `stop-hook.sh` (Task 8).

**Behavior (the algorithm):**
1. No `.claude/spar-weighin.local.md`, or `active` != true → `approve`.
2. `phase` != `running` → `approve` (plan phase is agent-driven; done is terminal).
3. `.claude/spar.local.md` present → `approve` (a task's `spar` loop is in flight; `spar`'s hook, which ran first, drives it).
4. `current_review_id` empty → `approve` (task not launched yet; the command body launches task 1).
5. Read `reviews/spar-<current_review_id>-outcome.md`. Missing → `approve` (fail open; `spar` always writes one on any terminal path).
6. `reason` = the outcome's `reason:` field:
   - `converged` or `skipped` → **task success**: flip checkboxes for `current` (index `0` when `mode=whole`), mark the task row `done`, `git add -A && git commit`. Then:
     - if `current` < `tasks` → increment `current`, write next task's text to `.claude/spar-weighin-task.txt`, launch it, `block` with the next task's implement-then-stop instructions.
     - else → set `phase: done`, record a weighin outcome line, `block` with a "all tasks converged — summarize and stop" message (the next stop, with `phase=done`, approves).
   - anything else (`cap`, `sweep-findings-at-cap`, `cancelled`, `error-bypass`) → mark the task row `stopped`, set `phase: done`, `block` with an honest "task N did not converge — report unresolved findings from its review and stop" message.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_stop_weighin.sh
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/plugins/spar/hooks/stop-weighin.sh"
chk(){ if echo "$3" | grep -qF "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want~:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }

# Each case runs in its own temp git repo so commits work.
setup(){ TMP=$(mktemp -d); cd "$TMP"; git init -q; git config user.email a@b.c; git config user.name t; git commit -q --allow-empty -m init; mkdir -p .claude reviews docs; export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/spar"; }
teardown(){ cd /; rm -rf "$TMP"; }
wstate(){ printf -- '---\nactive: true\nphase: %s\nmode: %s\nreviewer: codex\nplan_path: %s\nworktree: %s\ntasks: %s\ncurrent: %s\ncurrent_review_id: %s\n---\n' "$1" "$2" "$3" "$TMP" "$4" "$5" "$6"; }
outcome(){ printf -- '---\nreason: %s\nreview_id: %s\nrounds: 2\nreviewer: codex\nsweep: not-triggered\nrecorded_at: x\n---\n' "$1" "$2"; }

# Case A: no weighin state → approve
setup
chk "A no-state approve" '"approve"' "$(echo '{}' | bash "$HOOK")"
teardown

# Case B: spar loop in flight → approve
setup
wstate running per-task docs/p.md 2 1 20260724-101010-aaaaaa > .claude/spar-weighin.local.md
printf 'x' > .claude/spar.local.md
chk "B spar active approve" '"approve"' "$(echo '{}' | bash "$HOOK")"
teardown

# Case C: task 1 converged, task 2 remains → block + advance + checkbox + launch
setup
cat > docs/p.md <<'EOF'
### Task 1: Alpha
- [ ] a
### Task 2: Beta
- [ ] b
EOF
git add docs/p.md; git commit -q -m plan
wstate running per-task docs/p.md 2 1 20260724-101010-aaaaaa > .claude/spar-weighin.local.md
printf '1\tpending\tTask 1: Alpha\n2\tpending\tTask 2: Beta\n' >> .claude/spar-weighin.local.md
outcome converged 20260724-101010-aaaaaa > reviews/spar-20260724-101010-aaaaaa-outcome.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "C blocks" '"block"' "$OUT"
chk "C task1 checkbox flipped" "- [x] a" "$(sed -n '2p' docs/p.md)"
chk "C launched task2 spar" "review_id" "$(cat .claude/spar.local.md 2>/dev/null)"
teardown

# Case D: last task converged → finish (block to summarize, phase done)
setup
cat > docs/p.md <<'EOF'
### Task 1: Alpha
- [ ] a
EOF
git add docs/p.md; git commit -q -m plan
wstate running per-task docs/p.md 1 1 20260724-101010-bbbbbb > .claude/spar-weighin.local.md
printf '1\tpending\tTask 1: Alpha\n' >> .claude/spar-weighin.local.md
outcome converged 20260724-101010-bbbbbb > reviews/spar-20260724-101010-bbbbbb-outcome.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "D blocks with summary" '"block"' "$OUT"
chk "D phase done" "phase: done" "$(cat .claude/spar-weighin.local.md)"
teardown

# Case E: task hit cap → stop and report honestly
setup
cat > docs/p.md <<'EOF'
### Task 1: Alpha
- [ ] a
### Task 2: Beta
- [ ] b
EOF
git add docs/p.md; git commit -q -m plan
wstate running per-task docs/p.md 2 1 20260724-101010-cccccc > .claude/spar-weighin.local.md
printf '1\tpending\tTask 1: Alpha\n2\tpending\tTask 2: Beta\n' >> .claude/spar-weighin.local.md
outcome cap 20260724-101010-cccccc > reviews/spar-20260724-101010-cccccc-outcome.md
OUT="$(echo '{}' | bash "$HOOK")"
chk "E blocks" '"block"' "$OUT"
chk "E does not converge" "did not converge" "$OUT"
chk "E phase done" "phase: done" "$(cat .claude/spar-weighin.local.md)"
chk "E task2 not launched" "" "$(cat .claude/spar.local.md 2>/dev/null)"
teardown

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_stop_weighin.sh`
Expected: FAIL — hook missing.

- [ ] **Step 3: Implement `stop-weighin.sh`**

```bash
#!/usr/bin/env bash
# sparring weigh-in — second Stop hook. Runs AFTER spar's stop-hook.sh.
# Advances the plan task-by-task once each task's spar loop has terminated.
# Fails OPEN on any internal error. Acts only in the gap between tasks.
set -uo pipefail
WGN_STATE=".claude/spar-weighin.local.md"
SPAR_STATE=".claude/spar.local.md"
LOG=".claude/spar-weighin.log"
DIR="${CLAUDE_PLUGIN_ROOT:-}/commands"
LIB="$DIR/spar-weighin-lib.sh"
CHECK="$DIR/spar-weighin-check.sh"
LAUNCH="$DIR/spar-weighin-launch.sh"
TASKFILE=".claude/spar-weighin-task.txt"

log(){ mkdir -p .claude; echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }
approve(){ printf '{"decision":"approve"}\n'; exit 0; }
block(){ jq -nc --arg r "$1" --arg s "${2:-sparring weigh-in}" \
  '{decision:"block",reason:$r,systemMessage:$s}' 2>/dev/null \
  || printf '{"decision":"block","reason":"weighin"}\n'; exit 0; }

trap 'log "ERR line $LINENO — fail open"; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR
cat >/dev/null  # consume hook stdin

[ -f "$WGN_STATE" ] || approve
[ -f "$LIB" ] || approve
. "$LIB"

[ "$(wgn_field active "$WGN_STATE")" = "true" ] || approve
[ "$(wgn_field phase "$WGN_STATE")" = "running" ] || approve
[ -f "$SPAR_STATE" ] && approve   # a task loop is in flight; spar's hook drives it

RID="$(wgn_field current_review_id "$WGN_STATE")"
[ -n "$RID" ] || approve          # task not launched yet
OUTCOME="reviews/spar-${RID}-outcome.md"
[ -f "$OUTCOME" ] || approve      # no terminal yet — fail open

REASON="$(sed -n 's/^reason: *//p' "$OUTCOME" | head -1)"
CUR="$(wgn_field current "$WGN_STATE")"
TASKS="$(wgn_field tasks "$WGN_STATE")"
MODE="$(wgn_field mode "$WGN_STATE")"
PLAN="$(wgn_field plan_path "$WGN_STATE")"
case "$CUR" in ''|*[!0-9]*) log "bad current"; approve;; esac
case "$TASKS" in ''|*[!0-9]*) log "bad tasks"; approve;; esac

HEADING="$(wgn_task_line "$CUR" "$WGN_STATE" | cut -f3)"

case "$REASON" in
  converged|skipped)
    idx="$CUR"; [ "$MODE" = "whole" ] && idx=0
    [ -f "$PLAN" ] && bash "$CHECK" "$PLAN" "$idx" 2>>"$LOG" || log "checkbox flip skipped"
    wgn_set_task_status "$CUR" done "$WGN_STATE"
    git add -A 2>>"$LOG" || true
    git commit -q -m "weighin: task ${CUR} (${HEADING}) — ${REASON}" 2>>"$LOG" || log "nothing to commit for task $CUR"
    if [ "$CUR" -lt "$TASKS" ]; then
      NEXT=$((CUR+1)); wgn_set_field current "$NEXT" "$WGN_STATE"
      wgn_set_field current_review_id "" "$WGN_STATE"
      NHEAD="$(wgn_task_line "$NEXT" "$WGN_STATE" | cut -f3)"
      # Build the next task's text from its plan section (whole mode: entire plan).
      if [ "$MODE" = "whole" ]; then cp "$PLAN" "$TASKFILE"
      else awk -v h="### ${NHEAD}" '$0==h{f=1} f&&/^### /&&$0!=h&&seen{exit} $0==h{seen=1} f{print}' "$PLAN" > "$TASKFILE"; fi
      bash "$LAUNCH" "$WGN_STATE" "$TASKFILE" 2>>"$LOG" || { log "launch failed"; approve; }
      block "Task ${CUR} converged and was committed. Now implement task ${NEXT}: ${NHEAD}, following its steps in ${PLAN}. When done, stop — the sparring reviewer will engage automatically." \
        "sparring weigh-in: task ${NEXT}/${TASKS}"
    else
      wgn_set_field phase done "$WGN_STATE"
      block "All ${TASKS} tasks converged and were committed on this branch. Summarize what shipped for the user (branch, plan path, tasks), then stop." \
        "sparring weigh-in: complete"
    fi
    ;;
  *)
    wgn_set_task_status "$CUR" stopped "$WGN_STATE"
    wgn_set_field phase done "$WGN_STATE"
    block "Task ${CUR} (${HEADING}) did not converge — its sparring loop ended '${REASON}'. Per weigh-in policy the run stops here rather than advancing. Report the unresolved findings from that task's last review to the user honestly, then stop. (To resume later, fix and re-run /spar-weighin.)" \
      "sparring weigh-in: stopped — task ${CUR} ${REASON}"
    ;;
esac
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_stop_weighin.sh`
Expected: `PASS=13 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/hooks/stop-weighin.sh tests/test_stop_weighin.sh
git commit -m "feat: weighin Stop hook — advance/finish/stop per task"
```

---

## Task 8: Register the weighin hook after spar's

**Files:**
- Modify: `plugins/spar/hooks/hooks.json`
- Test: `tests/test_weighin_hooks_json.sh`

**Interfaces:**
- Consumes: Task 1's confirmed ordering guarantee.
- Produces: a `hooks.json` whose Stop array runs `stop-hook.sh` first and `stop-weighin.sh` second.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_weighin_hooks_json.sh
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
J="$ROOT/plugins/spar/hooks/hooks.json"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }
jq -e . "$J" >/dev/null && { echo "PASS: valid json"; PASS=$((PASS+1)); } || { echo "FAIL: valid json"; FAIL=$((FAIL+1)); }
CMDS="$(jq -r '.hooks.Stop[].hooks[].command' "$J")"
chk "first is stop-hook" "stop-hook.sh" "$(echo "$CMDS" | sed -n '1p' | sed 's#.*/##')"
chk "second is stop-weighin" "stop-weighin.sh" "$(echo "$CMDS" | sed -n '2p' | sed 's#.*/##')"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_weighin_hooks_json.sh`
Expected: FAIL — only one command present.

- [ ] **Step 3: Edit `hooks.json`**

Add the weighin hook as a second entry in the same Stop group's `hooks` array, after the existing one:

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
          },
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stop-weighin.sh",
            "timeout": 30,
            "statusMessage": "sparring weigh-in: checking plan progress..."
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `bash tests/test_weighin_hooks_json.sh`
Expected: `PASS=3 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/hooks/hooks.json tests/test_weighin_hooks_json.sh
git commit -m "feat: register weighin Stop hook after spar's"
```

---

## Task 9: The `/spar-weighin` command

**Files:**
- Create: `plugins/spar/commands/spar-weighin.md`

**Interfaces:**
- Consumes: `spar-weighin-resolve.sh` (Task 3), `spar-weighin-lib.sh` (Task 2), `spar-weighin-ingest.sh` (Task 4), `spar-weighin-launch.sh` (Task 6).
- Produces: the user-facing command. Setup bash guards against an active weighin or spar loop, resolves flags/spec, ensures the shared git-excludes exist, and writes the initial `.claude/spar-weighin.local.md` (`phase: plan`). Then instructs the agent to produce the plan (via writing-plans, without its execution handoff), ingest it, create the ring, and launch task 1.

- [ ] **Step 1: Write the command file**

````markdown
---
description: "Weigh-in: turn a spec into a checkbox plan, set up the ring, and run the enforced spar loop task-by-task to convergence"
argument-hint: "[--whole] [--reviewer codex|claude] [--] <spec path or description>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

First, activate the weigh-in by running this setup command:

```bash
set -e
if [ -f .claude/spar-weighin.local.md ]; then echo "Error: a weigh-in is already active. Finish it or run /spar-cancel."; exit 1; fi
if [ -f .claude/spar.local.md ]; then echo "Error: a sparring loop is already active. Use /spar-cancel first."; exit 1; fi
WGN_RAW="$(cat <<'WGN_ARGS_EOF'
$ARGUMENTS
WGN_ARGS_EOF
)"
RESOLVED="$("${CLAUDE_PLUGIN_ROOT}/commands/spar-weighin-resolve.sh" "$WGN_RAW")" || { printf '%s\n' "$RESOLVED" >&2; exit 1; }
WGN_MODE="${RESOLVED%%$'\t'*}"
WGN_REST="${RESOLVED#*$'\t'}"
WGN_REVIEWER="${WGN_REST%%$'\t'*}"
WGN_SPEC="${WGN_REST#*$'\t'}"
# Reviewer: empty means auto-detect (codex if present, else claude), matching /spar.
if [ -z "$WGN_REVIEWER" ]; then
  if command -v codex >/dev/null 2>&1; then WGN_REVIEWER=codex; else WGN_REVIEWER=claude; fi
fi
command -v "$WGN_REVIEWER" >/dev/null 2>&1 || { echo "Error: '$WGN_REVIEWER' CLI not on PATH."; exit 1; }
for D in .claude reviews docs/superpowers/plans; do mkdir -p "$D"; done
# Reuse spar's git-excludes so weighin's own commits never stage loop artifacts.
if git rev-parse --git-dir >/dev/null 2>&1; then
  EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
  for pat in 'reviews/spar-*' '.claude/spar*'; do
    grep -qxF "$pat" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$pat" >> "$EXCLUDE"
  done
fi
TMP="$(mktemp .claude/spar-weighin.local.md.tmp.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<STATE_EOF
---
active: true
phase: plan
mode: ${WGN_MODE}
reviewer: ${WGN_REVIEWER}
plan_path:
worktree:
tasks: 0
current: 1
current_review_id:
---
STATE_EOF
mv "$TMP" .claude/spar-weighin.local.md
trap - EXIT
printf 'Weigh-in activated (mode=%s, reviewer=%s)\nSPEC=%s\n' "$WGN_MODE" "$WGN_REVIEWER" "$WGN_SPEC"
```

Then run these steps in order. Do NOT stop until task 1's sparring loop is
launched — from that point the weigh-in Stop hook drives the rest.

1. **Produce the plan.** Read the spec (the `SPEC=` value printed above — a path
   or an inline description; if it is a path, read that file). Use the
   `superpowers:writing-plans` skill to write the implementation plan to
   `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`. **Do NOT run writing-plans'
   execution handoff (do not offer subagent/inline execution) — the weigh-in is
   the executor.** If the spec is empty or missing, stop and tell the user to run
   `superpowers:brainstorming` first.

2. **Record the plan path and create the ring.** Set the plan path into state and
   create an isolated worktree with the `superpowers:using-git-worktrees` skill,
   then record it:

   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/commands/spar-weighin-lib.sh"
   wgn_set_field plan_path "<the plan path you just wrote>"
   wgn_set_field worktree "$(pwd)"
   ```

3. **Ingest the plan into the task table:**

   ```bash
   MODE="$(sed -n 's/^mode: //p' .claude/spar-weighin.local.md | head -1)"
   bash "${CLAUDE_PLUGIN_ROOT}/commands/spar-weighin-ingest.sh" "<the plan path>" "$MODE" .claude/spar-weighin.local.md
   ```

4. **Launch task 1.** Write task 1's text to a file and activate its sparring
   loop, then implement it:

   ```bash
   PLAN="$(sed -n 's/^plan_path: //p' .claude/spar-weighin.local.md | head -1)"
   MODE="$(sed -n 's/^mode: //p' .claude/spar-weighin.local.md | head -1)"
   H1="$(awk -F'\t' 'c>=2 && $1==1{print $3; exit}' <(awk '/^---$/{c++}{print}' .claude/spar-weighin.local.md))"
   if [ "$MODE" = "whole" ]; then cp "$PLAN" .claude/spar-weighin-task.txt
   else awk -v h="### ${H1}" '$0==h{f=1} f&&/^### /&&$0!=h&&seen{exit} $0==h{seen=1} f{print}' "$PLAN" > .claude/spar-weighin-task.txt; fi
   bash "${CLAUDE_PLUGIN_ROOT}/commands/spar-weighin-launch.sh" .claude/spar-weighin.local.md .claude/spar-weighin-task.txt
   ```

   Then implement task 1 following its steps in the plan. When you believe it is
   done, stop — the sparring reviewer engages automatically, and on convergence
   the weigh-in advances to the next task on its own.

## Hard rules

- Never edit `.claude/spar-weighin.local.md` or `.claude/spar.local.md` by hand
  after setup. To abort, run `/spar-cancel`.
- Never write a sparring outcome or convergence marker yourself.
- If a task's loop ends unconverged, the weigh-in stops and asks you to report
  honestly — do not present the work as finished.
````

- [ ] **Step 2: Sanity-check the setup bash parses**

Run: `bash -n plugins/spar/commands/spar-weighin.md` will not work (it's markdown); instead extract and check the fenced setup block:
Run: `sed -n '/^```bash$/,/^```$/p' plugins/spar/commands/spar-weighin.md | sed '1d;$d' | bash -n -`
Expected: no output (syntax OK). If multiple bash blocks, check each.

- [ ] **Step 3: Commit**

```bash
git add plugins/spar/commands/spar-weighin.md
git commit -m "feat: /spar-weighin command"
```

---

## Task 10: Cancel integration + docs

**Files:**
- Modify: `plugins/spar/commands/spar-cancel.md`
- Modify: `plugins/spar/shared/policy.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: `/spar-cancel` also tears down weighin state; policy + README document Phase 8.

- [ ] **Step 1: Extend `/spar-cancel` to remove weighin state**

In `plugins/spar/commands/spar-cancel.md`, before the existing `rm -f` line, add weighin teardown so cancelling clears both loops:

```bash
if [ -f .claude/spar-weighin.local.md ]; then
  echo "Weigh-in state cleared."
fi
rm -f .claude/spar-weighin.local.md .claude/spar-weighin.log .claude/spar-weighin-task.txt
```

Keep the existing spar-state `rm -f` line and the closing echo. Cancelling mid-task therefore stops both the current sparring loop and the weigh-in.

- [ ] **Step 2: Document Phase 8 in `policy.md`**

Add to the Phase roadmap section of `plugins/spar/shared/policy.md`:

```markdown
Phase 8 (orchestration): `/spar-weighin` — a plan-to-spar orchestrator layered
ABOVE the loop. It runs writing-plans → isolated worktree → spar (per-task by
default, `--whole` optional), driven by a second Stop hook ordered after the
loop's own. It reads each task's durable outcome to advance, flips the plan's
checkboxes, and commits per task. Depends only on Phases 1–4; order-independent
of 5–7. It never writes convergence and stops honestly on a non-converged task.
```

- [ ] **Step 3: Add the Phase 8 row to the README roadmap**

In `README.md`'s Roadmap table, add:

```markdown
| 8 | `/spar-weighin` orchestrator: writing-plans → worktree → per-task (or `--whole`) spar loop, second Stop hook, per-task checkbox commits | planned |
```

Also add a one-line mention under "How it works" or Install noting `/spar-weighin` wraps `/spar` for multi-task plans.

- [ ] **Step 4: Run the full test suite**

Run: `for t in tests/test_*.sh; do echo "== $t =="; bash "$t" || exit 1; done`
Expected: every suite ends `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/commands/spar-cancel.md plugins/spar/shared/policy.md README.md
git commit -m "feat: weighin cancel teardown + Phase 8 docs"
```

---

## Self-Review

**Spec coverage:**
- Separate command in the spar plugin → Task 9. ✓
- Input = spec path/inline/none → Task 9 step 1. ✓
- writing-plans → worktree → spar flow → Task 9 steps 1–4. ✓
- Per-task default + `--whole` → Tasks 3, 4, 5, 7 (mode threaded through). ✓
- Plan doc as progress tracker (checkbox flips) → Tasks 5, 7. ✓
- Controller/hook, coexistence, terminal detection, non-converged stop, checkbox mapping, cancellation → Tasks 1, 6, 7, 8, 10. ✓
- Reuse existing skills, don't reinvent → Task 9 uses writing-plans + using-git-worktrees; no reimplementation. ✓
- Roadmap placement Phase 8 → Task 10. ✓

**Open risks carried from the spec:**
- Hook ordering is load-bearing and verified first (Task 1). If it fails, the plan branches to a single combined hook.
- `writing-plans` must run without its execution handoff — handled by an explicit instruction in Task 9; if the skill insists on the handoff, the command still works (the agent just declines the offered execution).
- `--whole` review quality is untested until real use; per-task remains the default.

**Type/name consistency:** state field names (`phase`, `mode`, `current`, `tasks`, `current_review_id`, `plan_path`, `worktree`), task-row TSV (`index\tstatus\theading`), and helper names (`wgn_field`, `wgn_task_line`, `wgn_set_field`, `wgn_set_task_status`) are used identically across Tasks 2, 4, 6, 7, 9. Outcome `reason:` values match `spar-record-outcome.sh` (`converged|cap|error-bypass|cancelled|skipped|blocked-pending-user|sweep-findings-at-cap`).
