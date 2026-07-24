#!/usr/bin/env bash
# Append one unattended pending design decision to a durable queue that
# survives stop-hook.sh cleanup() (cleanup touches no reviews/ path). Entries
# are keyed by "## <review-id> :: <fingerprint>" so repeated runs merge and a
# duplicate key is a no-op. Regular-file-vs-symlink safe. Best-effort: the
# caller ignores failures.
# Usage: spar-queue-pending.sh <review-id> <fingerprint> <finding-text-file> [queue-file]
# Exit: 0 success or duplicate; 2 usage error; 3 unsafe path / I/O failure.
set -uo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: spar-queue-pending.sh <review-id> <fingerprint> <finding-text-file> [queue-file]" >&2
  exit 2
fi
review_id="${1-}"; fp="${2-}"; txt="${3-}"; queue="${4:-reviews/spar-pending.md}"
# Normalize relative paths that begin with '-' by prefixing './', so no
# downstream command (cat, dirname, mkdir, grep, tail, mktemp, mv) can mistake
# a path such as "-n" for an option. Absolute paths never start with '-'.
case "$txt" in -*) txt="./$txt" ;; esac
case "$queue" in -*) queue="./$queue" ;; esac
if [ -z "$review_id" ] || [ -z "$fp" ] || [ ! -f "$txt" ]; then
  echo "usage: spar-queue-pending.sh <review-id> <fingerprint> <finding-text-file> [queue-file]" >&2
  exit 2
fi

# Reject a symlink at the queue path itself or at ANY existing ancestor
# directory — writing through a symlinked parent (even a deep one) is unsafe.
reject_unsafe_path() {
  [ -L "$queue" ] && { echo "error: queue path is a symlink" >&2; exit 3; }
  local anc="$queue"
  while :; do
    anc=$(dirname "$anc")
    { [ "$anc" = "." ] || [ "$anc" = "/" ]; } && break
    [ -L "$anc" ] && { echo "error: symlinked ancestor: $anc" >&2; exit 3; }
  done
  [ -e "$queue" ] && [ ! -f "$queue" ] \
    && { echo "error: queue path is not a regular file" >&2; exit 3; }
  return 0
}

dir=$(dirname "$queue")
reject_unsafe_path
mkdir -p "$dir" || exit 3

# Read the finding body BEFORE writing anything. If it cannot be read we abort
# without touching the queue, so a heading is never written without its body.
body=$(cat "$txt") || { echo "error: cannot read finding text: $txt" >&2; exit 3; }

heading="## ${review_id} :: ${fp}"

# Serialize the dedup read + publish with a lock dir (bounded wait; best-effort).
# The lock path is the literal queue name + ".lock" (never follows a symlink).
lock="${queue}.lock"
pub=""
i=0
while ! mkdir "$lock" 2>/dev/null; do
  i=$((i+1)); [ "$i" -ge 50 ] && { echo "error: could not lock queue" >&2; exit 3; }
  sleep 0.1
done
trap 'rm -f "$pub" 2>/dev/null; rmdir "$lock" 2>/dev/null || true' EXIT

# Re-validate the path UNDER the lock: during the wait the queue could have been
# swapped to a symlink or a non-regular file. Re-check before any read/write.
reject_unsafe_path

# Duplicate key already present → no-op (merge, never duplicate).
if [ -f "$queue" ] && grep -qxF "$heading" "$queue"; then
  exit 0
fi

# Build the FULL new queue in a temp regular file in the same directory, then
# publish it with an atomic rename. Every write is checked, so a partial write
# (e.g. ENOSPC) never leaves a committed heading without its body: the queue is
# only replaced once the complete content is on disk.
pub=$(mktemp "${dir}/.spar-pending.XXXXXX") || exit 3
if [ -f "$queue" ]; then
  cat "$queue" > "$pub" || exit 3
else
  printf '# sparring — pending design decisions (unattended runs)\n\nEach entry below is an essential design decision an unattended run could not make.\nResolve it, then delete its section.\n\n' > "$pub" || exit 3
fi
# Ensure the copied content ends with a newline, so the appended heading always
# starts its own line — otherwise a heading concatenated onto a non-terminated
# last line would defeat the exact-line dedup (grep -x) on the next run.
if [ -s "$pub" ] && [ -n "$(tail -c1 "$pub")" ]; then printf '\n' >> "$pub" || exit 3; fi
{ printf '%s\n\n' "$heading"; printf '%s\n\n' "$body"; } >> "$pub" || exit 3

# Re-validate the destination one last time, immediately before the rename.
# `mv` onto a symlink-to-directory moves the staged file INTO the external
# target and still exits 0 (verified on this platform), so a symlink swapped in
# after the earlier check would leak the finding out of the queue. Rejecting any
# symlink / non-regular destination here means `mv` only ever renames over a
# regular file or a fresh name. Pure bash cannot make the rename itself
# nofollow (no renameat/O_NOFOLLOW), so this recheck plus the serialize lock is
# the strongest guard available; the residual is a single-syscall window bounded
# by the lock that all cooperative writers honor.
reject_unsafe_path
mv "$pub" "$queue" || exit 3
pub=""   # consumed by the rename; nothing to clean up
exit 0
