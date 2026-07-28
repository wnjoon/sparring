# Loop Economy and Author Discipline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove five version-independent defects from the sparring engine and give the author, for the first time, guidance on *how* to fix rather than only *what* to fix.

**Architecture:** Every change lands in the existing single-file engine `plugins/spar/hooks/stop-hook.sh`, its prompt templates, and the three places that create loop state. Nothing changes who declares convergence, who may write the convergence marker, or how the judge and gate work. No file is split.

**Tech Stack:** POSIX-ish bash 3.2 (macOS default), awk, git. Tests are pure bash under `tests/`, driven with CLI stubs, and never invoke a real reviewer.

## Global Constraints

- The four invariants in `README.md` hold: single writer, reviewer-declares-convergence, deterministic enforcement with fail-open hooks, blind adjudication.
- Tests are pure bash in `tests/` and must never require a reviewer CLI on PATH.
- Both seats behave identically. A change that works only under Claude Code or only under Codex is a defect, not a saving.
- Every behavioural change needs a test that fails when the change is reverted. Perform the revert and record which checks failed; do not assert that a test would catch it.
- `stop-hook.sh` is a surface both seats share, so the release gate applies before the release that carries this work: one live `/spar:fight` in Claude Code and one live `spar-fight` in Codex.
- Do **not** touch the final sweep, the matcher trigger, or the every-round full re-read. Their justification rests on 29 runs of codex 0.144.1, the project now targets only the latest reviewer CLI, and that evidence must be rebuilt before any of them is changed.

---

### Task 1: One finding grammar

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh:313-343` (`parse_findings`), `:934-958` (`extract_finding`), `:1151-1179` (`parse_findings_verbose`), and the five `parse_findings` call sites at `:399`, `:513`, `:551`, `:565`, `:1032`
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `parse_findings_all` — one awk pass over a review file emitting, per finding, seven `\037`-separated fields in this order: `id`, `tag`, `loc`, `file`, `canon`, `problem`, `suggestion`. `loc` is the raw `- file:` value including any `:<line>` suffix; `file` is `loc` with that suffix stripped; `canon` is the title lowercased with every run of non-alphanumerics collapsed to one space and the ends trimmed. `parse_findings_verbose` becomes an alias for it. `parse_findings` becomes a projection printing `id`, `tag`, `file`, `canon` — still `\037`-separated, **not** tab-separated.

Three copies of this grammar exist today, and the title normalisation they each re-implement *is* the fingerprint definition. If one drifts, the same finding computed two ways stops matching, the rejection streak never accumulates, stalemate detection stops working, and nothing throws.

Unifying also fixes a live defect. `parse_findings` emits tab-separated fields and its callers read them with `IFS=$'\t'`. Bash treats tab as IFS whitespace, so a finding with no `- file:` line emits `id\ttag\t\tcanon` and the two adjacent tabs collapse into one: the title lands in the `file` variable and the title variable is empty. The fingerprint becomes `"some title | "` instead of `" | some title"`, and `build_matcher`'s file-overlap prefilter then compares titles against file names. Switching the projection to `\037` — a non-whitespace separator that preserves empty fields — is what makes the unification safe rather than a rename.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_stop_hook.sh`, before the `PASS=`/`FAIL=` summary:

```bash
# ── one finding grammar ─────────────────────────────────────────────────────
# A finding with no `- file:` line must still parse with its title in the title
# column. Tab-separated output collapses the empty file column and shifts the
# title left, which corrupts the fingerprint and makes the matcher's file
# prefilter compare a title against a file name.
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] some title here\n- problem: p\n- suggestion: s\n\n### F1-2 [MECHANICAL] located finding\n- file: a.py:10\n- problem: q\n- suggestion: t\n' > "$RF1"
printf -- '### F1-1: REJECTED — not a defect\n### F1-2: REJECTED — not a defect\n' > "$RP1"
run_hook >/dev/null
chk "a finding with no location keeps an empty file column" \
  "$(printf ' | some title here')" "$(cut -f1 .claude/spar-registry.tsv | head -1)"
chk "and the located finding is unaffected" \
  "$(printf 'a.py | located finding')" "$(cut -f1 .claude/spar-registry.tsv | sed -n 2p)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL: a finding with no location keeps an empty file column`, because today the registry's first column reads `some title here | `.

- [ ] **Step 3: Write the single parser**

Replace `parse_findings` (`:313-343`) with the shared implementation. Place it where `parse_findings` is today so the registry helpers below it keep reading top-to-bottom:

```bash
# ── finding grammar (ONE implementation) ────────────────────────────────────
# Every consumer of a reviewer finding reads it through here. The title
# normalisation below IS the fingerprint definition: two copies that drift make
# the same finding compute two different fingerprints, so the rejection streak
# never accumulates and stalemate detection silently stops working.
#
# US (\037) between fields, never tab: a finding with no `- file:` line leaves
# an empty column, bash treats tab as IFS whitespace, and `read` would collapse
# the empty column and shift every later field left.
parse_findings_all() { # $1 = review file → id·tag·loc·file·canon·problem·suggestion
  awk '
    function norm(s) { s = tolower(s); gsub(/[^a-z0-9]+/, " ", s)
                       gsub(/^ +| +$/, "", s); return s }
    function grab(s) { sub(/^-[ ]*[a-z]+:[ ]*/, "", s); gsub(/\t/, " ", s)
                       gsub(/^[ ]+|[ ]+$/, "", s); return s }
    function flush() {
      if (id != "") {
        f = loc; sub(/:[0-9]+.*$/, "", f); gsub(/^[ ]+|[ ]+$/, "", f)
        printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n",
               id, tag, loc, f, norm(title), prob, sugg
      }
      id=""; tag=""; loc=""; title=""; prob=""; sugg=""
    }
    /^### F[0-9]+-[0-9]+/ {
      flush()
      id=$2
      tag="UNKNOWN"
      if (match($0, /\[MECHANICAL\]/)) tag="MECHANICAL"
      else if (match($0, /\[DESIGN\]/)) tag="DESIGN"
      title=$0
      sub(/^### F[0-9]+-[0-9]+[ ]*(\[[A-Z]+\][ ]*)?/, "", title)
      gsub(/\t/, " ", title)
      next
    }
    /^-[ ]*file:/       { if (id != "" && loc  == "") loc  = grab($0); next }
    /^-[ ]*problem:/    { if (id != "" && prob == "") prob = grab($0); next }
    /^-[ ]*suggestion:/ { if (id != "" && sugg == "") sugg = grab($0); next }
    END { flush() }
  ' "$1" 2>/dev/null
}

# The four-field projection the registry helpers use: id, tag, file, canon.
parse_findings() { # $1 = review file
  local id tag loc file canon prob sugg
  while IFS=$'\037' read -r id tag loc file canon prob sugg; do
    [ -n "$id" ] || continue
    printf '%s\037%s\037%s\037%s\n' "$id" "$tag" "$file" "$canon"
  done < <(parse_findings_all "$1")
}
```

- [ ] **Step 4: Point every caller at the new separator**

Change the five `parse_findings` readers from `IFS=$'\t'` to `IFS=$'\037'`. They are at `:399` (`fold_registry`), `:513` (`fingerprints_of`), `:551` and `:565` (the productivity helpers), and `:1032` (`build_matcher`). Each currently reads `while IFS=$'\t' read -r id tag file nt; do`. Leave the body unchanged.

Then delete `parse_findings_verbose` (`:1151-1179`) and change its single caller at `:1264` (`build_fix_brief`) to call `parse_findings_all`. Its read loop already uses `IFS=$'\037'` and the field order is unchanged.

- [ ] **Step 5: Make `extract_finding` share the normalisation**

`extract_finding` must keep buffering raw markdown, which the record-emitting parser does not do, so it stays a separate awk program. Remove its private `norm()` and have it take the canonical form from the shared parser instead, so there is one definition rather than two that happen to agree:

```bash
# Extract the markdown block of the finding whose fingerprint matches $2.
# The fingerprint comparison is delegated to parse_findings so the title
# normalisation has exactly one definition; this pass only slices the text.
extract_finding() { # $1=review file  $2=fingerprint
  local want_id="" id tag file canon
  while IFS=$'\037' read -r id tag file canon; do
    [ "${file} | ${canon}" = "$2" ] || continue
    want_id="$id"; break
  done < <(parse_findings "$1")
  [ -n "$want_id" ] || return 0
  awk -v want="$want_id" '
    /^### F[0-9]+-[0-9]+/ {
      if (buf != "" && hit) { printf "%s", buf; exit }
      hit = ($2 == want); buf = $0 "\n"; next
    }
    { if (buf != "") buf = buf $0 "\n" }
    END { if (hit) printf "%s", buf }
  ' "$1" 2>/dev/null
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL=0`, with two more checks than before.

- [ ] **Step 7: Prove the tests discriminate**

Copy the tree to a scratch directory. Change the projection in `parse_findings` back to `printf '%s\t%s\t%s\t%s\n'` and the five readers back to `IFS=$'\t'`. Run the suite and record which checks fail — the two new ones must be among them. Restore. Then, in a second copy, change `norm()`'s `gsub(/[^a-z0-9]+/, " ", s)` to `gsub(/[^a-z0-9]+/, "", s)` and confirm the existing fingerprint and stalemate tests fail; this proves the shared normalisation is actually the one in use.

- [ ] **Step 8: Run every suite and commit**

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add -A
git commit -m "refactor(engine): one finding grammar, and a fingerprint that survives a missing location"
```

---

### Task 2: The economics measurement stops running when nothing is configured

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh:630-645` (`diff_line_count`), `:647-672` (`economics_flags`), and `build_fix_brief`'s reader call around `:1210`
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `economics_flags` and `build_fix_brief` behave exactly as before whenever any value is configured, and perform no git or python work at all when none is.

`economics_flags` evaluates `$(diff_line_count)` inside the command substitution that invokes the reader, so the count is computed before anything knows whether a value is set. A default install — where `shared/config.toml` is entirely comments — therefore pays a `git diff --numstat`, a `git ls-files --others`, one `awk` per untracked file and a `python3 -I` process spawn on every runner emission, three times on a findings round, to produce nothing.

- [ ] **Step 1: Write the failing test**

```bash
# ── economics: a default install measures nothing ───────────────────────────
# The reader is replaced with a stub that records every invocation. With no
# configured value the engine must not consult it with a real line count, and
# must not run the git scans that produce one.
fresh_dir; write_state task 0; mkdir -p reviews
no_skip
printf 'a\nb\nc\n' > f.txt
cat > .claude/fake-reader.sh <<'READER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PWD/.claude/reader-calls.txt"
printf 'model=\neffort=\nwriter=\nsource=default\n'
READER
chmod +x .claude/fake-reader.sh
SPAR_CONFIG_READER="$PWD/.claude/fake-reader.sh" run_hook >/dev/null
chk "an unconfigured install consults the reader at most once" "ok" \
  "$([ "$(wc -l < .claude/reader-calls.txt 2>/dev/null || echo 0)" -le 1 ] && echo ok || echo "called $(wc -l < .claude/reader-calls.txt) times")"
chk "and does not compute a line count for it" "0" \
  "$(awk '{print $2}' .claude/reader-calls.txt 2>/dev/null | head -1)"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL: and does not compute a line count for it` — today the stub is called with the measured count.

- [ ] **Step 3: Split the reader call into two phases**

The reader already answers with `source=default` when nothing is configured, and that answer does not depend on the line count. Ask it once with a count of `0` to learn whether anything is set, and measure only if something is:

```bash
# Memoised: three call sites can fire on one findings round, and the answer
# cannot change within a single hook invocation.
_ECON_LINES=""
diff_line_count() {
  if [ -z "$_ECON_LINES" ]; then
    local tracked untracked=0 f
    tracked=$(git diff --numstat "${BASE}" 2>/dev/null \
      | awk '{ if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/) n += $1 + $2 } END { print n+0 }')
    while IFS= read -r -d '' f; do
      { [ -f "$f" ] && [ ! -L "$f" ]; } || continue
      untracked=$(( untracked + $(awk 'END { print NR+0 }' "$f" 2>/dev/null || echo 0) ))
    done < <(git ls-files --others --exclude-standard -z 2>/dev/null)
    _ECON_LINES=$(( ${tracked:-0} + untracked ))
  fi
  printf '%s\n' "$_ECON_LINES"
}

# Does this install configure anything at all? Asked with a line count of 0,
# which the reader does not need to answer it: `source=` reports whether a file
# was read, and model/writer do not vary with size. Only the effort ladder does,
# so a real count is measured afterwards and only when it can matter.
economics_configured() {
  local k v src="" model="" writer=""
  [ -x "$CONFIG_READER" ] || return 1
  while IFS='=' read -r k v; do
    case "$k" in source) src="$v" ;; model) model="$v" ;; writer) writer="$v" ;; esac
  done < <("$CONFIG_READER" "$1" 0 2>/dev/null)
  [ "$src" = config ] || return 1
  [ -n "$model" ] || [ -n "$writer" ] && return 0
  # A ladder can still produce an effort at a nonzero size, so a config file
  # with only an [effort] table must not be treated as unconfigured.
  grep -q '^[[:space:]]*ladder[[:space:]]*=' "${SPAR_CONFIG_FILE:-${PLUGIN_ROOT}/shared/config.toml}" 2>/dev/null
}
```

Then have `economics_flags` return early:

```bash
economics_flags() { # $1=family → prints flags, or nothing
  local fam="$1" k v model="" effort="" src=""
  economics_configured "$fam" || return 0
  while IFS='=' read -r k v; do
    case "$k" in model) model="$v" ;; effort) effort="$v" ;; source) src="$v" ;; esac
  done < <("$CONFIG_READER" "$fam" "$(diff_line_count)" 2>/dev/null)
  [ "$src" = config ] || return 0
  ...unchanged from here...
}
```

Apply the same guard to `build_fix_brief` (its reader call, around `:1210`): call `economics_configured "$AUTHOR" || return 1` before the reader invocation that fetches the writer tier.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL=0`. The existing tests that *do* configure a value must still pass unchanged — they are what proves the short-circuit did not disable the feature.

- [ ] **Step 5: Prove the tests discriminate**

In a scratch copy, delete the `economics_configured "$fam" || return 0` line. Confirm the two new checks fail and nothing else does. Then, in a second copy, make `economics_configured` always return 1 and confirm every configured-value test fails — that is what shows the guard is not silently disabling the feature in the passing case.

- [ ] **Step 6: Run every suite and commit**

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add -A
git commit -m "perf(economics): measure nothing when nothing is configured"
```

---

### Task 3: Each dispatch carries what its recipient uses

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh:674-758` (`emit_runner`), `:930`, `:1008`, `:1073` (its three call sites)
- Modify: `plugins/spar/shared/prompts/matcher.md`
- Modify: `plugins/spar/hooks/stop-hook.sh` `build_matcher`'s `{{TASK}}` substitution
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: nothing from Tasks 1 or 2.
- Produces: `emit_runner <runner> <prompt> <out> <role>` where role is `reviewer`, `judge` or `matcher`. Only the `reviewer` role appends the diff surface to a claude-family runner.

`emit_runner` is role-oblivious: its claude branch appends the complete frozen-baseline diff for all three roles. The reviewer needs it. The judge rules on one cited finding and the matcher compares a prefiltered set of same-file titles; both already run with read-only `Read`, `Grep` and `Glob` and can open what they need. The codex branch, where the CLI inspects the repository itself, is unaffected.

`matcher.md` also carries `{{TASK}}`. The matcher's question is whether two finding texts describe one defect; the task requirements do not bear on it. Under `/spar:fight --whole` that placeholder is the entire plan file.

- [ ] **Step 1: Write the failing test**

```bash
# ── role-specific payloads ──────────────────────────────────────────────────
# The claude reviewer is handed the diff because it has no shell. The judge and
# the matcher have Read/Grep/Glob and a named target, so the full surface is
# payload they do not read.
fresh_dir; write_state review 1; mkdir -p reviews
sed -i '' 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md 2>/dev/null \
  || sed -i 's/^reviewer: codex/reviewer: claude/' .claude/spar.local.md
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] a.py off by one\n- file: a.py:10\n- problem: p\n- suggestion: s\n' > "$RF1"
printf -- '### F1-1: REJECTED — not a defect\n' > "$RP1"
run_hook >/dev/null
chk "the claude reviewer runner still carries the diff" "Changes under review" \
  "$(cat .claude/spar-run-reviewer.sh)"
printf 'STATUS: FINDINGS\n\n### F2-1 [MECHANICAL] a.py off by one\n- file: a.py:10\n- problem: p\n- suggestion: s\n' > "$RFb2"
printf -- '### F2-1: REJECTED — still not a defect\n' > "$RPb2"
run_hook >/dev/null
chk "a judge was dispatched" "present" \
  "$([ -f .claude/spar-run-judge.sh ] && echo present || echo absent)"
chk "the judge runner does not carry the diff" "absent" \
  "$(grep -qF 'Changes under review' .claude/spar-run-judge.sh && echo present || echo absent)"

# The matcher is asked about two titles, not about the task.
chk "matcher.md names no task placeholder" "absent" \
  "$(grep -qF '{{TASK}}' "$ROOT/plugins/spar/shared/prompts/matcher.md" && echo present || echo absent)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL: the judge runner does not carry the diff` and `FAIL: matcher.md names no task placeholder`.

- [ ] **Step 3: Give the runner a role**

Change the signature and gate the diff append:

```bash
emit_runner() { # $1=runner_path  $2=prompt_file  $3=out_file  $4=role
  local runner="$1" pf="$2" out="$3" role="${4:-reviewer}"
```

In the claude branch, the line that pipes the prompt currently reads:

```bash
if ! { cat "${pf}"; echo; echo '--- Changes under review ---'; cat "${DIFF_SURFACE_FILE}"; } | \
```

Build that prelude conditionally before the heredoc, so only the reviewer role gets it:

```bash
  # Only the reviewer reviews a surface. The judge is given one finding with a
  # cited path and the matcher a prefiltered set of titles; both have read-only
  # Read/Grep/Glob and can open exactly what they need. Handing them the whole
  # baseline diff is payload neither reads.
  local claude_input
  if [ "$role" = reviewer ]; then
    claude_input="{ cat \"${pf}\"; echo; echo '--- Changes under review ---'; cat \"${DIFF_SURFACE_FILE}\"; }"
  else
    claude_input="cat \"${pf}\""
  fi
```

and use `${claude_input}` in the generated script in place of the inline brace group. Write the diff surface file only when the role is `reviewer`.

- [ ] **Step 4: Pass the role at each call site**

- `:930` (`prepare_round`) → `emit_runner "$RUNNER" "$PROMPT_FILE" "$out" reviewer`
- `:1008` (`prepare_judge`) → `emit_runner "$JUDGE_RUNNER" "$JUDGE_PROMPT_FILE" "$out" judge`
- `:1073` (`build_matcher`) → `emit_runner "$MATCHER_RUNNER" "$MATCHER_PROMPT_FILE" "$out" matcher`

- [ ] **Step 5: Drop the task from the matcher prompt**

In `plugins/spar/shared/prompts/matcher.md`, delete the `## Task the author was given` heading and the `{{TASK}}` line beneath it. Remove the corresponding `prompt=${prompt//\{\{TASK\}\}/$TASK}` substitution in `build_matcher`. Leave `{{NEW_FINDINGS}}` and `{{EXISTING_FINDINGS}}` untouched.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL=0`.

- [ ] **Step 7: Prove the tests discriminate**

In a scratch copy, set `claude_input` unconditionally to the reviewer form. Confirm the judge check fails. In a second copy, restore `{{TASK}}` to `matcher.md` and confirm the matcher check fails. Also confirm the reviewer check still passes in both — it is what proves the reviewer did not lose its diff.

- [ ] **Step 8: Run every suite and commit**

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add -A
git commit -m "perf(engine): the judge and matcher stop receiving the whole baseline diff"
```

---

### Task 4: The author is told how to fix, not only what

**Files:**
- Modify: `plugins/spar/hooks/stop-hook.sh` — the block message in the review phase that demands a response file
- Modify: `plugins/spar/shared/policy.md` — protocol item 4
- Test: `tests/test_stop_hook.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: three lines of advice in the block message the author reads on every findings round. Advice only — the response file's required shape is unchanged and the hook checks nothing new.

The block message says only "fix every `[MECHANICAL]` finding, decide each `[DESIGN]` finding, write the response file". Each discipline below is traced to a finding in the 2026-07-27 runs that cost a round:

- Undo the fix and confirm the right checks fail. Three defects shipped because this was skipped: a substring assertion that passed for every value, a mutation that caught nothing because the fixture could not discriminate between two line-counting methods, and an `env -u` correction no test in the suite could observe.
- Find every place the changed rule is stated. One fix updated the code and left three documents describing the old rule; the correction for that then missed a fourth.
- When narrowing a definition, narrow all of it. "Location is not empty" let a bare path through when the contract is `file:line`.

Keep it short. This text is read on every findings round and becomes wallpaper if it is long. Do **not** make it a required response field — that decision is deferred until the effect on round counts is observed.

- [ ] **Step 1: Write the failing test**

```bash
# ── the author is told how to fix ───────────────────────────────────────────
# Advice, not a required field: the response file's shape is unchanged. These
# assert the text reaches the author on the round where fixing happens.
in_review 1
printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] off by one\n- file: a.py:10\n- problem: p\n- suggestion: s\n' > "$RF1"
OUT=$(run_hook)
chk "the fix message names the revert check" "Undo your fix" "$OUT"
chk "the fix message names the every-place check" "every place" "$OUT"
chk "the fix message names the whole-definition check" "narrow all of it" "$OUT"
chk "and it is still advice, not a new required field" "absent" \
  "$(printf '%s' "$OUT" | grep -qiF 'must record how you verified' && echo present || echo absent)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_stop_hook.sh`
Expected: the first three checks FAIL.

- [ ] **Step 3: Extend the block message**

Append to the existing reason string, before `${BRIEF_NOTE}`:

```
Three things this loop has paid for repeatedly, each worth the minute it costs:

- Undo your fix and check which tests fail. A test that passes either way is
  not testing the fix.
- Find every place the rule you changed is written down — the code, the comment
  above it, the docs, and the other seat's copy. One place fixed and another
  left stale reads as a contradiction next round.
- If you narrowed a definition, narrow all of it. "Not empty" and "well formed"
  are different rules.
```

- [ ] **Step 4: Record it in the protocol**

Extend `policy.md` protocol item 4 with one sentence stating that the author is given fix guidance in the block message, that it is advice rather than an enforced field, and why: the next round re-reviews the fix either way, and requiring a verification field would be checkable only for presence, not for truth.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/test_stop_hook.sh`
Expected: `FAIL=0`.

- [ ] **Step 6: Confirm the message did not become wallpaper**

Measure the block message's length before and after with `wc -c` on a captured `reason` field. Record both numbers in the commit message. If the addition more than doubles it, cut wording rather than dropping a discipline.

- [ ] **Step 7: Run every suite and commit**

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add -A
git commit -m "feat(loop): tell the author how to fix, not only what to fix"
```

---

### Task 5: A run records which reviewer build produced it, and `hard_cap` stops lying

**Files:**
- Modify: `plugins/spar/commands/spar-record-outcome.sh`
- Modify: `plugins/spar/commands/spar-fight-launch.sh:35-64`, `plugins/spar/commands/fight.md` (its state heredoc), `adapters/codex/skills/spar-fight/SKILL.md:164-176`
- Modify: `README.md:88-89`
- Test: `tests/test_record_outcome.sh`, `tests/test_fight_launch.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a `reviewer_version:` field in the loop state file, written at activation by all three entry points, and echoed into the outcome file. Absent or unreadable becomes `unknown` and never fails a run.

A run records `reviewer: codex` and nothing about which build did the reviewing. Capture it at activation rather than at teardown, so the recorded version is the one that actually performed the reviews.

`hard_cap` is read by the engine and `README.md` tells the user to set it, but no entry point writes the field and `fight.md` forbids hand-editing the state file, so the default `2 × max_rounds` is the only reachable value. Make the documentation match the code: state that the hard cap is fixed at twice `max_rounds` and is not user-settable.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_record_outcome.sh`. Note its `fresh()` already writes a
default `.claude/spar.local.md`, so each case below overwrites it deliberately:

```bash
# The outcome carries the reviewer build, so a run's behaviour can be explained
# later. Unreadable or absent must degrade to "unknown", never fail the run.
fresh
cat > .claude/spar.local.md <<'EOF'
---
active: true
phase: review
round: 3
review_id: 20260728-100000-abc123
reviewer: codex
reviewer_version: codex-cli 0.146.0-alpha.3
---
EOF
bash "$WRITER" converged .claude/spar.local.md clean
chk "outcome records the reviewer build" "reviewer_version: codex-cli 0.146.0-alpha.3" \
  "$(cat reviews/spar-20260728-100000-abc123-outcome.md)"

fresh
cat > .claude/spar.local.md <<'EOF'
---
active: true
phase: review
round: 3
review_id: 20260728-100001-abc124
reviewer: codex
---
EOF
bash "$WRITER" converged .claude/spar.local.md clean; RC=$?
chk "a missing version is not an error" "0" "$RC"
chk "and is recorded as unknown" "reviewer_version: unknown" \
  "$(cat reviews/spar-20260728-100001-abc124-outcome.md)"
```

In `tests/test_fight_launch.sh`, which drives the launcher as `$L` against a
prepared plan state, add after an existing successful launch:

```bash
chk "launch records the reviewer build" '^reviewer_version: .+' \
  "$(grep '^reviewer_version:' .claude/spar.local.md)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/test_record_outcome.sh` and `bash tests/test_fight_launch.sh`
Expected: the new checks FAIL.

- [ ] **Step 3: Read the field in the outcome writer**

In `spar-record-outcome.sh`, beside the existing `reviewer=$(field reviewer)`:

```bash
reviewer_version=$(field reviewer_version)
# A version string is free text from a third-party CLI. Keep it on one line and
# strip anything that could forge a second frontmatter field.
reviewer_version=$(printf '%s' "$reviewer_version" | tr -d '\r\n' | cut -c1-120)
[ -n "$reviewer_version" ] || reviewer_version=unknown
```

and emit `echo "reviewer_version: ${reviewer_version}"` after the existing `reviewer:` line.

- [ ] **Step 4: Capture it at activation, in all three entry points**

In `spar-fight-launch.sh`, before the state heredoc:

```bash
# Best-effort: a CLI that will not report a version must not stop a run.
reviewer_version="$("$reviewer" --version 2>/dev/null | head -1 | tr -d '\r')"
[ -n "$reviewer_version" ] || reviewer_version=unknown
```

and add `reviewer_version: ${reviewer_version}` to the emitted frontmatter. Make the same two changes in `fight.md`'s setup block and in the Codex seat's `spar-fight/SKILL.md` state heredoc, using each file's existing variable naming.

- [ ] **Step 5: Make the `hard_cap` documentation match the code**

In `README.md:88-89`, replace the text telling the user to set the `hard_cap` state field with a statement that the hard cap is fixed at twice `max_rounds`. `policy.md:61` already says only that the default is `2 × max_rounds` and does not claim it is settable, so it needs no change — confirm that before editing it. Do not add a way to set it: nothing has needed one, and the state file is not user-editable by design.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/test_record_outcome.sh`, `bash tests/test_fight_launch.sh`
Expected: `FAIL=0` in both.

- [ ] **Step 7: Prove the tests discriminate**

In a scratch copy, remove the `[ -n "$reviewer_version" ] || reviewer_version=unknown` fallback and confirm the missing-version check fails. In a second copy, feed a version string containing a newline and confirm the outcome file still has exactly one `reviewer_version:` line — if it does not, the sanitisation is wrong.

- [ ] **Step 8: Run every suite and commit**

```bash
for t in tests/test_*.sh; do bash "$t" >/dev/null || echo "FAILED: $t"; done
git add -A
git commit -m "feat(outcome): record the reviewer build, and stop documenting a cap nobody can set"
```

---

## Non-goals

- Removing or re-triggering the final sweep, changing the matcher's trigger, or replacing the every-round full re-read with an incremental one. Each was examined in the 2026-07-28 cross-review; each rests on measurements taken against codex 0.144.1, which the project no longer targets. Re-measure on the current reviewer before touching them.
- Splitting `stop-hook.sh`. Both independent reviews said its size is not causing harm and that a split would add a fail-open boundary and a path-resolution surface for no testability the black-box suite does not already provide.
- Making the author's verification a required response field. Deferred until the advice in Task 4 has been observed.
- Unifying `diff_line_count` with the `lines:` figure `spar-classify-change.sh` already computes. Real duplication, but the two are measured at different points in the run and merging them is a larger change than this plan's cost argument justifies.

## Verification this plan cannot do

Whether the Task 4 advice actually lowers the round count. The prior baseline — 29 runs, 3.2 reviewer rounds per run, 12 runs reaching five rounds or more — was measured against codex 0.144.1 and is not comparable to runs on the current build. A new baseline has to accumulate on the current reviewer before the advice can be judged, and the `reviewer_version` field from Task 5 is what will make that comparison possible at all.

`stop-hook.sh` is shared by both seats, so before the release that carries this work, run a live `/spar:fight` in Claude Code and a live `spar-fight` in Codex, per the release gate in `docs/design-decisions.md`.
