# Hermetic Tests + CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the test suite pass on a machine with no reviewer CLI installed, then run all of it automatically on every push and pull request.

**Architecture:** `tests/test_stop_hook.sh` currently depends on the developer having `codex` (or `claude`) on `PATH`, because `stop-hook.sh` blocks with "the 'codex' CLI is not on PATH" before reaching any reviewed path. Task 1 gives that suite its own stub `codex`/`claude` on `PATH` so it is self-contained, and adds the missing coverage for the genuine absent-CLI branch. Task 2 adds a GitHub Actions workflow that runs every `tests/test_*.sh` on Linux and macOS. No plugin behavior changes in either task.

**Tech Stack:** pure-bash test scripts under `tests/`, GitHub Actions (`.github/workflows/`).

**Why this matters:** nothing automated has ever executed these suites. The sparring reviewer cannot — it runs read-only and `mktemp` is denied, so every convergence in this repo's history was a static review with the test result taken on the author's word. The suites are the only executable check the project has, and today they run solely when a human remembers to.

## Investigation already done (do not redo)

Measured on this machine, `jq` and `git` in `/usr/bin`, `codex`/`claude` in `~/.local/bin`:

- With `PATH=/usr/bin:/bin:/usr/sbin:/sbin` (both CLIs absent), 17 of 18 suites pass and `tests/test_stop_hook.sh` fails **175** checks. Its first failure is
  `{"decision":"block","reason":"ERROR: the 'codex' CLI is not on PATH. …"}` — the gate at `plugins/spar/hooks/stop-hook.sh:793-797`.
- Adding stub `codex`/`claude` (`#!/bin/sh` + `exit 0`) to a temp dir on `PATH` makes that suite pass **235/235** with the real CLIs absent. Verified.
- No existing test asserts the absent-CLI branch, so a global stub breaks nothing. Verified by grepping `tests/test_stop_hook.sh` for `not on PATH` / `PATH=`.
- The absent-CLI branch is directly testable: with `PATH=/usr/bin:/bin` the hook blocks with the ERROR message, records `reason: error-bypass`, and removes the state file. Verified by hand.
- One test already builds its own fake `claude` (`FAKEBIN`, the live-sweep test around `tests/test_stop_hook.sh:657-669`) and prepends it to `PATH`, so it keeps winning over any stub added earlier in the file.

---

## Global Constraints

- **No plugin behavior changes.** Both tasks touch tests and CI only. `plugins/` is not modified — if a suite fails on Linux, that is a finding to report, not a licence to change the hook in this plan.
- **Stubs must not weaken coverage.** The stub `codex`/`claude` exist so the hook's *reviewed* paths are reachable; the absent-CLI branch gets its own explicit test rather than being lost.
- **Tests must stay hermetic.** After Task 1, every suite must pass with `PATH` reduced to system directories. That is the acceptance check, not "passes on my laptop".
- **Do not require a reviewer CLI in CI.** The workflow must never install or invoke `codex`/`claude`; the suites are pure bash and must stay that way.
- **CI declares its dependencies.** The suites need `bash`, `git`, `jq`, and the standard POSIX tools. `jq` is preinstalled on GitHub's `ubuntu-latest` and `macos-latest` images; the workflow verifies its presence in a step rather than assuming it silently.
- **Test harness detail:** `tests/test_stop_hook.sh`'s `chk` calls `grep -qF "$2"` **without** `--`, so no expectation added there may start with `-`.
- **No version bump.** `plugin.json` stays at `0.6.0`; this is not a release.

---

### Task 1: Make `tests/test_stop_hook.sh` hermetic

Give the suite its own stub reviewer CLIs, and cover the absent-CLI branch it has been silently relying on.

**Files:**
- Modify: `tests/test_stop_hook.sh` (stub setup after the `CLAUDE_PLUGIN_ROOT` export near line 7; one new test block before the trailing PASS/FAIL lines)

**Interfaces:**
- Consumes: `HOOK`, `CLAUDE_PLUGIN_ROOT`, `chk`, `fresh_dir`, `write_state`, `run_hook` — all already defined in that file.
- Produces: `STUB_BIN` (a temp dir on `PATH` holding no-op `codex` and `claude`) and `SYS_PATH` (`/usr/bin:/bin`, a `PATH` with neither CLI, for the absent-CLI test). Later tasks do not depend on these.

- [x] **Step 1: Write the failing test**

Append to `tests/test_stop_hook.sh`, immediately before the final `echo; echo "PASS=$PASS FAIL=$FAIL"` and `exit "$FAIL"` lines:

```bash
# ── CLI presence: the hook refuses to start a round without the reviewer CLI ──
# This branch (stop-hook.sh:793-797) had no coverage — the suite reached the
# reviewed paths only because the developer happened to have codex installed.
# SYS_PATH deliberately excludes STUB_BIN so the CLI really is missing. jq may
# also be absent there, which is fine: block() falls back to a printf JSON that
# still carries the first line of the reason.
fresh_dir; write_state task 0; mkdir -p reviews
OUT=$(PATH="$SYS_PATH" bash "$HOOK" <<< '{}')
chk "reviewer CLI absent → block" '"decision":"block"' "$OUT"
chk "reviewer CLI absent → says which CLI and why" "not on PATH" "$OUT"
chk "reviewer CLI absent → honest error-bypass outcome" "reason: error-bypass" \
  "$(cat reviews/spar-20260721-120000-abc123-outcome.md 2>/dev/null)"
chk "reviewer CLI absent → loop state cleaned up" "gone" \
  "$([ -f .claude/spar.local.md ] && echo present || echo gone)"
chk "reviewer CLI absent → no report (error-bypass never reports)" "absent" \
  "$([ -f reviews/spar-20260721-120000-abc123-report.md ] && echo present || echo absent)"

# With the stubs on PATH the same state starts a round instead — this is what
# every other test in this file has been relying on, now made explicit.
fresh_dir; write_state task 0; mkdir -p reviews
OUT=$(run_hook)
chk "reviewer CLI present → round 1 dispatched" "spar-run-reviewer.sh" "$OUT"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_stop_hook.sh`
Expected: the five `reviewer CLI absent` checks FAIL with `SYS_PATH: unbound variable` (or an empty `PATH` behaviour) because `SYS_PATH` and `STUB_BIN` do not exist yet. The final check may already pass.

- [x] **Step 3: Add the stub CLIs**

In `tests/test_stop_hook.sh`, insert this immediately after the
`export CLAUDE_PLUGIN_ROOT="$ROOT/plugins/spar"` line:

```bash
# The hook refuses to dispatch a round when the reviewer CLI is missing
# (stop-hook.sh:793-797), so every reviewed path below needs `codex` and
# `claude` to merely exist. Provide no-op stubs and put them first on PATH: the
# suite must not depend on what the developer happens to have installed, and CI
# must never need a real reviewer CLI. Tests that drive a runner script build
# their own fake CLI and prepend it, so they still win over these.
STUB_BIN=$(mktemp -d)
for stub_cli in codex claude; do
  printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/$stub_cli"
  chmod +x "$STUB_BIN/$stub_cli"
done
# A PATH with system tools but neither reviewer CLI, for the absent-CLI test.
SYS_PATH="/usr/bin:/bin"
PATH="$STUB_BIN:$PATH"
export PATH
trap 'rm -rf "$STUB_BIN"' EXIT
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL=0`.

- [x] **Step 5: Verify the whole suite is hermetic**

This is the acceptance check for the task — it must pass with no reviewer CLI reachable:

```bash
for t in tests/test_*.sh; do
  printf '%-34s ' "$t"
  env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin bash "$t" >/dev/null 2>&1 \
    && echo OK || echo FAILED
done
```
Expected: every line `OK`. Before this task `tests/test_stop_hook.sh` printed `FAILED` here (175 failing checks).

Then confirm nothing regressed with the CLIs present:

```bash
for t in tests/test_*.sh; do printf '%-34s ' "$t"; bash "$t" >/dev/null 2>&1 && echo OK || echo FAILED; done
```
Expected: every line `OK`.

- [x] **Step 6: Commit**

```bash
git add tests/test_stop_hook.sh
git commit -m "test: make the stop-hook suite hermetic (stub reviewer CLIs + absent-CLI coverage)"
```

---

### Task 2: Run every suite in CI on Linux and macOS

**Files:**
- Create: `.github/workflows/tests.yml`
- Test: `tests/test_ci_workflow.sh` (asserts the workflow stays wired to the suites)
- Modify: `README.md` (Development section — say where tests run)

**Interfaces:**
- Consumes: the hermetic suites from Task 1.
- Produces: a `tests` workflow running `bash tests/test_<name>.sh` for every suite on `ubuntu-latest` and `macos-latest`, plus `tests/test_ci_workflow.sh` guarding the wiring.

**Why both platforms:** the project is developed on macOS, and its scripts straddle BSD/GNU differences — `sed -i ''` vs `sed -i`, `date -u`, and awk dialects. A real example from this repo's history: an `awk -v` value containing newlines works under GNU awk but errors under macOS BWK awk ("newline in string"), which silently emptied a report section. A single-platform matrix would have missed the inverse case.

- [x] **Step 1: Write the failing test**

Create `tests/test_ci_workflow.sh`:

```bash
#!/usr/bin/env bash
# Guards the CI wiring: every tests/test_*.sh suite must actually be run by the
# workflow. A suite that exists but is never executed is worse than no CI.
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="$ROOT/.github/workflows/tests.yml"

chk() { # $1=desc $2=expected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$WF" ]; then
  echo "FAIL: workflow missing ($WF)"; echo; echo "PASS=0 FAIL=1"; exit 1
fi
WF_TEXT="$(cat "$WF")"

chk "runs on push" "push:" "$WF_TEXT"
chk "runs on pull requests" "pull_request:" "$WF_TEXT"
chk "runs on linux" "ubuntu-latest" "$WF_TEXT"
chk "runs on macos" "macos-latest" "$WF_TEXT"
chk "does not install a reviewer CLI" "no-reviewer-cli" "$WF_TEXT"

# Every suite must be reachable from the workflow's runner loop. The loop globs
# tests/test_*.sh, so assert the glob is there rather than listing each file.
chk "iterates every suite by glob" 'tests/test_*.sh' "$WF_TEXT"
chk "fails the job when a suite fails" "exit 1" "$WF_TEXT"

# The workflow must not silently swallow failures.
if printf '%s' "$WF_TEXT" | grep -q 'continue-on-error: *true'; then
  echo "FAIL: workflow tolerates failing suites"; FAIL=$((FAIL+1))
else
  echo "PASS: workflow does not tolerate failing suites"; PASS=$((PASS+1))
fi

# Sanity: the suites the workflow will pick up are all executable-by-bash files.
COUNT=$(ls "$ROOT"/tests/test_*.sh 2>/dev/null | wc -l | tr -d ' ')
chk "at least the suites known today are present" "1" \
  "$([ "$COUNT" -ge 19 ] && echo 1 || echo "only $COUNT")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_ci_workflow.sh`
Expected: `FAIL: workflow missing (.github/workflows/tests.yml)` and exit 1.

- [x] **Step 3: Write the workflow**

Create `.github/workflows/tests.yml`:

```yaml
name: tests

on:
  push:
    branches: ["**"]
  pull_request:

permissions:
  contents: read

jobs:
  suites:
    name: suites (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    steps:
      - uses: actions/checkout@v4

      # The suites are pure bash. They need git, jq and the standard POSIX
      # tools — and deliberately no-reviewer-cli: no codex, no claude. The hook
      # only checks that the CLI exists, and the stop-hook suite provides its
      # own stubs, so CI never installs or calls a model CLI.
      - name: Check prerequisites
        run: |
          set -eu
          for tool in bash git jq awk sed; do
            command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool"; exit 1; }
          done
          bash --version | head -1
          jq --version

      # The tests create their own repositories under mktemp, and some commit,
      # so git needs an identity on a fresh runner.
      - name: Configure git identity
        run: |
          git config --global user.email sparring@example.invalid
          git config --global user.name sparring-ci

      - name: Syntax-check every script
        run: |
          set -eu
          rc=0
          for f in plugins/spar/hooks/*.sh plugins/spar/commands/*.sh tests/test_*.sh; do
            bash -n "$f" || { echo "SYNTAX: $f"; rc=1; }
          done
          [ "$rc" -eq 0 ] || exit 1

      - name: Run every suite
        run: |
          set -u
          rc=0
          for t in tests/test_*.sh; do
            echo "::group::$t"
            if bash "$t"; then
              echo "OK   $t"
            else
              echo "FAIL $t"
              rc=1
            fi
            echo "::endgroup::"
          done
          [ "$rc" -eq 0 ] || exit 1
```

- [x] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_ci_workflow.sh`
Expected: `FAIL=0`.

- [x] **Step 5: Prove the workflow's own commands work locally**

The workflow body cannot be executed by GitHub from here, so run the two loops it uses, exactly as written, and confirm they behave:

```bash
rc=0
for f in plugins/spar/hooks/*.sh plugins/spar/commands/*.sh tests/test_*.sh; do
  bash -n "$f" || { echo "SYNTAX: $f"; rc=1; }
done
echo "syntax rc=$rc"

rc=0
for t in tests/test_*.sh; do bash "$t" >/dev/null 2>&1 && echo "OK   $t" || { echo "FAIL $t"; rc=1; }; done
echo "suites rc=$rc"
```
Expected: `syntax rc=0`, every suite `OK`, `suites rc=0`. If a suite fails only under the hermetic `PATH` from Task 1 Step 5, fix the suite — not the workflow.

- [x] **Step 6: Note it in the README**

In `README.md`'s Development section, after the `main` / `dev` branches bullet, add:

```markdown
- Tests are pure bash: `bash tests/test_<name>.sh`, or all of them with `for t in tests/test_*.sh; do bash "$t"; done`. CI ([.github/workflows/tests.yml](.github/workflows/tests.yml)) runs every suite on Linux and macOS for each push and pull request — no reviewer CLI required, since the suites stub it.
```

- [x] **Step 7: Run the whole suite**

```bash
for t in tests/test_*.sh; do printf '%-34s ' "$t"; bash "$t" >/dev/null 2>&1 && echo OK || echo FAILED; done
```
Expected: every line `OK` (19 suites now, including `test_ci_workflow.sh`).

- [x] **Step 8: Commit**

```bash
git add .github/workflows/tests.yml tests/test_ci_workflow.sh README.md
git commit -m "ci: run every bash suite on linux and macos for push and PR"
```

---

## Non-goals

- **`shellcheck` in CI** — worth doing, but it would surface a backlog of warnings across scripts written before it, so it needs its own pass with a decision on which rules to silence. Adding it here would bury this change's signal.
- **Running the reviewer or the loop itself in CI** — a model CLI in CI means credentials, cost, and non-determinism. The hook's *decisions* are what the suites check, and they check them offline.
- **Changing anything under `plugins/`** — if CI reveals a real Linux-vs-macOS defect, it is reported and fixed in its own change.
- **Branch protection / required checks** — a repository setting, not a file in this plan.
- **Version bump or release commit.**

## Self-Review notes

**Coverage of the goal:**
- Suite passes with no reviewer CLI → Task 1 Steps 3 and 5 (acceptance check runs every suite under a stripped `PATH`). ✅
- The absent-CLI branch no longer silently untested → Task 1 Step 1's five checks. ✅
- Every suite runs automatically → Task 2 Step 3's glob loop, guarded by `tests/test_ci_workflow.sh` so a new suite cannot be added without CI picking it up. ✅
- Both platforms → matrix with `fail-fast: false`, so a macOS-only failure still reports Linux's result. ✅
- Failures actually fail the job → `rc=1` plus the test that rejects `continue-on-error: true`. ✅

**Pre-verified (2026-07-25, before hand-off):** Task 1 was applied to a scratch
copy exactly as written — `tests/test_stop_hook.sh` reports `PASS=241 FAIL=0`
both with the real CLIs on `PATH` and under
`env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin` (before the change, the latter failed
175 checks). Task 2's `tests/test_ci_workflow.sh` was run against a scratch tree:
it fails with `workflow missing` when `.github/workflows/tests.yml` is absent and
reports `PASS=9 FAIL=0` once it exists. The workflow YAML parses (`ruby -ryaml`:
one job `suites`, matrix `[ubuntu-latest, macos-latest]`), and the syntax loop from
Task 2 Step 5 exits 0 over every script its three globs cover (35 files: 16 under
`plugins/spar/`, 19 suites). Prose-only steps (Task 2 Step 6) were
not executed.

**Risk the plan carries knowingly:** the workflow's YAML cannot be validated by GitHub from here. Task 2 Step 5 compensates by running the exact shell loops the workflow uses, so only the YAML wrapper is unverified; `tests/test_ci_workflow.sh` then pins the keys that matter (`push`, `pull_request`, both runners, the glob, the non-tolerance of failures). The first push to GitHub is the real check.

**Consistency:** `STUB_BIN` / `SYS_PATH` are introduced in Task 1 Step 3 and used in Task 1 Step 1's block — the step order is test-first, so the test is written before the variables exist, which is why Step 2 expects an unbound-variable failure rather than a clean assertion failure. `tests/test_ci_workflow.sh` expects at least 19 suites: the 18 present today plus itself.

**Marker used by the test:** the workflow contains the literal string `no-reviewer-cli` inside the prerequisites comment, and `tests/test_ci_workflow.sh` greps for it. That is deliberate — it pins the intent (CI never installs a model CLI) to something a future edit cannot quietly drop without turning a test red.
