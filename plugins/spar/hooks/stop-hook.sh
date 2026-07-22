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
LEDGER_FILE=".claude/spar-ledger.md"
REGISTRY_FILE=".claude/spar-registry.tsv"
REG_MARKER=".claude/spar-registry-round"

log() { mkdir -p "$(dirname "$LOG_FILE")"; echo "[$(date -u +%FT%TZ)] $*" >> "$LOG_FILE"; }
approve() { printf '{"decision":"approve"}\n'; exit 0; }
block() { # $1=reason $2=statusMessage
  jq -nc --arg r "$1" --arg s "${2:-sparring}" \
    '{decision:"block", reason:$r, systemMessage:$s}' 2>/dev/null \
    || printf '{"decision":"block","reason":"sparring: %s"}\n' "$(echo "$1" | head -1)"
  exit 0
}
cleanup() { rm -f "$STATE_FILE" "$RUNNER" "$PROMPT_FILE" "$RETRY_FILE" \
  "$LEDGER_FILE" "$REGISTRY_FILE" "$REG_MARKER"; }

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

BASE=$(field base_sha)
echo "$BASE" | grep -qE '^([0-9a-f]{7,40}|none)$' || BASE="HEAD"

TASK=$(awk '/^---$/{c++; next} c>=2{print}' "$STATE_FILE")

review_file() { echo "reviews/spar-${REVIEW_ID}-r${1}.md"; }
response_file() { echo "reviews/spar-${REVIEW_ID}-r${1}-response.md"; }

# ── finding registry (Phase 2a: deterministic fingerprint) ──────────────────
# Parse reviewer findings → "id<TAB>tag<TAB>file<TAB>normalized-title" per line.
parse_findings() { # $1 = review file
  awk '
    function flush() {
      if (id != "") {
        t = tolower(title); gsub(/[^a-z0-9]+/, " ", t); gsub(/^ +| +$/, "", t)
        printf "%s\t%s\t%s\t%s\n", id, tag, file, t
      }
      id=""; tag=""; file=""; title=""
    }
    /^### F[0-9]+-[0-9]+/ {
      flush()
      id=$2
      tag="UNKNOWN"
      if (match($0, /\[MECHANICAL\]/)) tag="MECHANICAL"
      else if (match($0, /\[DESIGN\]/)) tag="DESIGN"
      title=$0
      sub(/^### F[0-9]+-[0-9]+[ ]*(\[[A-Z]+\][ ]*)?/, "", title)
      next
    }
    /^-[ ]*file:/ {
      if (id != "" && file == "") {
        file=$0
        sub(/^-[ ]*file:[ ]*/, "", file)
        sub(/:[0-9]+.*$/, "", file)
        gsub(/^[ ]+|[ ]+$/, "", file)
      }
      next
    }
    END { flush() }
  ' "$1" 2>/dev/null
}

# Parse author response → "id<TAB>FIXED|REJECTED|UNKNOWN" per finding.
parse_responses() { # $1 = response file
  awk '
    /^### F[0-9]+-[0-9]+:/ {
      id=$2; sub(/:$/, "", id)
      disp="UNKNOWN"
      if (match($0, /:[ ]*FIXED/)) disp="FIXED"
      else if (match($0, /:[ ]*REJECTED/)) disp="REJECTED"
      print id "\t" disp
      next
    }
  ' "$1" 2>/dev/null
}

# Upsert one finding into the registry.
update_registry() { # $1=fp $2=tag $3=round $4=disposition
  local fp="$1" tag="$2" n="$3" disp="$4"
  local tmp="${REGISTRY_FILE}.tmp.$$"
  touch "$REGISTRY_FILE"
  awk -F'\t' -v OFS='\t' -v fp="$fp" -v tag="$tag" -v n="$n" -v disp="$disp" '
    $1==fp {
      found=1; lastrej=$3; streak=$4; status=$5
      if (disp=="REJECTED") { if (lastrej==n-1) streak=streak+1; else streak=1; lastrej=n }
      else { streak=0 }
      print $1, tag, lastrej, streak, status
      next
    }
    { print }
    END {
      if (!found) {
        if (disp=="REJECTED") print fp, tag, n, 1, "open"
        else print fp, tag, 0, 0, "open"
      }
    }
  ' "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

# Fold one round's findings+responses into the registry (idempotent per round).
fold_registry() { # $1 = round
  local n="$1"
  local marker; marker=$(cat "$REG_MARKER" 2>/dev/null || echo 0)
  case "$marker" in ''|*[!0-9]*) marker=0;; esac
  [ "$n" -le "$marker" ] && return 0
  local rf resp; rf=$(review_file "$n"); resp=$(response_file "$n")
  [ -f "$rf" ] && [ -f "$resp" ] || return 0
  local dmap; dmap=$(mktemp) || return 0
  parse_responses "$resp" > "$dmap"
  local id tag file nt disp fp
  while IFS=$'\t' read -r id tag file nt; do
    [ -n "$id" ] || continue
    disp=$(awk -F'\t' -v i="$id" '$1==i{print $2; exit}' "$dmap")
    [ -n "$disp" ] || disp="UNKNOWN"
    fp="${file} | ${nt}"
    update_registry "$fp" "$tag" "$n" "$disp"
  done < <(parse_findings "$rf")
  rm -f "$dmap"
  echo "$n" > "$REG_MARKER"
}

# Fingerprints at a 2-round stalemate and not yet escalated.
new_stalemates() {
  [ -f "$REGISTRY_FILE" ] || return 0
  awk -F'\t' '$4>=2 && $5=="open" {print $1}' "$REGISTRY_FILE" 2>/dev/null
}

# Mark a fingerprint escalated so it never re-fires.
mark_escalated() { # $1=fp
  local fp="$1" tmp="${REGISTRY_FILE}.tmp.$$"
  [ -f "$REGISTRY_FILE" ] || return 0
  awk -F'\t' -v OFS='\t' -v fp="$fp" '$1==fp{$5="escalated"} {print}' \
    "$REGISTRY_FILE" > "$tmp" && mv "$tmp" "$REGISTRY_FILE"
}

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

  local prompt ledger=""
  prompt=$(cat "$tpl_dir/reviewer.md")
  [ -f "$LEDGER_FILE" ] && ledger=$(cat "$LEDGER_FILE")
  prompt=${prompt//\{\{TASK\}\}/$TASK}
  prompt=${prompt//\{\{ROUND\}\}/$n}
  prompt=${prompt//\{\{DIFF_BASE\}\}/$BASE}
  prompt=${prompt//\{\{LEDGER\}\}/$ledger}

  mkdir -p reviews .claude
  printf '%s' "$prompt" > "$PROMPT_FILE"

  local out; out=$(review_file "$n")
  cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
# sparring reviewer runner — round ${n} (generated; do not edit)
set -uo pipefail
mkdir -p reviews
codex exec --sandbox read-only --skip-git-repo-check \\
  --output-last-message "${out}" < "${PROMPT_FILE}"
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
  review)
    RF=$(review_file "$ROUND"); RESP=$(response_file "$ROUND")

    if [ ! -f "$RF" ]; then
      n=$(cat "$RETRY_FILE" 2>/dev/null || echo 0); n=$((n+1))
      if [ "$n" -ge 3 ]; then
        log "reviewer never produced $RF — fail open"; cleanup; approve
      fi
      echo "$n" > "$RETRY_FILE"
      block "Round ${ROUND} review has not been produced yet. Run:
\`\`\`
bash ${RUNNER}
\`\`\`" "sparring [${REVIEW_ID}] round ${ROUND}: reviewer pending"
    fi
    STATUS=$(head -1 "$RF" | tr -d '\r')
    if [ "$STATUS" = "STATUS: CONVERGED" ]; then
      log "converged at round $ROUND"; cleanup; approve
    fi

    if [ "$STATUS" != "STATUS: FINDINGS" ]; then
      n=$(cat "$RETRY_FILE" 2>/dev/null || echo 0); n=$((n+1))
      if [ "$n" -ge 3 ]; then
        log "reviewer output invalid ${n}x — fail open"; cleanup; approve
      fi
      echo "$n" > "$RETRY_FILE"
      mv "$RF" "${RF}.invalid-${n}" 2>/dev/null
      block "Round ${ROUND} reviewer output is invalid — its first line is
neither 'STATUS: CONVERGED' nor 'STATUS: FINDINGS', so the reviewer likely
failed (the bad output was set aside as ${RF}.invalid-${n}). Never treat a
blank or malformed review as findings or as convergence. Re-run:
\`\`\`
bash ${RUNNER}
\`\`\`" "sparring [${REVIEW_ID}] round ${ROUND}: invalid reviewer output"
    fi
    rm -f "$RETRY_FILE"

    if [ ! -f "$RESP" ]; then
      block "Round ${ROUND} review has findings you have not responded to.

Read ${RF}. Fix every [MECHANICAL] finding. Decide each [DESIGN] finding on
the merits. Then write ${RESP} with one section per finding ID:
'FIXED — <what you did>' or 'REJECTED — <reason grounded in code or the task
requirements>'. Then stop again." \
        "sparring [${REVIEW_ID}] round ${ROUND}: respond to findings"
    fi

    fold_registry "$ROUND"

    STALE=$(new_stalemates)
    if [ -n "$STALE" ]; then
      while IFS= read -r fp; do [ -n "$fp" ] && mark_escalated "$fp"; done <<STALE_EOF
$STALE
STALE_EOF
      block "Stalemate: the following finding(s) were raised by the reviewer AND
rejected by you for 2 consecutive rounds:

${STALE}

Automated adjudication (blind judge / batched user gate) lands in Phase 2b.
For now, do NOT keep deciding this yourself: surface the disagreement to the
user — give the reviewer's problem and your rejection reason — and let them
rule. Apply their decision and note it. Then stop again; the loop continues
on everything else (this stalemate will not be raised again)." \
        "sparring [${REVIEW_ID}] round ${ROUND}: stalemate — user decision needed"
    fi

    if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
      log "round cap ${MAX_ROUNDS} reached — unconverged exit"
      tmp="${STATE_FILE}.tmp.$$"
      awk '/^active:/{print "active: false"; next}{print}' "$STATE_FILE" > "$tmp" \
        && mv "$tmp" "$STATE_FILE"
      block "Round cap (${MAX_ROUNDS}) reached and the reviewer has NOT
converged. Do not keep fixing. Report to the user: the loop ended
unconverged — summarize the unresolved findings from ${RF} honestly, then
stop. The loop is now deactivated; your next stop will be released." \
        "sparring [${REVIEW_ID}]: round cap — unconverged"
    fi

    NEXT=$((ROUND + 1))
    prepare_round "$NEXT"
    set_state review "$NEXT"
    block "Response recorded. Round ${NEXT} verification review is required. Run:
\`\`\`
bash ${RUNNER}
\`\`\`
Then handle $(review_file "$NEXT") exactly as before (fix / respond / stop)." \
      "sparring [${REVIEW_ID}] round ${NEXT}: run reviewer"
    ;;
  *)
    log "unknown phase: $PHASE"; cleanup; approve
    ;;
esac
