#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I="$ROOT/plugins/spar/commands/spar-ready-ingest.sh"
LIB="$ROOT/plugins/spar/commands/spar-plan-lib.sh"; . "$LIB"
chk(){ if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "  want:[$2]"; echo "  got :[$3]"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d); PLAN="$TMP/plan.md"; ST="$TMP/state.md"
cat > "$PLAN" <<'EOF'
# X Plan
### Task 1: Alpha
- [ ] Step 1
### Task 2: Beta component
- [ ] Step 1
### Task 3: Gamma
EOF
printf -- '---\nactive: true\nphase: plan\nmode: per-task\nreviewer: codex\nplan_path: %s\nbranch: /tmp/wt\ntasks: 0\ncurrent: 1\ncurrent_review_id:\n---\n' "$PLAN" > "$ST"

bash "$I" "$PLAN" per-task "$ST"
chk "counts 3 tasks" "3" "$(plan_field tasks "$ST")"
chk "phase planned" "planned" "$(plan_field phase "$ST")"
chk "task 2 heading" "Task 2: Beta component" "$(plan_task_line 2 "$ST" | cut -f3)"
chk "task 3 status" "pending" "$(plan_task_line 3 "$ST" | cut -f2)"

# whole mode → single synthetic task
printf -- '---\nactive: true\nphase: plan\nmode: whole\nreviewer: codex\nplan_path: %s\nbranch: /tmp/wt\ntasks: 0\ncurrent: 1\ncurrent_review_id:\n---\n' "$PLAN" > "$ST"
bash "$I" "$PLAN" whole "$ST"
chk "whole → 1 task" "1" "$(plan_field tasks "$ST")"
chk "whole heading" "WHOLE PLAN" "$(plan_task_line 1 "$ST" | cut -f3)"

rm -rf "$TMP"
# v0.10.0: the sixth resolver field is destructured, and the spec stays last.
# Nothing fails loudly if this is missed: the spec text silently becomes the word
# "true" and the plan gets written against it.
# chk here is an exact-equality check, so ask for a computed yes/no.
has() { grep -qF -- "$2" "$1" && echo yes || echo no; }
# The Claude seat's two documents. The Codex mirrors are asserted in
# tests/test_codex_adapter.sh, which is the suite that fails when a mirror
# drifts — putting them here would leave that suite green on a broken adapter.
chk "ready.md destructures plan_review" "yes" \
  "$(has "$ROOT/plugins/spar/commands/ready.md" 'RDY_PLAN_REVIEW=')"
chk "ready.md destructures verify_spec" "yes" \
  "$(has "$ROOT/plugins/spar/commands/ready.md" 'RDY_VERIFY_SPEC=')"
chk "fight.md destructures plan_review" "yes" \
  "$(has "$ROOT/plugins/spar/commands/fight.md" 'SPAR_PLAN_REVIEW=')"
# Behavioural, not a substring: the resolver's own output must put flags before
# the final free-text field.
RR="$ROOT/plugins/spar/commands/spar-ready-resolve.sh"
chk "the flag lands in field 4" "false" "$(bash "$RR" "--no-plan-review -- some spec" | cut -f4)"
chk "the spec verification flag lands in field 5" "true" "$(bash "$RR" "--verify-spec -- some spec" | cut -f5)"
chk "and the spec in field 6" "some spec" "$(bash "$RR" "--no-plan-review -- some spec" | cut -f6)"

# ── Phase 9: the Claude seat captures the spec and records the fields ───────
chk "ready.md captures the spec" "yes" \
  "$(has "$ROOT/plugins/spar/commands/ready.md" 'spar-plan-spec.txt')"
chk "ready.md records plan_review" "yes" \
  "$(has "$ROOT/plugins/spar/commands/ready.md" 'plan_review:')"
chk "ready.md records plan_review_id" "yes" \
  "$(has "$ROOT/plugins/spar/commands/ready.md" 'plan_review_id:')"
chk "ready.md prints spec verification mode" "yes" \
  "$(has "$ROOT/plugins/spar/commands/ready.md" 'spec-verify=')"
chk "ready.md runs spec verification before branch creation" "yes" \
  "$(awk '/spar-spec-verify-check\.sh/{v=NR} /git checkout -b/{b=NR} END{print (v && b && v < b) ? "yes" : "no"}' "$ROOT/plugins/spar/commands/ready.md")"
chk "ready.md runs spec verification before plan state" "yes" \
  "$(awk '/spar-spec-verify-check\.sh/{v=NR} /cat > "\$TMP" <<STATE_EOF/{s=NR} END{print (v && s && v < s) ? "yes" : "no"}' "$ROOT/plugins/spar/commands/ready.md")"
chk "ready.md tells planner to read spec verification" "yes" \
  "$(has "$ROOT/plugins/spar/commands/ready.md" '.claude/spar-spec-verify.md')"
# The capture is only authoritative if the plan is written from it. Scoped to the
# authoring step, not the whole document: the path appears in the setup block
# regardless, so a document-wide grep would pass while step 1 still sent the
# author back to the mutable original.
RM="$ROOT/plugins/spar/commands/ready.md"
STEP1="$(awk '/^1\. \*\*Produce the plan/{f=1} f&&/^2\. /{exit} f' "$RM")"
chk "ready.md's authoring step reads the captured spec" "yes" \
  "$(printf '%s' "$STEP1" | grep -qF '.claude/spar-plan-spec.txt' && echo yes || echo no)"
# The old "stop after ingest" wording predates the review step, which comes
# after ingest — an author following it literally skips the review entirely.
chk "ready.md no longer says to stop after ingest" "no" \
  "$(has "$RM" 'stop after ingest')"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
