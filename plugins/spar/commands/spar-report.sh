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

# New files never appear in `git diff --stat`, and a run's whole deliverable is
# often new files — list them so the change surface is not silently understated.
# reviews/ and .claude/ are filtered explicitly: they hold the loop's own
# artifacts (including this report's temp file), and relying on the repo's
# .git/info/exclude entries would leak them wherever those are absent.
untracked_files() {
  command -v git >/dev/null 2>&1 || return 0
  git ls-files --others --exclude-standard 2>/dev/null \
    | grep -v -e '^reviews/' -e '^\.claude/' \
    | sed 's/^/- /'
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
