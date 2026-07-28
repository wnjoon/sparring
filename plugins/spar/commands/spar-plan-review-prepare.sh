#!/usr/bin/env bash
# Prepare one independent review of a plan, before /spar:fight will execute it.
# Usage: spar-plan-review-prepare.sh <plan-path> <state-file>
#
# Writes .claude/spar-plan-review-prompt.txt and .claude/spar-run-plan-review.sh
# and exits 0. Exits 1 without writing either when the state does not ask for a
# review, when the template or the plan is missing, or when the reviewer CLI is
# not on PATH — a caller can treat non-zero as "no review was prepared" and carry
# on, which is what /spar:ready does.
set -uo pipefail

plan="${1-}"
state="${2-.claude/spar-plan.local.md}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${DIR}/../shared/prompts/plan-reviewer.md"
PROMPT=".claude/spar-plan-review-prompt.txt"
RUNNER=".claude/spar-run-plan-review.sh"
HASHFILE=".claude/spar-plan-review-hash"
SPEC=".claude/spar-plan-spec.txt"

field() { sed -n "s/^${1}: *//p" "$state" 2>/dev/null | head -1; }

[ -f "$state" ] || exit 1
[ -n "$plan" ] && [ -f "$plan" ] || exit 1
[ -f "$TPL" ] || exit 1
[ "$(field plan_review)" = required ] || exit 1

reviewer="$(field reviewer)"
case "$reviewer" in codex|claude) ;; *) exit 1 ;; esac
command -v "$reviewer" >/dev/null 2>&1 || exit 1

prid="$(field plan_review_id)"
printf '%s' "$prid" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' || exit 1
out="reviews/spar-plan-${prid}.md"

# Single-quote wrap, the same shape stop-hook.sh's shq() uses. Every path below
# reaches the generated runner from the state file, so none of them is a fixed
# string: a plan path holding a space or a `$` would word-split or expand.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# Assembled structurally, not by two sequential replacements. Both inputs are
# arbitrary document text — this repository's own plans and specs quote
# "{{SPEC}}" and "{{PLAN}}" while describing this very file — and with sequential
# replacement whichever goes first has its inserted text re-scanned by the
# second. Splitting the TEMPLATE on both placeholders and concatenating means no
# inserted byte is ever looked at again.
prompt="$(cat "$TPL")"
spec_text=""
[ -f "$SPEC" ] && spec_text="$(cat "$SPEC")"
[ -n "$spec_text" ] || spec_text="(no spec was captured for this plan)"
plan_text="$(cat "$plan")"
case "$prompt" in *'{{SPEC}}'*'{{PLAN}}'*) ;; *) exit 1 ;; esac
head=${prompt%%'{{SPEC}}'*}
rest=${prompt#*'{{SPEC}}'}
mid=${rest%%'{{PLAN}}'*}
tail=${rest#*'{{PLAN}}'}
# Exactly one of each: a second copy would survive in a fixed part and reach the
# reviewer as literal placeholder text, which is how the template silently loses
# a section.
case "${head}${mid}${tail}" in *'{{SPEC}}'*|*'{{PLAN}}'*) exit 1 ;; esac
prompt="${head}${spec_text}${mid}${plan_text}${tail}"

mkdir -p .claude reviews
printf '%s\n' "$prompt" > "$PROMPT"

Q_OUT="$(shq "$out")"
Q_PROMPT="$(shq "$PROMPT")"
Q_PLAN="$(shq "$plan")"
Q_HASH="$(shq "$HASHFILE")"

if [ "$reviewer" = claude ]; then
  INVOKE="if ! claude -p --safe-mode --tools Read Grep Glob < ${Q_PROMPT} > \"\$tmp\"; then"
else
  INVOKE="if ! codex exec --sandbox read-only --skip-git-repo-check --output-last-message \"\$tmp\" < ${Q_PROMPT}; then"
fi

cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
# sparring plan-review runner — ${reviewer} family (generated; do not edit)
# Mirrors the loop's reviewer runners: read-only invocation, a lock so two
# sessions cannot race, mktemp + hard-link publish so the result appears whole
# or not at all, and a refusal to touch anything that is not a regular file.
set -uo pipefail
if [ -e reviews ] || [ -L reviews ]; then
  [ -d reviews ] && [ ! -L reviews ] || exit 1
else
  mkdir reviews || exit 1
fi
# An existing regular result is FINAL. That is what makes this runner safe to
# re-run, and it is why a malformed result is quarantined by the checker rather
# than overwritten here.
if [ -e ${Q_OUT} ] || [ -L ${Q_OUT} ]; then
  [ -f ${Q_OUT} ] && [ ! -L ${Q_OUT} ] && exit 0
  echo "invalid pre-existing plan-review artifact" >&2
  exit 1
fi
lock=${Q_OUT}.lock
if ! mkdir "\$lock" 2>/dev/null; then
  echo "a plan review is already running" >&2
  exit 1
fi
tmp=\$(mktemp ${Q_OUT}.tmp.XXXXXX) || { rmdir "\$lock"; exit 1; }
trap 'rm -f "\$tmp"; rmdir "\$lock" 2>/dev/null || true' EXIT
# Recheck under the lock. Another invocation can publish and release between the
# check above and this one's mkdir; without this, that invocation would rewrite
# the hash from a possibly newer plan and leave the retained review paired with a
# revision it never saw.
if [ -e ${Q_OUT} ] || [ -L ${Q_OUT} ]; then
  [ -f ${Q_OUT} ] && [ ! -L ${Q_OUT} ] && exit 0
  echo "invalid pre-existing plan-review artifact" >&2
  exit 1
fi
# The hash of the plan AS REVIEWED, written by the plugin rather than the author,
# so /spar:fight can say whether what it is about to run is what was read.
git hash-object ${Q_PLAN} > ${Q_HASH} 2>/dev/null || true
${INVOKE}
  echo "plan reviewer exited non-zero" >&2
  exit 1
fi
[ -s "\$tmp" ] || exit 1
ln "\$tmp" ${Q_OUT} || exit 1
EOF
chmod +x "$RUNNER"
