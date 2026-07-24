# Phase 5 — Final Run Report (`/spar:report`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a deterministic, human-readable report of a completed sparring run (`reviews/spar-<id>-report.md`) at the run's terminal path, and add a read-only `/spar:report [id]` command that displays it.

**Architecture:** Generation and display are split. A standalone generator `plugins/spar/commands/spar-report.sh` assembles the report from a run's artifacts (state file, outcome file, per-round reviews/responses, judge files, sweep file, ledger, registry, `git diff --stat`) and publishes it atomically. `stop-hook.sh` gains ONE fail-open helper, `generate_report()`, called from `finish_approve` when the reason is `converged` — before `cleanup()`, because cleanup deletes the ledger and registry the report reads. The already-shipped unattended terminal (`unattended_block_terminal`, which today calls the generator inline) is refactored onto the same helper. Display is a small resolver script plus a `report.md` command file; it only re-reads the frozen report and never re-derives anything.

**Tech Stack:** POSIX-ish bash (Claude Code plugin scripts + hooks), `awk`/`sed` for parsing, `git` for the change surface, `jq` only where hooks already use it, pure-bash test scripts under `tests/`.

**Source specs:**
- `docs/superpowers/specs/2026-07-24-spar-report-design.md` — the report half of Phase 5 (this plan implements it).
- `docs/superpowers/specs/2026-07-24-phase5-unattended-mode-design.md` — the other half, already shipped in v0.5.0. Relevant here only because its terminal path feeds the report (parked / blocked-pending-user) and already contains the generator call site.

**Current state of the code (verified before planning):**
- `plugins/spar/hooks/stop-hook.sh:45` already defines `REPORT_GEN="${CLAUDE_PLUGIN_ROOT:-}/commands/spar-report.sh"`.
- `plugins/spar/hooks/stop-hook.sh:102-104` already calls it (guarded by `[ -x ]`) inside `unattended_block_terminal`.
- `plugins/spar/commands/spar-report.sh` **does not exist yet** — the call is a no-op today. This plan creates it.
- Three `finish_approve converged …` call sites exist (`stop-hook.sh:862`, `:879`, `:1119`); routing the report through `finish_approve` covers all three with one edit.

---

## Global Constraints

- **Informational, never enforcing.** The report must never change the loop's decision, block a session, or trap the user. Every call site is fail-open: a missing, non-executable, failing, or slow generator logs and continues.
- **Generation runs BEFORE `cleanup()`.** `cleanup()` (`stop-hook.sh:51-59`) deletes `.claude/spar-ledger.md` and `.claude/spar-registry.tsv`; the report's "escalations & decisions" section cannot be reconstructed afterwards. `record_outcome` runs first, so `reviews/spar-<id>-outcome.md` is already on disk when the generator runs.
- **Scope: `converged` + the existing unattended `blocked-pending-user` path only.** The generator itself is terminal-reason-agnostic (it reads the reason from the outcome file), but no new call sites are added at `cap`, `sweep-findings-at-cap`, `skipped`, or `cancelled`. Those are deliberately deferred (spec §Scope).
- **The report is an artifact, not a commit.** It lands under `reviews/spar-*`, which is already in `.git/info/exclude`. Never `git add` it.
- **Path safety, matching `spar-queue-pending.sh` and `spar-record-outcome.sh`:** reject a symlink at the target path or at any existing ancestor directory; reject an existing non-regular file; build in a `mktemp` file inside the destination directory and publish with an atomic `mv`.
- **Style:** `set -uo pipefail` (never `set -e`) in standalone scripts; `stop-hook.sh` keeps its existing no-`set` style and ERR trap. Never write `[ cond ] && cmd` as a function's last statement in `stop-hook.sh` — use `if … fi`, so a false test cannot leak a non-zero return into the ERR trap.
- **Exit codes for new standalone scripts:** `0` success, `1` nothing to show (display only), `2` usage / invalid argument, `3` unsafe path or I/O failure. Mirrors `spar-queue-pending.sh`.
- **Command naming:** the display command is `/spar:report` (file `plugins/spar/commands/report.md`), matching the post-refactor `/spar:fight` / `/spar:ready` / `/spar:cancel` namespace. The generator keeps the spec's filename `spar-report.sh`. The specs' older `/spar-report` spelling is updated in Task 5's docs step.
- **Findings parsing is an independent lightweight parse inside `spar-report.sh`** (spec's open question 3, decided): the report is best-effort, so it does NOT source or refactor `stop-hook.sh`'s `parse_findings` / `parse_responses`. It mirrors the same heading contract (`### F<round>-<n> [TAG] <title>`, `### F<round>-<n>: FIXED|REJECTED …`).
- **Report layout is fixed by this plan** (spec's open question 1, decided) — see the layout block in Task 1. Section headings are load-bearing: tests grep for them, and Tasks 2 and 3 insert sections into a fixed order (`## Result`, `## Findings`, `## Escalations & decisions`, `## Changed files`).
- **Discovery hint** (spec's open question 2, decided): add the one-line hint to `plugins/spar/commands/fight.md`'s loop protocol and to the README only. Do NOT edit the hook's `block` message texts — existing tests assert on them and the report is written at the terminal, after the last block.
- **No version bump / release commit** in this plan. `plugins/spar/.claude-plugin/plugin.json` stays at `0.5.0`; versioning happens in the separate release commit.

---

### Task 1: Report generator — skeleton, safe publish, `## Result` + `## Changed files`

Create the generator with its full CLI contract, path safety, atomic publish, the result header, and the change surface. Findings (Task 2) and escalations (Task 3) are added into the same file afterwards, between `## Result` and `## Changed files`.

**Files:**
- Create: `plugins/spar/commands/spar-report.sh`
- Test: `tests/test_spar_report.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks (first task).
- Produces (later tasks and the hook rely on this exact contract):
  - Invocation: `spar-report.sh <review-id> <base-sha> [reviews-dir] [state-dir]`
  - Defaults: `reviews-dir` = `reviews`, `state-dir` = `.claude`
  - Output file: `<reviews-dir>/spar-<review-id>-report.md`
  - Exit: `0` written; `2` usage / invalid review id; `3` unsafe path or I/O failure
  - Section order in the output: `## Result`, `## Findings`, `## Escalations & decisions`, `## Changed files`
  - Internal helpers later tasks use: `field <key> <file>` (first `key: value` line, empty if the file is missing), direct path variables `STATE`, `LEDGER`, `REGISTRY`, `OUTCOME`, `SWEEP`, `REPORT`, and the shell variables `rev_dir` / `review_id`

The target layout (the whole file, once all three tasks are done). The four
`###` sub-headings are shown indented by two spaces **only** so this plan's own
task extractor does not treat them as a new task heading — in the real report
they start at column 1:

````markdown
# sparring run report — 20260721-120000-abc123

## Result

- outcome: converged
- rounds: 3
- reviewer: codex — cross-model (claude author ↔ codex reviewer)
- sweep: clean
- base_sha: aaaaaaaaaaaa
- generated_at: 2026-07-25T06:29:24Z

## Findings

- raised: 7 (MECHANICAL 5, DESIGN 2)
- fixed: 6
- rejected: 1
- unanswered: 0

Per round:

- round 1: raised 4, fixed 3, rejected 1
- round 2: raised 3, fixed 3, rejected 0

## Escalations & decisions

  ### Judge rulings

- UPHELD — mod.py | missing null check

  ### Decisions you settled

#### P1: keep the module cohesive — splitting would duplicate the parser

  ### Pending design decisions

- parked (no decision recorded) — mod.py | split the module

  ### Sweep findings

- SWEEP: FINDINGS
- S-1 [MECHANICAL] missing test for empty input

## Changed files

```text
 mod.py | 12 ++++++---
 1 file changed, 9 insertions(+), 3 deletions(-)
```

Untracked (new) files:

- newmod.py
````

- [ ] **Step 1: Write the failing test**

Create `tests/test_spar_report.sh`:

```bash
#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/commands/spar-report.sh
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/plugins/spar/commands/spar-report.sh"
ID=20260721-120000-abc123
R="reviews/spar-${ID}-report.md"

# NOTE: `grep -qF -- "$2"` — the `--` is required. Many expectations here start
# with "- " (report list items) and grep would otherwise read them as options.
chk() { # $1=desc $2=expected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi
}
chk_absent() { # $1=desc $2=unexpected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; echo "  unwanted:$2"; FAIL=$((FAIL+1))
  else echo "PASS: $1"; PASS=$((PASS+1)); fi
}

fresh() {
  d=$(mktemp -d); cd "$d" || exit 1
  mkdir -p reviews .claude
  git init -q
  git config user.email t@example.com
  git config user.name t
}

outcome() { # $1=reason $2=rounds $3=reviewer $4=sweep
  printf -- '---\nreason: %s\nreview_id: %s\nrounds: %s\nreviewer: %s\nsweep: %s\nrecorded_at: 2026-07-25T00:00:00Z\n---\n' \
    "$1" "$ID" "$2" "$3" "$4" > "reviews/spar-${ID}-outcome.md"
}

state() { # $1=round $2=reviewer $3=sweep_result
  cat > .claude/spar.local.md <<EOF
---
active: true
phase: review
round: $1
review_id: ${ID}
base_sha: none
reviewer: $2
max_rounds: 5
sweep_done: false
sweep_result: $3
---

do the thing
EOF
}

# ── 1. result header comes from the outcome file ──
fresh; outcome converged 3 codex clean; state 3 codex clean
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "report written" "present" "$([ -f "$R" ] && echo present || echo absent)"
OUT="$(cat "$R" 2>/dev/null)"
chk "title carries the review id" "# sparring run report — ${ID}" "$OUT"
chk "result section present" "## Result" "$OUT"
chk "outcome reason" "- outcome: converged" "$OUT"
chk "rounds" "- rounds: 3" "$OUT"
chk "codex → cross-model pairing" "- reviewer: codex — cross-model" "$OUT"
chk "sweep result" "- sweep: clean" "$OUT"
chk "base sha line" "- base_sha: none" "$OUT"
chk "generated_at stamped" "- generated_at: 20" "$OUT"
chk "changed files section present" "## Changed files" "$OUT"

# ── 2. claude reviewer → same-model pairing ──
fresh; outcome converged 2 claude not-triggered; state 2 claude not-triggered
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "claude → same-model pairing" "- reviewer: claude — same-model" "$(cat "$R")"

# ── 3. no outcome file → falls back to the state file, reason unknown ──
fresh; state 4 codex findings
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R" 2>/dev/null)"
chk "missing outcome → unknown reason" "- outcome: unknown" "$OUT"
chk "missing outcome → rounds from state" "- rounds: 4" "$OUT"
chk "missing outcome → reviewer from state" "- reviewer: codex" "$OUT"

# ── 4. invalid review id → usage error, nothing written ──
fresh
bash "$GEN" "../../evil" none >/dev/null 2>&1
chk "invalid id → exit 2" "2" "$?"
chk "invalid id → no stray file" "absent" "$([ -f reviews/spar-../../evil-report.md ] && echo present || echo absent)"

# ── 5. symlinked report path → refused, never followed ──
fresh; outcome converged 1 codex not-run
outside=$(mktemp); printf 'ORIGINAL\n' > "$outside"
ln -s "$outside" "$R"
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "symlink target → exit 3" "3" "$?"
chk "symlink target untouched" "ORIGINAL" "$(cat "$outside")"

# ── 6. unusable baseline → soft note, report still produced ──
fresh; outcome converged 1 codex not-run
bash "$GEN" "$ID" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1
chk "bad baseline → soft note" "(no usable baseline" "$(cat "$R")"

# ── 7. real baseline → diff --stat of tracked change, untracked files listed ──
fresh; outcome converged 1 codex not-run
printf 'one\n' > mod.py
git add mod.py; git commit -qm base
BASE="$(git rev-parse HEAD)"
printf 'one\ntwo\n' > mod.py
printf 'brand new\n' > newmod.py
bash "$GEN" "$ID" "$BASE" >/dev/null 2>&1
OUT="$(cat "$R")"
chk "diff --stat lists the changed file" "mod.py" "$OUT"
chk "diff --stat summary line" "1 file changed" "$OUT"
chk "untracked section" "Untracked (new) files:" "$OUT"
chk "untracked file listed" "- newmod.py" "$OUT"
chk_absent "loop artifacts never listed as untracked" "outcome.md" "$OUT"

# ── 8. re-run overwrites in place (regular file), still exactly one report ──
fresh; outcome converged 1 codex not-run
bash "$GEN" "$ID" none >/dev/null 2>&1
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "re-run → exit 0" "0" "$?"
chk "one title only" "1" "$(grep -c '^# sparring run report' "$R")"
chk_absent "no temp files left behind" ".spar-report-" "$(ls -a reviews)"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_spar_report.sh`
Expected: FAIL — every check fails because `plugins/spar/commands/spar-report.sh` does not exist (`bash: … No such file or directory`).

- [ ] **Step 3: Write the generator**

Create `plugins/spar/commands/spar-report.sh` with exactly this content, then `chmod +x` it (Step 4):

```bash
#!/usr/bin/env bash
# Assemble the final report for one sparring run: reviews/spar-<id>-report.md.
# Deterministic and read-only apart from the report it publishes. Best-effort by
# contract — every caller (the stop-hook terminal paths) ignores failures, so a
# broken report can never change a loop outcome or trap a session.
# Usage: spar-report.sh <review-id> <base-sha> [reviews-dir] [state-dir]
# Exit: 0 report written; 2 usage / invalid id; 3 unsafe path or I/O failure.
set -uo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "usage: spar-report.sh <review-id> <base-sha> [reviews-dir] [state-dir]" >&2
  exit 2
fi
review_id="${1-}"; base="${2-}"; rev_dir="${3:-reviews}"; state_dir="${4:-.claude}"
# Normalize relative paths beginning with '-' so no downstream command mistakes
# a path such as "-n" for an option. Absolute paths never start with '-'.
case "$rev_dir" in -*) rev_dir="./$rev_dir" ;; esac
case "$state_dir" in -*) state_dir="./$state_dir" ;; esac

# The id is interpolated into a path, so validate it strictly (no traversal).
printf '%s' "$review_id" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' \
  || { echo "error: invalid review id: $review_id" >&2; exit 2; }
# An unusable baseline degrades to a soft note; it is never fatal.
printf '%s' "$base" | grep -qE '^([0-9a-f]{7,40}|none|HEAD)$' || base=none

STATE="${state_dir}/spar.local.md"
LEDGER="${state_dir}/spar-ledger.md"
REGISTRY="${state_dir}/spar-registry.tsv"
OUTCOME="${rev_dir}/spar-${review_id}-outcome.md"
SWEEP="${rev_dir}/spar-${review_id}-sweep.md"
REPORT="${rev_dir}/spar-${review_id}-report.md"

# First "key: value" line of a file; empty when the file is absent.
field() { # $1=key $2=file
  [ -f "$2" ] || return 0
  sed -n "s/^${1}: *//p" "$2" 2>/dev/null | head -1
}

# Reject a symlink at the report path or at ANY existing ancestor directory —
# writing through a symlinked parent (even a deep one) is unsafe.
reject_unsafe_path() {
  [ -L "$REPORT" ] && { echo "error: report path is a symlink" >&2; exit 3; }
  local anc="$REPORT"
  while :; do
    anc=$(dirname "$anc")
    { [ "$anc" = "." ] || [ "$anc" = "/" ]; } && break
    [ -L "$anc" ] && { echo "error: symlinked ancestor: $anc" >&2; exit 3; }
  done
  [ -e "$REPORT" ] && [ ! -f "$REPORT" ] \
    && { echo "error: report path is not a regular file" >&2; exit 3; }
  return 0
}

mkdir -p "$rev_dir" || exit 3
reject_unsafe_path

# ── result header ───────────────────────────────────────────────────────────
# The outcome file is authoritative (record_outcome always runs first at every
# terminal path); the live state file is the fallback while it is still present.
reason=$(field reason "$OUTCOME"); [ -n "$reason" ] || reason=unknown
rounds=$(field rounds "$OUTCOME"); [ -n "$rounds" ] || rounds=$(field round "$STATE")
case "$rounds" in ''|*[!0-9]*) rounds=0 ;; esac
reviewer=$(field reviewer "$OUTCOME")
[ -n "$reviewer" ] || reviewer=$(field reviewer "$STATE")
case "$reviewer" in
  codex)  pairing="cross-model (claude author ↔ codex reviewer)" ;;
  claude) pairing="same-model (claude author ↔ claude reviewer)" ;;
  *)      reviewer=unknown; pairing="unknown pairing" ;;
esac
sweep=$(field sweep "$OUTCOME"); [ -n "$sweep" ] || sweep=$(field sweep_result "$STATE")
case "$sweep" in not-run|not-triggered|pending|clean|findings|error) ;; *) sweep=not-run ;; esac

# ── change surface ──────────────────────────────────────────────────────────
changed_files() {
  command -v git >/dev/null 2>&1 || { echo "(git unavailable)"; return 0; }
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "(not a git repository)"; return 0; }
  if [ "$base" != none ] && git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1
  then
    git diff --stat "$base" 2>/dev/null || echo "(diff unavailable)"
  else
    echo "(no usable baseline: ${base})"
  fi
}

# New files never appear in `git diff --stat`, and a run's whole deliverable is
# often new files — list them so the change surface is not silently understated.
# reviews/ and .claude/ are filtered explicitly: they hold the loop's own
# artifacts (including this report's temp file), and relying on the repo's
# .git/info/exclude entries would leak them wherever those are absent.
untracked_files() {
  command -v git >/dev/null 2>&1 || return 0
  git ls-files --others --exclude-standard 2>/dev/null \
    | grep -v -e '^reviews/' -e '^\.claude/' \
    | sed 's/^/- /'
}

# ── publish ─────────────────────────────────────────────────────────────────
tmp=$(mktemp "${rev_dir}/.spar-report-${review_id}.XXXXXX") || exit 3
trap 'rm -f "$tmp"' EXIT
{
  echo "# sparring run report — ${review_id}"
  echo
  echo "## Result"
  echo
  echo "- outcome: ${reason}"
  echo "- rounds: ${rounds}"
  echo "- reviewer: ${reviewer} — ${pairing}"
  echo "- sweep: ${sweep}"
  echo "- base_sha: ${base}"
  echo "- generated_at: $(date -u +%FT%TZ)"
  echo
  echo "## Changed files"
  echo
  echo '```text'
  changed_files
  echo '```'
  u=$(untracked_files)
  if [ -n "$u" ]; then
    echo
    echo "Untracked (new) files:"
    echo
    printf '%s\n' "$u"
  fi
} > "$tmp" || exit 3

# Re-validate immediately before the rename: the destination could have been
# swapped to a symlink while the report was being assembled.
reject_unsafe_path
mv "$tmp" "$REPORT" || exit 3
trap - EXIT
exit 0
```

- [ ] **Step 4: Make it executable and run the test to verify it passes**

```bash
chmod +x plugins/spar/commands/spar-report.sh
bash tests/test_spar_report.sh
```
Expected: `PASS=… FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add plugins/spar/commands/spar-report.sh tests/test_spar_report.sh
git commit -m "feat: spar-report.sh generator — result header + change surface"
```

---

### Task 2: `## Findings` section — per-round tally

Add the findings tally: totals split by `[MECHANICAL]` / `[DESIGN]`, fixed / rejected / unanswered, plus one line per round. Parsing is independent of the hook (Global Constraints) but mirrors its heading contract.

**Files:**
- Modify: `plugins/spar/commands/spar-report.sh` (add two counters + the `## Findings` block, inserted before `## Changed files`)
- Test: `tests/test_spar_report.sh` (append a new section before the trailing `echo; echo "PASS=…"` lines)

**Interfaces:**
- Consumes from Task 1: `review_id`, `rev_dir`, the `{ … } > "$tmp"` publish block, and its section order.
- Produces: the `## Findings` section with these exact lines — `- raised: <N> (MECHANICAL <m>, DESIGN <d>)`, `- fixed: <N>`, `- rejected: <N>`, `- unanswered: <N>`, and per-round `- round <N>: raised <r>, fixed <f>, rejected <x>`.

Input contract being parsed (produced by the reviewer and the author):
- review file `reviews/spar-<id>-r<N>.md` — `### F<N>-<n> [MECHANICAL|DESIGN] <title>`
- response file `reviews/spar-<id>-r<N>-response.md` — `### F<N>-<n>: FIXED — …` or `### F<N>-<n>: REJECTED — …`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_spar_report.sh`, immediately before the final `echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"` lines:

```bash
# ── 9. findings tally across rounds ──
fresh; outcome converged 2 codex not-triggered; state 2 codex not-triggered
{
  printf 'STATUS: FINDINGS\n\n'
  printf '### F1-1 [MECHANICAL] off-by-one in the paginator\n- file: page.py:10\n- problem: last page dropped\n- suggestion: use <=\n\n'
  printf '### F1-2 [DESIGN] split the module\n- file: mod.py:3\n- problem: two responsibilities\n- suggestion: split\n\n'
  printf '### F1-3 [MECHANICAL] missing test for empty input\n- file: page.py:40\n- problem: untested\n- suggestion: add a test\n'
} > "reviews/spar-${ID}-r1.md"
{
  printf '### F1-1: FIXED — use <= in the bound check\n'
  printf '### F1-2: REJECTED — cohesive on purpose\n'
  printf '### F1-3: FIXED — added the empty-input test\n'
} > "reviews/spar-${ID}-r1-response.md"
{
  printf 'STATUS: FINDINGS\n\n'
  printf '### F2-1 [MECHANICAL] stale docstring\n- file: page.py:8\n- problem: says 1-indexed\n- suggestion: fix the wording\n'
} > "reviews/spar-${ID}-r2.md"
printf '### F2-1: FIXED — docstring corrected\n' > "reviews/spar-${ID}-r2-response.md"
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R")"
chk "findings section present" "## Findings" "$OUT"
chk "total raised with tag split" "- raised: 4 (MECHANICAL 3, DESIGN 1)" "$OUT"
chk "total fixed" "- fixed: 3" "$OUT"
chk "total rejected" "- rejected: 1" "$OUT"
chk "nothing unanswered" "- unanswered: 0" "$OUT"
chk "per-round line for round 1" "- round 1: raised 3, fixed 2, rejected 1" "$OUT"
chk "per-round line for round 2" "- round 2: raised 1, fixed 1, rejected 0" "$OUT"
chk "findings precede changed files" "## Findings" "$(sed -n '/## Findings/,/## Changed files/p' "$R")"

# ── 10. a round with no response file → counted as unanswered, never crashed ──
fresh; outcome cap 1 codex not-run; state 1 codex not-run
{
  printf 'STATUS: FINDINGS\n\n'
  printf '### F1-1 [DESIGN] rename the flag\n- file: cli.py:2\n- problem: unclear\n- suggestion: rename\n'
} > "reviews/spar-${ID}-r1.md"
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R")"
chk "unanswered finding counted" "- unanswered: 1" "$OUT"
chk "unanswered round line" "- round 1: raised 1, fixed 0, rejected 0" "$OUT"

# ── 11. converged run with zero findings → explicit none line, no round list ──
fresh; outcome converged 1 codex not-triggered; state 1 codex not-triggered
printf 'STATUS: CONVERGED\n\nNothing to raise.\n' > "reviews/spar-${ID}-r1.md"
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R")"
chk "zero findings raised" "- raised: 0 (MECHANICAL 0, DESIGN 0)" "$OUT"
chk "no findings note" "No findings were raised." "$OUT"

# ── 12. rounds beyond 9 sort numerically, not lexicographically ──
fresh; outcome cap 10 codex not-run; state 10 codex not-run
for n in 2 10; do
  printf 'STATUS: FINDINGS\n\n### F%s-1 [MECHANICAL] t%s\n- file: a.py:1\n- problem: p\n- suggestion: s\n' "$n" "$n" \
    > "reviews/spar-${ID}-r${n}.md"
  printf '### F%s-1: FIXED — done\n' "$n" > "reviews/spar-${ID}-r${n}-response.md"
done
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "round 2 listed before round 10" "- round 2: raised 1, fixed 1, rejected 0
- round 10: raised 1, fixed 1, rejected 0" "$(cat "$R")"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_spar_report.sh`
Expected: the new checks FAIL (`want:## Findings`, `want:- raised: 4 …`) while Task 1's checks still PASS.

- [ ] **Step 3: Add the counters**

In `plugins/spar/commands/spar-report.sh`, insert this block immediately after the `# ── result header ───…` section (that is, after the `case "$sweep" in …` line) and before `# ── change surface ──`:

```bash
# ── findings tally ──────────────────────────────────────────────────────────
# Independent lightweight parse of the same heading contract stop-hook.sh uses.
# The report is best-effort, so it never sources the hook.
count_findings() { # $1=review file → "raised<TAB>mechanical<TAB>design"
  awk '
    /^### F[0-9]+-[0-9]+/ {
      r++
      if (/\[MECHANICAL\]/) m++
      else if (/\[DESIGN\]/) d++
    }
    END { printf "%d\t%d\t%d\n", r+0, m+0, d+0 }
  ' "$1" 2>/dev/null
}

count_responses() { # $1=response file → "fixed<TAB>rejected"
  [ -f "$1" ] || { printf '0\t0\n'; return 0; }
  awk '
    /^### F[0-9]+-[0-9]+:/ {
      if (/:[ ]*FIXED/) f++
      else if (/:[ ]*REJECTED/) x++
    }
    END { printf "%d\t%d\n", f+0, x+0 }
  ' "$1" 2>/dev/null
}

# Round numbers that actually have a review file, numerically sorted. The glob
# excludes "-r<N>-response.md" (its suffix is not numeric) and any set-aside
# ".invalid-<n>" file (it does not end in .md).
round_numbers() {
  local f n nums=""
  for f in "${rev_dir}/spar-${review_id}-r"*.md; do
    [ -f "$f" ] || continue
    n=${f##*-r}; n=${n%.md}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    nums="${nums}${n}
"
  done
  [ -n "$nums" ] || return 0
  printf '%s' "$nums" | sort -n
}

tot_raised=0; tot_mech=0; tot_design=0; tot_fixed=0; tot_rej=0
round_lines=""
while IFS= read -r n; do
  [ -n "$n" ] || continue
  IFS=$'\t' read -r r m d <<EOF
$(count_findings "${rev_dir}/spar-${review_id}-r${n}.md")
EOF
  IFS=$'\t' read -r f x <<EOF
$(count_responses "${rev_dir}/spar-${review_id}-r${n}-response.md")
EOF
  tot_raised=$((tot_raised + r)); tot_mech=$((tot_mech + m)); tot_design=$((tot_design + d))
  tot_fixed=$((tot_fixed + f)); tot_rej=$((tot_rej + x))
  [ "$r" -gt 0 ] || continue
  round_lines="${round_lines}- round ${n}: raised ${r}, fixed ${f}, rejected ${x}
"
done <<EOF
$(round_numbers)
EOF
tot_unanswered=$((tot_raised - tot_fixed - tot_rej))
[ "$tot_unanswered" -ge 0 ] || tot_unanswered=0
```

- [ ] **Step 4: Emit the section**

In the same file, inside the `{ … } > "$tmp"` publish block, insert this between the `echo "- generated_at: …"` line's trailing `echo` and `echo "## Changed files"`:

```bash
  echo "## Findings"
  echo
  echo "- raised: ${tot_raised} (MECHANICAL ${tot_mech}, DESIGN ${tot_design})"
  echo "- fixed: ${tot_fixed}"
  echo "- rejected: ${tot_rej}"
  echo "- unanswered: ${tot_unanswered}"
  echo
  if [ -n "$round_lines" ]; then
    echo "Per round:"
    echo
    printf '%s' "$round_lines"
  else
    echo "No findings were raised."
  fi
  echo
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test_spar_report.sh`
Expected: `PASS=… FAIL=0`.

- [ ] **Step 6: Commit**

```bash
git add plugins/spar/commands/spar-report.sh tests/test_spar_report.sh
git commit -m "feat: report findings tally (totals, tag split, per-round)"
```

---

### Task 3: `## Escalations & decisions` section

Add judge rulings, the user's settled ledger decisions, still-pending design items, and sweep findings. This is the section that requires generation before `cleanup()` — the ledger and registry only exist at the terminal path.

**Files:**
- Modify: `plugins/spar/commands/spar-report.sh` (add the collectors + the section, before `## Changed files`)
- Test: `tests/test_spar_report.sh` (append before the trailing PASS/FAIL lines)

**Interfaces:**
- Consumes from Tasks 1–2: `LEDGER`, `REGISTRY`, `SWEEP`, `rev_dir`, `review_id`, `reason`, and the publish block's section order.
- Produces the exact lines tests grep for:
  - `### Judge rulings` with `- UPHELD — <fingerprint>` / `- DISMISSED — <fingerprint>` / `- ESCALATED to the user (judge unavailable) — <fingerprint>`, or `- (no escalations)`
  - `### Decisions you settled` with each ledger `### P<k>: …` heading demoted to `#### P<k>: …` and its body verbatim, or `- (none recorded)`
  - `### Pending design decisions` with `- parked (no decision recorded) — <fingerprint>`, or `- (none)`; plus the queue pointer line when the outcome is `blocked-pending-user`
  - `### Sweep findings` with the sweep's first line and each `- S-<n> …` heading, or `- (no sweep findings)`

Input contracts being read:
- registry `.claude/spar-registry.tsv` — TSV `fingerprint<TAB>tag<TAB>last_rejected_round<TAB>streak<TAB>status`, status ∈ `open|parked|judging|upheld|dismissed|escalated|settled`
- ledger `.claude/spar-ledger.md` — one section per gate tag: `### P<k>: <decision + basis>`
- judge files `reviews/spar-<id>-judge-<k>.md` — first line `RULING: UPHELD` or `RULING: DISMISSED` (no fingerprint inside the file; attribution comes from the registry)
- sweep file `reviews/spar-<id>-sweep.md` — first line `SWEEP: CLEAN|FINDINGS`, findings as `### S-<n> [TAG] <title>`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_spar_report.sh`, before the final PASS/FAIL lines:

```bash
# ── 13. judge rulings, ledger decisions, parked items, sweep findings ──
fresh; outcome converged 3 codex findings; state 3 codex findings
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] null deref\n- file: mod.py:4\n- problem: p\n- suggestion: s\n' \
  > "reviews/spar-${ID}-r1.md"
printf '### F1-1: FIXED — guarded\n' > "reviews/spar-${ID}-r1-response.md"
printf 'RULING: UPHELD\nIt is a real defect.\n' > "reviews/spar-${ID}-judge-1.md"
printf 'RULING: DISMISSED\nNot a defect.\n' > "reviews/spar-${ID}-judge-2.md"
printf '%s\t%s\t%s\t%s\t%s\n' \
  'mod.py | null deref' MECHANICAL 2 2 upheld \
  > .claude/spar-registry.tsv
printf '%s\t%s\t%s\t%s\t%s\n' \
  'page.py | inline the helper' MECHANICAL 2 2 dismissed \
  >> .claude/spar-registry.tsv
printf '%s\t%s\t%s\t%s\t%s\n' \
  'cli.py | rename the flag' DESIGN 3 2 settled \
  >> .claude/spar-registry.tsv
printf '%s\t%s\t%s\t%s\t%s\n' \
  'mod.py | split the module' DESIGN 3 2 parked \
  >> .claude/spar-registry.tsv
{
  printf '# decisions\n\n'
  printf '### P1: keep the flag name — the CLI is published and renaming breaks callers\n'
  printf 'Basis: the flag appears in the released docs.\n'
} > .claude/spar-ledger.md
{
  printf 'SWEEP: FINDINGS\n\n'
  printf '### S-1 [MECHANICAL] missing test for empty input\n- file: page.py:40\n- problem: untested\n- suggestion: add a test\n'
} > "reviews/spar-${ID}-sweep.md"
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R")"
chk "escalations section present" "## Escalations & decisions" "$OUT"
chk "judge rulings heading" "### Judge rulings" "$OUT"
chk "upheld ruling attributed" "- UPHELD — mod.py | null deref" "$OUT"
chk "dismissed ruling attributed" "- DISMISSED — page.py | inline the helper" "$OUT"
chk "settled decisions heading" "### Decisions you settled" "$OUT"
chk "ledger decision demoted to h4" "#### P1: keep the flag name" "$OUT"
chk "ledger basis carried verbatim" "Basis: the flag appears in the released docs." "$OUT"
chk "pending heading" "### Pending design decisions" "$OUT"
chk "parked item listed" "- parked (no decision recorded) — mod.py | split the module" "$OUT"
chk "sweep heading" "### Sweep findings" "$OUT"
chk "sweep status carried" "- SWEEP: FINDINGS" "$OUT"
chk "sweep finding listed" "- S-1 [MECHANICAL] missing test for empty input" "$OUT"

# ── 14. nothing escalated → explicit empty markers, never a blank section ──
fresh; outcome converged 1 codex not-triggered; state 1 codex not-triggered
printf 'STATUS: CONVERGED\n\nclean\n' > "reviews/spar-${ID}-r1.md"
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R")"
chk "no judge rulings marker" "- (no escalations)" "$OUT"
chk "no ledger decisions marker" "- (none recorded)" "$OUT"
chk "no pending items marker" "- (none)" "$OUT"
chk "no sweep marker" "- (no sweep findings)" "$OUT"

# ── 15. blocked-pending-user → parked items plus the durable-queue pointer ──
fresh; outcome blocked-pending-user 2 codex not-run; state 2 codex not-run
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:3\n- problem: p\n- suggestion: s\n' \
  > "reviews/spar-${ID}-r2.md"
printf '%s\t%s\t%s\t%s\t%s\n' 'mod.py | split the module' DESIGN 2 2 parked \
  > .claude/spar-registry.tsv
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R")"
chk "blocked outcome reported honestly" "- outcome: blocked-pending-user" "$OUT"
chk "parked item listed" "- parked (no decision recorded) — mod.py | split the module" "$OUT"
chk "queue pointer for the next session" "reviews/spar-pending.md" "$OUT"

# ── 16. judge ruling with no registry attribution → still reported by file ──
fresh; outcome converged 2 codex not-run; state 2 codex not-run
printf 'RULING: UPHELD\nreal defect\n' > "reviews/spar-${ID}-judge-1.md"
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "unattributed ruling from the judge file" "- UPHELD — (fingerprint unavailable)" "$(cat "$R")"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_spar_report.sh`
Expected: the new checks FAIL (`want:## Escalations & decisions`, …); Tasks 1–2 checks still PASS.

- [ ] **Step 3: Add the collectors**

In `plugins/spar/commands/spar-report.sh`, insert this block immediately after the findings-tally block added in Task 2 (that is, after the `[ "$tot_unanswered" -ge 0 ] || tot_unanswered=0` line) and before `# ── change surface ──`:

```bash
# ── escalations & decisions ─────────────────────────────────────────────────
# The registry and ledger only exist before stop-hook.sh's cleanup(), which is
# exactly why generation runs at the terminal path.
registry_by_status() { # $1=status → one fingerprint per line
  [ -f "$REGISTRY" ] || return 0
  awk -F'\t' -v s="$1" '$5==s {print $1}' "$REGISTRY" 2>/dev/null
}

judge_lines() {
  local fp out=""
  while IFS= read -r fp; do
    [ -n "$fp" ] || continue
    out="${out}- UPHELD — ${fp}
"
  done <<EOF
$(registry_by_status upheld)
EOF
  while IFS= read -r fp; do
    [ -n "$fp" ] || continue
    out="${out}- DISMISSED — ${fp}
"
  done <<EOF
$(registry_by_status dismissed)
EOF
  while IFS= read -r fp; do
    [ -n "$fp" ] || continue
    out="${out}- ESCALATED to the user (judge unavailable) — ${fp}
"
  done <<EOF
$(registry_by_status escalated)
EOF
  # Fall back to the judge files when the registry carries no attribution (a
  # ruling file always exists per dispatch, the registry may be gone or stale).
  if [ -z "$out" ]; then
    local jf line
    for jf in "${rev_dir}/spar-${review_id}-judge-"*.md; do
      [ -f "$jf" ] || continue
      line=$(head -1 "$jf" | tr -d '\r' | sed 's/[[:space:]]*$//')
      case "$line" in
        "RULING: UPHELD")    out="${out}- UPHELD — (fingerprint unavailable)
" ;;
        "RULING: DISMISSED") out="${out}- DISMISSED — (fingerprint unavailable)
" ;;
      esac
    done
  fi
  printf '%s' "$out"
}

# Ledger sections verbatim, with '### P<k>:' demoted to '#### P<k>:' so the
# report keeps one heading hierarchy. Everything else is copied untouched.
ledger_lines() {
  [ -f "$LEDGER" ] || return 0
  awk '
    /^### P[0-9]+:/ { inside=1; sub(/^### /, "#### "); print; next }
    /^#/ && !/^#### P[0-9]+:/ { if (inside) inside=0 }
    inside { print }
  ' "$LEDGER" 2>/dev/null
}

pending_lines() {
  local fp out=""
  while IFS= read -r fp; do
    [ -n "$fp" ] || continue
    out="${out}- parked (no decision recorded) — ${fp}
"
  done <<EOF
$(registry_by_status parked)
EOF
  printf '%s' "$out"
}

sweep_lines() {
  [ -f "$SWEEP" ] || return 0
  local first
  first=$(head -1 "$SWEEP" | tr -d '\r' | sed 's/[[:space:]]*$//')
  case "$first" in
    "SWEEP: CLEAN"|"SWEEP: FINDINGS") echo "- ${first}" ;;
    *) echo "- (sweep output unreadable)" ;;
  esac
  awk '/^### S-[0-9]+/ { sub(/^### /, "- "); print }' "$SWEEP" 2>/dev/null
}

JUDGE_OUT=$(judge_lines)
LEDGER_OUT=$(ledger_lines)
PENDING_OUT=$(pending_lines)
SWEEP_OUT=$(sweep_lines)
```

- [ ] **Step 4: Emit the section**

In the same file, inside the `{ … } > "$tmp"` publish block, insert this between the findings block (Task 2) and `echo "## Changed files"`:

```bash
  echo "## Escalations & decisions"
  echo
  echo "### Judge rulings"
  echo
  if [ -n "$JUDGE_OUT" ]; then printf '%s\n' "$JUDGE_OUT"; else echo "- (no escalations)"; fi
  echo
  echo "### Decisions you settled"
  echo
  if [ -n "$LEDGER_OUT" ]; then printf '%s\n' "$LEDGER_OUT"; else echo "- (none recorded)"; fi
  echo
  echo "### Pending design decisions"
  echo
  if [ -n "$PENDING_OUT" ]; then printf '%s\n' "$PENDING_OUT"; else echo "- (none)"; fi
  if [ "$reason" = blocked-pending-user ]; then
    echo
    echo "This run stopped on an essential design decision, so the work is INCOMPLETE."
    echo "The pending item(s) are queued for the next session in \`reviews/spar-pending.md\`."
  fi
  echo
  echo "### Sweep findings"
  echo
  if [ -n "$SWEEP_OUT" ]; then printf '%s\n' "$SWEEP_OUT"; else echo "- (no sweep findings)"; fi
  echo
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test_spar_report.sh`
Expected: `PASS=… FAIL=0`.

- [ ] **Step 6: Commit**

```bash
git add plugins/spar/commands/spar-report.sh tests/test_spar_report.sh
git commit -m "feat: report escalations, settled decisions, pending items, sweep"
```

---

### Task 4: Hook wiring — one fail-open call at the converged terminal

Route report generation through a single `generate_report()` helper in `stop-hook.sh`, call it from `finish_approve` when the reason is `converged`, and refactor the existing unattended terminal onto the same helper. No new phase, no extra round-trip, no change to any block message or convergence decision.

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` (add `generate_report()` after `record_outcome()` around line 70; extend `finish_approve` at lines 71-75; replace the inline generator call in `unattended_block_terminal` at lines 102-104)
- Test: `tests/test_stop_hook.sh` (append a Phase 5 report section before the trailing PASS/FAIL lines)

**Interfaces:**
- Consumes from Task 1: `spar-report.sh <review-id> <base-sha>` (defaults for both directories are correct here — the hook always runs at the repo root).
- Produces: `generate_report()`, a fail-open no-argument helper using the hook's `REVIEW_ID` and `BASE`; safe to call from any terminal path. Later extension to `cap` / `sweep-findings-at-cap` is a one-line change at those paths (deliberately not done here).

- [ ] **Step 1: Write the failing test**

Append to `tests/test_stop_hook.sh`, immediately before the final `echo; echo "PASS=$PASS FAIL=$FAIL"` and `exit "$FAIL"` lines. It reuses that file's existing `chk`, `chk_file`, `fresh_dir`, `write_state`, `run_hook`, and `add_unattended` helpers. Note its `chk` calls `grep -qF "$2"` **without** `--`, so no expectation here may start with `-` (that is why the outcome checks below grep `outcome: converged`, not `- outcome: converged`):

```bash
# ── Phase 5: final report at the terminal path ──
RPT="reviews/spar-20260721-120000-abc123-report.md"

# Converge with the sweep already accounted for, so these tests exercise the
# terminal path itself instead of the sweep dispatch (mirrors test 6 above —
# without this, should_sweep() fires and the hook blocks for the sweep first).
converged_no_sweep() {
  printf 'STATUS: CONVERGED\n\nAll good.\n' > reviews/spar-20260721-120000-abc123-r1.md
  sed -i '' 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' \
    .claude/spar.local.md 2>/dev/null \
    || sed -i 's/^sweep_done: false/sweep_done: true/; s/^sweep_result: not-run/sweep_result: clean/' \
      .claude/spar.local.md
}

# R1. converged → report generated before cleanup
fresh_dir; write_state review 1; mkdir -p reviews
converged_no_sweep
OUT=$(run_hook)
chk "converged → approve" '"decision":"approve"' "$OUT"
chk_file "converged → report generated" "$RPT"
chk "report records the converged outcome" "outcome: converged" "$(cat "$RPT" 2>/dev/null)"
chk "report has the result section" "## Result" "$(cat "$RPT" 2>/dev/null)"
chk "report has the findings section" "## Findings" "$(cat "$RPT" 2>/dev/null)"
chk "report has the changed-files section" "## Changed files" "$(cat "$RPT" 2>/dev/null)"
chk "report survives cleanup" "gone" "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# R2. the report reads the ledger, which cleanup() would have deleted
fresh_dir; write_state review 1; mkdir -p reviews
printf '# decisions\n\n### P1: keep it cohesive — splitting duplicates the parser\n' \
  > .claude/spar-ledger.md
converged_no_sweep
run_hook >/dev/null
chk "ledger decision captured before cleanup" "#### P1: keep it cohesive" "$(cat "$RPT" 2>/dev/null)"
chk "ledger itself was cleaned up" "gone" "$([ -f .claude/spar-ledger.md ] && echo present || echo gone)"

# R3. round cap → no report (scope: converged only for now)
fresh_dir; write_state review 5; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F5-1 [MECHANICAL] t\n- file: a.py:1\n- problem: p\n- suggestion: s\n' \
  > reviews/spar-20260721-120000-abc123-r5.md
printf '### F5-1: FIXED — done\n' > reviews/spar-20260721-120000-abc123-r5-response.md
run_hook >/dev/null
chk "cap → no report (out of scope)" "absent" "$([ -f "$RPT" ] && echo present || echo absent)"

# R4. unattended blocked-pending-user terminal → report generated too
fresh_dir; write_state review 1; add_unattended; mkdir -p reviews
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' \
  > reviews/spar-20260721-120000-abc123-r1.md
printf '### F1-1: REJECTED — cohesive on purpose\n' \
  > reviews/spar-20260721-120000-abc123-r1-response.md
run_hook >/dev/null
printf 'STATUS: FINDINGS\n\n### F2-1 [DESIGN] split the module\n- file: mod.py:10\n- problem: big\n- suggestion: split\n' \
  > reviews/spar-20260721-120000-abc123-r2.md
printf '### F2-1: REJECTED — still cohesive\n' \
  > reviews/spar-20260721-120000-abc123-r2-response.md
run_hook >/dev/null
chk_file "unattended terminal → report generated" "$RPT"
chk "report is honest about the blocked outcome" "outcome: blocked-pending-user" \
  "$(cat "$RPT" 2>/dev/null)"
chk "report lists the parked decision" "mod.py | split the module" "$(cat "$RPT" 2>/dev/null)"

# R5. fail-open: a failing generator (symlinked report path) never traps the session
fresh_dir; write_state review 1; mkdir -p reviews
ln -s /dev/null "$RPT"
converged_no_sweep
OUT=$(run_hook)
chk "failing generator → still approve" '"decision":"approve"' "$OUT"
chk "failing generator → outcome still recorded" "reason: converged" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
chk "failing generator → still cleaned up" "gone" \
  "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# R6. fail-open: a missing generator never traps the session
fresh_dir; write_state review 1; mkdir -p reviews
FAKE_ROOT=$(mktemp -d)
cp -R "$ROOT/plugins/spar/." "$FAKE_ROOT/"
rm -f "$FAKE_ROOT/commands/spar-report.sh"
converged_no_sweep
OUT=$(CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" bash "$HOOK" <<< '{}')
chk "missing generator → still approve" '"decision":"approve"' "$OUT"
chk "missing generator → outcome still recorded" "reason: converged" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
chk "missing generator → no report" "absent" "$([ -f "$RPT" ] && echo present || echo absent)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_stop_hook.sh`
Expected: the new `R1`, `R2`, and `R4` checks FAIL (no report file is produced — `finish_approve` never calls the generator, and R4's inline call is currently the only one). `R3`, `R5`, `R6` may already pass; that is fine.

- [ ] **Step 3: Add `generate_report()`**

In `plugins/spar/hooks/stop-hook.sh`, insert this immediately after the closing `}` of `record_outcome()` (currently line 70) and before `finish_approve()`:

```bash
# Best-effort informational report. MUST run BEFORE cleanup(): the generator
# reads .claude/spar-ledger.md and .claude/spar-registry.tsv, which cleanup()
# deletes. Enforcement is not involved — a failure only means "no report".
generate_report() {
  [ -n "${REVIEW_ID:-}" ] || return 0
  if [ -x "$REPORT_GEN" ]; then
    "$REPORT_GEN" "$REVIEW_ID" "${BASE:-none}" 2>>"$LOG_FILE" \
      || log "report generation failed"
  else
    log "report generator missing: $REPORT_GEN"
  fi
  return 0
}
```

- [ ] **Step 4: Call it from the converged terminal**

Replace `finish_approve()` (currently lines 71-75) with:

```bash
finish_approve() { # $1=reason $2=sweep result (optional)
  record_outcome "$1" "${2:-not-run}"
  # Converged runs get an informational report, generated while the ledger and
  # registry still exist. Other reasons are deliberately out of scope for now
  # (the generator itself is reason-agnostic, so adding one is a one-liner).
  if [ "$1" = converged ]; then generate_report; fi
  cleanup
  approve
}
```

Then, in `unattended_block_terminal`, replace the inline generator call (currently lines 102-104):

```bash
  if [ -x "$REPORT_GEN" ]; then
    "$REPORT_GEN" "$REVIEW_ID" "$BASE" 2>>"$LOG_FILE" || log "report generation failed"
  fi
```

with the shared helper:

```bash
  generate_report
```

- [ ] **Step 5: Run both test suites to verify they pass**

```bash
bash tests/test_stop_hook.sh
bash tests/test_spar_report.sh
```
Expected: `FAIL=0` for both.

- [ ] **Step 6: Commit**

```bash
git add plugins/spar/hooks/stop-hook.sh tests/test_stop_hook.sh
git commit -m "feat: generate the final report at the converged terminal (fail-open)"
```

---

### Task 5: `/spar:report` display command + docs

Add the read-only display path — a testable resolver script plus the command file — and update the docs that describe the loop's surface.

**Files:**
- Create: `plugins/spar/commands/spar-report-show.sh`
- Create: `plugins/spar/commands/report.md`
- Test: `tests/test_report_show.sh`
- Modify: `plugins/spar/commands/fight.md` (loop protocol step 2 — the discovery hint)
- Modify: `plugins/spar/shared/policy.md` (§Protocol — add the report item; complete item 9's outcome enum)
- Modify: `README.md` (feature list, Roadmap Phase 5 row, repository layout)
- Modify: `docs/design-decisions.md` (§Phase 5 — mark the report delivered)
- Modify: `docs/superpowers/specs/2026-07-24-spar-report-design.md` (Status + terminal state → implemented; record the three settled open questions)
- Modify: `docs/superpowers/specs/2026-07-24-phase5-unattended-mode-design.md` (§1 half-note → the report half is implemented)

**Interfaces:**
- Consumes from Task 1: the output path `reviews/spar-<review-id>-report.md`.
- Produces:
  - `spar-report-show.sh [review-id] [reviews-dir]` — prints `# report file: <path>` then the report body. Exit `0` printed; `1` nothing readable to show (message on stdout); `2` invalid review id.
  - `/spar:report [id]` — the user-facing command.

- [ ] **Step 1: Write the failing test**

Create `tests/test_report_show.sh`:

```bash
#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/commands/spar-report-show.sh
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOW="$ROOT/plugins/spar/commands/spar-report-show.sh"
CMD="$ROOT/plugins/spar/commands/report.md"

# `--` is required: several expectations start with "- " (see test_spar_report.sh).
chk() { # $1=desc $2=expected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi
}
chk_absent() { # $1=desc $2=unexpected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; echo "  unwanted:$2"; FAIL=$((FAIL+1))
  else echo "PASS: $1"; PASS=$((PASS+1)); fi
}

fresh() { d=$(mktemp -d); cd "$d" || exit 1; mkdir -p reviews; }

plant() { # $1=id $2=marker
  printf '# sparring run report — %s\n\n## Result\n\n- outcome: %s\n' "$1" "$2" \
    > "reviews/spar-$1-report.md"
}

# 1. no reports at all → plain message, exit 1
fresh
OUT="$(bash "$SHOW" 2>&1)"; RC=$?
chk "no reports → message" "No sparring report found" "$OUT"
chk "no reports → exit 1" "1" "$RC"

# 2. one report, no id → printed with its path
fresh; plant 20260721-120000-abc123 converged
OUT="$(bash "$SHOW")"; RC=$?
chk "prints the report path" "reviews/spar-20260721-120000-abc123-report.md" "$OUT"
chk "prints the report body" "- outcome: converged" "$OUT"
chk "success exit 0" "0" "$RC"

# 3. two reports, no id → the most recent one
fresh
plant 20260721-120000-abc123 converged
sleep 1
plant 20260722-090000-def456 blocked-pending-user
OUT="$(bash "$SHOW")"
chk "newest report selected" "20260722-090000-def456" "$OUT"
chk "newest report body" "- outcome: blocked-pending-user" "$OUT"

# 4. explicit id → that report, not the newest
OUT="$(bash "$SHOW" 20260721-120000-abc123)"
chk "explicit id honored" "spar-20260721-120000-abc123-report.md" "$OUT"

# 5. explicit id with no report → plain message, exit 1
OUT="$(bash "$SHOW" 20260101-000000-aaaaaa 2>&1)"; RC=$?
chk "missing id → message" "No readable report" "$OUT"
chk "missing id → exit 1" "1" "$RC"

# 6. invalid id → usage error, exit 2
OUT="$(bash "$SHOW" '../../etc/passwd' 2>&1)"; RC=$?
chk "invalid id → error" "invalid review id" "$OUT"
chk "invalid id → exit 2" "2" "$RC"

# 7. symlinked report → refused, never followed
fresh
outside=$(mktemp); printf 'SECRET\n' > "$outside"
ln -s "$outside" reviews/spar-20260721-120000-abc123-report.md
OUT="$(bash "$SHOW" 20260721-120000-abc123 2>&1)"
chk "symlink refused" "No readable report" "$OUT"
chk_absent "symlink content never printed" "SECRET" "$OUT"

# 8. the command file exists and declares itself
chk "command file has a description" "description:" "$(cat "$CMD")"
chk "command file calls the resolver" "spar-report-show.sh" "$(cat "$CMD")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_report_show.sh`
Expected: FAIL — `spar-report-show.sh` and `report.md` do not exist yet.

- [ ] **Step 3: Write the resolver script**

Create `plugins/spar/commands/spar-report-show.sh`:

```bash
#!/usr/bin/env bash
# Print one sparring run's frozen final report. With no id, the most recently
# modified report in the reviews directory. Read-only: it never re-derives a
# report (the loop state it would need is deleted at cleanup) and never writes.
# Usage: spar-report-show.sh [review-id] [reviews-dir]
# Exit: 0 printed; 1 nothing readable to show; 2 invalid review id.
set -uo pipefail

id="${1-}"; rev_dir="${2:-reviews}"
case "$rev_dir" in -*) rev_dir="./$rev_dir" ;; esac

if [ -n "$id" ]; then
  printf '%s' "$id" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' \
    || { echo "error: invalid review id: $id" >&2; exit 2; }
  f="${rev_dir}/spar-${id}-report.md"
else
  # Report names are fixed-format (no spaces), so this listing is safe.
  f=$(ls -t "${rev_dir}"/spar-*-report.md 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "No sparring report found in ${rev_dir}/."; exit 1; }
fi

# Only ever read a real regular file — never follow a symlink.
[ -f "$f" ] && [ ! -L "$f" ] \
  || { echo "No readable report at ${f} (missing, a symlink, or not a regular file)."; exit 1; }

echo "# report file: ${f}"
cat "$f"
```

Then `chmod +x plugins/spar/commands/spar-report-show.sh`.

- [ ] **Step 4: Write the command file**

Create `plugins/spar/commands/report.md`:

```markdown
---
description: "Report: show the final report of a completed sparring run"
argument-hint: "[review-id]"
allowed-tools:
  - Bash
  - Read
---

Run this, then present the report to the user:

```bash
SPAR_REPORT_ID="$(printf '%s' "$ARGUMENTS" | tr -d '[:space:]')"
"${CLAUDE_PLUGIN_ROOT}/commands/spar-report-show.sh" "$SPAR_REPORT_ID" || true
```

Then summarize what it says, in this order: the outcome and round count, the
findings tally, any decision still pending, and the changed files. Read-only —
never edit, regenerate, or reinterpret the report; it is frozen at the end of
the run it describes. If nothing was printed, tell the user plainly that no
report exists for that run (reports are written only for runs that reached a
terminal path with this feature installed).
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test_report_show.sh`
Expected: `PASS=… FAIL=0`.

- [ ] **Step 6: Add the discovery hint to `fight.md`**

In `plugins/spar/commands/fight.md`, in the "Loop protocol" section, replace this line:

```markdown
   - First line `STATUS: CONVERGED` → stop again; the hook releases the session.
```

with:

```markdown
   - First line `STATUS: CONVERGED` → stop again; the hook releases the session.
     A summary of the whole run is written to `reviews/spar-<id>-report.md` —
     mention it, or run `/spar:report` to show it.
```

- [ ] **Step 7: Update `policy.md`**

In `plugins/spar/shared/policy.md` §Protocol, item 9 currently lists the outcome enum without `blocked-pending-user`. Replace:

```markdown
9. Every terminal path atomically writes one immutable outcome before cleanup:
   at least `converged`, `cap`, `error-bypass`, `cancelled`, `skipped`, or
   `sweep-findings-at-cap`. Only `converged` asserts a clean review result.
```

with:

```markdown
9. Every terminal path atomically writes one immutable outcome before cleanup:
   at least `converged`, `cap`, `error-bypass`, `cancelled`, `skipped`,
   `blocked-pending-user`, or `sweep-findings-at-cap`. Only `converged` asserts
   a clean review result.
10. A run that converges (and an unattended run that stops at
    `blocked-pending-user`) also gets an informational report,
    `reviews/spar-<id>-report.md`: outcome, rounds, reviewer pairing, sweep
    result, findings tally, judge rulings, the user's settled decisions, still
    pending decisions, and the changed files. It is generated deterministically
    BEFORE cleanup (the ledger and registry it reads are deleted there), is
    fail-open (a failure only means "no report"), and is never part of
    enforcement. `/spar:report [id]` displays it.
```

- [ ] **Step 8: Update `README.md`**

In the feature list under "Today `/spar:fight` gives you:", add one bullet after the existing unattended/sweep bullets:

```markdown
- **final run report** — every converged (and every unattended `blocked-pending-user`) run writes `reviews/spar-<id>-report.md`: outcome, rounds, reviewer pairing, sweep result, findings tally, judge rulings, your settled design decisions, anything still pending, and the changed files. `/spar:report [id]` shows it (defaults to the latest run);
```

Change the Roadmap Phase 5 row from:

```markdown
| 5 | Unattended mode + final report | planned |
```

to:

```markdown
| 5 | Unattended mode + final report (`/spar:report`) | ✅ done |
```

And in "Repository layout", change:

```
  commands/              /spar:ready, /spar:fight, /spar:cancel, setup guards + surface helpers
```

to:

```
  commands/              /spar:ready, /spar:fight, /spar:cancel, /spar:report, setup guards + surface helpers
```

- [ ] **Step 9: Update `docs/design-decisions.md`**

In §"Phase 5 — unattended + final report", append one line to the "Final report delivery" bullet:

```markdown
  Implemented 2026-07-25 (`docs/superpowers/plans/2026-07-25-spar-report.md`):
  `spar-report.sh` + a `generate_report()` fail-open call from `finish_approve`
  for `converged` (the unattended `blocked-pending-user` terminal shares it),
  displayed by `/spar:report [id]`. Command spelled `/spar:report` to match the
  post-refactor namespace. `cap`, `sweep-findings-at-cap`, `skipped`, and a
  `/spar:fight` roll-up remain deferred.
```

- [ ] **Step 10: Update both specs' status lines**

In `docs/superpowers/specs/2026-07-24-spar-report-design.md`, replace the Status paragraph:

```markdown
**Status:** design, prepared for **Phase 5**. NOT yet implemented. This refines
the "Final report" half of Phase 5 (the other half is unattended mode); see
`docs/design-decisions.md` §Phase 5.
```

with:

```markdown
**Status:** **implemented** 2026-07-25 via
`docs/superpowers/plans/2026-07-25-spar-report.md`. The three open questions
below were settled in that plan: (1) the report layout is fixed by the
generator; (2) the discovery hint lives in `fight.md` and the README, not in the
hook's block texts; (3) findings parsing is an independent lightweight parse
inside `spar-report.sh`, not a refactor of the hook's parsers. The display
command is `/spar:report` (post-refactor namespace).
```

And replace its "## Terminal state" body:

```markdown
Prepared for Phase 5. Do NOT implement now — this document is the starting point
for the Phase 5 plan.
```

with:

```markdown
Implemented. Scope as designed: converged runs (plus the unattended
`blocked-pending-user` terminal, which shares the same call). `cap`,
`sweep-findings-at-cap`, `skipped`, and the `/spar:fight` roll-up stay deferred.
```

In `docs/superpowers/specs/2026-07-24-phase5-unattended-mode-design.md`, in the "Phase 5 has **two halves**" list, replace:

```markdown
1. **Final report** — already designed in
   `docs/superpowers/specs/2026-07-24-spar-report-design.md` (deterministic
   `spar-report.sh` generates `reviews/spar-<id>-report.md` before cleanup; a
   `/spar-report [id]` command displays it). This document does not re-specify it;
   it only notes how unattended mode feeds it (parked / blocked-pending-user).
```

with:

```markdown
1. **Final report** — designed in
   `docs/superpowers/specs/2026-07-24-spar-report-design.md` and **implemented
   2026-07-25** (deterministic `spar-report.sh` generates
   `reviews/spar-<id>-report.md` before cleanup; `/spar:report [id]` displays
   it). This document does not re-specify it; it only notes how unattended mode
   feeds it (parked / blocked-pending-user).
```

- [ ] **Step 11: Run the whole test suite**

```bash
for t in tests/test_*.sh; do echo "== $t"; bash "$t" >/dev/null 2>&1 && echo OK || echo "FAILED: $t"; done
```
Expected: every line `OK`. If any suite reports `FAILED`, re-run it directly to see which check broke and fix the cause before committing.

- [ ] **Step 12: Commit**

```bash
git add plugins/spar/commands/spar-report-show.sh plugins/spar/commands/report.md \
  tests/test_report_show.sh plugins/spar/commands/fight.md \
  plugins/spar/shared/policy.md README.md docs/design-decisions.md \
  docs/superpowers/specs/2026-07-24-spar-report-design.md \
  docs/superpowers/specs/2026-07-24-phase5-unattended-mode-design.md
git commit -m "feat: /spar:report display command + docs for the final report"
```

---

## Non-goals

- New report call sites at `cap`, `sweep-findings-at-cap`, `skipped`, or `cancelled` (the generator is reason-agnostic; adding one is a one-line change later).
- A `/spar:fight` roll-up report aggregating every task's per-run report.
- Committing the report to git, or any change to the enforced invariants, block messages, or the convergence decision.
- A plugin version bump / release commit (`plugin.json` stays at `0.5.0`).

## Self-Review notes

**Spec coverage** (`2026-07-24-spar-report-design.md`):
- Generation/display split → Tasks 1-3 (generator), Task 5 (display). ✅
- Generation before `cleanup()` → Task 4 (`generate_report` inside `finish_approve`, before `cleanup`), asserted by test R2 (ledger captured, ledger then gone). ✅
- Generator invocation contract `<review-id> <base-sha> [reviews-dir] [state-dir]` → Task 1 Interfaces. ✅
- Fail-open → Task 4 Step 3 helper + tests R5 (failing generator) and R6 (missing generator). ✅
- All declared inputs read → state (Task 1), outcome (Task 1), per-round review/response (Task 2), judge files + ledger + registry + sweep (Task 3), `git diff --stat` (Task 1). ✅
- Four report sections → Result (Task 1), Findings tally with per-round lines (Task 2), Escalations & decisions (Task 3), Changed files (Task 1). ✅
- Atomic write, under the existing `reviews/spar-*` exclude → Task 1 publish block; Global Constraints. ✅
- `/spar-report [id]` display, newest by default, plain message when missing → Task 5. Renamed `/spar:report`, recorded in Global Constraints and Task 5 Step 10. ✅
- Scope = converged only → Global Constraints + test R3 asserts the cap path writes no report. ✅
- Testing (pure-bash fixture test of the generator + a display smoke test) → `tests/test_spar_report.sh`, `tests/test_report_show.sh`. ✅
- Three open questions → decided in Global Constraints, documented in Task 5 Step 10. ✅

From `2026-07-24-phase5-unattended-mode-design.md`: only the report's relationship to parked / blocked-pending-user is in scope here — covered by Task 3 (`### Pending design decisions` + queue pointer) and Task 4 (shared `generate_report`), asserted by generator test 15 and hook test R4.

**Type/name consistency:** `spar-report.sh` (generator), `spar-report-show.sh` (display resolver), `report.md` (command), `generate_report()` (hook helper), `REPORT_GEN` (existing hook variable, unchanged), report path `reviews/spar-<id>-report.md` — used identically in every task. Section headings `## Result` / `## Findings` / `## Escalations & decisions` / `## Changed files` match between Task 1's layout block, Tasks 2-3's emitters, and every test.

**Pre-verified (2026-07-25, before this plan was handed off):** every `bash`
code block here was extracted and run as-is against a scratch copy of the repo —
the assembled generator plus its test file (Tasks 1-3) reported `PASS=60 FAIL=0`,
the display resolver plus its test (Task 5) `PASS=16 FAIL=0`, and `stop-hook.sh`
patched exactly as Task 4 describes ran the full existing suite plus the new
report checks at `PASS=214 FAIL=0`. Two harness details were found that way and
are already fixed in the code above: the new tests' `chk` must call
`grep -qF -- "$2"` (report expectations start with `-`, which grep would read as
an option), and the Task 4 fixtures must force `sweep_done: true` /
`sweep_result: clean` (otherwise `should_sweep()` fires and the hook blocks for a
final sweep instead of reaching the terminal path). Steps that only edit prose
(Task 5 Steps 6-10) were not executed.

**Known fixture detail:** `tests/test_stop_hook.sh`'s `write_state` sets `base_sha: aaaaaaaa…`, which is not a real commit in the temp repo. The generator handles that by design (Task 1 test 6): the change surface degrades to `(no usable baseline: …)` and the report is still written. Tests R1-R4 therefore assert on sections, not on diff content.
