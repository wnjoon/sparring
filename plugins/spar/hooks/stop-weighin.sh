#!/usr/bin/env bash
# sparring weigh-in — the plugin's single Stop hook (combined dispatcher).
# Runs spar's unchanged stop-hook.sh in-process, captures its decision, and
# only when a weigh-in is active AND spar approved (a task loop terminated)
# advances the plan. Otherwise passes spar's decision through. Fails OPEN,
# preserving spar's decision (never loses a spar block).
set -uo pipefail
WGN_STATE=".claude/spar-weighin.local.md"
LOG=".claude/spar-weighin.log"
DIR="${CLAUDE_PLUGIN_ROOT:-}/commands"
LIB="$DIR/spar-weighin-lib.sh"
CHECK="$DIR/spar-weighin-check.sh"
LAUNCH="$DIR/spar-weighin-launch.sh"
TASKFILE=".claude/spar-weighin-task.txt"
SPAR_HOOK="${SPAR_WEIGHIN_SPAR_HOOK:-${CLAUDE_PLUGIN_ROOT:-}/hooks/stop-hook.sh}"

log(){ mkdir -p .claude; echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }
SPAR_DEC='{"decision":"approve"}'
passthrough(){ printf '%s\n' "$SPAR_DEC"; exit 0; }
block(){ jq -nc --arg r "$1" --arg s "${2:-sparring weigh-in}" \
  '{decision:"block",reason:$r,systemMessage:$s}' 2>/dev/null \
  || printf '{"decision":"block","reason":"weighin"}\n'; exit 0; }

# On any internal error emit spar's captured decision — never lose a spar block.
trap 'log "ERR line $LINENO — emitting spar decision"; printf "%s\n" "$SPAR_DEC"; exit 0' ERR

INPUT="$(cat)"
NEW="$(printf '%s' "$INPUT" | bash "$SPAR_HOOK" 2>>"$LOG")" && [ -n "$NEW" ] && SPAR_DEC="$NEW"
DEC="$(printf '%s\n' "$SPAR_DEC" | jq -r '.decision // "approve"' 2>/dev/null || echo approve)"

[ -f "$WGN_STATE" ] || passthrough
[ -f "$LIB" ] || passthrough
. "$LIB"
[ "$(wgn_field active "$WGN_STATE")" = "true" ] || passthrough
[ "$DEC" = "approve" ] || passthrough            # spar blocked mid-round — let it drive
[ "$(wgn_field phase "$WGN_STATE")" = "running" ] || passthrough

RID="$(wgn_field current_review_id "$WGN_STATE")"
[ -n "$RID" ] || passthrough                      # task not launched yet
OUTCOME="reviews/spar-${RID}-outcome.md"
[ -f "$OUTCOME" ] || passthrough                  # no terminal yet

REASON="$(sed -n 's/^reason: *//p' "$OUTCOME" | head -1)"
CUR="$(wgn_field current "$WGN_STATE")"
TASKS="$(wgn_field tasks "$WGN_STATE")"
MODE="$(wgn_field mode "$WGN_STATE")"
PLAN="$(wgn_field plan_path "$WGN_STATE")"
case "$CUR" in ''|*[!0-9]*) log "bad current"; passthrough;; esac
case "$TASKS" in ''|*[!0-9]*) log "bad tasks"; passthrough;; esac

HEADING="$(wgn_task_line "$CUR" "$WGN_STATE" | cut -f3)"

case "$REASON" in
  converged|skipped)
    idx="$CUR"; [ "$MODE" = "whole" ] && idx=0
    [ -f "$PLAN" ] && bash "$CHECK" "$PLAN" "$idx" 2>>"$LOG" || log "checkbox flip skipped"
    wgn_set_task_status "$CUR" done "$WGN_STATE"
    # Exclude loop artifacts even if the command's git-excludes are absent
    # (defense in depth; the command also adds them to .git/info/exclude).
    git add -A -- . ':!.claude/spar*' ':!reviews/spar-*' 2>>"$LOG" || git add -A 2>>"$LOG" || true
    git commit -q -m "weighin: task ${CUR} (${HEADING}) — ${REASON}" 2>>"$LOG" || log "nothing to commit for task $CUR"
    if [ "$CUR" -lt "$TASKS" ]; then
      NEXT=$((CUR+1))
      # Atomic: advance current AND clear current_review_id in ONE write. A crash
      # between two separate writes could otherwise leave current=NEXT with a
      # stale, already-consumed review_id whose outcome file still exists — the
      # next invocation would then advance again into an unimplemented task and
      # falsely mark it done. One awk pass makes that state unreachable.
      wtmp="${WGN_STATE}.tmp.$$"
      awk -v n="$NEXT" '
        /^---$/ {m++}
        m<2 && /^current: / {print "current: " n; next}
        m<2 && /^current_review_id: / {print "current_review_id:"; next}
        {print}
      ' "$WGN_STATE" > "$wtmp" && mv "$wtmp" "$WGN_STATE"
      NHEAD="$(wgn_task_line "$NEXT" "$WGN_STATE" | cut -f3)"
      # Build the next task's text from its plan section (whole mode: entire plan).
      if [ "$MODE" = "whole" ]; then cp "$PLAN" "$TASKFILE"
      else awk -v h="### ${NHEAD}" '$0==h{f=1} f&&/^### /&&$0!=h&&seen{exit} $0==h{seen=1} f{print}' "$PLAN" > "$TASKFILE"; fi
      if ! bash "$LAUNCH" "$WGN_STATE" "$TASKFILE" 2>>"$LOG"; then
        log "launch failed for task $NEXT"
        wgn_set_field phase done "$WGN_STATE"
        block "Task ${CUR} converged, but launching task ${NEXT} failed. The
weigh-in is stopping — check .claude/spar-weighin.log, then re-run
/spar-weighin to resume." "sparring weigh-in: launch failed"
      fi
      block "Task ${CUR} converged and was committed. Now implement task ${NEXT}: ${NHEAD}, following its steps in ${PLAN}. When done, stop — the sparring reviewer will engage automatically." \
        "sparring weigh-in: task ${NEXT}/${TASKS}"
    else
      wgn_set_field phase done "$WGN_STATE"
      block "All ${TASKS} tasks converged and were committed on this branch. Summarize what shipped for the user (branch, plan path, tasks), then stop." \
        "sparring weigh-in: complete"
    fi
    ;;
  *)
    wgn_set_task_status "$CUR" stopped "$WGN_STATE"
    wgn_set_field phase done "$WGN_STATE"
    block "Task ${CUR} (${HEADING}) did not converge — its sparring loop ended '${REASON}'. Per weigh-in policy the run stops here rather than advancing. Report the unresolved findings from that task's last review to the user honestly, then stop. (To resume later, fix and re-run /spar-weighin.)" \
      "sparring weigh-in: stopped — task ${CUR} ${REASON}"
    ;;
esac
