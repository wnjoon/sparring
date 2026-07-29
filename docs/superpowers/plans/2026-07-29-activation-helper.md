# Shared plan-activation helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two hand-maintained copies of the plan-activation sequence with one executable helper that both fight entry points invoke, and test that helper directly.

**Architecture:** A new `plugins/spar/commands/spar-plan-activate.sh` performs everything from the phase checks through the launch. It locates `spar-plan-lib.sh`, `spar-plan-review-check.sh` and `spar-fight-launch.sh` from `BASH_SOURCE`, so the caller's plugin-root variable never enters the shared code. Both `plugins/spar/commands/fight.md` and `adapters/codex/skills/spar-fight/SKILL.md` shrink to a single invocation. Behaviour is unchanged: every message, exit status and state write stays as it is today, with the seat-specific wording derived from one argument rather than duplicated.

**Tech Stack:** POSIX-ish bash, pure-bash test suites (no framework), `git hash-object` for fixtures.

## Global Constraints

- No observable behaviour change. Messages, exit statuses and state writes stay as they are; only their source moves.
- The helper resolves its siblings from `BASH_SOURCE`, never from `CLAUDE_PLUGIN_ROOT` or `SPAR_ROOT`.
- Any refusal leaves the plan state exactly as it found it.
- `plan_put_field` for `plan_review`, `author` and `owner_session`; `plan_set_field` only for `phase`, which always exists.
- No change to `plugins/spar/hooks/stop-hook.sh` or `stop-fight.sh`.
- Both new and modified scripts stay executable, and the mode is asserted in a test.

---

### Task 1: The helper, tested directly

**Files:**
- Create: `plugins/spar/commands/spar-plan-activate.sh`
- Test: `tests/test_plan_activate.sh` (new)

**Interfaces:**
- Produces: `spar-plan-activate.sh <state-file> <plan-review-flag> <seat> [session-id]`. `<plan-review-flag>` is `true` or `false`; `false` means `--no-plan-review` was given. `<seat>` is `claude` or `codex`. Exit 0 having printed the "Fight started" line on stdout; exit 1 with a message on stderr. Task 2 wires both entry points to it.
- Consumes: `plan_field` / `plan_set_field` / `plan_put_field` from `spar-plan-lib.sh`; `spar-plan-review-check.sh`; `spar-fight-launch.sh`.

**The seat argument decides three things and nothing else.** The command names in
messages (`/spar:fight` and `/spar:cancel` for `claude`, `spar-fight` and
`spar-cancel` for `codex`), whether the author/owner stamps are written (`codex`
only), and the trailing sentence of the success line. Everything else is shared.
An unknown seat is an error, not a default — a typo that silently selected the
Claude wording would leave a Codex run unstamped and ungated.

- [x] **Step 1: Write the failing tests**

Create `tests/test_plan_activate.sh`, executable, following `tests/test_plan_review_check.sh`'s harness shape — its own temp repo, `chk`/`chk_absent`/`eqchk`, `cd "$(pwd -P)"` after `mktemp -d` so macOS's `/var` symlink does not confuse path checks:

```bash
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/plugins/spar/commands/spar-plan-activate.sh"
chk(){ if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent(){ if printf '%s' "$3" | grep -qF -- "$2"; then echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }
eqchk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got:[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); cd "$TMP" || exit 1; cd "$(pwd -P)" || exit 1
git init -q; git config user.email t@t; git config user.name t
mkdir -p .claude reviews
ST=".claude/spar-plan.local.md"
PRID=20260729-120000-abc123

mkplan() { printf '# Plan\n\n### Task 1: Alpha\n\nfirst\n\n### Task 2: Beta\n\nsecond\n' > p.md; }
mkstate() { # $1=phase  $2=mode  $3=extra frontmatter lines (may be empty)
  { printf -- '---\nactive: true\nphase: %s\nmode: %s\nreviewer: codex\nunattended: false\n' "$1" "$2"
    [ -n "${3:-}" ] && printf '%s\n' "$3"
    printf 'plan_path: p.md\nbranch: b\ntasks: 2\ncurrent: 1\ncurrent_review_id:\n---\n1\tpending\tTask 1: Alpha\n2\tpending\tTask 2: Beta\n'
  } > "$ST"
}
reset() { rm -f .claude/spar.local.md .claude/spar-fight-task.txt reviews/spar-plan-*.md; mkplan; }
# Every refusal must leave the state byte-for-byte as it was. Substring checks
# like "phase: planned" cannot see a stamp or a plan_review line written before
# the refusal, which is exactly the ordering defect this refactor exists to make
# impossible in one place instead of two.
refuses() { # $1=label  $2..=args to the helper
  local label="$1"; shift
  local before; before="$(cat "$ST")"
  local out rc
  out="$(bash "$A" "$@" 2>&1)"; rc=$?
  eqchk "$label — refuses" "1" "$rc"
  eqchk "$label — leaves the state untouched" "$before" "$(cat "$ST")"
  eqchk "$label — starts no loop" "absent" \
    "$([ -f .claude/spar.local.md ] && echo present || echo absent)"
  printf '%s' "$out"
}
```

**The suite must end with a footer, or a failure cannot fail anything.** Without
it `$FAIL` is never reported and the exit status is the last command's, so the
commit guard in step 6 and the whole-suite loop both read a broken suite as
green. Copy `tests/test_plan_review_check.sh:263-264`:

```bash
cd /; rm -rf "$TMP"
echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

Then the cases. Each asserts the exit status and, where the point of the case is
the message, the message:

```bash
eqchk "the helper is executable" "yes" "$([ -x "$A" ] && echo yes || echo no)"

# ── preconditions, each refusing before anything is written ─────────────────
reset; mkstate running per-task ''
OUT="$(refuses "a running plan" "$ST" true claude)"
chk "and says so" "already being fought" "$OUT"
chk "in Claude's words" "/spar:cancel" "$OUT"

reset; mkstate running per-task ''
OUT="$(refuses "a running plan, codex seat" "$ST" true codex sess1)"
chk "in Codex's words for that seat" "spar-cancel" "$OUT"
chk_absent "and not Claude's" "/spar:cancel" "$OUT"

reset; mkstate done per-task ''
refuses "any other phase" "$ST" true claude >/dev/null

reset; mkstate planned per-task ''; printf 'x\n' > .claude/spar.local.md
BEFORE="$(cat "$ST")"
OUT="$(bash "$A" "$ST" true claude 2>&1)"; RC=$?
eqchk "an active loop blocks activation" "1" "$RC"
chk "and says a loop is active" "already active" "$OUT"
eqchk "leaving the state untouched" "$BEFORE" "$(cat "$ST")"
rm -f .claude/spar.local.md

reset; mkstate planned per-task ''; rm -f p.md
OUT="$(refuses "a missing plan file" "$ST" true claude)"
chk "naming the path" "p.md" "$OUT"

reset; mkstate planned per-task ''
refuses "an unknown seat" "$ST" true banana >/dev/null

# The session id is required for the codex seat: without it the run activates
# with an empty owner_session and the ownership the seat exists to record is
# gone. Rejected before any state write, and on the same character class
# spar-fight-launch.sh:22-25 rejects — a newline there injects a frontmatter field.
reset; mkstate planned per-task ''
refuses "a codex seat with no session" "$ST" true codex >/dev/null
reset; mkstate planned per-task ''
refuses "a codex session with a newline" "$ST" true codex "$(printf 'a\nb: c')" >/dev/null
reset; mkstate planned per-task ''
refuses "a codex session with a space" "$ST" true codex "bad id" >/dev/null

# ── the plan-review gate ────────────────────────────────────────────────────
# required with no result: refused, and NOTHING may have been written — not the
# phase, not a stamp. A refusal that already flipped the phase leaves cancel as
# the only way out; a refusal that stamped first is the ordering defect this
# refactor exists to make impossible in one place instead of two.
reset; mkstate planned per-task "$(printf 'plan_review: required\nplan_review_id: %s' "$PRID")"
refuses "an unreviewed plan" "$ST" true claude >/dev/null
reset; mkstate planned per-task "$(printf 'plan_review: required\nplan_review_id: %s' "$PRID")"
refuses "an unreviewed plan, codex seat" "$ST" true codex sess-1 >/dev/null

# a CLEAN review clears it
reset; mkstate planned per-task "$(printf 'plan_review: required\nplan_review_id: %s' "$PRID")"
printf 'PLAN-REVIEW: CLEAN\n' > "reviews/spar-plan-${PRID}.md"
eqchk "a reviewed plan activates" "0" "$(bash "$A" "$ST" true claude >/dev/null 2>&1; echo $?)"
chk "and the phase moved" "phase: running" "$(cat "$ST")"

# the override, on a state with NO plan_review key — the case plan_set_field gets wrong
reset; mkstate planned per-task ''
OUT="$(bash "$A" "$ST" false claude 2>&1)"; RC=$?
eqchk "the override activates" "0" "$RC"
chk "and is recorded on a state that lacked the field" "plan_review: overridden" "$(cat "$ST")"
chk "and it says the review was skipped" "--no-plan-review" "$OUT"
chk "and the task table survived the append" "Task 2: Beta" "$(tail -1 "$ST")"

# ── seat-specific stamps ────────────────────────────────────────────────────
reset; mkstate planned per-task ''
bash "$A" "$ST" false codex sess-1 >/dev/null 2>&1
chk "the codex seat stamps the author" "author: codex" "$(cat "$ST")"
chk "and the owning session" "owner_session: sess-1" "$(cat "$ST")"

reset; mkstate planned per-task ''
bash "$A" "$ST" false claude >/dev/null 2>&1
chk_absent "the claude seat stamps no author" "author:" "$(cat "$ST")"
chk_absent "and no session" "owner_session:" "$(cat "$ST")"

# ── task extraction ─────────────────────────────────────────────────────────
reset; mkstate planned per-task ''
bash "$A" "$ST" false claude >/dev/null 2>&1
chk "per-task mode extracts task 1" "first" "$(cat .claude/spar-fight-task.txt)"
chk_absent "and not task 2" "second" "$(cat .claude/spar-fight-task.txt)"

reset; mkstate planned whole ''
bash "$A" "$ST" false claude >/dev/null 2>&1
chk "whole mode hands over the entire plan" "second" "$(cat .claude/spar-fight-task.txt)"

# ── it launched a real loop ─────────────────────────────────────────────────
reset; mkstate planned per-task ''
OUT="$(bash "$A" "$ST" false claude 2>&1)"
chk "a loop state exists afterwards" "phase: task" "$(cat .claude/spar.local.md)"
chk "and the success line names the task count" "task 1/2" "$OUT"
```

- [x] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_plan_activate.sh`
Expected: every check fails — the helper does not exist.

- [x] **Step 3: Write the helper**

`plugins/spar/commands/spar-plan-activate.sh`. Structure:

```bash
#!/usr/bin/env bash
# Activate a prepared plan: check the preconditions, clear the plan-review gate,
# stamp the seat, flip the phase, hand task 1 over and launch the loop.
# Usage: spar-plan-activate.sh <state-file> <plan-review-flag> <seat> [session-id]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/spar-plan-lib.sh"

PLAN_STATE="${1:?plan state}"
NO_REVIEW_FLAG="${2:-true}"
SEAT="${3:?seat}"
SESSION="${4:-}"

case "$SEAT" in
  claude) FIGHT_CMD="/spar:fight"; CANCEL_CMD="/spar:cancel" ;;
  codex)  FIGHT_CMD="spar-fight";  CANCEL_CMD="spar-cancel"  ;;
  *) echo "error: unknown seat: $SEAT" >&2; exit 1 ;;
esac

# Validated here, before any check that could write: the codex seat's whole point
# is that the plan is owned by a named session, and an empty value would activate
# with that ownership silently absent. Same character class spar-fight-launch.sh
# rejects at :22-25 — a newline would inject an arbitrary frontmatter field.
if [ "$SEAT" = codex ]; then
  [ -n "$SESSION" ] || { echo "error: the codex seat requires a session id" >&2; exit 1; }
  case "$SESSION" in *[!A-Za-z0-9_.-]*)
    echo "error: session id has unexpected characters" >&2; exit 1 ;;
  esac
fi
```

Then, in this order, each refusal printing to stderr and exiting 1:

1. `PHASE="$(plan_field phase "$PLAN_STATE")"`; `running` → "this plan is already being fought. Continue by stopping, or ${CANCEL_CMD} to abandon it."; anything other than `planned` → "plan state is not ready to fight (phase: $PHASE)."
2. `[ -f .claude/spar.local.md ]` → "a fight loop is already active. Use ${CANCEL_CMD} first."
3. `PLAN="$(plan_field plan_path "$PLAN_STATE")"`, `MODE="$(plan_field mode "$PLAN_STATE")"`; `[ -f "$PLAN" ]` or → "plan file not found: $PLAN".
4. The gate:
   ```bash
   if [ "$NO_REVIEW_FLAG" = false ]; then
     plan_put_field plan_review overridden "$PLAN_STATE"
     echo "Note: starting without a plan review because --no-plan-review was given."
   elif ! bash "$DIR/spar-plan-review-check.sh" "$PLAN" "$PLAN_STATE"; then
     exit 1
   fi
   ```
5. `codex` seat only: `plan_put_field author codex "$PLAN_STATE"` and `plan_put_field owner_session "$SESSION" "$PLAN_STATE"`.
6. `plan_set_field phase running "$PLAN_STATE"`.
7. Task extraction, copied verbatim from either document — they are already identical:
   ```bash
   H1="$(plan_task_line 1 "$PLAN_STATE" | cut -f3)"
   if [ "$MODE" = "whole" ]; then cp "$PLAN" .claude/spar-fight-task.txt
   else awk -v h="### ${H1}" '$0==h{f=1} f&&/^### /&&$0!=h&&seen{exit} $0==h{seen=1} f{print}' "$PLAN" > .claude/spar-fight-task.txt; fi
   ```
8. `bash "$DIR/spar-fight-launch.sh" "$PLAN_STATE" .claude/spar-fight-task.txt || { echo "Error: could not launch task 1." >&2; exit 1; }`
9. The success line:
   ```bash
   echo "Fight started on the ready plan (task 1/$(plan_field tasks "$PLAN_STATE")). Implement task 1 following its steps in ${PLAN}, then stop${TAIL}"
   ```
   where `TAIL` is `.` for `codex` and ` — the sparring reviewer engages automatically and the fight advances task-by-task on convergence.` for `claude`, preserving both documents' current wording exactly.

**The order is the Codex seat's, adopted for both.** The gate sits before the
author/owner stamps, not merely before the phase flip, so a refusal writes
nothing at all. The Claude seat has no stamps today, so this is invisible there —
which is exactly why it must live in the shared code rather than in one copy.

**`plan_put_field`, not `plan_set_field`, for `plan_review`.** The latter is a
pure replace and does nothing on a state written before the field existed
(`spar-plan-lib.sh:31-35` says so in its own comment). A plan prepared by an
older version carries no `plan_review` line, and `--no-plan-review` on it must
still record the override rather than silently do nothing.

`chmod +x` the script.

- [x] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_plan_activate.sh`
Expected: `FAIL=0`.

- [x] **Step 5: Prove each part is independently caught**

Five scratch copies of the repository. In each, make the named change, run
`bash tests/test_plan_activate.sh`, and confirm the named checks fail and the
rest stay green:

1. Move the gate to *after* the author/owner stamps → "an unreviewed plan, codex
   seat — leaves the state untouched" fails, because the stamps landed on a plan
   that was then refused. This is the check the first draft of this plan admitted
   it had no way to catch; the byte comparison is what catches it. The Claude-seat
   case stays green, since that seat writes no stamps — which is precisely why
   the ordering has to live in shared code rather than in one copy.
2. Remove the gate entirely → the two "an unreviewed plan" groups fail.
3. `plan_put_field plan_review overridden` → `plan_set_field` → "is recorded on a
   state that lacked the field" fails.
4. Drop the `codex` arm of the stamp block → both codex stamp checks fail, and
   the two `claude` absence checks stay green.
5. Remove the session validation → the three "codex … session" refusal groups
   fail.
6. Make an unknown seat fall back to `claude` instead of erroring → "an unknown
   seat — refuses" fails.
7. Make `whole` mode extract task 1 anyway → "whole mode hands over the entire
   plan" fails.
8. Delete the suite's footer → run the suite with a deliberately broken helper and
   confirm the exit status is no longer non-zero; restore. Without this the
   commit guard in step 6 cannot fail.

- [x] **Step 6: Commit**

```bash
bash tests/test_plan_activate.sh || { echo "not committing — the suite failed"; exit 1; }
git add plugins/spar/commands/spar-plan-activate.sh tests/test_plan_activate.sh
git commit -m "feat(fight): one activation helper for both seats"
```

---

### Task 2: Both entry points invoke the helper

**Files:**
- Modify: `plugins/spar/commands/fight.md`
- Modify: `adapters/codex/skills/spar-fight/SKILL.md`
- Test: `tests/test_stop_hook.sh`, `tests/test_codex_adapter.sh`

**Interfaces:**
- Consumes: `spar-plan-activate.sh <state-file> <plan-review-flag> <seat> [session-id]` from Task 1.

- [x] **Step 1: Write the failing tests**

**Every static assertion that names an activation internal has to move with the
code, or the suites cannot pass.** They assert that a *document* contains a
string; the refactor takes those strings out of the documents. Adding new checks
beside them is not enough — the old ones must be retargeted at
`spar-plan-activate.sh` or deleted. This is the whole of the work in this step,
so here is the exact list, verified against the files as they stand.

Retarget in `tests/test_stop_hook.sh` (all three read `fight.md` today):

| line | assertion | new subject |
|---|---|---|
| 141 | `/spar:fight gates on the plan review` → `spar-plan-review-check.sh` | the helper |
| 145 | `and does so before flipping the phase` (awk comparing two line numbers) | the helper |
| 150 | `the override appends rather than replaces` → `plan_put_field plan_review overridden` | the helper |

Retarget in `tests/test_codex_adapter.sh` (all read `$FIGHT`, the skill's text):

| line | assertion | new subject |
|---|---|---|
| 260 | `fight skill gates on the plan review` | the helper |
| 262 | `and does so before flipping the phase` | the helper |
| 268 | `fight skill appends the override` | the helper |
| 281 | `fight skill launches through the shared launcher` → `spar-fight-launch.sh` | the helper |
| 285 | `fight skill stamps the author with an inserting write` | the helper |
| 286 | `fight skill stamps the session with an inserting write` | the helper |
| 287 | `chk_absent … never stamps the seat with a replace-only write` | the helper |

Leave alone — these name strings the documents keep, and retargeting them would
weaken real coverage: `spar-check-worktree.sh` (`:282`) and `spar-fight-resolve.sh`
(`:289`) live in the single-task path; `reviewer_version:` (`:259`) and
`author: codex` (`:241`) also appear in that path's state heredoc at
`SKILL.md:194-197`; the liveness checks (`:239`, `:269`, `:273`, `:274`), the
`SPAR_PLAN_REVIEW=` destructuring (`:244`), the task-arg refusal (`:280`) and the
`mktemp`/`mv` state checks in `tests/test_stop_hook.sh:134-137`.

Then add the wiring checks — the part that can still drift once the body is
shared. For `tests/test_stop_hook.sh`:

```bash
chk "/spar:fight activates through the shared helper" 'spar-plan-activate.sh' \
  "$(cat "$CLAUDE_PLUGIN_ROOT/commands/fight.md")"
# The seat argument selects the stamps and the wording. Passed wrong, a Claude
# run would stamp author: codex and name the wrong commands — and the behavioural
# test would not notice, because it does not look at the author field. So it does
# below, too.
chk "and names its own seat" 'spar-plan-activate.sh" "$PLAN_STATE" "$SPAR_PLAN_REVIEW" claude' \
  "$(cat "$CLAUDE_PLUGIN_ROOT/commands/fight.md")"
chk "and no longer carries its own copy" "absent" \
  "$(grep -q 'plan_set_field phase running' "$CLAUDE_PLUGIN_ROOT/commands/fight.md" && echo present || echo absent)"
```

and for `tests/test_codex_adapter.sh`:

```bash
chk "fight skill activates through the shared helper" "spar-plan-activate.sh" "$FIGHT"
chk "and names its own seat" 'spar-plan-activate.sh" "$PLAN_STATE" "$SPAR_PLAN_REVIEW" codex "$SPAR_SESSION"' "$FIGHT"
chk "and no longer carries its own copy" "absent" \
  "$(grep -q 'plan_set_field phase running' "$ROOT/adapters/codex/skills/spar-fight/SKILL.md" && echo present || echo absent)"
```

`run_activation` in `tests/test_stop_hook.sh` — the block-extraction test added in
the previous phase — must keep passing **unchanged**. It is the regression guard
for this whole task: if it needs editing, behaviour changed. Add one assertion to
it, since the seat argument is now what keeps the Claude seat unstamped:

```bash
chk_absent "and the claude seat stamped no author" "author:" \
  "$(cat .claude/spar-plan.local.md)"
```

**The Codex adapter suite gains its first execution test.** It has only ever
grepped. The fixture must be hermetic — that suite runs with `set -u` (`:3`), so
every variable the assertions read has to be defined in the fixture itself:

```bash
# The one behavioural test in this suite. Everything above greps the document;
# this runs it. Its own temp repo, because the suite's other cases do not need
# one and must not inherit this one's state.
CTMP=$(mktemp -d); ( cd "$CTMP" && cd "$(pwd -P)" || exit 1
  git init -q; git config user.email t@t; git config user.name t
  mkdir -p .claude reviews
  PLAN_STATE=".claude/spar-plan.local.md"
  printf '# Plan\n\n### Task 1: A\n\ndo it\n' > p.md
  git add p.md && git commit -q -m base
  # No plan_review key: the state a plan prepared before Phase 9 has, and the
  # case a replace-only write gets wrong.
  printf -- '---\nactive: true\nphase: planned\nmode: per-task\nreviewer: claude\nplan_path: p.md\nbranch: b\ntasks: 1\ncurrent: 1\ncurrent_review_id:\n---\n1\tpending\tTask 1: A\n' \
    > "$PLAN_STATE"
  # The skill refuses without a live-hook marker matching this session, and reads
  # its arguments from a file. Neither is what this test is about.
  export CODEX_THREAD_ID=t1
  printf 't1\n' > "$(git rev-parse --git-dir)/spar-hook-live"
  printf -- '--no-plan-review\n' > .claude/spar-args.txt
  export SPAR_PLUGIN_ROOT="$ROOT/plugins/spar"
  # reviewer=claude above and a stub on PATH: spar-fight-launch.sh asks the
  # reviewer CLI for its version, and a real call would make this test depend on
  # a network.
  STUBS=$(mktemp -d); printf '#!/bin/sh\necho 1.0.0\n' > "$STUBS/claude"
  chmod +x "$STUBS/claude"; PATH="$STUBS:$PATH"
  awk '/^```bash$/{f=1; next} /^```$/{if (f) exit} f' \
    "$ROOT/adapters/codex/skills/spar-fight/SKILL.md" | bash >/dev/null 2>&1
  cat "$PLAN_STATE" > "$CTMP/after.txt"
  rm -rf "$STUBS" )
AFTER="$(cat "$CTMP/after.txt" 2>/dev/null)"; rm -rf "$CTMP"
chk "the codex block records the override" "plan_review: overridden" "$AFTER"
chk "and stamps its own seat" "author: codex" "$AFTER"
chk "and the owning session" "owner_session: t1" "$AFTER"
chk "and the plan activated" "phase: running" "$AFTER"
```

**These four assertions pass before the refactor as well as after** — the skill
already does all four things today (`SKILL.md:129-152`). That is deliberate: they
are the regression guard, the Codex counterpart of `run_activation`, and a
regression guard that only starts passing after the change guards nothing. The
checks that fail in step 2 are the static ones.

- [x] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`, `bash tests/test_codex_adapter.sh`

Expected, precisely:

- The new wiring checks fail in both suites — no document names the helper yet.
- Every retargeted check fails — `spar-plan-activate.sh` does not contain those
  strings yet either. (It does after Task 1 is merged; if Task 1 is already in
  place these pass, which is correct and not a problem.)
- The `and no longer carries its own copy` checks fail — the documents still do.
- The four new Codex **execution** checks pass, because the skill already records
  the override, stamps both fields and flips the phase (`SKILL.md:129-152`). They
  are a regression guard, not a red-phase check. If any of them is red here, the
  fixture is wrong, not the code.
- `run_activation` passes, unchanged.

- [x] **Step 3: Replace `fight.md`'s copy**

Everything from `. "${CLAUDE_PLUGIN_ROOT}/commands/spar-plan-lib.sh"` through the
`echo "Fight started …"` line becomes:

```bash
  bash "${CLAUDE_PLUGIN_ROOT}/commands/spar-plan-activate.sh" "$PLAN_STATE" "$SPAR_PLAN_REVIEW" claude || exit 1
  exit 0
```

The `SPAR_TASK`-with-a-plan refusal above it stays — it is about argument
handling, not activation.

- [x] **Step 4: Replace the Codex skill's copy**

The same, with that document's own root variable and its session:

```bash
  bash "$SPAR_ROOT/commands/spar-plan-activate.sh" "$PLAN_STATE" "$SPAR_PLAN_REVIEW" codex "$SPAR_SESSION" || exit 1
  exit 0
```

Its liveness check and `SPAR_TASK` refusal stay where they are.

- [x] **Step 5: Run the tests to verify they pass**

Run all suites:

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
echo "rc=$rc"
```

Expected: `rc=0`. In particular `run_activation` in `tests/test_stop_hook.sh` —
the behavioural test that predates this task — must still pass untouched. If it
needed editing to accommodate the refactor, the refactor changed behaviour.

- [x] **Step 6: Prove the wiring is independently caught**

Four scratch copies:

1. Remove the helper call from `fight.md` → the Claude static checks and the two
   `run_activation` behavioural groups fail.
2. Pass `codex` as the seat in `fight.md` → the seat static check fails, and the
   behavioural test should too; if it does not, add an assertion that the Claude
   seat's activated state carries no `author:` line.
3. Remove the helper call from the Codex skill → that suite's static and
   execution checks fail, and the Claude suite stays green.
4. Drop `"$SPAR_SESSION"` from the Codex call → `owner_session` is empty in the
   activated state; assert on it if nothing else catches this.

- [x] **Step 7: Update the design record and commit**

Add a short paragraph to the Phase 9 section of `docs/design-decisions.md`:
that activation now lives in one helper, that the trigger was a finding about a
test which reimplemented the logic it was meant to guard, and that the seat
argument is the only thing the two entry points still differ by.

```bash
rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null || { echo "FAILED: $t"; rc=1; }; done
[ "$rc" -eq 0 ] || { echo "not committing — a suite failed"; exit 1; }
git add -A
git commit -m "refactor(fight): both seats activate a plan through one helper"
```

---

## Non-goals

- Any observable behaviour change. If a message, exit status or state write
  differs after this plan, it is a defect, not an improvement.
- Merging the single-task (no plan) path. The two seats differ there in argument
  handling, which is an entry-point concern.
- Touching `stop-hook.sh` or `stop-fight.sh`. Task advancement after the first
  belongs to the hook and already has exactly one implementation.
- Fixing `spar-report.sh`'s pre-existing `reviewer` fallback, carried over as a
  non-goal from the previous phase.

## Verification this plan cannot do

Whether one helper actually prevents the next drift. It removes the mechanism —
there is no second copy to forget — but a new seat added carelessly could still
bypass it. The static checks assert that each document calls the helper; they
cannot assert that a document added later does.
