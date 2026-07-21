#!/usr/bin/env bash
# sparring — Stop hook. Deterministic gatekeeper for the review loop.
#   task   : author finished implementing → prepare round 1, block exit
#   review : a round is in flight → converged / respond / next round / cap
# On any internal error: fail OPEN (approve). Never trap the user.

LOG_FILE=".claude/spar.log"
STATE_FILE=".claude/spar.local.md"
RUNNER=".claude/spar-run-reviewer.sh"
PROMPT_FILE=".claude/spar-reviewer-prompt.txt"
RETRY_FILE=".claude/spar-retries"

log() { mkdir -p "$(dirname "$LOG_FILE")"; echo "[$(date -u +%FT%TZ)] $*" >> "$LOG_FILE"; }
approve() { printf '{"decision":"approve"}\n'; exit 0; }
block() { # $1=reason $2=statusMessage
  jq -nc --arg r "$1" --arg s "${2:-sparring}" \
    '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
    || printf '{"decision":"block","reason":"sparring: %s"}\n' "$(echo "$1" | head -1)"
  exit 0
}
cleanup() { rm -f "$STATE_FILE" "$RUNNER" "$PROMPT_FILE" "$RETRY_FILE"; }

trap 'log "ERR trap line $LINENO"; cleanup; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

HOOK_INPUT=$(cat) # consume stdin (hook JSON)

[ -f "$STATE_FILE" ] || approve

field() { sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1; }

ACTIVE=$(field active); PHASE=$(field phase); ROUND=$(field round)
REVIEW_ID=$(field review_id); MAX_ROUNDS=$(field max_rounds)

[ "$ACTIVE" = "true" ] || { cleanup; approve; }
echo "$REVIEW_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$' \
  || { log "invalid review_id: $REVIEW_ID"; cleanup; approve; }
case "$ROUND" in ''|*[!0-9]*) log "invalid round: $ROUND"; cleanup; approve;; esac
case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=5;; esac

TASK=$(awk '/^---$/{c++; next} c>=2{print}' "$STATE_FILE")

review_file() { echo "reviews/spar-${REVIEW_ID}-r${1}.md"; }
response_file() { echo "reviews/spar-${REVIEW_ID}-r${1}-response.md"; }

set_state() { # $1=phase $2=round
  local tmp="${STATE_FILE}.tmp.$$"
  awk -v p="$1" -v r="$2" '
    /^phase:/ { print "phase: " p; next }
    /^round:/ { print "round: " r; next }
    { print }' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

prepare_round() { # $1=round number → writes PROMPT_FILE + RUNNER
  local n="$1"
  local tpl_dir="${CLAUDE_PLUGIN_ROOT:-}/shared/prompts"
  [ -f "$tpl_dir/reviewer.md" ] \
    || { log "template missing: $tpl_dir/reviewer.md"; cleanup; approve; }

  local prompt prev_ctx=""
  prompt=$(cat "$tpl_dir/reviewer.md")
  if [ "$n" -gt 1 ]; then
    prev_ctx=$(cat "$tpl_dir/reviewer-prev-context.md")
    prev_ctx=${prev_ctx//\{\{PREV_REVIEW\}\}/$(review_file $((n-1)))}
    prev_ctx=${prev_ctx//\{\{PREV_RESPONSE\}\}/$(response_file $((n-1)))}
  fi
  prompt=${prompt//\{\{TASK\}\}/$TASK}
  prompt=${prompt//\{\{ROUND\}\}/$n}
  prompt=${prompt//\{\{PREV_CONTEXT\}\}/$prev_ctx}

  mkdir -p reviews .claude
  printf '%s' "$prompt" > "$PROMPT_FILE"

  local out; out=$(review_file "$n")
  cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
# sparring reviewer runner — round ${n} (generated; do not edit)
set -uo pipefail
mkdir -p reviews
codex exec --sandbox read-only --skip-git-repo-check \\
  --output-last-message "${out}" "\$(cat "${PROMPT_FILE}")"
EOF
  chmod +x "$RUNNER"
}

command -v codex >/dev/null 2>&1 || {
  log "codex CLI not found"; cleanup
  block "ERROR: Codex CLI not found. Install it (npm install -g @openai/codex), then run /spar again." \
        "sparring: codex missing"
}

case "$PHASE" in
  task)
    prepare_round 1
    set_state review 1
    rm -f "$RETRY_FILE"
    block "Implementation phase done. Round 1 independent review is required.

Run (use a 600000ms timeout — reviews take minutes):
\`\`\`
bash ${RUNNER}
\`\`\`

Then read $(review_file 1):
- STATUS: CONVERGED → simply stop again; the loop will release.
- STATUS: FINDINGS → fix every [MECHANICAL] finding; decide each [DESIGN]
  finding on the merits; then write $(response_file 1) with one section per
  finding ID: 'FIXED — <what you did>' or 'REJECTED — <reason grounded in
  code/requirements>'. Then stop again." \
      "sparring [${REVIEW_ID}] round 1: run reviewer"
    ;;
  *)
    log "unknown phase: $PHASE"; cleanup; approve
    ;;
esac
