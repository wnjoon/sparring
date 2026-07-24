#!/usr/bin/env bash
# Shared readers/writers for the plan/handoff state file. Sourced, never executed.
# State file layout:
#   ---
#   <frontmatter: name: value>
#   ---
#   <task table: index<TAB>status<TAB>heading  (one row per task)>
PLAN_STATE_DEFAULT=".claude/spar-plan.local.md"

plan_field() { # $1=name [$2=file]
  local f="${2:-$PLAN_STATE_DEFAULT}"
  sed -n "s/^${1}: *//p" "$f" 2>/dev/null | head -1
}

plan_task_line() { # $1=index [$2=file]
  local f="${2:-$PLAN_STATE_DEFAULT}"
  awk -v i="$1" -F'\t' '/^---$/{c++} c>=2 && $1==i {print; exit}' "$f" 2>/dev/null
}

plan_set_field() { # $1=name $2=value [$3=file]
  local f="${3:-$PLAN_STATE_DEFAULT}" tmp
  tmp="${f}.tmp.$$"
  awk -v k="$1" -v v="$2" '
    BEGIN{done=0}
    /^---$/ {marks++}
    marks<2 && $0 ~ "^" k ": *" && !done { print k ": " v; done=1; next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

plan_set_task_status() { # $1=index $2=status [$3=file]
  local f="${3:-$PLAN_STATE_DEFAULT}" tmp
  tmp="${f}.tmp.$$"
  awk -v i="$1" -v s="$2" '
    BEGIN{c=0}
    /^---$/ {c++; print; next}
    c>=2 && $1==i { print $1 "\t" s "\t" substr($0, index($0,$3)); next }
    { print }
  ' FS='\t' OFS='\t' "$f" > "$tmp" && mv "$tmp" "$f"
}
