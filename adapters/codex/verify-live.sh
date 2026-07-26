#!/usr/bin/env bash
# Phase 6 release gate: set up an isolated Codex session a human can drive, then
# judge what can be judged from the artifacts it leaves. Accepting a hook-trust
# prompt is interactive, so this harness deliberately stops short of pretending
# to automate it — it makes the manual run cheap and repeatable instead.
# Usage: verify-live.sh setup|check|clean [--dir <path>]
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
  # config.toml, keyed by the hooks.json path and the event. Matched as a FIXED
  # string against OUR hooks.json, so a trust record belonging to some other
  # registration in the same file is not read as ours.
  cfg="$want/home/config.toml"
  trusted=0
  if [ -f "$cfg" ] && grep -qF "hooks.state.\"$want/home/hooks.json:" "$cfg" 2>/dev/null; then
    trusted=1
  fi

  gitdir="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)"
  case "$gitdir" in "") gitdir="$repo/.git" ;; /*) ;; *) gitdir="$repo/$gitdir" ;; esac
  marker="$gitdir/spar-hook-live"
  seen=""; [ -f "$marker" ] && seen="$(head -1 "$marker")"

  # Item 1 — the trust path. The artifact settles "accepted". It cannot separate
  # "never prompted" from "declined", which is why the checklist asks for that.
  if [ "$trusted" = 1 ]; then
    say 1 "CONFIRMED" \
      "$cfg records a trusted_hash for this workspace's hooks.json — the prompt appeared and you accepted it"
  elif [ -n "$seen" ]; then
    say 1 "FAILED" \
      "a liveness marker exists but $cfg records no trusted_hash — the hooks ran without the trust path this gate exists to exercise"
    failed=1
  else
    say 1 "NEEDS YOUR ANSWER" \
      "no trusted_hash in $cfg and no liveness marker — either no session ran, or you were never asked, or you declined; which was it?"
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
  owner="$(sed -n 's/^owner_session: *//p' "$repo/.claude/spar.local.md" 2>/dev/null | head -1)"
  if [ -z "$seen" ]; then
    say 3 "NEEDS YOUR ANSWER" \
      "no liveness marker, so ordering cannot be judged — did spar-fight refuse to start?"
  elif [ -n "$owner" ] && [ "$owner" != "$seen" ]; then
    say 3 "FAILED" \
      "marker names $seen but the loop recorded owner_session $owner — activation did not read this session's marker"
    failed=1
  else
    say 3 "CONFIRMED" \
      "marker names $seen${owner:+, matching the owner_session the loop recorded} — SessionStart fired before activation read it"
  fi

  # Item 4 — the planted bug reaching CONVERGED. Only a terminal path writes a
  # report, so its absence means the loop never finished rather than that it lost.
  rpt="$(ls "$repo"/reviews/spar-*-report.md 2>/dev/null | tail -1)"
  if [ -z "$rpt" ]; then
    say 4 "NEEDS YOUR ANSWER" \
      "no run report under $repo/reviews — the loop never reached a terminal path"
  else
    outcome="$(sed -n 's/^- outcome: *//p' "$rpt" | head -1)"
    if [ "$outcome" = converged ]; then
      say 4 "CONFIRMED" "$(basename "$rpt") records outcome: converged"
    else
      say 4 "FAILED" "$(basename "$rpt") records outcome: ${outcome:-unreadable}, not converged"
      failed=1
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

Everything below needs a real interactive Codex session. Run it from:

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

When the session is over:

    bash @@SELFQ@@ check --dir @@WSQ@@

CHECK
  # Two kinds of substitution, deliberately. Prose gets the bare path because it
  # is read, not run. Anything the human is meant to TYPE is shell-quoted: a
  # workspace under a directory with a space would otherwise produce commands
  # that do not work, and one containing $(...) would produce commands that do
  # something else entirely.
  WS="$want" RT="$REPO_ROOT" python3 - "$want/checklist.md" <<'PY' || exit 3
import os, re, shlex, sys
ws, rt = os.environ["WS"], os.environ["RT"]
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
values = {
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
