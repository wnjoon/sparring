---
name: spar-ready
description: Turn a spec into a checkbox implementation plan on a dedicated branch, then stop — spar-fight executes it task by task.
---

# spar-ready

Turns a spec into a plan and stops. It never runs the review loop; `spar-fight`
does that. This skill mirrors the Claude-hosted `/spar:ready` command.

## 1. Setup

**Before running the block below**, write whatever the user passed — flags and
the spec path or description, byte for byte — to `.claude/spar-args.txt` with your
file-writing tool, creating `.claude` if it does not exist. Never paste their text
into the shell block; the block reads the file as data.

```bash
set -e
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-}"
[ -n "$SPAR_ROOT" ] || SPAR_ROOT=@@SPAR_PLUGIN_ROOT@@
[ -d "$SPAR_ROOT" ] || { echo "Error: set SPAR_PLUGIN_ROOT to sparring's plugins/spar." >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Error: spar-ready must run inside a git repository." >&2; exit 1; }
if [ -f .claude/spar-plan.local.md ]; then echo "Error: a plan is already ready. Run spar-fight, or spar-cancel first." >&2; exit 1; fi
if [ -f .claude/spar.local.md ]; then echo "Error: a fight loop is already active. Use spar-cancel first." >&2; exit 1; fi
# Arguments arrive in a FILE, never pasted into this block — a spec description is
# arbitrary prose, and a line matching a heredoc delimiter would close the heredoc
# early and hand the rest to the shell. Read once, then removed.
RDY_ARGS_FILE=".claude/spar-args.txt"
RDY_RAW="$(cat "$RDY_ARGS_FILE" 2>/dev/null || true)"
rm -f "$RDY_ARGS_FILE"
RESOLVED="$("$SPAR_ROOT/commands/spar-ready-resolve.sh" "$RDY_RAW")" || { printf '%s\n' "$RESOLVED" >&2; exit 1; }
RDY_MODE="${RESOLVED%%$'\t'*}"
RDY_REST="${RESOLVED#*$'\t'}"
RDY_REVIEWER="${RDY_REST%%$'\t'*}"
RDY_REST2="${RDY_REST#*$'\t'}"
RDY_UNATTENDED="${RDY_REST2%%$'\t'*}"
RDY_REST3="${RDY_REST2#*$'\t'}"
RDY_PLAN_REVIEW="${RDY_REST3%%$'\t'*}"
RDY_REST4="${RDY_REST3#*$'\t'}"
RDY_VERIFY_SPEC="${RDY_REST4%%$'\t'*}"
RDY_SPEC="${RDY_REST4#*$'\t'}"
# Mirror of the Claude seat's auto-detect: Codex authors here, so claude reviews
# when it is installed and only a machine without it falls back to same-family.
if [ -z "$RDY_REVIEWER" ]; then
  if command -v claude >/dev/null 2>&1; then
    RDY_REVIEWER=claude
  else
    # Falling back to same-family review is a supported mode, but it is NOT what
    # this seat is for, and a silent fallback reads as a cross-model run in the
    # report afterwards. Measured in a real session: claude lives in ~/.local/bin,
    # which a non-interactive shell does not have on PATH, so the default degraded
    # without anyone noticing until the run was over.
    RDY_REVIEWER=codex
    echo "warning: 'claude' is not on PATH, so this run will be codex reviewing codex." >&2
    echo "         That is single-agent mode, not the cross-model pairing this seat exists for." >&2
    echo "         For cross-model review, put claude on PATH (it is often in ~/.local/bin)" >&2
    echo "         and start again, or pass --reviewer claude to fail loudly instead." >&2
  fi
fi
command -v "$RDY_REVIEWER" >/dev/null 2>&1 || { echo "Error: '$RDY_REVIEWER' CLI not on PATH." >&2; exit 1; }
# Planning is not an enforced loop, so a missing liveness marker is not fatal here
# — but spar-fight WILL refuse without one, and finding that out only after a plan
# has been written wastes the work. Warn now.
RDY_LIVE="$(git rev-parse --git-dir)/spar-hook-live"
if [ "$(head -1 "$RDY_LIVE" 2>/dev/null || true)" != "${CODEX_THREAD_ID:-}" ]; then
  echo "warning: sparring's hooks have not proven themselves live in this session." >&2
  echo "         spar-fight will refuse to start until they do (install them, then" >&2
  echo "         start a new session and accept the trust prompt)." >&2
fi
# Isolate this run on a dedicated branch in the CURRENT directory. No separate
# worktree, so the working directory — and thus every state path the Stop hook
# reads — never changes mid-run. All task commits land on this branch.
# Basename and extension stripping is for a spec that IS a file. Applied to an
# inline description it cuts everything before the last '/' the prose happens to
# contain, and the branch name starts mid-sentence.
if [ -f "$RDY_SPEC" ]; then RDY_SLUG_SRC="$(printf '%s' "$RDY_SPEC" | sed 's#.*/##; s/\.[A-Za-z0-9]*$//')"
else RDY_SLUG_SRC="$RDY_SPEC"; fi
# The squeeze matters because the ASCII filter deletes characters BETWEEN the
# dashes that spaces became: a non-Latin phrase would otherwise leave a run of
# them. Deliberately ASCII-only — git takes UTF-8 refs, but a branch name is not
# where the topic is read, and byte-safe truncation of multibyte text is
# machinery this does not need.
RDY_SLUG="$(printf '%s' "$RDY_SLUG_SRC" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | tr -s '-' | sed 's/^-*//; s/-*$//' | cut -c1-40)"
[ -n "$RDY_SLUG" ] || RDY_SLUG=run
RDY_BRANCH="spar/${RDY_SLUG}-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$RDY_BRANCH" || { echo "Error: could not create branch $RDY_BRANCH." >&2; exit 1; }
for D in .claude reviews docs/superpowers/plans; do mkdir -p "$D"; done
# The captured copy is authoritative from here: a spec file edited later does not
# change what the plan was written against. A path is copied byte for byte;
# inline text gets a trailing newline.
if [ -f "$RDY_SPEC" ]; then cp "$RDY_SPEC" .claude/spar-plan-spec.txt
else printf '%s\n' "$RDY_SPEC" > .claude/spar-plan-spec.txt; fi
RDY_PR_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
if [ "$RDY_PLAN_REVIEW" = false ]; then RDY_PR=skipped; else RDY_PR=required; fi
if [ "$RDY_VERIFY_SPEC" = true ]; then RDY_SV=required; else RDY_SV=skipped; fi
# Reuse spar's git-excludes so fight's own commits never stage loop artifacts.
EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
for pat in 'reviews/spar-*' '.claude/spar*'; do
  grep -qxF "$pat" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$pat" >> "$EXCLUDE"
done
# 'author: codex' is the seat — it decides which family runs the final sweep for
# every task of this plan. Recorded here so the prepared plan is self-describing;
# spar-fight re-stamps it (and the owning session, which is only knowable once the
# plan is actually being fought, possibly from a later session) at launch.
TMP="$(mktemp .claude/spar-plan.local.md.tmp.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<STATE_EOF
---
active: true
phase: planned
mode: ${RDY_MODE}
author: codex
reviewer: ${RDY_REVIEWER}
owner_session:
unattended: ${RDY_UNATTENDED}
plan_review: ${RDY_PR}
plan_review_id: ${RDY_PR_ID}
plan_path:
branch: ${RDY_BRANCH}
tasks: 0
current: 1
current_review_id:
---
STATE_EOF
mv "$TMP" .claude/spar-plan.local.md
trap - EXIT
printf 'Ready — plan branch %s (author=codex, reviewer=%s, unattended=%s, plan-review=%s, spec-verify=%s).\nSPEC=%s\n' \
  "$RDY_BRANCH" "$RDY_REVIEWER" "$RDY_UNATTENDED" "$RDY_PR" "$RDY_SV" "$RDY_SPEC"
```

## 2. Write the plan

Read `.claude/spar-plan-spec.txt` — section 1 captured the spec there, and that
copy is what the plan will be reviewed against. Read it rather than the `SPEC=`
path, so an edit to the original after setup cannot put the plan and the review
on different specs. If it is empty, stop and say so.

Write the implementation plan to `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`:
bite-sized tasks, each with its own failing test → implementation → verification
→ commit steps, and exact file paths. No placeholders — every step must carry the
content an implementer needs, because each task is handed to the loop on its own.

**Watch out:** no line inside a task body may start with `### ` unless it is the
next task heading — the extractor stops there, silently truncating what the
implementer receives. Write fixtures as `printf '### F1-1 …\n'` one-liners.

## 3. Record and ingest

```bash
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-}"
[ -n "$SPAR_ROOT" ] || SPAR_ROOT=@@SPAR_PLUGIN_ROOT@@
. "$SPAR_ROOT/commands/spar-plan-lib.sh"
plan_set_field plan_path "<the plan path you just wrote>"
MODE="$(sed -n 's/^mode: //p' .claude/spar-plan.local.md | head -1)"
bash "$SPAR_ROOT/commands/spar-ready-ingest.sh" "<the plan path>" "$MODE" .claude/spar-plan.local.md
```

## 4. Have the plan reviewed

Skip this section entirely when section 1 printed `plan-review=skipped`.

```bash
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-}"
[ -n "$SPAR_ROOT" ] || SPAR_ROOT=@@SPAR_PLUGIN_ROOT@@
bash "$SPAR_ROOT/commands/spar-plan-review-prepare.sh" "<the plan path>" .claude/spar-plan.local.md \
  && bash .claude/spar-run-plan-review.sh
```

Read `reviews/spar-plan-<plan_review_id>.md` (the id is in the plan state) and
show the user what it says. You did not write this review and you must not edit
or delete it.

If its first line is `PLAN-REVIEW: FINDINGS`, decide each finding on the merits —
accept it and edit the plan, or reject it with a reason grounded in the plan, the
spec, or the code — and write `.claude/spar-plan-review-response.md` with one
section per finding:

```
### PR1: ACCEPTED — <what you changed in the plan>
### PR2: REJECTED — <grounded reason>
```

`spar-fight` refuses to start until that file accounts for every finding. A
grounded rejection clears a finding exactly as an acceptance does — the point is
that each one was answered, not that the reviewer always wins.

## 5. Stop

Tell the user the plan path and branch, and that `spar-fight` with no task will
drive the plan to convergence task by task. Do not start it — the checkpoint here
is deliberate, so the plan can be reviewed or edited first.

## Hard rules

- Never edit `.claude/spar-plan.local.md` by hand after setup. To abort, run the
  `spar-cancel` skill.
- `spar-ready` never runs the review loop. Do not launch a task or write a
  sparring outcome yourself.
