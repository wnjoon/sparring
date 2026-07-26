# Phase 6 — Codex Adapter, Remaining Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the Codex-hosted seat — get the unverified owner gate independently reviewed, then ship the adapter's registration, installer, skills, and liveness marker.

**Architecture:** Unchanged from the spec. Codex registers the *same two scripts* the Claude adapter registers (`stop-fight.sh` on `Stop`, `session-start.sh` on `SessionStart`) via a `hooks.json`, and gets its command surface as Codex skills. The three engine changes the Codex seat needs are already in the tree.

**Tech Stack:** POSIX-ish bash (plugin scripts + hooks), Codex CLI 0.144.1 hooks and skills, pure-bash test scripts under `tests/`.

**Source spec:** `docs/superpowers/specs/2026-07-25-phase6-codex-adapter-design.md`. Evidence for the enforcement premise: `docs/superpowers/notes/codex-hooks-spike.md`.

**Predecessor plan:** `docs/superpowers/plans/2026-07-25-phase6-codex-adapter.md` — its Tasks 1 and 2 converged and shipped (`c3d7dbd`, `60715b5`, `f39df76`); its Task 3 shipped at the **round cap** (`41009b7`) with the final fix unreviewed, which is why Task 1 below exists. Its Tasks 4-5 are carried here verbatim as Tasks 2-3.

---

## Already landed (do NOT redo)

- **Self-locating plugin root** — both hooks derive `PLUGIN_ROOT` from `${BASH_SOURCE[0]}`, with `CLAUDE_PLUGIN_ROOT` still winning when set.
- **`author` state field** — the final sweep and its CLI guard resolve from it (absent → `claude`), and the same-model notice keys off the pairing. `spar-report.sh` labels the pairing from both seats.
- **Owner-session gating** — present but **not independently verified**; see Task 1.

## Global Constraints

- **Claude-side behavior must not change.** Every engine change is gated on a state field absent from existing runs. All 19 suites must stay green after every task.
- **Fail-open stays.** A broken or missing hook must never trap a session.
- **Never claim unobserved enforcement.** If the hook cannot be confirmed live, the skill says so plainly rather than implying the loop is enforced (spec §6).
- **No risky-path change.** `.codex/hooks.json` is already covered by `spar-classify-change.sh`; measured, not assumed (spec §2.1d). Do not "fix" it.
- **Test harness detail:** `tests/test_stop_hook.sh`'s `chk` uses `grep -qF "$2"` **without** `--`, so no expectation there may start with `-`. It stubs `codex`/`claude` on `PATH` via `STUB_BIN`; tests needing a CLI absent use `SYS_PATH`, and the jq-absent cases build their own PATH.
- **No version bump.** `plugin.json` stays at `0.6.0`.

---

### Task 1: Independently verify the owner gate's ordering contract

`41009b7` landed the owner gate at the round cap, so its final shape — the gate sitting between the field validations and the `active != true` teardown — was never re-reviewed. Nothing suggests it is wrong (287 checks pass, both directions are pinned), but "the author says so" is not the standard this repo holds itself to, and the ordering took five rounds precisely because it is easy to get backwards.

This task adds the coverage that would have caught the whole class in one go, and puts the gate in front of a reviewer.

**Files:**
- Test: `tests/test_stop_hook.sh` (one consolidated case; no production change expected)

**Interfaces:**
- Consumes: the landed gate in `plugins/spar/hooks/stop-hook.sh` (fields → validations → gate → teardown).
- Produces: no new interface. If the review finds the ordering wrong, the fix belongs here too.

- [x] **Step 1: Write the consolidated contract test**

The existing cases check each rule separately, which is how the contradictory instruction survived three rounds. Append one case that walks a single foreign session through every state the gate must distinguish, before the final PASS/FAIL lines:

```bash
# ── the gate's full ordering contract, in one place ──
# fields → validations → gate → teardown. Each row below fails if the gate moves
# in one direction, and the pair together pins it from both sides.
owner_state() { # $1=extra sed expression applied to the state file
  fresh_dir; write_state task 0; mkdir -p reviews; add_owner sess-aaa
  [ -n "${1:-}" ] && { sed -i '' "$1" .claude/spar.local.md 2>/dev/null \
    || sed -i "$1" .claude/spar.local.md; }
  return 0
}

# 1. healthy + foreign → untouched (gate is before the teardown)
owner_state
OUT=$(payload sess-zzz | bash "$HOOK")
chk "contract: healthy+foreign → approve" '"decision":"approve"' "$OUT"
chk "contract: healthy+foreign → state kept" "present" \
  "$([ -f .claude/spar.local.md ] && echo present || echo absent)"

# 2. inactive + foreign → untouched (the teardown is a mutation; strangers skip it)
owner_state 's/^active: true/active: false/'
payload sess-zzz | bash "$HOOK" >/dev/null
chk "contract: inactive+foreign → state kept" "present" \
  "$([ -f .claude/spar.local.md ] && echo present || echo absent)"
chk "contract: inactive+foreign → no outcome" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-outcome.md ] && echo present || echo absent)"

# 3. corrupt + foreign → HANDLED (validations run first; a file we cannot parse
#    cannot be trusted to name its owner, and must not sit inert)
owner_state 's/^review_id: .*/review_id: ..\/..\/evil/'
payload sess-zzz | bash "$HOOK" >/dev/null
chk "contract: corrupt+foreign → cleaned up" "gone" \
  "$([ -f .claude/spar.local.md ] && echo present || echo gone)"

# 4. healthy + owner → proceeds normally
owner_state
OUT=$(payload sess-aaa | bash "$HOOK")
chk "contract: healthy+owner → round dispatched" "spar-run-reviewer.sh" "$OUT"
```

- [x] **Step 2: Run it**

```bash
bash tests/test_stop_hook.sh
```
Expected: `FAIL=0` — the contract already holds; this case documents it as one unit.

- [x] **Step 3: Prove each row is load-bearing**

Move the gate in a scratch copy and confirm the rows disagree, so the case is a real guard rather than a restatement:

```bash
SC=$(mktemp -d); cp -R plugins tests "$SC"/
# gate below the teardown → rows 2 must fail, row 3 must still pass
python3 - "$SC" <<'PY'
import sys
p=f"{sys.argv[1]}/plugins/spar/hooks/stop-hook.sh"
s=open(p).read()
act='[ "$ACTIVE" = "true" ] || { record_outcome cap; cleanup; approve; }\n'
gs=s.index("# Anything that is not a verified match"); ge=s.index(act)
gate=s[gs:ge].rstrip("\n")+"\n"
open(p,"w").write((s[:gs]+s[ge:]).replace(act, act+"\n"+gate, 1))
PY
(cd "$SC" && bash tests/test_stop_hook.sh 2>&1 | grep -cE '^FAIL')
rm -rf "$SC"
```
Expected: a non-zero count, and the failures name the `inactive+foreign` rows.

- [x] **Step 4: Run the whole suite**

```bash
for t in tests/test_*.sh; do printf '%-34s ' "$t"; bash "$t" >/dev/null 2>&1 && echo OK || echo FAILED; done
```
Expected: every line `OK`.

- [x] **Step 5: Commit**

```bash
git add tests/test_stop_hook.sh
git commit -m "test: pin the owner gate's full ordering contract in one case"
```

---
### Task 2: The Codex adapter — hooks.json and installer

**Files:**
- Create: `adapters/codex/hooks.json.template`
- Create: `adapters/codex/install.sh`
- Test: `tests/test_codex_adapter.sh`

**Interfaces:**
- Consumes: the two registered scripts (`hooks/stop-fight.sh`, `hooks/session-start.sh`) and `PLUGIN_ROOT` self-location from Task 1.
- Produces: `install.sh [--scope user|project] [--target <hooks.json>]`, defaulting to user scope (`~/.codex/hooks.json`). Idempotent: a second run with the same plugin path leaves the file byte-identical, so Codex's hook trust is not reset. Exit `0` installed or already current; `2` usage; `3` unsafe path or I/O failure.

- [x] **Step 1: Write the failing test**

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

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_codex_adapter.sh`
Expected: everything fails — `adapters/codex/install.sh` does not exist.

- [x] **Step 3: Write the template and installer**

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

- [x] **Step 4: Run the test to verify it passes**

```bash
bash tests/test_codex_adapter.sh
```
Expected: `PASS=… FAIL=0`.

- [x] **Step 5: Run the whole suite**

```bash
for t in tests/test_*.sh; do printf '%-34s ' "$t"; bash "$t" >/dev/null 2>&1 && echo OK || echo FAILED; done
```
Expected: every line `OK` (20 suites now).

- [x] **Step 6: Commit**

```bash
git add adapters/codex/hooks.json.template adapters/codex/install.sh tests/test_codex_adapter.sh
git commit -m "feat: codex adapter — register both hooks via an idempotent installer"
```

---

---

### Task 3: Codex skills, the liveness marker, and docs

The author seat needs its command surface as Codex skills, and activation must refuse to start a loop it cannot confirm is enforced. Liveness cannot be checked statically — hook trust is a per-session choice and no CLI reports hook state — so the `SessionStart` hook leaves a marker keyed by `session_id`, and activation looks for it.

**Files:**
- Modify: `plugins/spar/hooks/session-start.sh` (write the liveness marker)
- Create: `adapters/codex/skills/spar-fight/SKILL.md`, `spar-ready/SKILL.md`, `spar-cancel/SKILL.md`, `spar-report/SKILL.md`
- Modify: `adapters/codex/install.sh` (place the skills)
- Modify: `tests/test_session_start.sh`, `tests/test_codex_adapter.sh`
- Modify: `README.md` (seat table: Codex column becomes real), `docs/design-decisions.md` (§Phase 6 → implemented)

**Already done in the predecessor plan's Task 2** (the sweep's family resolution created the drift, so it
was corrected there rather than left for this pass): `policy.md` §Protocol 8 and
`README.md`'s feature bullet no longer call the sweep a *Claude* instance, and
`spar-report.sh` now derives the pairing label from both seats instead of assuming
a claude author — otherwise a codex↔codex run would have been reported as
cross-model. `tests/test_spar_report.sh` covers all four pairings.

**Interfaces:**
- Consumes: `install.sh` (Task 2), the `author` and `owner_session` fields (carried over).
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

---

## Pre-verified (2026-07-26, before hand-off)

Task 1's consolidated case was appended to a scratch copy exactly as written:
`tests/test_stop_hook.sh` reports `PASS=293 FAIL=0` against the real tree, and with
the gate moved back below the teardown it reports `PASS=289 FAIL=4` with the two
`contract: inactive+foreign` rows among the failures — so the case is a real guard,
and the `corrupt+foreign` row correctly stays green in that configuration, which is
what distinguishes the two rules. Tasks 2-3 are carried over from the predecessor
plan and were pre-verified there only as far as their code blocks parsing; their
substance is unexecuted.

## Non-goals

- A git pre-commit hook (spec §1); renaming `.claude/` state paths (spec §5); risky-path changes (spec §2.1d).
- Codex-Codex same-family sparring — falls out of the `author` field but is not designed or tested here.
- Version bump, release, or plugin reinstall.

## Verification this plan cannot do

Four things need a real Codex session with model credentials and are a release gate, not tests (spec §7):

1. The **trust path** — both spikes used `--dangerously-bypass-hook-trust`.
2. **Hook scope** — the spec's spike fired a project-scope hook; the cross-review could only make user scope fire. Settle by measurement, prefer user scope.
3. **`SessionStart` ordering** — whether it fires before the skill's first action. If not, the liveness marker cannot gate activation and the spec §6 fallback applies.
4. **End-to-end**: a planted-bug task authored by Codex, reviewed by `claude -p`, going FINDINGS → fix → re-review → CONVERGED.

Task 3 must not claim Phase 6 is done in the docs until item 4 has been run once.
