#!/usr/bin/env bash
# Deterministically summarize the frozen-baseline change surface.
# Output is machine-readable "key: value" lines; raw paths never cross the
# interface, so unusual filenames cannot corrupt the control protocol.
# Usage: spar-classify-change.sh <base-sha|none>
set -uo pipefail

base="${1-}"
case "$base" in
  none) ;;
  *)
    printf '%s' "$base" | grep -qE '^[0-9a-f]{7,40}$' \
      || { echo "error: invalid baseline" >&2; exit 2; }
    git cat-file -e "${base}^{commit}" 2>/dev/null \
      || { echo "error: baseline commit not found" >&2; exit 2; }
    ;;
esac
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "error: not a Git worktree" >&2; exit 2; }

tmp_dir=$(mktemp -d) || exit 3
trap 'rm -rf "$tmp_dir"' EXIT
numstat="$tmp_dir/numstat"
names="$tmp_dir/names"
raw="$tmp_dir/raw"
status_file="$tmp_dir/status"

if [ "$base" = none ]; then
  : > "$numstat"; : > "$names"; : > "$raw"
else
  git diff -C --find-copies-harder --numstat -z "$base" > "$numstat" 2>/dev/null || exit 3
  git diff -C --find-copies-harder --name-status -z "$base" > "$names" 2>/dev/null || exit 3
  git diff -C --find-copies-harder --raw -z "$base" > "$raw" 2>/dev/null || exit 3
fi
git status --porcelain=v1 -z --untracked-files=all > "$status_file" 2>/dev/null || exit 3

lines=0
paths=0
unsafe_kind=false
touched_risk=false
repo_risk=false
touched_reasons=""
repo_reasons=""

add_reason() { # $1=current-list $2=reason
  case ",$1," in *",$2,"*) printf '%s' "$1";; *)
    if [ -n "$1" ]; then printf '%s,%s' "$1" "$2"; else printf '%s' "$2"; fi
  esac
}

classify_touched_path() { # $1=path
  local lower="/$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')/"
  case "$lower" in
    */auth/*|*/authentication/*|*/authorization/*|*/sessions/*|*/permissions/*|*/oauth/*)
      touched_risk=true; touched_reasons=$(add_reason "$touched_reasons" auth-security) ;;
  esac
  case "$lower" in
    */migrations/*|*/migration/*|*/schema/*|*.sql/|*/schema.*/*)
      touched_risk=true; touched_reasons=$(add_reason "$touched_reasons" database-schema) ;;
  esac
  case "$lower" in
    */.github/workflows/*|*/.circleci/*|*/.gitlab-ci.yml/*|*/jenkinsfile/*|*/release.yml/*)
      touched_risk=true; touched_reasons=$(add_reason "$touched_reasons" ci-release) ;;
  esac
  case "$lower" in
    */.claude/hooks/*|*/.git/hooks/*|*/.husky/*|*/hooks.json/*|*stop-hook*|*pre-commit*)
      touched_risk=true; touched_reasons=$(add_reason "$touched_reasons" hooks-enforcement) ;;
  esac
  case "$lower" in
    *.sol/|*/contracts/*|*/foundry.toml/*|*/hardhat.config.*/*)
      touched_risk=true; touched_reasons=$(add_reason "$touched_reasons" smart-contract) ;;
  esac
  case "$lower" in
    *.tf/|*.tfvars/|*/terraform/*|*/k8s/*|*/kubernetes/*|*/deploy/*|*/production/*)
      touched_risk=true; touched_reasons=$(add_reason "$touched_reasons" infra-production) ;;
  esac
}

count_untracked_file() { # $1=path
  local path="$1" one="$tmp_dir/one" rec adds deletes rest rc
  paths=$((paths + 1))
  classify_touched_path "$path"
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    unsafe_kind=true
    return 0
  fi
  : > "$one"
  git diff --no-index --numstat -- /dev/null "$path" > "$one" 2>/dev/null
  rc=$?
  case "$rc" in 0|1) ;; *) unsafe_kind=true; return 0;; esac
  IFS= read -r rec < "$one" || rec=""
  [ -n "$rec" ] || return 0
  adds="${rec%%$'\t'*}"; rest="${rec#*$'\t'}"; deletes="${rest%%$'\t'*}"
  case "$adds:$deletes" in
    *-*) unsafe_kind=true ;;
    *[!0-9:]*|'':*) unsafe_kind=true ;;
    *) lines=$((lines + adds + deletes)) ;;
  esac
}

# Count tracked content lines. Rename/copy numstat records carry an empty path
# followed by old/new path NUL records; consume both to keep the stream aligned.
while IFS= read -r -d '' rec <&3; do
  adds="${rec%%$'\t'*}"; rest="${rec#*$'\t'}"
  deletes="${rest%%$'\t'*}"; path="${rest#*$'\t'}"
  case "$adds:$deletes" in
    *-*) unsafe_kind=true ;;
    *[!0-9:]*|'':*) unsafe_kind=true ;;
    *) lines=$((lines + adds + deletes)) ;;
  esac
  if [ -z "$path" ]; then
    IFS= read -r -d '' _old <&3 || true
    IFS= read -r -d '' _new <&3 || true
  fi
done 3< "$numstat"

# Count tracked paths, classify both sides of renames, and conservatively reject
# non-content kinds from skip eligibility.
while IFS= read -r -d '' change <&3; do
  IFS= read -r -d '' path <&3 || { unsafe_kind=true; break; }
  case "$change" in
    R*|C*)
      old="$path"
      IFS= read -r -d '' path <&3 || { unsafe_kind=true; break; }
      paths=$((paths + 2))
      classify_touched_path "$old"; classify_touched_path "$path"
      unsafe_kind=true
      ;;
    A|M)
      paths=$((paths + 1)); classify_touched_path "$path" ;;
    *)
      paths=$((paths + 1)); classify_touched_path "$path"; unsafe_kind=true ;;
  esac
done 3< "$names"

# Raw modes catch symlinks, gitlinks, and mode/type changes that numstat can
# otherwise report as a harmless 0/0 change.
while IFS= read -r -d '' meta <&3; do
  meta="${meta#:}"
  oldmode="${meta%% *}"; rest="${meta#* }"; newmode="${rest%% *}"
  IFS= read -r -d '' _path <&3 || { unsafe_kind=true; break; }
  case "$meta" in *" R"*|*" C"*) IFS= read -r -d '' _path2 <&3 || true;; esac
  # A normal tracked add is 000000 -> 100644 and is not a mode change.
  # Deletes are already unsafe via name-status. Compare modes only when both
  # sides exist so staged adds behave like equivalent untracked adds.
  if [ "$oldmode" != 000000 ] && [ "$newmode" != 000000 ] \
    && [ "$oldmode" != "$newmode" ]; then
    unsafe_kind=true
  fi
  case "$oldmode:$newmode" in
    *120000*|*160000*) unsafe_kind=true ;;
  esac
done 3< "$raw"

# Untracked files are absent from every git diff. With base=none, every status
# path is pre-baseline and therefore never skip-eligible.
while IFS= read -r -d '' entry; do
  code="${entry:0:2}"
  path="${entry:3}"
  if [ "$base" = none ]; then
    unsafe_kind=true
    count_untracked_file "$path"
  elif [ "$code" = "??" ]; then
    count_untracked_file "$path"
  fi
done < "$status_file"

# Repo-level signals are separate: they can trigger a sweep but never make an
# unrelated touched path ineligible for skip.
while IFS= read -r -d '' path; do
  lower="/$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')/"
  case "$lower" in
    */auth/*|*/authentication/*|*/authorization/*)
      repo_risk=true; repo_reasons=$(add_reason "$repo_reasons" repo-auth) ;;
  esac
  case "$lower" in
    */migrations/*|*/migration/*|*.sql/|*/schema/*)
      repo_risk=true; repo_reasons=$(add_reason "$repo_reasons" repo-database) ;;
  esac
  case "$lower" in
    *.sol/|*/contracts/*|*/foundry.toml/*|*/hardhat.config.*/*)
      repo_risk=true; repo_reasons=$(add_reason "$repo_reasons" repo-smart-contract) ;;
  esac
done < <(git ls-files -z 2>/dev/null)

has_changes=false
[ "$paths" -gt 0 ] && has_changes=true
small=false
[ "$lines" -le 10 ] && [ "$paths" -le 2 ] && small=true

echo "has_changes: $has_changes"
echo "lines: $lines"
echo "paths: $paths"
echo "small: $small"
echo "unsafe_kind: $unsafe_kind"
echo "touched_risk: $touched_risk"
echo "repo_risk: $repo_risk"
echo "touched_reasons: ${touched_reasons:-none}"
echo "repo_reasons: ${repo_reasons:-none}"
