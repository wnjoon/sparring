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
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$PWD/${1#./}" ;; esac; }
want="$(abs "$dir")"; real="$(abs "$real_home")"
case "$want/" in
  "$real"/*|"$real"/)
    echo "error: refusing to use $want — it is inside the real CODEX_HOME ($real)" >&2
    exit 3 ;;
esac

is_ours() { [ -f "$1/$MARKER_NAME" ] && grep -qxF "$MARKER_TEXT" "$1/$MARKER_NAME" 2>/dev/null; }

# ── clean ────────────────────────────────────────────────────────────────────
if [ "$cmd" = clean ]; then
  [ -e "$want" ] || { echo "nothing to clean at $want"; exit 0; }
  is_ours "$want" \
    || { echo "error: $want is not a harness workspace; refusing to remove it" >&2; exit 3; }
  rm -rf "$want" && echo "removed $want"
  exit 0
fi

# ── setup ────────────────────────────────────────────────────────────────────
if [ "$cmd" = setup ]; then
  # Rebuilt from scratch every time, so a second run is a clean slate rather than
  # a merge with whatever the last one left. That is only safe because the marker
  # proves the directory is ours before anything is removed.
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
  git -C "$want/repo" init -q || exit 3
  git -C "$want/repo" add -A || exit 3
  git -C "$want/repo" -c user.email=harness@local -c user.name=harness \
    commit -qm "planted: sum_to is off by one" || exit 3

  CODEX_HOME="$want/home" HOME="$want/home" \
    bash "$REPO_ROOT/adapters/codex/install.sh" --scope user >/dev/null || exit 3

  # Written with a quoted heredoc and the two paths substituted afterwards: the
  # checklist is prose the human reads, and an unquoted heredoc would let a stray
  # backtick or $ in it run as shell.
  cat > "$want/checklist.md" <<'CHECK'
# Phase 6 live verification — your part

Everything below needs a real interactive Codex session. Run it from:

    cd @@WS@@/repo
    CODEX_HOME=@@WS@@/home codex

Nothing here touches your real Codex configuration.

1. TRUST PATH. On the first turn Codex should ask you to trust sparring's hooks.
   Accept. The check step reads that decision back out of the isolated
   config.toml, so you do not have to report it — but do write down what the
   prompt actually said, since the wording is what a new user has to understand.

2. HOOK SCOPE. The hooks above are installed at USER scope, inside the isolated
   home. Start the session in @@WS@@/repo, which has no .codex/ of its own. The
   check step tells trust apart from scope: a trusted registration that left no
   liveness marker means user scope did not fire here.

3. SESSIONSTART ORDERING. Immediately, before anything else, run the spar-fight
   skill. If SessionStart fired first, activation succeeds; if it did not, the
   skill refuses with "sparring's SessionStart hook left no liveness marker".
   Write down which happened. This is the one that decides whether the liveness
   marker can gate activation at all.

4. END TO END. Give spar-fight the task in TASK.md and let the loop run to a
   verdict. Do not fix anything by hand. Expect FINDINGS on the off-by-one, then
   a fix, then a blind re-review, then CONVERGED.

When the session is over:

    bash @@ROOT@@/adapters/codex/verify-live.sh check --dir @@WS@@

CHECK
  WS="$want" RT="$REPO_ROOT" python3 - "$want/checklist.md" <<'PY' || exit 3
import os, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("@@WS@@", os.environ["WS"]).replace("@@ROOT@@", os.environ["RT"])
open(p, "w", encoding="utf-8").write(t)
PY
  cat "$want/checklist.md"
  exit 0
fi
