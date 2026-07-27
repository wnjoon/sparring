# Phase 7 — model economics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a run spend less on typing without spending less on judgment — configurable reviewer model and effort, and fix execution delegated to a cheaper writer when the fix is unambiguous.

**Architecture:** A new `plugins/spar/shared/config.toml` holds per-family reviewer model, writer tier, and an effort ladder. A small reader turns it into shell variables the hook already has places for; the generated runner scripts gain the flags each CLI actually accepts (`codex exec -c model_reasoning_effort=…`, `claude -p --effort …`, `--model` on both). Fix delegation is *instructional*, not mechanical: the hook computes and hands the author a self-contained brief plus a tier recommendation, and the author dispatches its own subagent — the plugin cannot switch the session model and must not pretend to.

**Tech Stack:** Bash + a python3 TOML read (3.11+ `tomllib`, the same dependency and version floor `verify-live.sh` already declares). Tests are pure bash in `tests/`, hermetic, no reviewer CLI.

## Global Constraints

- The four invariants in `README.md` hold unchanged: single-writer, reviewer-declares, deterministic enforcement with fail-open hooks, blind adjudication.
- **Judgment never delegates; typing may.** The session model keeps planning, initial implementation, reading reviews, classifying findings, rejecting with grounds, compiling briefs, and gate handling.
- Every config value is optional. A missing or unreadable `config.toml` must leave behaviour exactly as it is today — this is an economics feature, not a new dependency of the loop.
- Effort values are the ones the CLIs accept, measured not guessed: `claude --effort low|medium|high|xhigh|max`; `codex exec -c model_reasoning_effort="…"`. Both accept `--model`.
- No test may require `codex` or `claude` on PATH.
- Per-round lens rotation and the cross-family sweep are **out of scope**.
- `plugins/spar/hooks/stop-hook.sh` is a surface both seats share. Per the release gate in `docs/design-decisions.md`, the change must be exercised in a live session of each seat before the release that carries it.

---

### Task 1: Config file, reader, and the effort ladder

**Files:**
- Create: `plugins/spar/shared/config.toml`
- Create: `plugins/spar/commands/spar-config.sh`
- Test: `tests/test_config.sh`

**Interfaces:**
- Produces: `spar-config.sh <family> <diff-lines>` prints four `key=value` lines on stdout — `model=`, `effort=`, `writer=`, `source=` — and exits 0 always. `source=` is `config` or `default`. Unknown family, missing file, unreadable TOML, or absent python3 all yield the default line set with `source=default`. Consumed by Task 2 (runner flags) and Task 3 (writer tier).

- [ ] **Step 1: Write the failing test**

Create `tests/test_config.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/plugins/spar/commands/spar-config.sh"
chk() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent() { if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }
fresh() { d=$(mktemp -d); cd "$d" || exit 1; cd "$(pwd -P)" || exit 1; }

# 1. shipped defaults: no override file anywhere
fresh
OUT=$(SPAR_CONFIG_FILE=/nonexistent bash "$C" claude 40); RC=$?
chk "missing config → exit 0" "0" "$RC"
chk "missing config → says it used defaults" "source=default" "$OUT"
chk "missing config → still names an effort" "effort=" "$OUT"
chk "missing config → writer tier present" "writer=" "$OUT"
chk_absent "missing config → invents no model" "model=null" "$OUT"

# 2. a config supplies per-family values
fresh
cat > cfg.toml <<'TOML'
[reviewer.claude]
model = "claude-sonnet-5"
[reviewer.codex]
model = "gpt-5.6-sol"
[writer.claude]
tier = "claude-haiku-4-5-20251001"
TOML
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40)
chk "claude model read from config" "model=claude-sonnet-5" "$OUT"
chk "claude writer tier read from config" "writer=claude-haiku-4-5-20251001" "$OUT"
chk "reads as config, not default" "source=config" "$OUT"
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" codex 40)
chk "codex model read from its own table" "model=gpt-5.6-sol" "$OUT"
chk "codex writer falls back when its table is absent" "writer=" "$OUT"

# 3. effort scales with diff size, using the ladder in the config
fresh
cat > cfg.toml <<'TOML'
[effort]
ladder = [[0, "low"], [200, "medium"], [1000, "high"]]
TOML
for pair in "10 low" "199 low" "200 medium" "999 medium" "1000 high" "50000 high"; do
  set -- $pair
  OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude "$1")
  chk "diff $1 lines → effort $2" "effort=$2" "$OUT"
done

# 4. a broken config never breaks the loop
fresh
printf 'this is [ not = toml\n' > cfg.toml
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40); RC=$?
chk "unparseable config → exit 0" "0" "$RC"
chk "unparseable config → falls back to defaults" "source=default" "$OUT"

fresh
mkdir -p cfg.toml
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40); RC=$?
chk "config is a directory → exit 0" "0" "$RC"
chk "config is a directory → defaults" "source=default" "$OUT"

fresh
printf '[reviewer.claude]\nmodel = "x"\n' > cfg.toml
ln -s "$PWD/cfg.toml" link.toml
OUT=$(SPAR_CONFIG_FILE="$PWD/link.toml" bash "$C" claude 40)
chk "symlinked config → ignored, defaults used" "source=default" "$OUT"

# 5. a value of the wrong shape is ignored, not passed through
fresh
cat > cfg.toml <<'TOML'
[reviewer.claude]
model = 42
[effort]
ladder = "not a ladder"
TOML
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40)
chk_absent "non-string model is dropped" "model=42" "$OUT"
chk "bad ladder → default effort still emitted" "effort=" "$OUT"

# 6. an unknown family is not an error
fresh
OUT=$(SPAR_CONFIG_FILE=/nonexistent bash "$C" gemini 40); RC=$?
chk "unknown family → exit 0" "0" "$RC"
chk "unknown family → defaults" "source=default" "$OUT"

# 7. output is exactly four key=value lines, nothing else
fresh
OUT=$(SPAR_CONFIG_FILE=/nonexistent bash "$C" claude 40)
chk "exactly four lines" "4" "$(printf '%s\n' "$OUT" | grep -c '=')"
chk_absent "no stray prose" " " "$(printf '%s\n' "$OUT" | tr -d '\n')"

# 8. the shipped config parses and every family it names is one we support
CFG="$ROOT/plugins/spar/shared/config.toml"
chk "shipped config exists" "present" "$([ -f "$CFG" ] && echo present || echo absent)"
OUT=$(SPAR_CONFIG_FILE="$CFG" bash "$C" claude 100)
chk "shipped config parses" "source=" "$OUT"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_config.sh`
Expected: every check FAILs — neither the reader nor the config exists.

- [ ] **Step 3: Write the shipped config**

`plugins/spar/shared/config.toml`, commented so a reader learns the contract from the file:

```toml
# sparring — model economics. Every value here is optional: delete this file and
# the loop behaves exactly as it did before Phase 7. Judgment never delegates;
# only typing does, so nothing here can change which model reads a review,
# classifies a finding, or decides whether to reject it.

[reviewer.claude]
# model = "claude-sonnet-5"

[reviewer.codex]
# model = "gpt-5.6-sol"

[writer.claude]
# Fix execution only, and only for findings the hook screens as unambiguous.
# tier = "claude-haiku-4-5-20251001"

[writer.codex]
# tier = "gpt-5.6-sol-mini"

[effort]
# Reviewer reasoning effort by changed-line count: [threshold, level] pairs,
# lowest first. A diff at or above a threshold takes that level.
# claude accepts low|medium|high|xhigh|max; codex takes the same words through
# -c model_reasoning_effort=.
ladder = [[0, "low"], [200, "medium"], [1000, "high"]]
```

- [ ] **Step 4: Write the reader**

`plugins/spar/commands/spar-config.sh`. It must never fail the caller:

```bash
#!/usr/bin/env bash
# Read model-economics settings for one family. Prints four key=value lines and
# always exits 0 — an economics setting that cannot be read must degrade to the
# old behaviour, never stop a review.
# Usage: spar-config.sh <family> <changed-line-count>
set -uo pipefail

FAMILY="${1-}"; LINES="${2-0}"
case "$LINES" in ''|*[!0-9]*) LINES=0 ;; esac
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${SPAR_CONFIG_FILE:-$DIR/../shared/config.toml}"

emit_default() { printf 'model=\neffort=medium\nwriter=\nsource=default\n'; exit 0; }

[ -f "$CFG" ] && [ ! -L "$CFG" ] || emit_default
command -v python3 >/dev/null 2>&1 || emit_default

OUT="$(CFG="$CFG" FAMILY="$FAMILY" LINES="$LINES" python3 -I - <<'PY' 2>/dev/null)" || emit_default
import os, sys
try:
    import tomllib
except Exception:
    sys.exit(1)
try:
    with open(os.environ["CFG"], "rb") as fh:
        cfg = tomllib.load(fh)
except Exception:
    sys.exit(1)

fam, lines = os.environ["FAMILY"], int(os.environ["LINES"])

def s(table, key):
    v = cfg.get(table, {}).get(fam, {}).get(key)
    return v if isinstance(v, str) and v.strip() else ""

effort = "medium"
ladder = cfg.get("effort", {}).get("ladder")
if isinstance(ladder, list):
    picked = None
    for row in ladder:
        if (isinstance(row, list) and len(row) == 2
                and isinstance(row[0], int) and isinstance(row[1], str)
                and lines >= row[0]):
            if picked is None or row[0] >= picked[0]:
                picked = row
    if picked:
        effort = picked[1]

for k, v in (("model", s("reviewer", "model")), ("effort", effort),
             ("writer", s("writer", "tier")), ("source", "config")):
    if "\n" in v or "\r" in v:
        sys.exit(1)
    print("%s=%s" % (k, v))
PY
printf '%s\n' "$OUT"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/test_config.sh`
Expected: `PASS=<n> FAIL=0`.

- [ ] **Step 6: Prove the fallbacks are real**

In a scratch copy, make `emit_default` print `source=config` and confirm the four fallback checks fail; then make the ladder ignore thresholds and confirm the six effort checks fail.

- [ ] **Step 7: Run the whole suite and commit**

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add plugins/spar/shared/config.toml plugins/spar/commands/spar-config.sh tests/test_config.sh
git commit -m "feat(economics): optional per-family model, writer tier and effort ladder"
```

---

### Task 2: Reviewer model and effort on the generated runners

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh`
- Modify: `tests/test_stop_hook.sh`
- Modify: `plugins/spar/shared/policy.md`, `README.md`

**Interfaces:**
- Consumes: `spar-config.sh <family> <lines>` from Task 1.
- Produces: generated runners carrying `--model` and effort flags when configured, and carrying neither when not. The reviewer, judge, matcher and sweep runners all go through one helper so a family's flags cannot drift between them.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_stop_hook.sh` before the tally. Fixtures use `printf` one-liners so no line here begins with a heading marker:

```bash
# Economics: a configured model and effort reach the generated runner.
in_review 1
printf '[reviewer.codex]\nmodel = "gpt-5.6-sol"\n[effort]\nladder = [[0, "low"]]\n' > .claude/cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/cfg.toml" run_hook >/dev/null
chk "configured model reaches the codex runner" '--model gpt-5.6-sol' "$(cat .claude/spar-run-reviewer.sh)"
chk "configured effort reaches the codex runner" 'model_reasoning_effort="low"' "$(cat .claude/spar-run-reviewer.sh)"

# With no config the runner is byte-identical to today's.
in_review 1
SPAR_CONFIG_FILE=/nonexistent run_hook >/dev/null
chk_absent "no config → no model flag" '--model' "$(cat .claude/spar-run-reviewer.sh)"
chk_absent "no config → no effort flag" 'model_reasoning_effort' "$(cat .claude/spar-run-reviewer.sh)"

# An unreadable config must not stop a review being dispatched.
in_review 1
printf 'not = = toml\n' > .claude/cfg.toml
OUT=$(SPAR_CONFIG_FILE="$PWD/.claude/cfg.toml" run_hook)
chk "broken config → the round is still dispatched" 'spar-run-reviewer.sh' "$OUT"
chk_absent "broken config → no half-written flag" '--model ' "$(cat .claude/spar-run-reviewer.sh)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: the four positive checks FAIL; the rest of the suite still passes.

- [ ] **Step 3: Add one flag helper and use it in every emitter**

In `stop-hook.sh`, next to the other helpers:

```bash
# Economics flags for one family, as a single string spliced into a generated
# runner. Empty when nothing is configured, which is what keeps a config-less
# install byte-identical to before. Values are shell-quoted: they come from a
# file the user edits, and they land in a script the loop executes.
economics_flags() { # $1=family  → prints the flags, or nothing
  local fam="$1" line model="" effort="" src=""
  [ -x "$CONFIG_READER" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in model) model="$v" ;; effort) effort="$v" ;; source) src="$v" ;; esac
  done < <("$CONFIG_READER" "$fam" "$(diff_line_count)" 2>/dev/null)
  [ "$src" = config ] || return 0
  case "$fam" in
    claude)
      [ -n "$model" ] && printf ' --model %s' "$(shq "$model")"
      [ -n "$effort" ] && printf ' --effort %s' "$(shq "$effort")" ;;
    codex)
      [ -n "$model" ] && printf ' --model %s' "$(shq "$model")"
      [ -n "$effort" ] && printf ' -c model_reasoning_effort=%s' "$(shq "\"$effort\"")" ;;
  esac
}
```

`shq` is a small single-quote escaper; `diff_line_count` counts lines in
`$DIFF_SURFACE_FILE` (0 when absent). Splice `$(economics_flags claude)` into the
`claude -p` invocations and `$(economics_flags codex)` into the `codex exec` ones,
in the reviewer, judge, matcher and sweep emitters alike.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_stop_hook.sh`
Expected: `PASS=<n> FAIL=0`, with the pre-existing 293 unchanged.

- [ ] **Step 5: Prove the flags are earned**

Mutate `economics_flags` to ignore `src` and confirm the no-config checks fail;
mutate it to emit `--effort` for codex and confirm the codex effort check fails.

- [ ] **Step 6: Document the mechanism where both seats read it**

Add a numbered item to `plugins/spar/shared/policy.md` stating that reviewer
model and effort are configuration, that absence means today's behaviour, and
that no configuration can change who declares convergence. Add one line to
`README.md` under Development naming `plugins/spar/shared/config.toml`.

- [ ] **Step 7: Run the whole suite and commit**

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add -A
git commit -m "feat(economics): reviewer model and effort flags on the generated runners"
```

---

### Task 3: The fix brief and its tier recommendation

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh`
- Modify: `plugins/spar/commands/fight.md`, `adapters/codex/skills/spar-fight/SKILL.md`
- Modify: `tests/test_stop_hook.sh`
- Modify: `docs/design-decisions.md`

**Interfaces:**
- Consumes: `spar-config.sh` writer tier; the round's parsed findings.
- Produces: `.claude/spar-fix-brief.md` when at least one finding is delegable, and a line in the block message pointing at it. The author dispatches; the hook only recommends.

- [ ] **Step 1: Write the failing test**

```bash
# A mechanical finding with a file:line becomes a delegable brief.
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] off by one\n- file: a.py:10\n- problem: loop stops early\n- suggestion: use n + 1\n' > "$RF1"
printf '[writer.codex]\ntier = "cheap-tier"\n' > .claude/cfg.toml
OUT=$(SPAR_CONFIG_FILE="$PWD/.claude/cfg.toml" run_hook)
chk "brief written for a delegable finding" "present" "$([ -f .claude/spar-fix-brief.md ] && echo present || echo absent)"
chk "brief carries the location" "a.py:10" "$(cat .claude/spar-fix-brief.md)"
chk "brief carries the basis, not just the title" "loop stops early" "$(cat .claude/spar-fix-brief.md)"
chk "brief names the recommended tier" "cheap-tier" "$(cat .claude/spar-fix-brief.md)"
chk "the block message points at the brief" "spar-fix-brief.md" "$OUT"
chk_absent "the hook does not claim to have dispatched anything" "dispatched the writer" "$OUT"

# A design finding is judgment and is never delegated.
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [DESIGN] split the module\n- file: mod.py:1\n- problem: big\n- suggestion: split\n' > "$RF1"
printf '[writer.codex]\ntier = "cheap-tier"\n' > .claude/cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/cfg.toml" run_hook >/dev/null
chk_absent "design findings are never delegated" "cheap-tier" "$(cat .claude/spar-fix-brief.md 2>/dev/null)"

# No writer tier configured → no brief, no behaviour change.
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] off by one\n- file: a.py:10\n- problem: p\n- suggestion: s\n' > "$RF1"
SPAR_CONFIG_FILE=/nonexistent run_hook >/dev/null
chk "no tier configured → no brief" "absent" "$([ -f .claude/spar-fix-brief.md ] && echo present || echo absent)"

# Escalation: a finding whose fingerprint the previous round already raised is
# the session model's to fix, not a cheap writer's.
in_review 2
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] a.py off by one\n- file: a.py:10\n- problem: p\n- suggestion: s\n' > "$RF1"
printf -- '### F1-1: FIXED — did it\n' > "$RP1"
printf 'STATUS: FINDINGS\n\n### F2-1 [MECHANICAL] a.py off by one\n- file: a.py:10\n- problem: still wrong\n- suggestion: s\n' > "$RFb2"
printf '[writer.codex]\ntier = "cheap-tier"\n' > .claude/cfg.toml
SPAR_CONFIG_FILE="$PWD/.claude/cfg.toml" run_hook >/dev/null
chk "a repeat of the previous round is not delegated" "escalated" "$(cat .claude/spar-fix-brief.md 2>/dev/null; echo escalated-absent)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: the brief checks FAIL.

- [ ] **Step 3: Generate the brief**

After `fold_registry`, when a writer tier is configured, write
`.claude/spar-fix-brief.md`: one section per finding that is `[MECHANICAL]`, has a
`- file:` line, and whose fingerprint was not raised in the previous round. Each
section carries the finding id, the location, the problem text as the verified
basis, the suggestion as the fix direction, and the recommended tier. Findings
that fail any of those tests are listed under a heading saying they stay with the
session model and why.

- [ ] **Step 4: Point the author at it, without overstating**

In `fight.md` and the Codex skill's loop protocol, extend the `[MECHANICAL]` step:
when `.claude/spar-fix-brief.md` exists, the author may dispatch a fresh
cheaper-tier subagent per section and must re-read the result before responding —
the response file is still the author's statement, and the next round re-reviews
the fix regardless. State plainly that the hook cannot dispatch anything itself.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/test_stop_hook.sh`
Expected: `PASS=<n> FAIL=0`.

- [ ] **Step 6: Prove the exclusions hold**

Mutate the generator to include `[DESIGN]` findings and confirm that check fails;
mutate it to ignore the previous round and confirm the escalation check fails.

- [ ] **Step 7: Record the decision and commit**

Add to `docs/design-decisions.md` under Phase 7 what was built and what was
deliberately not: the hook recommends and briefs, the author dispatches, and no
configuration can move judgment. Then:

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add -A
git commit -m "feat(economics): a self-contained fix brief with a writer-tier recommendation"
```

## Non-goals

- Switching the session model. The plugin cannot, and the docs must not imply it can.
- Per-round lens rotation and the cross-family sweep — refinements to Phase 3's single-agent mode, out of scope until dogfooding shows a need.
- Any change to who declares convergence, who may write the convergence marker, or how the judge and gate work.

## Verification this plan cannot do

Whether a cheaper writer tier actually produces fixes that survive the next
round. Only dogfooding answers that, and the loop is the instrument: if delegated
fixes start causing the following round's findings, the escalation rule in Task 3
is what should catch it — and if it does not, the tier is wrong or the rule is.

`stop-hook.sh` is shared by both seats, so before the release that carries Tasks 2
and 3, run a live `/spar:fight` in Claude Code and a live `spar-fight` in Codex,
per the release gate.
