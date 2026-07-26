# Phase 6 live-verification harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Phase 6's release gate from four vague unknowns into one repeatable command that sets up an isolated Codex session, tells the human exactly what to do, and then judges whatever it can judge on its own.

**Architecture:** One script, `adapters/codex/verify-live.sh`, with three subcommands. `setup` builds a throwaway `CODEX_HOME` plus a scratch git repository holding a planted bug, installs sparring's hooks and skills *into that isolation*, and prints a numbered checklist. The human then runs Codex there by hand — nothing else can, because accepting a hook-trust prompt is interactive. `check` reads the durable artifacts the run leaves behind and prints a per-item verdict, saying plainly which items it cannot see. `clean` removes the workspace.

**Tech Stack:** Bash (POSIX-ish, same style as the rest of `adapters/codex/`), git, the existing `adapters/codex/install.sh`. Tests are pure bash in `tests/`, hermetic, and must not require the `codex` CLI.

## Global Constraints

- The developer's real `CODEX_HOME` must never be written to. The script refuses if the resolved isolation directory is, or is inside, `${CODEX_HOME:-$HOME/.codex}`.
- Hooks fail open; the harness must never leave a state that traps a real session.
- No test may require `codex` or `claude` on PATH. Stub them the way `tests/test_stop_hook.sh` does.
- The harness reports what it verified and what it could not. It never prints a pass for something only the human observed.
- Hook trust is durable and therefore checkable. Accepting a trust prompt writes `[hooks.state."<hooks.json path>:<event>:<group>:<hook>"]` with a `trusted_hash` into `$CODEX_HOME/config.toml`; a home whose hooks were never trusted has no such entry (measured against Codex 0.144.1). Item 1 is read from there, not from the human.
- Every file the harness creates lives under one workspace directory, and `clean` removes exactly that.
- The four items under verification are fixed and are referred to by these numbers throughout: (1) hook trust path, (2) user-vs-project hook scope, (3) `SessionStart` ordering relative to a skill's first action, (4) a planted-bug run reaching CONVERGED.

---

### Task 1: `setup` — isolation, refusals, and the checklist

**Files:**
- Create: `adapters/codex/verify-live.sh`
- Test: `tests/test_verify_live.sh`

**Interfaces:**
- Consumes: `adapters/codex/install.sh` (`--scope`, `--target`), `plugins/spar/hooks/session-start.sh`.
- Produces: `verify-live.sh setup [--dir <path>]` → creates the workspace and exits 0; `verify-live.sh` with no subcommand → usage, exit 2. Workspace layout that Task 2 depends on:
  - `<dir>/.spar-live-workspace` — marker file, one line: `spar-live-verify`
  - `<dir>/home/` — the isolated `CODEX_HOME`
  - `<dir>/repo/` — scratch git repository, one commit, containing `sum_to.py` with the planted bug and `TASK.md`
  - `<dir>/checklist.md` — the printed checklist, also saved

- [ ] **Step 1: Write the failing test**

Create `tests/test_verify_live.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$ROOT/adapters/codex/verify-live.sh"
chk() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent() { if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }
fresh() { d=$(mktemp -d); cd "$d" || exit 1; cd "$(pwd -P)" || exit 1
  export HOME="$PWD/.testhome" CODEX_HOME="$PWD/.testcodex"; }

# 1. no subcommand → usage, exit 2
fresh
OUT=$(bash "$V" 2>&1); RC=$?
chk "no subcommand → exit 2" "2" "$RC"
chk "no subcommand → prints usage" "usage:" "$OUT"

# 2. setup builds the workspace
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
chk "setup → workspace marker" "spar-live-verify" "$(cat ./ws/.spar-live-workspace 2>/dev/null)"
chk "setup → isolated home has hooks.json" "stop-fight.sh" "$(cat ./ws/home/hooks.json 2>/dev/null)"
chk "setup → all four skills installed" "4" \
  "$(ls ./ws/home/skills 2>/dev/null | wc -l | tr -d ' ')"
chk "setup → scratch repo is a git repo" "true" \
  "$(git -C ./ws/repo rev-parse --is-inside-work-tree 2>/dev/null)"
chk "setup → planted bug present" "range(1, n)" "$(cat ./ws/repo/sum_to.py 2>/dev/null)"
chk "setup → task description present" "sum_to" "$(cat ./ws/repo/TASK.md 2>/dev/null)"
chk "setup → checklist saved" "trust" "$(cat ./ws/checklist.md 2>/dev/null)"

# 3. the real CODEX_HOME is never a target
fresh
OUT=$(CODEX_HOME="$PWD/.testcodex" bash "$V" setup --dir "$PWD/.testcodex/ws" 2>&1); RC=$?
chk "target inside the real CODEX_HOME → exit 3" "3" "$RC"
chk "target inside the real CODEX_HOME → says so" "refusing" "$OUT"
chk_absent "target inside the real CODEX_HOME → nothing written" "ws" \
  "$(ls "$PWD/.testcodex" 2>/dev/null)"

# 4. re-running is safe: same marker, no duplication
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf 'stale\n' > ./ws/repo/leftover.txt
bash "$V" setup --dir ./ws >/dev/null 2>&1; RC=$?
chk "re-run → exit 0" "0" "$RC"
chk "re-run → stale file gone" "absent" \
  "$([ -e ./ws/repo/leftover.txt ] && echo present || echo absent)"
chk "re-run → workspace still valid" "spar-live-verify" "$(cat ./ws/.spar-live-workspace 2>/dev/null)"

# 5. a directory that is not ours is refused rather than wiped
fresh
mkdir -p ./notours && printf 'precious\n' > ./notours/keep.txt
OUT=$(bash "$V" setup --dir ./notours 2>&1); RC=$?
chk "non-workspace dir → exit 3" "3" "$RC"
chk "non-workspace dir → file untouched" "precious" "$(cat ./notours/keep.txt)"

# 6. the checklist names all four items and does not claim to automate them
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
CL="$(cat ./ws/checklist.md)"
for item in "trust" "scope" "SessionStart" "CONVERGED"; do
  chk "checklist covers $item" "$item" "$CL"
done
chk "checklist tells the human to run codex themselves" "codex" "$CL"
chk "checklist prints the isolated home to use" "CODEX_HOME=" "$CL"

# 7. clean removes exactly the workspace
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
bash "$V" clean --dir ./ws >/dev/null 2>&1
chk "clean → workspace gone" "absent" "$([ -e ./ws ] && echo present || echo absent)"
OUT=$(bash "$V" clean --dir ./notours 2>&1); RC=$?
chk "clean refuses a directory that is not ours" "3" "$RC"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_verify_live.sh`
Expected: every check FAILs (the script does not exist yet).

- [ ] **Step 3: Write `adapters/codex/verify-live.sh` — setup and clean**

The script begins with a self-locating root and the refusals, then builds the workspace:

```bash
#!/usr/bin/env bash
# Phase 6 release gate: set up an isolated Codex session a human can drive, then
# judge what can be judged from the artifacts it leaves. Accepting a hook-trust
# prompt is interactive, so this harness deliberately stops short of pretending
# to automate it.
# Usage: verify-live.sh setup|check|clean [--dir <path>]
# Exit: 0 ok; 2 usage; 3 unsafe path or I/O failure.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
MARKER_NAME=".spar-live-workspace"
MARKER_TEXT="spar-live-verify"

usage() { echo "usage: verify-live.sh setup|check|clean [--dir <path>]" >&2; exit 2; }

cmd="${1-}"; shift 2>/dev/null || true
case "$cmd" in setup|check|clean) ;; *) usage ;; esac

dir="./.spar-live"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="${2-}"; [ -n "$dir" ] || usage; shift 2 || usage ;;
    *) usage ;;
  esac
done

# The whole point is isolation. Resolve both sides and refuse if the workspace is
# the real Codex home or lives inside it — a harness that can clobber the
# developer's actual configuration is worse than no harness.
real_home="${CODEX_HOME:-$HOME/.codex}"
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$PWD/${1#./}" ;; esac; }
want="$(abs "$dir")"; real="$(abs "$real_home")"
case "$want/" in
  "$real"/*|"$real"/) echo "error: refusing to use $want — it is inside the real CODEX_HOME ($real)" >&2; exit 3 ;;
esac

is_ours() { [ -f "$1/$MARKER_NAME" ] && grep -qxF "$MARKER_TEXT" "$1/$MARKER_NAME" 2>/dev/null; }
```

`clean` refuses anything without the marker, then removes the directory:

```bash
if [ "$cmd" = clean ]; then
  [ -e "$want" ] || { echo "nothing to clean at $want"; exit 0; }
  is_ours "$want" || { echo "error: $want is not a harness workspace; refusing to remove it" >&2; exit 3; }
  rm -rf "$want" && echo "removed $want"
  exit 0
fi
```

`setup` refuses a non-empty directory that is not already a workspace, then
rebuilds from scratch so a re-run is deterministic:

```bash
if [ "$cmd" = setup ]; then
  if [ -e "$want" ] && ! is_ours "$want"; then
    echo "error: $want already exists and is not a harness workspace; refusing to overwrite it" >&2
    exit 3
  fi
  rm -rf "$want" || exit 3
  mkdir -p "$want/home" "$want/repo" || exit 3
  printf '%s\n' "$MARKER_TEXT" > "$want/$MARKER_NAME" || exit 3

  # Scratch repository with a planted bug. Off-by-one, small enough that a review
  # cannot miss it and a fix cannot be mistaken for a rewrite.
  cat > "$want/repo/sum_to.py" <<'PY'
def sum_to(n):
    """Return the sum of every integer from 1 to n inclusive."""
    total = 0
    for i in range(1, n):
        total += i
    return total
PY
  cat > "$want/repo/TASK.md" <<'TASK'
Fix `sum_to` so it returns the sum of every integer from 1 to n INCLUSIVE, and
add a test that would fail against the current implementation.
TASK
  git -C "$want/repo" init -q
  git -C "$want/repo" add -A
  git -C "$want/repo" -c user.email=harness@local -c user.name=harness \
    commit -qm "planted: sum_to is off by one"

  CODEX_HOME="$want/home" HOME="$want/home" \
    bash "$REPO_ROOT/adapters/codex/install.sh" --scope user >/dev/null || exit 3
```

- [ ] **Step 4: Write the checklist**

Still inside the `setup` branch, generate `checklist.md` and print it. Each item
names what to do and what to write down, and says which ones the harness can
confirm later on its own:

```bash
  cat > "$want/checklist.md" <<CHECK
# Phase 6 live verification — your part

Everything below needs a real interactive Codex session. Run it from:

    cd $want/repo
    CODEX_HOME=$want/home codex

Nothing here touches your real Codex configuration.

1. TRUST PATH. On the first turn Codex should ask you to trust sparring's hooks.
   Accept. Write down: were you asked at all, and what did the prompt say?
   (\`check\` can confirm the hooks then RAN, but not what you saw.)

2. HOOK SCOPE. The hooks above are installed at USER scope, inside the isolated
   home. Confirm they fire for a session started in $want/repo — a directory
   with no .codex/ of its own. Write down: did they?

3. SESSIONSTART ORDERING. Immediately, before anything else, run the spar-fight
   skill. If SessionStart fired first, activation succeeds; if it did not, the
   skill refuses with "sparring's SessionStart hook left no liveness marker".
   Write down which happened. This is the one that decides whether the liveness
   marker can gate activation at all.

4. END TO END. Give spar-fight the task in TASK.md and let the loop run to a
   verdict. Do not fix anything by hand. Expect FINDINGS on the off-by-one, then
   a fix, then a blind re-review, then CONVERGED.

When the session is over:

    bash $REPO_ROOT/adapters/codex/verify-live.sh check --dir $want

CHECK
  cat "$want/checklist.md"
  exit 0
fi
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/test_verify_live.sh`
Expected: `PASS=<n> FAIL=0`.

- [ ] **Step 6: Prove the refusals actually refuse**

Revert each guard in a scratch copy and confirm the matching checks fail:

```bash
SC=$(mktemp -d); cp -R . "$SC/repo"; cd "$SC/repo"
cp adapters/codex/verify-live.sh /tmp/vl.bak
python3 - <<'PY'
p='adapters/codex/verify-live.sh'; s=open(p).read()
s=s.replace('  "$real"/*|"$real"/) echo', '  __never__) echo')
open(p,'w').write(s)
PY
bash tests/test_verify_live.sh 2>&1 | grep '^FAIL:'
cp /tmp/vl.bak adapters/codex/verify-live.sh
cd /; rm -rf "$SC"
```

Expected: the two "inside the real CODEX_HOME" checks fail. Repeat for the
`is_ours` guard in `setup` and expect the "non-workspace dir" checks to fail.

- [ ] **Step 7: Run the whole suite and commit**

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add adapters/codex/verify-live.sh tests/test_verify_live.sh
git commit -m "feat(codex): isolated live-verification workspace for the Phase 6 gate"
```

---

### Task 2: `check` — verdicts from the artifacts, and honest gaps

**Files:**
- Modify: `adapters/codex/verify-live.sh`
- Modify: `tests/test_verify_live.sh`
- Modify: `README.md`, `docs/design-decisions.md`, `docs/superpowers/plans/2026-07-26-phase6-remaining.md`

**Interfaces:**
- Consumes: the workspace layout Task 1 produces.
- Produces: `verify-live.sh check --dir <path>` → prints one block per item with a verdict line beginning `ITEM <n>:` and one of `CONFIRMED`, `FAILED`, or `NEEDS YOUR ANSWER`, each followed by the evidence used. Exits 0 when nothing FAILED, 1 when anything did.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_verify_live.sh`, before the final tally. Note the fixtures
are written with `printf` one-liners so no line inside this task body begins with
a heading marker:

```bash
# 8. check before the human has run anything: nothing invented
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "check before a run → item 1 unresolved" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk "check before a run → item 3 unresolved" "ITEM 3: NEEDS YOUR ANSWER" "$OUT"
chk "check before a run → item 4 unresolved" "ITEM 4: NEEDS YOUR ANSWER" "$OUT"
chk "check before a run → says the marker is absent" "no liveness marker" "$OUT"
chk_absent "check before a run → never claims a pass" "ITEM 4: CONFIRMED" "$OUT"

# 8b. trust is read from the isolated config.toml, not from the human
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf '[hooks.state."%s/ws/home/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:deadbeef"\n' "$PWD" \
  > ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "trusted_hash present → item 1 confirmed" "ITEM 1: CONFIRMED" "$OUT"
chk "trusted but no marker → item 2 failed, not unknown" "ITEM 2: FAILED" "$OUT"

# 8c. a hook that ran without a trust record is a failure, not a pass
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
GD=\$(git -C ./ws/repo rev-parse --git-dir)
printf 'sess-untrusted\n' > "./ws/repo/\$GD/spar-hook-live"
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "marker without trust record → item 1 failed" "ITEM 1: FAILED" "$OUT"
chk "marker without trust record → nonzero exit" "1" "$RC"

# 9. a marker naming a session, and a converged report → items 3 and 4 confirmed
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
GD=\$(git -C ./ws/repo rev-parse --git-dir)
printf 'sess-live-9\n' > "./ws/repo/\$GD/spar-hook-live"
mkdir -p ./ws/repo/reviews ./ws/repo/.claude
printf -- '---\nactive: false\nauthor: codex\nreviewer: claude\nowner_session: sess-live-9\n---\n' > ./ws/repo/.claude/spar.local.md
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] off by one\n' > ./ws/repo/reviews/spar-20260726-120000-aaaaaa-r1.md
printf 'STATUS: CONVERGED\n' > ./ws/repo/reviews/spar-20260726-120000-aaaaaa-r2.md
printf -- '- outcome: converged\n- rounds: 2\n' > ./ws/repo/reviews/spar-20260726-120000-aaaaaa-report.md
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "marker present → item 3 confirmed" "ITEM 3: CONFIRMED" "$OUT"
chk "item 3 evidence names the session" "sess-live-9" "$OUT"
chk "converged report → item 4 confirmed" "ITEM 4: CONFIRMED" "$OUT"
chk "item 4 evidence names the outcome" "outcome: converged" "$OUT"
chk "trust plus marker → item 2 confirmed" "ITEM 2: CONFIRMED" "$OUT"

# 10. a marker naming a DIFFERENT session than the loop owned → failure, not a pass
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
GD=\$(git -C ./ws/repo rev-parse --git-dir)
printf 'sess-A\n' > "./ws/repo/\$GD/spar-hook-live"
mkdir -p ./ws/repo/.claude
printf -- '---\nactive: false\nowner_session: sess-B\n---\n' > ./ws/repo/.claude/spar.local.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "mismatched session → item 3 failed" "ITEM 3: FAILED" "$OUT"
chk "mismatched session → nonzero exit" "1" "$RC"

# 11. a capped run is not a converged run
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
mkdir -p ./ws/repo/reviews
printf -- '- outcome: cap\n- rounds: 5\n' > ./ws/repo/reviews/spar-20260726-120000-bbbbbb-report.md
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "capped run → item 4 failed" "ITEM 4: FAILED" "$OUT"
chk "capped run → evidence names the cap" "outcome: cap" "$OUT"

# 12. check refuses a directory that is not ours
fresh
mkdir -p ./notours
OUT=$(bash "$V" check --dir ./notours 2>&1); RC=$?
chk "check on a foreign dir → exit 3" "3" "$RC"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_verify_live.sh`
Expected: checks 8–12 FAIL (`check` is not implemented); checks 1–7 still pass.

- [ ] **Step 3: Implement `check`**

Add before the `setup` branch. Each item prints a verdict and the evidence
behind it; items only the human saw are stated as such rather than guessed:

```bash
if [ "$cmd" = check ]; then
  is_ours "$want" || { echo "error: $want is not a harness workspace" >&2; exit 3; }
  repo="$want/repo"
  failed=0
  say() { printf 'ITEM %s: %s\n  %s\n\n' "$1" "$2" "$3"; }

  # Trust is durable: accepting the prompt writes a trusted_hash into the isolated
  # config.toml, keyed by the hooks.json path and the event. That is what tells
  # item 1 apart from item 2 — without it, a hook that never ran could not say
  # whether trust was refused or the registration simply did not fire here.
  cfg="$want/home/config.toml"
  trusted=0
  if [ -f "$cfg" ] \
    && grep -q "^\[hooks\.state\.\"$want/home/hooks\.json:" "$cfg" 2>/dev/null; then
    trusted=1
  fi
  gitdir="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)"
  marker="$repo/${gitdir:-.git}/spar-hook-live"
  seen=""; [ -f "$marker" ] && seen="$(head -1 "$marker")"

  if [ "$trusted" = 1 ]; then
    say 1 "CONFIRMED" "$cfg records a trusted_hash for the harness hooks.json — the prompt appeared and you accepted it"
  elif [ -n "$seen" ]; then
    say 1 "FAILED" "a liveness marker exists but $cfg records no trusted_hash — the hooks ran without the trust path this gate is meant to exercise"
    failed=1
  else
    say 1 "NEEDS YOUR ANSWER" "no trusted_hash in $cfg and no liveness marker — either no session ran, or you declined the prompt; which was it?"
  fi

  if [ -n "$seen" ]; then
    say 2 "CONFIRMED" "the user-scope registration fired for $repo, which has no .codex/ of its own — marker names '$seen'"
  elif [ "$trusted" = 1 ]; then
    say 2 "FAILED" "trust was granted but no liveness marker appeared under $repo — user scope did not fire for this directory"
    failed=1
  else
    say 2 "NEEDS YOUR ANSWER" "nothing ran, so scope was never exercised"
  fi

  # 3 is the one the artifacts can settle: the marker must name the session the
  # loop recorded as its owner.
  owner="$(sed -n 's/^owner_session: *//p' "$repo/.claude/spar.local.md" 2>/dev/null | head -1)"
  if [ -z "$seen" ]; then
    say 3 "NEEDS YOUR ANSWER" "no liveness marker, so ordering cannot be judged; did spar-fight refuse?"
  elif [ -n "$owner" ] && [ "$owner" != "$seen" ]; then
    say 3 "FAILED" "marker names '$seen' but the loop recorded owner_session '$owner'"
    failed=1
  else
    say 3 "CONFIRMED" "marker names '$seen'${owner:+, matching the loop's owner_session}; SessionStart fired before activation read it"
  fi

  # 4 is settled by the run report, which only a terminal path writes.
  rpt="$(ls "$repo"/reviews/spar-*-report.md 2>/dev/null | tail -1)"
  if [ -z "$rpt" ]; then
    say 4 "NEEDS YOUR ANSWER" "no run report under $repo/reviews — the loop never reached a terminal path"
  else
    out="$(sed -n 's/^- outcome: *//p' "$rpt" | head -1)"
    if [ "$out" = converged ]; then
      say 4 "CONFIRMED" "$(basename "$rpt") records outcome: converged"
    else
      say 4 "FAILED" "$(basename "$rpt") records outcome: $out, not converged"
      failed=1
    fi
  fi
  exit "$failed"
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_verify_live.sh`
Expected: `PASS=<n> FAIL=0`.

- [ ] **Step 5: Prove the verdicts are earned**

In a scratch copy, make `check` always print CONFIRMED for item 4 and confirm the
capped-run check fails; then make it ignore the owner mismatch and confirm the
mismatch check fails.

- [ ] **Step 6: Wire it into the documents that name the gate**

In `docs/superpowers/plans/2026-07-26-phase6-remaining.md`, under "Verification
this plan cannot do", add a line pointing at the harness and saying it does not
replace the human step. In `docs/design-decisions.md`, in the Phase 6 section,
add the same pointer next to the four unknowns. In `README.md`, leave the roadmap
status alone — the harness does not make Phase 6 done — and add one line under
Development naming the command.

- [ ] **Step 7: Run the whole suite and commit**

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add -A
git commit -m "feat(codex): verdicts from the live-verification artifacts"
```

## Non-goals

- Automating the trust prompt. It is interactive by design, and a harness that
  bypassed it would verify a path no real user takes. Reading the decision back
  out of `config.toml` afterwards is not the same thing and is fair game.
- Running Codex or Claude from the harness. Starting the session is the human's
  step; only the artifacts it leaves are the harness's.
- Marking Phase 6 done. That happens after a real run, not after this lands.

## Verification this plan cannot do

Whether the harness's own instructions are followable by someone who did not
write them. The first real run is the test of that, and any confusion it causes
should be fixed in `checklist.md` rather than explained away.
