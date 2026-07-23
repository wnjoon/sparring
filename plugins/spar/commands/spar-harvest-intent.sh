#!/usr/bin/env bash
# Harvest repository-resident design intent for the current changed surface.
# Output contains pointers only; repository content is never copied.
# Usage: spar-harvest-intent.sh <base-sha|none> <output-file>
set -uo pipefail

base="${1-}"
out="${2-}"
[ -n "$out" ] || { echo "error: output path required" >&2; exit 2; }
case "$base" in
  none) ;;
  *)
    printf '%s' "$base" | grep -qE '^[0-9a-f]{7,40}$' \
      || { echo "error: invalid baseline" >&2; exit 2; }
    git cat-file -e "${base}^{commit}" 2>/dev/null \
      || { echo "error: baseline commit not found" >&2; exit 2; }
    ;;
esac

tmp_dir=$(mktemp -d) || exit 3
trap 'rm -rf "$tmp_dir"' EXIT
changed="$tmp_dir/changed"
pointers="$tmp_dir/pointers"
: > "$changed"; : > "$pointers"

safe_pointer_path() { # reject control chars that would corrupt line protocol
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 1;; *) return 0;; esac
}
append_changed() { printf '%s\0' "$1" >> "$changed"; }

if [ "$base" != none ]; then
  names="$tmp_dir/names"
  git diff --name-status -z "$base" > "$names" 2>/dev/null || exit 3
  while IFS= read -r -d '' change <&3; do
    IFS= read -r -d '' path <&3 || break
    case "$change" in
      R*|C*)
        append_changed "$path"
        IFS= read -r -d '' path <&3 || break
        append_changed "$path"
        ;;
      *) append_changed "$path" ;;
    esac
  done 3< "$names"
fi

status_file="$tmp_dir/status"
git status --porcelain=v1 -z --untracked-files=all > "$status_file" 2>/dev/null || exit 3
while IFS= read -r -d '' entry; do
  code="${entry:0:2}"; path="${entry:3}"
  if [ "$base" = none ] || [ "$code" = "??" ]; then append_changed "$path"; fi
done < "$status_file"

glob_matches() { # $1=path $2=rule glob (limited Claude paths: syntax)
  local path="$1" pat="$2" prefix body suffix item alt compact
  pat="${pat#\"}"; pat="${pat%\"}"; pat="${pat#\'}"; pat="${pat%\'}"
  case "$pat" in
    *'{'*'}'*)
      prefix="${pat%%\{*}"; body="${pat#*\{}"; body="${body%%\}*}"
      suffix="${pat#*\}}"
      old_ifs="$IFS"; IFS=,
      for item in $body; do
        alt="${prefix}${item}${suffix}"
        if glob_matches "$path" "$alt"; then IFS="$old_ifs"; return 0; fi
      done
      IFS="$old_ifs"
      return 1
      ;;
  esac
  [[ "$path" == $pat ]] && return 0
  compact="${pat//\*\*\//}"
  [[ "$path" == $compact ]]
}

rule_patterns() { # $1=rule file
  awk '
    NR==1 && $0=="---" { fm=1; next }
    fm && $0=="---" { exit }
    fm && /^paths:[[:space:]]*$/ { paths=1; next }
    fm && paths && /^[[:space:]]*-[[:space:]]*/ {
      x=$0; sub(/^[[:space:]]*-[[:space:]]*/, "", x); print x; next
    }
    fm && paths && /^[^[:space:]-]/ { paths=0 }
  ' "$1" 2>/dev/null
}

unscoped_rule_relevant() { # $1=rule
  local rule="$1" stem token path lower base_name top
  stem="${rule##*/}"; stem="${stem%.md}"
  old_ifs="$IFS"; IFS='-_.'
  for token in $stem; do
    [ "${#token}" -ge 4 ] || continue
    while IFS= read -r -d '' path <&3; do
      lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
      case "$lower" in *"$token"*) IFS="$old_ifs"; return 0;; esac
    done 3< "$changed"
  done
  IFS="$old_ifs"
  while IFS= read -r -d '' path <&3; do
    base_name="${path##*/}"; top="${path%%/*}"
    if [ "${#base_name}" -ge 4 ] && grep -qiF "$base_name" "$rule" 2>/dev/null; then return 0; fi
    if [ "$top" != "$path" ] && [ "${#top}" -ge 4 ] \
      && grep -qiF "$top" "$rule" 2>/dev/null; then return 0
    fi
  done 3< "$changed"
  return 1
}

# Relevant path-scoped and content-corresponding project rules.
if [ -d .claude/rules ]; then
  while IFS= read -r -d '' rule; do
    rel="${rule#./}"
    patterns=$(rule_patterns "$rule")
    include=false
    if [ -n "$patterns" ]; then
      while IFS= read -r pat; do
        while IFS= read -r -d '' path <&3; do
          if glob_matches "$path" "$pat"; then include=true; break 2; fi
        done 3< "$changed"
      done <<EOF
$patterns
EOF
    elif unscoped_rule_relevant "$rule"; then
      include=true
    fi
    [ "$include" = true ] && printf 'rule: %s:1\n' "$rel" >> "$pointers"
  done < <(find .claude/rules -type f -name '*.md' -print0 2>/dev/null)
fi

emit_guide_sections() { # $1=guide path
  local guide="$1" rel="${1#./}"
  awk -v p="$rel" '
    /^#{1,6}[[:space:]]+/ {
      h=tolower($0)
      if (h ~ /(design|architecture|rationale|decision|intent|invariant|why|trade[- ]?off|compatib)/)
        printf "guide: %s:%d\n", p, NR
    }
  ' "$guide" >> "$pointers"
}

# Root and ancestor project guides, bounded to directories of changed paths.
while IFS= read -r -d '' path; do
  safe_pointer_path "$path" || continue
  dir="${path%/*}"; [ "$dir" = "$path" ] && dir="."
  while :; do
    for guide_name in CLAUDE.md AGENTS.md; do
      if [ "$dir" = "." ]; then guide="$guide_name"; else guide="$dir/$guide_name"; fi
      [ -f "$guide" ] && emit_guide_sections "$guide"
    done
    [ "$dir" = "." ] && break
    case "$dir" in */*) dir="${dir%/*}";; *) dir=".";; esac
  done
done < "$changed"

comment_pointers_from_diff() { # $1=path
  local path="$1" diff_file="$tmp_dir/diff"
  git diff --no-color --unified=3 "$base" -- "$path" > "$diff_file" 2>/dev/null || return 0
  awk -v p="$path" -v b="$base" '
    function intentional(s, low) {
      low=tolower(s)
      return s ~ /^[[:space:]]*(#|\/\/|\/\*|\*|--)/ &&
        low ~ /(because|intentional|invariant|compatib|trade.?off|deliberate|must remain|why)/
    }
    /^@@ / {
      old=$0; sub(/^@@ -/, "", old); sub(/[, ].*$/, "", old)
      new=$0; sub(/^@@ -[^+]*\+/, "", new); sub(/[, ].*$/, "", new)
      in_hunk=1; next
    }
    !in_hunk { next }
    /^\\/ { next }
    {
      mark=substr($0,1,1); text=substr($0,2)
      if (mark==" ") {
        if (intentional(text)) printf "comment: %s:%d\n", p, new
        old++; new++
      } else if (mark=="+") {
        if (intentional(text)) printf "comment: %s:%d\n", p, new
        new++
      } else if (mark=="-") {
        if (intentional(text)) printf "comment: git:%s:%s:%d\n", b, p, old
        old++
      }
    }
  ' "$diff_file" >> "$pointers"
}

comment_pointers_untracked() { # $1=path
  awk -v p="$1" '
    {
      low=tolower($0)
      if ($0 ~ /^[[:space:]]*(#|\/\/|\/\*|\*|--)/ &&
          low ~ /(because|intentional|invariant|compatib|trade.?off|deliberate|must remain|why)/)
        printf "comment: %s:%d\n", p, NR
    }
  ' "$1" 2>/dev/null >> "$pointers"
}

while IFS= read -r -d '' path; do
  safe_pointer_path "$path" || continue
  if [ -f "$path" ] && ! git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    comment_pointers_untracked "$path"
  elif [ "$base" != none ]; then
    comment_pointers_from_diff "$path"
  fi
done < "$changed"

mkdir -p "$(dirname "$out")" || exit 3
LC_ALL=C sort -u "$pointers" > "${out}.tmp.$$" || exit 3
mv "${out}.tmp.$$" "$out" || exit 3
exit 0
