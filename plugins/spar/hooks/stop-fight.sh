#!/usr/bin/env bash
# sparring fight — the plugin's single Stop hook (combined dispatcher).
# Runs spar's unchanged stop-hook.sh in-process, captures its decision, and
# only when a plan is active AND spar approved (a task loop terminated)
# advances the plan. Otherwise passes spar's decision through. Fails OPEN,
# preserving spar's decision (never loses a spar block).
set -uo pipefail
PLAN_STATE=".claude/spar-plan.local.md"
LOG=".claude/spar-fight.log"
DIR="${CLAUDE_PLUGIN_ROOT:-}/commands"
LIB="$DIR/spar-plan-lib.sh"
CHECK="$DIR/spar-fight-check.sh"
LAUNCH="$DIR/spar-fight-launch.sh"
TASKFILE=".claude/spar-fight-task.txt"
SPAR_HOOK="${SPAR_FIGHT_SPAR_HOOK:-${CLAUDE_PLUGIN_ROOT:-}/hooks/stop-hook.sh}"

log(){ mkdir -p .claude; echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }
SPAR_DEC='{"decision":"approve"}'
passthrough(){ printf '%s\n' "$SPAR_DEC"; exit 0; }
block(){ jq -nc --arg r "$1" --arg s "${2:-sparring fight}" \
  '{decision:"block",reason:$r,systemMessage:$s}' 2>/dev/null \
  || printf '{"decision":"block","reason":"fight"}\n'; exit 0; }

# On any internal error emit spar's captured decision — never lose a spar block.
trap 'log "ERR line $LINENO — emitting spar decision"; printf "%s\n" "$SPAR_DEC"; exit 0' ERR

INPUT="$(cat)"
NEW="$(printf '%s' "$INPUT" | bash "$SPAR_HOOK" 2>>"$LOG")" && [ -n "$NEW" ] && SPAR_DEC="$NEW"
DEC="$(printf '%s\n' "$SPAR_DEC" | jq -r '.decision // "approve"' 2>/dev/null || echo approve)"

[ -f "$PLAN_STATE" ] || passthrough
[ -f "$LIB" ] || passthrough
. "$LIB"
[ "$(plan_field active "$PLAN_STATE")" = "true" ] || passthrough
[ "$DEC" = "approve" ] || passthrough            # spar blocked mid-round — let it drive
[ "$(plan_field phase "$PLAN_STATE")" = "running" ] || passthrough

RID="$(plan_field current_review_id "$PLAN_STATE")"
[ -n "$RID" ] || passthrough                      # task not launched yet
OUTCOME="reviews/spar-${RID}-outcome.md"
[ -f "$OUTCOME" ] || passthrough                  # no terminal yet

REASON="$(sed -n 's/^reason: *//p' "$OUTCOME" | head -1)"
CUR="$(plan_field current "$PLAN_STATE")"
TASKS="$(plan_field tasks "$PLAN_STATE")"
MODE="$(plan_field mode "$PLAN_STATE")"
PLAN="$(plan_field plan_path "$PLAN_STATE")"
case "$CUR" in ''|*[!0-9]*) log "bad current"; passthrough;; esac
case "$TASKS" in ''|*[!0-9]*) log "bad tasks"; passthrough;; esac

HEADING="$(plan_task_line "$CUR" "$PLAN_STATE" | cut -f3)"

case "$REASON" in
  converged|skipped)
    idx="$CUR"; [ "$MODE" = "whole" ] && idx=0
    [ -f "$PLAN" ] && bash "$CHECK" "$PLAN" "$idx" 2>>"$LOG" || log "checkbox flip skipped"
    plan_set_task_status "$CUR" done "$PLAN_STATE"
    # Exclude loop artifacts even if the command's git-excludes are absent
    # (defense in depth; the command also adds them to .git/info/exclude).
    git add -A -- . ':!.claude/spar*' ':!reviews/spar-*' 2>>"$LOG" || git add -A 2>>"$LOG" || true
    git commit -q -m "fight: task ${CUR} (${HEADING}) — ${REASON}" 2>>"$LOG" || log "nothing to commit for task $CUR"
    if [ "$CUR" -lt "$TASKS" ]; then
      NEXT=$((CUR+1))
      # Atomic: advance current AND clear current_review_id in ONE write. A crash
      # between two separate writes could otherwise leave current=NEXT with a
      # stale, already-consumed review_id whose outcome file still exists — the
      # next invocation would then advance again into an unimplemented task and
      # falsely mark it done. One awk pass makes that state unreachable.
      wtmp="${PLAN_STATE}.tmp.$$"
      awk -v n="$NEXT" '
        /^---$/ {m++}
        m<2 && /^current: / {print "current: " n; next}
        m<2 && /^current_review_id: / {print "current_review_id:"; next}
        {print}
      ' "$PLAN_STATE" > "$wtmp" && mv "$wtmp" "$PLAN_STATE"
      NHEAD="$(plan_task_line "$NEXT" "$PLAN_STATE" | cut -f3)"
      # Build the next task's text from its plan section (whole mode: entire plan).
      if [ "$MODE" = "whole" ]; then cp "$PLAN" "$TASKFILE"
      else awk -v h="### ${NHEAD}" '$0==h{f=1} f&&/^### /&&$0!=h&&seen{exit} $0==h{seen=1} f{print}' "$PLAN" > "$TASKFILE"; fi
      if ! bash "$LAUNCH" "$PLAN_STATE" "$TASKFILE" 2>>"$LOG"; then
        log "launch failed for task $NEXT"
        plan_set_field phase done "$PLAN_STATE"
        block "Task ${CUR} converged, but launching task ${NEXT} failed. The
fight is stopping — check .claude/spar-fight.log, run /spar:cancel to
clear this plan, then start a new /spar:ready." \
          "sparring fight: launch failed"
      fi
      block "Task ${CUR} converged and was committed. Now implement task ${NEXT}: ${NHEAD}, following its steps in ${PLAN}. When done, stop — the sparring reviewer will engage automatically." \
        "sparring fight: task ${NEXT}/${TASKS}"
    else
      plan_set_field phase done "$PLAN_STATE"
      block "All ${TASKS} tasks converged and were committed on this branch. Summarize what shipped for the user (branch, plan path, tasks). Then run /spar:cancel to clear this plan's state (otherwise the next /spar:ready is refused as 'already ready'), and stop." \
        "sparring fight: complete"
    fi
    ;;
  *)
    plan_set_task_status "$CUR" stopped "$PLAN_STATE"
    plan_set_field phase done "$PLAN_STATE"
    block "Task ${CUR} (${HEADING}) did not converge — its sparring loop ended '${REASON}'. Per fight policy the run stops here rather than advancing. Report the unresolved findings from that task's last review to the user honestly, then stop. (To move on: run /spar:cancel to clear this plan, fix the findings, then start a new /spar:ready.)" \
      "sparring fight: stopped — task ${CUR} ${REASON}"
    ;;
esac
