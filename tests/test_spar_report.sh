#!/usr/bin/env bash
# Pure-bash tests for plugins/spar/commands/spar-report.sh
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/plugins/spar/commands/spar-report.sh"
ID=20260721-120000-abc123
R="reviews/spar-${ID}-report.md"

# NOTE: `grep -qF -- "$2"` — the `--` is required. Many expectations here start
# with "- " (report list items) and grep would otherwise read them as options.
chk() { # $1=desc $2=expected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi
}
chk_absent() { # $1=desc $2=unexpected-substring $3=actual
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; echo "  unwanted:$2"; FAIL=$((FAIL+1))
  else echo "PASS: $1"; PASS=$((PASS+1)); fi
}

fresh() {
  d=$(mktemp -d); cd "$d" || exit 1
  mkdir -p reviews .claude
  git init -q
  git config user.email t@example.com
  git config user.name t
}

outcome() { # $1=reason $2=rounds $3=reviewer $4=sweep
  printf -- '---\nreason: %s\nreview_id: %s\nrounds: %s\nreviewer: %s\nsweep: %s\nrecorded_at: 2026-07-25T00:00:00Z\n---\n' \
    "$1" "$ID" "$2" "$3" "$4" > "reviews/spar-${ID}-outcome.md"
}

state() { # $1=round $2=reviewer $3=sweep_result
  cat > .claude/spar.local.md <<EOF
---
active: true
phase: review
round: $1
review_id: ${ID}
base_sha: none
reviewer: $2
max_rounds: 5
sweep_done: false
sweep_result: $3
---

do the thing
EOF
}

# ── 1. result header comes from the outcome file ──
fresh; outcome converged 3 codex clean; state 3 codex clean
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "report written" "present" "$([ -f "$R" ] && echo present || echo absent)"
OUT="$(cat "$R" 2>/dev/null)"
chk "title carries the review id" "# sparring run report — ${ID}" "$OUT"
chk "result section present" "## Result" "$OUT"
chk "outcome reason" "- outcome: converged" "$OUT"
chk "rounds" "- rounds: 3" "$OUT"
chk "codex → cross-model pairing" "- reviewer: codex — cross-model" "$OUT"
chk "sweep result" "- sweep: clean" "$OUT"
chk "base sha line" "- base_sha: none" "$OUT"
chk "generated_at stamped" "- generated_at: 20" "$OUT"
chk "changed files section present" "## Changed files" "$OUT"

# ── 2. claude reviewer → same-model pairing ──
fresh; outcome converged 2 claude not-triggered; state 2 claude not-triggered
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "claude → same-model pairing" "- reviewer: claude — same-model" "$(cat "$R")"

# ── 3. no outcome file → falls back to the state file, reason unknown ──
fresh; state 4 codex findings
bash "$GEN" "$ID" none >/dev/null 2>&1
OUT="$(cat "$R" 2>/dev/null)"
chk "missing outcome → unknown reason" "- outcome: unknown" "$OUT"
chk "missing outcome → rounds from state" "- rounds: 4" "$OUT"
chk "missing outcome → reviewer from state" "- reviewer: codex" "$OUT"

# ── 4. invalid review id → usage error, nothing written ──
fresh
bash "$GEN" "../../evil" none >/dev/null 2>&1
chk "invalid id → exit 2" "2" "$?"
chk "invalid id → no stray file" "absent" "$([ -f reviews/spar-../../evil-report.md ] && echo present || echo absent)"

# ── 5. symlinked report path → refused, never followed ──
fresh; outcome converged 1 codex not-run
outside=$(mktemp); printf 'ORIGINAL\n' > "$outside"
ln -s "$outside" "$R"
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "symlink target → exit 3" "3" "$?"
chk "symlink target untouched" "ORIGINAL" "$(cat "$outside")"

# ── 6. unusable baseline → soft note, report still produced ──
fresh; outcome converged 1 codex not-run
bash "$GEN" "$ID" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1
chk "bad baseline → soft note" "(no usable baseline" "$(cat "$R")"

# ── 7. real baseline → diff --stat of tracked change, untracked files listed ──
fresh; outcome converged 1 codex not-run
printf 'one\n' > mod.py
git add mod.py; git commit -qm base
BASE="$(git rev-parse HEAD)"
printf 'one\ntwo\n' > mod.py
printf 'brand new\n' > newmod.py
bash "$GEN" "$ID" "$BASE" >/dev/null 2>&1
OUT="$(cat "$R")"
chk "diff --stat lists the changed file" "mod.py" "$OUT"
chk "diff --stat summary line" "1 file changed" "$OUT"
chk "untracked section" "Untracked (new) files:" "$OUT"
chk "untracked file listed" "- newmod.py" "$OUT"
chk_absent "loop artifacts never listed as untracked" "outcome.md" "$OUT"

# ── 8. re-run overwrites in place (regular file), still exactly one report ──
fresh; outcome converged 1 codex not-run
bash "$GEN" "$ID" none >/dev/null 2>&1
bash "$GEN" "$ID" none >/dev/null 2>&1
chk "re-run → exit 0" "0" "$?"
chk "one title only" "1" "$(grep -c '^# sparring run report' "$R")"
chk_absent "no temp files left behind" ".spar-report-" "$(ls -a reviews)"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
