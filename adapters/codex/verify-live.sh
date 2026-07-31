#!/usr/bin/env bash
# Phase 6 release gate: set up an isolated Codex session a human can drive, then
# judge what can be judged from the artifacts it leaves. Accepting a hook-trust
# prompt is interactive, so this harness deliberately stops short of pretending
# to automate it — it makes the manual run cheap and repeatable instead.
# Usage: verify-live.sh setup|check|clean [--dir <path>]
# Requires python3. `check` additionally needs python3 3.11+ to read the trust
# record itself (tomllib); on an older one that single item is handed back to the
# human with the reason, and everything else still works.
# Exit: 0 ok; 2 usage; 3 unsafe path or I/O failure.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
MARKER_NAME=".spar-live-workspace"
MARKER_TEXT="spar-live-verify"

usage() { echo "usage: verify-live.sh setup|check|clean [--dir <path>]" >&2; exit 2; }

cmd="${1-}"
[ "$#" -gt 0 ] && shift
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

# A string prefix test is not a containment test. "/tmp/x/../real/ws" does not
# start with "/tmp/real" and neither does a path reaching the same place through
# a symlink, yet both land inside it — and this script removes what it is given.
# So both sides are canonicalised first: `..` and `.` collapsed, and symlinks
# resolved on the deepest part that already exists (the rest cannot be a symlink,
# because it does not exist yet). python3 is already required by install.sh,
# which this script calls, so it adds no new dependency.
# A newline in either path would shift the fields of the line-delimited result
# below, so that `want` became a prefix of what was asked for — and this script
# deletes what it resolves. Rather than teach the transfer to carry newlines,
# refuse them: a newline in a workspace path or a CODEX_HOME is never intentional,
# and refusing is the direction that cannot destroy anything.
case "$dir" in *"
"*) echo "error: --dir must not contain a newline" >&2; exit 3 ;; esac
case "$real_home" in *"
"*) echo "error: CODEX_HOME must not contain a newline" >&2; exit 3 ;; esac

# Containment is decided here too, not by a shell glob afterwards. The glob had
# an edge it could not express: with CODEX_HOME resolving to "/", the pattern
# becomes "//*", which matches nothing, so every absolute path would have been
# allowed even though all of them are inside it. commonpath has no such corner.
command -v python3 >/dev/null 2>&1 \
  || { echo "error: python3 is required to resolve paths safely" >&2; exit 3; }
resolved="$(WANT="$dir" REAL="$real_home" python3 -c '
import os, sys

def canon(p):
    p = os.path.abspath(p)
    head, tail = p, []
    while not os.path.exists(head) and head != os.path.dirname(head):
        head, t = os.path.split(head)
        tail.append(t)
    return os.path.join(os.path.realpath(head), *reversed(tail))

try:
    want, real = canon(os.environ["WANT"]), canon(os.environ["REAL"])
except Exception as exc:
    sys.stderr.write("error: could not resolve a path: %s\n" % exc)
    sys.exit(3)

# Checked HERE, not only on the inputs: realpath can introduce a newline that the
# input never had, by resolving a symlink whose target contains one. The result
# is transferred as three lines, so a newline anywhere in it silently reassigns
# the fields — and the field it corrupts is the directory this script deletes.
for label, p in (("--dir", want), ("CODEX_HOME", real)):
    if "\n" in p:
        sys.stderr.write(
            "error: the resolved %s path contains a newline; refusing\n" % label)
        sys.exit(3)

try:
    inside = os.path.commonpath([want, real]) == real
except ValueError:            # different drives / unrelated roots
    inside = False
print(want); print(real); print("INSIDE" if inside else "OUTSIDE")
')" || resolved=""
want="$(printf '%s\n' "$resolved" | sed -n 1p)"
real="$(printf '%s\n' "$resolved" | sed -n 2p)"
verdict="$(printf '%s\n' "$resolved" | sed -n 3p)"
{ [ -n "$want" ] && [ -n "$real" ] && [ -n "$verdict" ]; } \
  || { echo "error: could not resolve the workspace path" >&2; exit 3; }
if [ "$verdict" = INSIDE ]; then
  echo "error: refusing to use $want — it is inside the real CODEX_HOME ($real)" >&2
  exit 3
fi

# The marker is what stands between `rm -rf` and someone else's directory, so it
# has to be a real file we could have written — not a symlink pointing at a
# genuine marker elsewhere, which `-f` alone would happily accept.
is_ours() {
  [ -f "$1/$MARKER_NAME" ] && [ ! -L "$1/$MARKER_NAME" ] \
    && grep -qxF "$MARKER_TEXT" "$1/$MARKER_NAME" 2>/dev/null
}

# ── clean ────────────────────────────────────────────────────────────────────
if [ "$cmd" = clean ]; then
  # -e is false for a DANGLING symlink, so it has to be asked about separately or
  # a planted link would be reported as "nothing to clean" while still sitting
  # there. Whatever it points at, it is not something this script wrote.
  if [ ! -e "$want" ] && [ ! -L "$want" ]; then
    echo "nothing to clean at $want"; exit 0
  fi
  is_ours "$want" \
    || { echo "error: $want is not a harness workspace; refusing to remove it" >&2; exit 3; }
  rm -rf "$want" || { echo "error: could not remove $want" >&2; exit 3; }
  echo "removed $want"
  exit 0
fi

# ── check ────────────────────────────────────────────────────────────────────
if [ "$cmd" = check ]; then
  is_ours "$want" || { echo "error: $want is not a harness workspace" >&2; exit 3; }
  repo="$want/repo"
  failed=0
  say() { printf 'ITEM %s: %s\n  %s\n\n' "$1" "$2" "$3"; }

  # Trust is durable: accepting the prompt writes a trusted_hash into the isolated
  # config.toml, under a key of the form <hooks.json path>:<event>:<group>:<hook>.
  # The file is parsed as TOML and the key matched by prefix against THIS
  # workspace's hooks.json, so another registration's record in the same file is
  # not read as ours.
  # Every artifact below is evidence for a verdict, so each has to be something a
  # genuine run could have produced. None of them is ever a symlink in a real run
  # — session-start.sh writes the marker through a temp file and renames it, and
  # the fight skill refuses a symlinked marker outright — so a link here means the
  # evidence was planted, not observed. Ignored, and said out loud: silently
  # treating it as absent would hide the tampering it is meant to catch.
  real_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
  ignored=""
  note_ignored() { ignored="${ignored}  ignored: $1
"; }

  # Checking only the leaf files leaves the way in one level up: if home, repo,
  # the git directory, .claude or reviews is a symlink, every artifact under it
  # is a perfectly regular file belonging to somewhere else. Containment is a
  # property of the whole path, so the directories are verified before anything
  # under them is read, and a violation is an unsafe workspace (exit 3) rather
  # than a verdict — there is nothing here to judge.
  require_real_dir() {  # $1=path (skipped when absent)
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if [ -L "$1" ]; then
      echo "error: $1 is a symlink; this workspace is not self-contained" >&2; exit 3
    fi
    [ -d "$1" ] || { echo "error: $1 is not a directory" >&2; exit 3; }
    return 0
  }
  require_real_dir "$want/home"
  require_real_dir "$want/repo"

  # A symlink is the interesting case, but it is not the only one: a directory, a
  # FIFO or a device at any of these paths is equally not something a run wrote,
  # and skipping it without a word is the same silence this block exists to break.
  reject_unless_regular() {   # $1=path → true when usable, false and noted otherwise
    real_file "$1" && return 0
    if [ -L "$1" ]; then note_ignored "$1 is a symlink"
    elif [ -e "$1" ]; then note_ignored "$1 is not a regular file"
    fi
    return 1
  }

  cfg="$want/home/config.toml"
  trusted=0
  trust_note=""
  # Parsed as TOML, not pattern-matched. A substring test cannot tell
  # [hooks.state."<path>:stop:0:0"] from a foreign parent table that merely
  # contains that text, and it has no answer at all for a workspace path holding
  # a character TOML escapes. Exit codes: 0 trusted, 1 not, 2 unparseable here,
  # 3 malformed file. Anything but 0 or 1 leaves item 1 for the human rather than
  # guessing in either direction.
  if [ -e "$cfg" ] || [ -L "$cfg" ]; then
    if ! reject_unless_regular "$cfg"; then
      trust_note=" (the config it would be read from was ignored; see above)"
    fi
  fi
  if real_file "$cfg"; then
    # -I: no PYTHONPATH, no user site. The parser that decides whether the trust
    # gate was exercised has to be the standard library's, not whatever a
    # directory on the path happens to call tomllib.
    trust_answer="$(CFG="$cfg" HOOKS="$want/home/hooks.json" python3 -I - <<'TRUSTPY'
import os, sys

# tomllib only, deliberately. A hand-rolled reader kept looking almost right and
# being wrong — first on foreign parent tables, then on child tables like
# [hooks.state."<key>".other], and it could return on a plausible hash before
# noticing malformed TOML further down. Each hole was cheap to patch and the next
# one was never visible; that is the wrong shape for the check that decides
# whether the trust gate was exercised, where a false CONFIRMED is the failure
# that matters.
#
# The answer is PRINTED, not inferred from the exit status. Python exits 1 for an
# uncaught exception too, so reading 1 as "no trust record" would turn any
# interpreter mishap into ITEM 1: FAILED — an accusation that the hooks ran
# untrusted, on no evidence. A token nobody else can produce is unambiguous, and
# anything unrecognised is treated as unreadable.
def answer(token):
    sys.stdout.write(token)
    raise SystemExit(0)

# The version, not the import. tomllib entered the standard library in 3.11; on
# anything older an importable module of that name is something else wearing the
# name, and this is the one verdict where a parser of unknown provenance must not
# be the thing that says "trusted".
if sys.version_info < (3, 11):
    answer("NO_TOMLLIB")

try:
    import tomllib
except Exception:
    answer("NO_TOMLLIB")

try:
    with open(os.environ["CFG"], "rb") as fh:
        data = tomllib.load(fh)
except Exception:
    answer("BAD_TOML")

try:
    state = data.get("hooks", {}).get("state", {})
    prefix = os.environ["HOOKS"] + ":"
    if isinstance(state, dict):
        for key, entry in state.items():
            if key.startswith(prefix) and isinstance(entry, dict):
                h = entry.get("trusted_hash")
                if isinstance(h, str) and h.strip():
                    answer("TRUSTED")
    answer("UNTRUSTED")
except Exception:
    answer("BAD_TOML")
TRUSTPY
)" || trust_answer=""
    case "$trust_answer" in
      TRUSTED)    trusted=1 ;;
      UNTRUSTED)  ;;
      NO_TOMLLIB) trust_note=" (reading it needs python3 3.11 or newer for tomllib; this one is older)" ;;
      BAD_TOML)   trust_note=" ($cfg is not valid TOML)" ;;
      *)          trust_note=" (the reader gave no usable answer, so nothing is known either way)" ;;
    esac
  fi

  # .git must be PRESENT, not merely unsuspicious. git searches upward, so a
  # workspace whose own .git is gone silently adopts the enclosing repository —
  # and the default workspace lives under a checkout of this very project, whose
  # .git holds a spar-hook-live written by an unrelated session. That would
  # confirm item 2 from a marker no harness run ever produced.
  require_real_dir "$repo/.git"
  [ -d "$repo/.git" ] || {
    echo "error: $repo has no .git of its own; git would resolve to an enclosing repository" >&2
    exit 3; }
  gitdir="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)"
  case "$gitdir" in "") gitdir="$repo/.git" ;; /*) ;; *) gitdir="$repo/$gitdir" ;; esac
  require_real_dir "$gitdir"
  # Belt to that brace: whatever git reports must land inside the workspace, and
  # the workspace must be the top of it, not a subdirectory of something larger.
  repo_real="$(cd "$repo" 2>/dev/null && pwd -P)" || repo_real=""
  gitdir_real="$(cd "$gitdir" 2>/dev/null && pwd -P)" || gitdir_real=""
  top_real="$(cd "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && pwd -P)" \
    || top_real=""
  { [ -n "$repo_real" ] && [ -n "$gitdir_real" ]; } \
    || { echo "error: could not resolve the scratch repository under $want" >&2; exit 3; }
  case "$gitdir_real/" in
    "$repo_real"/*) ;;
    *) echo "error: the git directory for $repo resolves outside it ($gitdir_real)" >&2; exit 3 ;;
  esac
  [ "$top_real" = "$repo_real" ] || {
    echo "error: $repo is not the top of its own git repository (top is ${top_real:-unknown})" >&2
    exit 3; }
  require_real_dir "$repo/.claude"
  require_real_dir "$repo/reviews"
  marker="$gitdir/spar-hook-live"
  seen=""
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    reject_unless_regular "$marker" && seen="$(head -1 "$marker")"
  fi

  state="$repo/.claude/spar.local.md"
  owner=""
  if [ -e "$state" ] || [ -L "$state" ]; then
    reject_unless_regular "$state" \
      && owner="$(sed -n 's/^owner_session: *//p' "$state" | head -1)"
  fi
  # Any round artifact proves activation happened; the outcome file and the
  # report are written at terminal paths, the round files during the loop.
  ran=""
  for cand in "$repo"/reviews/spar-*-r[0-9]*.md "$repo"/reviews/spar-*-outcome.md; do
    [ -e "$cand" ] || [ -L "$cand" ] || continue     # unmatched glob
    reject_unless_regular "$cand" && ran="$cand"
  done

  rpt=""
  for cand in "$repo"/reviews/spar-*-report.md; do
    [ -e "$cand" ] || [ -L "$cand" ] || continue
    reject_unless_regular "$cand" && rpt="$cand"
  done

  # The plan path's artifacts, discovered here rather than at item 5 so a planted
  # one lands in the IGNORED EVIDENCE block printed just below. Noting it after
  # that block has already printed is a note nobody reads.
  #
  # The result is the one the STATE names, not whichever spar-plan-*.md sorts last.
  # More than one is expected — item 5 tells the human to cancel and re-run
  # spar-ready when the first review comes back CLEAN, and spar-cancel keeps the
  # results — so picking by glob would let a stale review from an abandoned attempt
  # vouch for the plan that actually ran, including one started with
  # --no-plan-review.
  plan_state=""
  for cand in "$repo/.claude/spar-plan.local.md"; do
    [ -e "$cand" ] || [ -L "$cand" ] || continue
    reject_unless_regular "$cand" && plan_state="$cand"
  done
  plan_rid=""
  if [ -n "$plan_state" ]; then
    plan_rid="$(sed -n 's/^plan_review_id: *//p' "$plan_state" | head -1)"
    # Interpolated into a path, so validated like every other id in this codebase.
    printf '%s' "$plan_rid" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' || plan_rid=""
  fi
  # Every candidate is validated, whether or not a state names it: tamper
  # reporting must not depend on the state existing, and a result on disk is
  # itself evidence the plan review ran.
  # One pass decides both: whether any usable result exists at all, and whether
  # the one the state NAMES is among them. Selecting the named file separately
  # afterwards would need a second existence test, and a `[ -f ]` there follows a
  # symlink — handing item 5 a file this loop had just reported as ignored. Picking
  # it inside the loop means the named result is only ever the validated one.
  plan_any=""
  plan_res=""
  for cand in "$repo"/reviews/spar-plan-*.md; do
    [ -e "$cand" ] || [ -L "$cand" ] || continue
    case "$cand" in *-response.md|*.invalid-*) continue ;; esac
    reject_unless_regular "$cand" || continue
    plan_any="$cand"
    # Not "the last candidate the glob returned": the state may name an earlier
    # one, and a run that produced two results is the documented path.
    [ -n "$plan_rid" ] && case "$cand" in
      */"spar-plan-${plan_rid}.md") plan_res="$cand" ;;
    esac
  done

  # Said once, before any verdict, so a planted artifact is visible up front
  # rather than buried under whichever item happened to look for it.
  [ -n "$ignored" ] && printf 'IGNORED EVIDENCE (not regular files):\n%s\n' "$ignored"

  # Item 1 — the trust path. The artifact settles "accepted". It cannot separate
  # "never prompted" from "declined", which is why the checklist asks for that.
  if [ "$trusted" = 1 ]; then
    say 1 "CONFIRMED" \
      "$cfg records a trusted_hash for this workspace's hooks.json — the prompt appeared and you accepted it"
  elif [ -n "$trust_note" ]; then
    say 1 "NEEDS YOUR ANSWER" \
      "the trust record could not be read${trust_note} — were you asked to trust the hooks, and did you accept?"
  elif [ -n "$seen" ]; then
    say 1 "FAILED" \
      "a liveness marker exists but $cfg records no trusted_hash — the hooks ran without the trust path this gate exists to exercise"
    failed=1
  else
    say 1 "NEEDS YOUR ANSWER" \
      "no trusted_hash for this workspace in $cfg and no liveness marker — either no session ran, or you were never asked, or you declined; which was it?"
  fi

  # Item 2 — the user-scope registration firing for a project with no .codex/ of
  # its own. Trust granted with nothing fired is what separates scope from trust.
  if [ -n "$seen" ]; then
    say 2 "CONFIRMED" \
      "the user-scope registration fired for $repo, which has no .codex/ of its own — marker names $seen"
  elif [ "$trusted" = 1 ]; then
    say 2 "FAILED" \
      "trust was granted but no liveness marker appeared under $repo — user scope did not fire for this directory"
    failed=1
  else
    say 2 "NEEDS YOUR ANSWER" "nothing ran, so scope was never exercised"
  fi

  # Item 3 — SessionStart ordering. The marker must name the session the loop
  # recorded as its owner; a mismatch means activation read a stale one.
  # The loop state is NOT durable — cleanup() deletes it on every terminal path —
  # so it cannot be what settles this after a finished run. What is durable, and
  # is actually stronger, is that the run happened: the Codex spar-fight skill
  # refuses to activate unless the marker names the session running right then
  # (skills/spar-fight/SKILL.md), so any round artifact is proof that the gate was
  # passed, and therefore that SessionStart fired before the skill's first action.
  # owner_session is still compared when the state file is present, which is the
  # case if check runs mid-loop rather than after it.
  if [ -n "$owner" ] && [ -n "$seen" ] && [ "$owner" != "$seen" ]; then
    say 3 "FAILED" \
      "marker names $seen but the live loop state records owner_session $owner — activation did not read this session's marker"
    failed=1
  elif [ -n "$owner" ] && [ "$owner" = "$seen" ]; then
    # Mid-run, before the first round file exists. The loop only writes
    # owner_session after spar-fight's marker gate has passed, so a state file
    # agreeing with the marker is the same proof a round artifact would be —
    # and without this branch the run falls through to "nothing activated",
    # which the state file sitting there disproves.
    say 3 "CONFIRMED" \
      "the live loop state records owner_session $owner, matching the marker — spar-fight writes that field only after its marker gate, so SessionStart fired before activation"
  elif [ -n "$ran" ]; then
    say 3 "CONFIRMED" \
      "$(basename "$ran") exists, so spar-fight activated — and it refuses to start unless the marker names the current session, so SessionStart fired before its first action"
  elif [ -n "$seen" ]; then
    say 3 "NEEDS YOUR ANSWER" \
      "a marker names $seen but no round artifact exists — the hook ran and nothing activated; did spar-fight refuse, and what did it say?"
  else
    say 3 "NEEDS YOUR ANSWER" \
      "no liveness marker and no round artifact, so ordering was never exercised"
  fi

  # Item 4 — the planted bug reaching CONVERGED. Only a terminal path writes a
  # report, so its absence means the loop never finished rather than that it lost.
  if [ -z "$rpt" ]; then
    say 4 "NEEDS YOUR ANSWER" \
      "no run report under $repo/reviews — the loop never reached a terminal path"
  else
    outcome="$(sed -n 's/^- outcome: *//p' "$rpt" | head -1)"
    pairing="$(sed -n 's/^- reviewer: *//p' "$rpt" | head -1)"
    rounds="$(sed -n 's/^- rounds: *//p' "$rpt" | head -1)"
    raised="$(sed -n 's/^- raised: *//p' "$rpt" | head -1)"
    # Converging is not the whole item. This seat exists so that Codex authors and
    # claude -p reviews; a same-model run converging proves the machinery turns,
    # not the thing Phase 6 claims. A real session degraded to codex-reviews-codex
    # without anyone noticing, and this check counted it as a pass — so the
    # pairing is now part of the verdict rather than a detail in the report.
    if [ "$outcome" != converged ]; then
      say 4 "FAILED" "$(basename "$rpt") records outcome: ${outcome:-unreadable}, not converged"
      failed=1
    elif ! printf '%s' "$pairing" | grep -qF cross-model; then
      say 4 "FAILED" "$(basename "$rpt") converged, but the pairing was '${pairing:-unrecorded}' — this gate is about Codex authoring and claude -p reviewing, and a same-model run does not exercise it"
      failed=1
    else
      say 4 "CONFIRMED" "$(basename "$rpt") records outcome: converged with $pairing${rounds:+, $rounds round(s)}${raised:+, raised $raised}"
    fi
    # Stated, not scored: a first-round convergence is a legitimate result, but it
    # means the FINDINGS -> fix -> blind re-review path never ran, so the gate's
    # own wording is only partly demonstrated.
    case "$raised" in
      0*) printf '  note: no findings were raised, so the debate path (FINDINGS then a re-review) was not exercised by this run.\n\n' ;;
    esac
  fi

  # Item 5 — the plan path. Phase 9's gate lives here and items 1-4 never touch
  # it. Three artifacts carry what can be judged: the review result, its marker,
  # and the stamps only this seat's activation writes into the plan state.
  #
  # Absence is not automatically a failure. check is documented to run before a
  # session as well as after, and a bare absence cannot tell "the human skipped
  # item 5" from "no session ran at all" — so it only fails when other durable
  # evidence shows the run happened. Same rule item 3 follows.
  if [ -n "$plan_any" ] && [ -z "$plan_state" ]; then
    # A review was produced and no plan state remains to say the plan was ever
    # activated through this seat. spar-cancel leaves exactly this — it keeps the
    # review and deletes the state — so the checklist warns about it, but it is
    # still an item that was not carried through.
    say 5 "FAILED" \
      "$(basename "$plan_any") exists but there is no plan state, so nothing shows the plan was activated through this seat — spar-cancel leaves this shape"
    failed=1
  elif [ -z "$plan_res" ] && [ -z "$plan_state" ]; then
    # The same evidence item 3 uses: a round artifact, a report, or a loop state
    # whose owner_session matches the marker. Any of them means the run got as far
    # as activating, and a run that activated without going through spar-ready
    # skipped this item.
    #
    # This treats a session still part-way through item 4 as a failure too, since
    # item 5 comes after item 4. That is deliberate and it is the specified
    # behaviour: check is documented to be run when the session is over, so a
    # mid-run reading is off-label, and "item 5 is not done" is true there. See
    # the plan's note on the alternative that was considered.
    if [ -n "$ran" ] || [ -n "$rpt" ] \
      || { [ -n "$owner" ] && [ "$owner" = "$seen" ]; }; then
      say 5 "FAILED" \
        "the live run happened but left no plan-path artifacts under $repo — spar-ready and its plan review were never exercised"
      failed=1
    else
      say 5 "NEEDS YOUR ANSWER" \
        "no plan-path artifacts and no sign of a run — did you get to item 5?"
    fi
  elif [ -z "$plan_res" ]; then
    if [ -z "$plan_rid" ]; then
      say 5 "FAILED" \
        "a plan state exists but carries no usable plan_review_id, so nothing names the review that gated it"
    else
      say 5 "FAILED" \
        "the plan state names plan_review_id $plan_rid but reviews/spar-plan-${plan_rid}.md is not there — this plan was activated without the review it claims"
    fi
    failed=1
  else
    plan_marker="$(head -1 "$plan_res" | tr -d '\r')"
    plan_author="$(sed -n 's/^author: *//p' "${plan_state:-/dev/null}" | head -1)"
    plan_owner="$(sed -n 's/^owner_session: *//p' "${plan_state:-/dev/null}" | head -1)"
    case "$plan_marker" in
      "PLAN-REVIEW: CLEAN"|"PLAN-REVIEW: FINDINGS") plan_ok=1 ;;
      *) plan_ok=0 ;;
    esac
    if [ "$plan_ok" -eq 0 ]; then
      say 5 "FAILED" \
        "$(basename "$plan_res") does not start with a PLAN-REVIEW marker (found: ${plan_marker:-empty}) — the loop's own STATUS: marker must never be mistaken for this pass's"
      failed=1
    elif [ "$plan_author" != codex ] || [ -z "$plan_owner" ]; then
      say 5 "FAILED" \
        "$(basename "$plan_res") is a valid plan review, but the plan state records author: ${plan_author:-none} and owner_session: ${plan_owner:-none} — activation through this seat writes both, so without them nothing shows the Codex seat activated the plan"
      failed=1
    else
      say 5 "CONFIRMED" \
        "$(basename "$plan_res") holds $plan_marker and the plan state records author: codex, owner_session: $plan_owner — spar-ready produced a review and this seat activated the plan. NOTE: no artifact records a refusal, so whether spar-fight actually gated before the disposition is item 5's part (a), yours to answer."
    fi
  fi
  exit "$failed"
fi

# ── setup ────────────────────────────────────────────────────────────────────
if [ "$cmd" = setup ]; then
  # Rebuilt from scratch every time, so a second run is a clean slate rather than
  # a merge with whatever the last one left. That is only safe because the marker
  # proves the directory is ours before anything is removed.
  # Same -e blind spot, and here it is destructive: a dangling symlink would skip
  # the ownership guard entirely, and the rm -rf below would delete the user's
  # link and put a workspace in its place. An entry we did not write is refused
  # whether or not it resolves to anything.
  if { [ -e "$want" ] || [ -L "$want" ]; } && ! is_ours "$want"; then
    echo "error: $want already exists and is not a harness workspace; refusing to overwrite it" >&2
    exit 3
  fi
  rm -rf "$want" || exit 3
  mkdir -p "$want/home" "$want/repo" || exit 3
  printf '%s\n' "$MARKER_TEXT" > "$want/$MARKER_NAME" || exit 3

  # Scratch repository with a planted bug. Off-by-one, small enough that a review
  # cannot miss it and a fix cannot be mistaken for a rewrite.
  cat > "$want/repo/sum_to.py" <<'PY' || exit 3
def sum_to(n):
    """Return the sum of every integer from 1 to n inclusive."""
    total = 0
    for i in range(1, n):
        total += i
    return total
PY
  cat > "$want/repo/TASK.md" <<'TASK' || exit 3
Fix `sum_to` so it returns the sum of every integer from 1 to n INCLUSIVE, and
add a test that would fail against the current implementation.
TASK
  git -C "$want/repo" init -q || exit 3
  git -C "$want/repo" add -A || exit 3
  git -C "$want/repo" -c user.email=harness@local -c user.name=harness \
    commit -qm "planted: sum_to is off by one" || exit 3

  CODEX_HOME="$want/home" HOME="$want/home" \
    bash "$REPO_ROOT/adapters/codex/install.sh" --scope user >/dev/null || exit 3

  # Written with a quoted heredoc and the two paths substituted afterwards: the
  # checklist is prose the human reads, and an unquoted heredoc would let a stray
  # backtick or $ in it run as shell.
  cat > "$want/checklist.md" <<'CHECK' || exit 3
# Phase 6 live verification — your part

Everything below needs a real interactive Codex session.

BEFORE YOU START — two things the isolated home does not inherit, both learned
the hard way on the first real run:

@@PRESTART@@
Then:

    cd @@REPOQ@@
    CODEX_HOME=@@HOMEQ@@ codex

Nothing here touches your real Codex configuration.

1. TRUST PATH. On the first turn Codex should ask you to trust sparring's hooks.
   Accept.
   WRITE DOWN: (a) were you asked at all? (b) what did the prompt say, word for
   word or close to it?
   Why both: if no trust record turns up afterwards, the artifacts cannot tell
   "never prompted" from "prompted and declined" — only you can. And the wording
   is what a new user has to understand, which nothing automated can judge.

2. HOOK SCOPE. The hooks above are installed at USER scope, inside the isolated
   home. Start the session in @@WS@@/repo, which has no .codex/ of its own.
   WRITE DOWN: did the hooks fire for this directory? Anything Codex printed
   about them?
   The check step can tell trust apart from scope afterwards — a trusted
   registration that left no liveness marker means user scope did not fire here
   — but your observation is the cross-check on that inference, not a duplicate
   of it.

3. SESSIONSTART ORDERING. Immediately, before anything else, run the spar-fight
   skill. If SessionStart fired first, activation succeeds; if it did not, the
   skill refuses with "sparring's SessionStart hook left no liveness marker".
   Write down which happened. This is the one that decides whether the liveness
   marker can gate activation at all.

4. END TO END. Give spar-fight the task in TASK.md and let the loop run to a
   verdict. Do not fix anything by hand. Expect FINDINGS on the off-by-one, then
   a fix, then a blind re-review, then CONVERGED.

5. THE PLAN PATH — THE GATE REFUSING IS THE WHOLE ITEM. Items 1-4 all give
   spar-fight a task, which is the single-task path. Phase 9 added an independent
   review of the plan itself, and none of it is touched above.

   THE ONE THING TO OBSERVE: run spar-fight while a plan review has findings and
   NO disposition has been written, and watch it refuse.
   WRITE DOWN: (a) did spar-fight refuse? (b) did the refusal name spar-fight and
   spar-cancel, or /spar:fight and /spar:cancel — the Claude spellings, which do
   not exist in this session?
   Nothing else in this item is the test. An earlier version of this checklist put
   the setup first and a real run stopped at the setup and reported back, so the
   observation was never made — which is why it is stated before the steps that
   produce it.
   Why you and not the check step: nothing durable records that a refusal
   happened, so the artifacts afterwards look identical whether it refused or
   never gated at all. (b) is the defect 0.9.1 fixed.

   To reach that state, in the same session:

   5a. spar-ready make sum_to reject a non-integer n, with a test
       Expect the setup output to say plan-review=required.

   5b. The moment reviews/spar-plan-<id>.md appears, INTERRUPT the skill — before
       it writes .claude/spar-plan-review-response.md. It answers its own findings
       and then stops, so once it returns nothing is outstanding and there is
       nothing to refuse. This is a prerequisite, not the finish line: after
       interrupting, go run spar-fight. That is (a) and (b) above.

   5c. Then let the skill finish, or write the disposition yourself, and run
       spar-fight again — it should start, and the plan state should gain
       author: codex and an owner_session.

   IF THE REVIEW CAME BACK CLEAN there is no finding to leave outstanding, and the
   gate correctly does not refuse. Say so and move on — or, to exercise the
   refusal anyway: run spar-cancel FIRST, because spar-ready refuses while a plan
   is ready or a loop is active, and by this point you have both. Then spar-ready
   again on a change whose plan you expect to draw a finding (a test that cannot
   fail is the reliable one). The earlier CLEAN result stays under reviews/ and
   check reads the later id, so it does not interfere.
   Do NOT hand-edit the review to manufacture a finding: the author must never
   write reviewer output, and check reads a planted artifact as tampering.

   If you cancel and stop there without re-activating, expect item 5 to report
   FAILED — spar-cancel keeps the review but deletes the plan state, so its stamps
   are gone. That verdict is correct for the artifacts, not a bug.

6. SPEC VERIFICATION. Run spar-ready twice with a small spec: once with
   --verify-spec, and once with --unattended --verify-spec. In both runs, the
   setup output should say spec-verify=required, verification should happen
   before any new spar/<slug>-<timestamp> branch is created, and durable
   reviews/spar-spec-verify-<id>-claude.md plus
   reviews/spar-spec-verify-<id>-codex.md should appear. If the verifier blocks,
   the plan state should not exist yet. If it passes, the generated plan should
   cite .claude/spar-spec-verify.md before ordinary plan review runs.

When the session is over:

    bash @@SELFQ@@ check --dir @@WSQ@@

CHECK
  # Two kinds of substitution, deliberately. Prose gets the bare path because it
  # is read, not run. Anything the human is meant to TYPE is shell-quoted: a
  # workspace under a directory with a space would otherwise produce commands
  # that do not work, and one containing $(...) would produce commands that do
  # something else entirely.
  WS="$want" RT="$REPO_ROOT" \
  REAL_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" CLAUDE_PATH="$(command -v claude || true)" \
  python3 - "$want/checklist.md" <<'PY' || exit 3
import os, re, shlex, sys
ws, rt = os.environ["WS"], os.environ["RT"]
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
# Two things the isolated home starts without. Both stopped a real run: no
# credentials means the login screen appears before item 1, and no claude on
# PATH means the cross-model default degrades to codex-reviews-codex, which is
# the one outcome this gate must not accept. The text is generated from what is
# actually true on this machine rather than left as advice.
auth = os.path.join(os.environ.get("REAL_CODEX_HOME", ""), "auth.json")
claude = os.environ.get("CLAUDE_PATH", "")
pre = []
if os.path.exists(auth):
    pre.append("1. CREDENTIALS. The isolated home has none, so Codex would ask you to log in\n"
               "   before you reach item 1. Either copy yours in:\n\n"
               "       cp %s %s\n\n"
               "   or log in inside the isolated session — it stays in that home either way."
               % (shlex.quote(auth), shlex.quote(os.path.join(ws, "home"))))
else:
    pre.append("1. CREDENTIALS. The isolated home has none and no auth.json was found to copy,\n"
               "   so log in inside the isolated session. It stays in that home.")
if claude:
    pre.append("2. CROSS-MODEL REVIEW. This seat is Codex authoring and claude reviewing, but a\n"
               "   non-interactive shell does not have claude on PATH, and the skill falls back\n"
               "   to codex-reviews-codex — which does NOT satisfy item 4. Start the session with\n"
               "   claude reachable:\n\n"
               "       PATH=%s:$PATH CODEX_HOME=%s codex\n\n"
               "   or pass --reviewer claude to spar-fight so it fails loudly instead of degrading."
               % (shlex.quote(os.path.dirname(claude)), shlex.quote(os.path.join(ws, "home"))))
else:
    pre.append("2. CROSS-MODEL REVIEW. claude was not found on this machine at all. Item 4 needs\n"
               "   Codex authoring and claude reviewing, so install it first — otherwise the run\n"
               "   can only be codex-reviews-codex, which this gate does not accept.")

values = {
    "@@PRESTART@@": "\n\n".join(pre) + "\n",
    "@@REPOQ@@": shlex.quote(os.path.join(ws, "repo")),
    "@@HOMEQ@@": shlex.quote(os.path.join(ws, "home")),
    "@@SELFQ@@": shlex.quote(os.path.join(rt, "adapters", "codex", "verify-live.sh")),
    "@@WSQ@@": shlex.quote(ws),
    "@@WS@@": ws,
}
# Validate the TEMPLATE, then substitute in ONE pass. Both halves matter and both
# are about the same thing: the workspace path is user-controlled, so it must
# never be treated as template. Scanning the rendered text for a leftover "@@"
# would reject a perfectly good path like /tmp/project@@copy, and substituting
# key by key would let a path containing the literal text of a later placeholder
# be rewritten by that later pass. A single re.sub inserts values without ever
# rescanning what it inserted.
unknown = sorted(set(re.findall(r"@@[A-Z]+@@", t)) - set(values))
if unknown:
    sys.stderr.write("error: unknown placeholder(s) in the checklist template: %s\n"
                     % ", ".join(unknown))
    sys.exit(3)
t = re.sub(r"@@[A-Z]+@@", lambda m: values[m.group(0)], t)
open(p, "w", encoding="utf-8").write(t)
PY
  # The printed checklist IS the deliverable of setup — a run that wrote it but
  # could not show it has not done its job, and saying nothing while exiting 0
  # would leave the user believing they saw everything there was.
  cat "$want/checklist.md" \
    || { echo "error: could not print the checklist (it is saved at $want/checklist.md)" >&2; exit 3; }
  exit 0
fi
