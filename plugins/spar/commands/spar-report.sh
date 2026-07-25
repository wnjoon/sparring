#!/usr/bin/env bash
# Assemble the final report for one sparring run: reviews/spar-<id>-report.md.
# Deterministic and read-only apart from the report it publishes. Best-effort by
# contract — every caller (the stop-hook terminal paths) ignores failures, so a
# broken report can never change a loop outcome or trap a session.
# Usage: spar-report.sh <review-id> <base-sha> [reviews-dir] [state-dir]
# Exit: 0 report written; 2 usage / invalid id; 3 unsafe path or I/O failure.
set -uo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "usage: spar-report.sh <review-id> <base-sha> [reviews-dir] [state-dir]" >&2
  exit 2
fi
review_id="${1-}"; base="${2-}"; rev_dir="${3:-reviews}"; state_dir="${4:-.claude}"
# Normalize relative paths beginning with '-' so no downstream command mistakes
# a path such as "-n" for an option. Absolute paths never start with '-'.
case "$rev_dir" in -*) rev_dir="./$rev_dir" ;; esac
case "$state_dir" in -*) state_dir="./$state_dir" ;; esac

# The reviews directory is the only path written to, and a `..` component makes
# the symlink guard unsound: in `missing/../link/new` the checks cannot resolve
# `missing/..` before `mkdir -p` creates it, so the walk misses `link` and the
# directory is created through it. Reject `..` outright instead — nothing needs
# it (the hook passes plain `reviews`), and no partial creation can precede the
# rejection. The state directory is read-only, so it may still contain `..`.
case "/${rev_dir}/" in
  */../*) echo "error: reviews-dir must not contain a '..' component: $rev_dir" >&2; exit 3 ;;
esac

# The id is interpolated into a path, so validate it strictly (no traversal).
printf '%s' "$review_id" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' \
  || { echo "error: invalid review id: $review_id" >&2; exit 2; }
# An unusable baseline degrades to a soft note; it is never fatal.
printf '%s' "$base" | grep -qE '^([0-9a-f]{7,40}|none|HEAD)$' || base=none

STATE="${state_dir}/spar.local.md"
LEDGER="${state_dir}/spar-ledger.md"
REGISTRY="${state_dir}/spar-registry.tsv"
OUTCOME="${rev_dir}/spar-${review_id}-outcome.md"
SWEEP="${rev_dir}/spar-${review_id}-sweep.md"
REPORT="${rev_dir}/spar-${review_id}-report.md"

# First "key: value" line of a file; empty when the file is absent.
field() { # $1=key $2=file
  [ -f "$2" ] || return 0
  sed -n "s/^${1}: *//p" "$2" 2>/dev/null | head -1
}

# Reject a symlink at the report path or at ANY existing ancestor directory —
# writing through a symlinked parent (even a deep one) is unsafe.
reject_unsafe_path() {
  [ -L "$REPORT" ] && { echo "error: report path is a symlink" >&2; exit 3; }
  local anc="$REPORT"
  while :; do
    anc=$(dirname "$anc")
    { [ "$anc" = "." ] || [ "$anc" = "/" ]; } && break
    [ -L "$anc" ] && { echo "error: symlinked ancestor: $anc" >&2; exit 3; }
  done
  [ -e "$REPORT" ] && [ ! -f "$REPORT" ] \
    && { echo "error: report path is not a regular file" >&2; exit 3; }
  return 0
}

# Validate BEFORE creating anything: `mkdir -p` on a path whose ancestor is a
# symlink would create a directory through that link before the rejection, which
# would write outside the intended scope. Re-validate after the mkdir, because
# it may have created the parent the first walk could not inspect.
reject_unsafe_path
mkdir -p "$rev_dir" || exit 3
reject_unsafe_path

# ── result header ───────────────────────────────────────────────────────────
# The outcome file is authoritative (record_outcome always runs first at every
# terminal path); the live state file is the fallback while it is still present.
reason=$(field reason "$OUTCOME"); [ -n "$reason" ] || reason=unknown
rounds=$(field rounds "$OUTCOME"); [ -n "$rounds" ] || rounds=$(field round "$STATE")
case "$rounds" in ''|*[!0-9]*) rounds=0 ;; esac
reviewer=$(field reviewer "$OUTCOME")
[ -n "$reviewer" ] || reviewer=$(field reviewer "$STATE")
case "$reviewer" in
  codex)  pairing="cross-model (claude author ↔ codex reviewer)" ;;
  claude) pairing="same-model (claude author ↔ claude reviewer)" ;;
  *)      reviewer=unknown; pairing="unknown pairing" ;;
esac
sweep=$(field sweep "$OUTCOME"); [ -n "$sweep" ] || sweep=$(field sweep_result "$STATE")
case "$sweep" in not-run|not-triggered|pending|clean|findings|error) ;; *) sweep=not-run ;; esac

# ── change surface ──────────────────────────────────────────────────────────
changed_files() {
  command -v git >/dev/null 2>&1 || { echo "(git unavailable)"; return 0; }
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "(not a git repository)"; return 0; }
  if [ "$base" != none ] && git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1
  then
    git diff --stat "$base" 2>/dev/null || echo "(diff unavailable)"
  else
    echo "(no usable baseline: ${base})"
  fi
}

# Directory prefixes holding the loop's own artifacts — the resolved reviews and
# state directories plus the defaults. Filtering the resolved ones (not just the
# literals) keeps a custom `reviews-dir` / `state-dir` out of the change surface,
# including this report's own temp file, which still exists while the report is
# being assembled. `git ls-files` prints paths relative to the cwd, and both
# directory arguments are interpreted relative to the same cwd.
# An existing directory is canonicalized with `pwd -P` and re-expressed relative
# to the cwd, so an absolute path, a symlinked path, or one containing `..` still
# matches what `git ls-files` prints. A directory outside the cwd tree has nothing
# in the listing, and the cwd itself has no usable prefix — that case is handled
# by CWD_ARTIFACTS below. A not-yet-created relative directory falls back to a
# lexical form.
dir_prefix() { # $1=dir → "some/dir/" or nothing
  local d="$1" real cwd
  if real=$(cd "$d" 2>/dev/null && pwd -P); then
    cwd=$(pwd -P)
    case "$real" in
      "$cwd") return 0 ;;
      "$cwd"/*) printf '%s/' "${real#"$cwd"/}"; return 0 ;;
      *) return 0 ;;
    esac
  fi
  d="${d%/}"; d="${d#./}"
  case "$d" in /*) return 0 ;; esac
  [ -n "$d" ] && printf '%s/' "$d"
  return 0
}
dir_is_cwd() { # $1=dir
  local real; real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  [ "$real" = "$(pwd -P)" ]
}
PREFIX_REV=$(dir_prefix "$rev_dir")
PREFIX_STATE=$(dir_prefix "$state_dir")
# With `reviews-dir` / `state-dir` set to the working directory itself there is no
# prefix to match on, so the loop's artifacts sit next to real project files. Skip
# them by name instead. The two directories are tracked separately: review-artifact
# names are only skipped when the REVIEWS dir is the cwd, and the fixed state
# filenames only when the STATE dir is the cwd — otherwise a mixed configuration
# (say `reviews-dir=myrev`, `state-dir=.`) would hide a legitimate project file
# that happens to match the other group's names.
CWD_REV=false; CWD_STATE=false
if dir_is_cwd "$rev_dir"; then CWD_REV=true; fi
if dir_is_cwd "$state_dir"; then CWD_STATE=true; fi

# New files never appear in `git diff --stat`, and a run's whole deliverable is
# often new files — list them so the change surface is not silently understated.
# Matching is a quoted `case` prefix test (every character literal, and BWK awk
# rejects newline-separated -v values, so this stays pure bash).
untracked_files() {
  command -v git >/dev/null 2>&1 || return 0
  local p pre skip
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    skip=0
    if [ "$CWD_REV" = true ]; then
      # Enumerate the actual artifact filenames rather than a blanket
      # "spar-<id>-*": at the top level that prefix would also hide a real
      # project file such as spar-<id>-helper.py. The trailing * on the .md
      # names covers the ".invalid-<n>" files the hook sets aside.
      case "$p" in
        "spar-${review_id}-r"[0-9]*) skip=1 ;;
        "spar-${review_id}-outcome.md"*) skip=1 ;;
        "spar-${review_id}-report.md"*) skip=1 ;;
        "spar-${review_id}-sweep.md"*) skip=1 ;;
        "spar-${review_id}-sweep-response.md"*) skip=1 ;;
        "spar-${review_id}-judge-"[0-9]*) skip=1 ;;
        "spar-${review_id}-matcher-r"[0-9]*) skip=1 ;;
        ".spar-report-${review_id}."*) skip=1 ;;
        spar-pending.md) skip=1 ;;
      esac
    fi
    if [ "$CWD_STATE" = true ]; then
      case "$p" in
        spar.local.md|spar-ledger.md|spar-registry.tsv) skip=1 ;;
      esac
    fi
    [ "$skip" = 1 ] && continue
    for pre in "$PREFIX_REV" "$PREFIX_STATE" "reviews/" ".claude/"; do
      [ -n "$pre" ] || continue
      case "$p" in "$pre"*) skip=1; break ;; esac
    done
    [ "$skip" = 1 ] || printf -- '- %s\n' "$p"
  done < <(git ls-files --others --exclude-standard 2>/dev/null)
}

# ── publish ─────────────────────────────────────────────────────────────────
tmp=$(mktemp "${rev_dir}/.spar-report-${review_id}.XXXXXX") || exit 3
trap 'rm -f "$tmp"' EXIT
{
  echo "# sparring run report — ${review_id}"
  echo
  echo "## Result"
  echo
  echo "- outcome: ${reason}"
  echo "- rounds: ${rounds}"
  echo "- reviewer: ${reviewer} — ${pairing}"
  echo "- sweep: ${sweep}"
  echo "- base_sha: ${base}"
  echo "- generated_at: $(date -u +%FT%TZ)"
  echo
  echo "## Changed files"
  echo
  echo '```text'
  changed_files
  echo '```'
  u=$(untracked_files)
  if [ -n "$u" ]; then
    echo
    echo "Untracked (new) files:"
    echo
    printf '%s\n' "$u"
  fi
} > "$tmp" || exit 3

# Re-validate immediately before the rename: the destination could have been
# swapped to a symlink while the report was being assembled.
reject_unsafe_path
mv "$tmp" "$REPORT" || exit 3
trap - EXIT
exit 0
