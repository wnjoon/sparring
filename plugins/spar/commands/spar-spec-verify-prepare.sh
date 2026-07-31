#!/usr/bin/env bash
# Prepare independent read-only spec verification runners for Claude and Codex.
# Usage: spar-spec-verify-prepare.sh <spec path or inline spec> <reviewer-family> <author-family>
set -uo pipefail

spec_source="${1-}"
reviewer_family="${2-}"
author_family="${3-}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${DIR}/../shared/prompts/spec-verifier.md"

case "$reviewer_family" in codex|claude) ;; *) echo "error: reviewer family must be codex|claude" >&2; exit 2 ;; esac
case "$author_family" in codex|claude) ;; *) echo "error: author family must be codex|claude" >&2; exit 2 ;; esac
[ -n "$spec_source" ] || { echo "error: no spec path or description given" >&2; exit 2; }
[ -f "$TPL" ] || { echo "error: missing spec verifier template" >&2; exit 1; }

if [ -f "$spec_source" ]; then
  source_label="$spec_source"
  spec_text="$(cat "$spec_source")"
else
  source_label="inline spec"
  spec_text="$spec_source"
fi
[ -n "$spec_text" ] || { echo "error: spec is empty" >&2; exit 2; }

mkid() {
  printf '%s-%s' "$(date +%Y%m%d-%H%M%S)" \
    "$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

build_prompt() {
  family="$1"
  prompt="$(cat "$TPL")"
  family_note="Verifier family: ${family}
Author family: ${author_family}
Reviewer family: ${reviewer_family}
Input: ${source_label}"
  case "$prompt" in *'{{SPEC_SOURCE}}'*'{{SPEC}}'*) ;; *) return 1 ;; esac
  head=${prompt%%'{{SPEC_SOURCE}}'*}
  rest=${prompt#*'{{SPEC_SOURCE}}'}
  mid=${rest%%'{{SPEC}}'*}
  tail=${rest#*'{{SPEC}}'}
  case "${head}${mid}${tail}" in *'{{SPEC_SOURCE}}'*|*'{{SPEC}}'*) return 1 ;; esac
  printf '%s%s%s%s%s\n' "$head" "$family_note" "$mid" "$spec_text" "$tail"
}

write_runner() {
  family="$1"
  prompt_path=".claude/spar-spec-verify-prompt-${family}.txt"
  runner_path=".claude/spar-run-spec-verify-${family}.sh"
  out_path="reviews/spar-spec-verify-${verify_id}-${family}.md"
  Q_OUT="$(shq "$out_path")"
  Q_PROMPT="$(shq "$prompt_path")"

  if [ "$family" = claude ]; then
    invoke="if ! claude -p --safe-mode --tools Read Grep Glob < ${Q_PROMPT} > \"\$tmp\"; then"
  else
    invoke="if ! codex exec --sandbox read-only --skip-git-repo-check --output-last-message \"\$tmp\" < ${Q_PROMPT}; then"
  fi

  build_prompt "$family" > "$prompt_path" || exit 1
  cat > "$runner_path" <<EOF
#!/usr/bin/env bash
# sparring spec-verifier runner — ${family} family (generated; do not edit)
set -uo pipefail
if [ -e reviews ] || [ -L reviews ]; then
  [ -d reviews ] && [ ! -L reviews ] || exit 1
else
  mkdir reviews || exit 1
fi
if [ -e ${Q_OUT} ] || [ -L ${Q_OUT} ]; then
  [ -f ${Q_OUT} ] && [ ! -L ${Q_OUT} ] && exit 0
  echo "invalid pre-existing spec-verification artifact" >&2
  exit 1
fi
lock=${Q_OUT}.lock
if ! mkdir "\$lock" 2>/dev/null; then
  echo "a spec verification is already running" >&2
  exit 1
fi
tmp=\$(mktemp ${Q_OUT}.tmp.XXXXXX) || { rmdir "\$lock"; exit 1; }
trap 'rm -f "\$tmp"; rmdir "\$lock" 2>/dev/null || true' EXIT
if [ -e ${Q_OUT} ] || [ -L ${Q_OUT} ]; then
  [ -f ${Q_OUT} ] && [ ! -L ${Q_OUT} ] && exit 0
  echo "invalid pre-existing spec-verification artifact" >&2
  exit 1
fi
${invoke}
  echo "spec verifier exited non-zero" >&2
  exit 1
fi
[ -s "\$tmp" ] || exit 1
ln "\$tmp" ${Q_OUT} || exit 1
EOF
  chmod +x "$runner_path"
}

mkdir -p .claude reviews || exit 1
verify_id="$(mkid)"
printf '%s\n' "$verify_id" > .claude/spar-spec-verify-id
write_runner claude
write_runner codex
printf 'spec-verify-id=%s\nclaude=reviews/spar-spec-verify-%s-claude.md\ncodex=reviews/spar-spec-verify-%s-codex.md\n' \
  "$verify_id" "$verify_id" "$verify_id"
