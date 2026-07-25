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
  # Physical cwd: on macOS mktemp hands back /var/... where /var is a symlink,
  # and the generator (correctly) refuses to publish under a symlinked ancestor.
  # The absolute-path cases below need a path with no symlinked component.
  cd "$(pwd -P)" || exit 1
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

# ── 9. symlinked ancestor → refused, and nothing is created through it ──
fresh
outside=$(mktemp -d)
ln -s "$outside" link
bash "$GEN" "$ID" none link/new >/dev/null 2>&1
chk "symlinked ancestor → exit 3" "3" "$?"
chk "no directory created through the symlink" "absent" \
  "$([ -d "$outside/new" ] && echo present || echo absent)"
chk "no report written through the symlink" "absent" \
  "$([ -f "$outside/new/spar-${ID}-report.md" ] && echo present || echo absent)"

# ── 10. custom reviews/state dirs → their artifacts stay out of the surface ──
fresh
mkdir -p myrev mystate
printf -- '---\nreason: converged\nreview_id: %s\nrounds: 1\nreviewer: codex\nsweep: not-run\n---\n' \
  "$ID" > "myrev/spar-${ID}-outcome.md"
printf -- '---\nactive: true\nround: 1\nreviewer: codex\nsweep_result: not-run\n---\n' \
  > mystate/spar.local.md
printf 'brand new\n' > newmod.py
bash "$GEN" "$ID" none myrev mystate >/dev/null 2>&1
OUT="$(cat "myrev/spar-${ID}-report.md" 2>/dev/null)"
chk "custom dirs → report written there" "- outcome: converged" "$OUT"
chk "real untracked file still listed" "- newmod.py" "$OUT"
chk_absent "custom reviews dir kept out of the surface" "myrev/" "$OUT"
chk_absent "custom state dir kept out of the surface" "mystate/" "$OUT"
chk_absent "report temp file kept out of the surface" ".spar-report-" "$OUT"

# ── 11. absolute custom dirs → still recognized as artifact dirs ──
fresh
mkdir -p myrev mystate
printf -- '---\nreason: converged\nreview_id: %s\nrounds: 1\nreviewer: codex\nsweep: not-run\n---\n' \
  "$ID" > "myrev/spar-${ID}-outcome.md"
printf -- '---\nactive: true\nround: 1\nreviewer: codex\nsweep_result: not-run\n---\n' \
  > mystate/spar.local.md
printf 'brand new\n' > newmod.py
bash "$GEN" "$ID" none "$PWD/myrev" "$PWD/mystate" >/dev/null 2>&1
OUT="$(cat "myrev/spar-${ID}-report.md" 2>/dev/null)"
chk "absolute dirs → report written there" "- outcome: converged" "$OUT"
chk "absolute dirs → real untracked file still listed" "- newmod.py" "$OUT"
chk_absent "absolute reviews dir kept out of the surface" "myrev/" "$OUT"
chk_absent "absolute state dir kept out of the surface" "mystate/" "$OUT"
chk_absent "absolute dirs → temp file kept out of the surface" ".spar-report-" "$OUT"

# ── 12. read-only state dir may contain '..' and is still recognized ──
fresh
mkdir -p sub myrev mystate
printf -- '---\nreason: converged\nreview_id: %s\nrounds: 1\nreviewer: codex\nsweep: not-run\n---\n' \
  "$ID" > "myrev/spar-${ID}-outcome.md"
printf -- '---\nactive: true\nround: 1\nreviewer: codex\nsweep_result: not-run\n---\n' \
  > mystate/spar.local.md
printf 'brand new\n' > newmod.py
bash "$GEN" "$ID" none myrev sub/../mystate >/dev/null 2>&1
OUT="$(cat "myrev/spar-${ID}-report.md" 2>/dev/null)"
chk "dotdot state dir → report written" "- outcome: converged" "$OUT"
chk "dotdot state dir → real untracked file still listed" "- newmod.py" "$OUT"
chk_absent "dotdot state dir kept out of the surface" "mystate/" "$OUT"
chk_absent "dotdot state dir → temp file kept out of the surface" ".spar-report-" "$OUT"

# ── 13. '..' in the WRITE target is refused (it defeats the symlink guard) ──
fresh
outside=$(mktemp -d)
ln -s "$outside" link
bash "$GEN" "$ID" none missing/../link/new >/dev/null 2>&1
chk "dotdot reviews-dir → exit 3" "3" "$?"
chk "dotdot reviews-dir → nothing created through the symlink" "absent" \
  "$([ -d "$outside/new" ] && echo present || echo absent)"
chk "dotdot reviews-dir → no partial component created" "absent" \
  "$([ -d missing ] && echo present || echo absent)"
bash "$GEN" "$ID" none sub/../myrev >/dev/null 2>&1
chk "plain dotdot reviews-dir also refused" "3" "$?"

# ── 14. artifact dir == working directory → filtered by name, not skipped ──
fresh
printf -- '---\nreason: converged\nreview_id: %s\nrounds: 1\nreviewer: codex\nsweep: not-run\n---\n' \
  "$ID" > "spar-${ID}-outcome.md"
printf -- '---\nactive: true\nround: 1\nreviewer: codex\nsweep_result: not-run\n---\n' \
  > spar.local.md
printf '# decisions\n' > spar-ledger.md
printf 'brand new\n' > newmod.py
bash "$GEN" "$ID" none . . >/dev/null 2>&1
OUT="$(cat "spar-${ID}-report.md" 2>/dev/null)"
chk "cwd as artifact dir → report written" "- outcome: converged" "$OUT"
chk "cwd as artifact dir → real untracked file still listed" "- newmod.py" "$OUT"
chk_absent "cwd outcome artifact kept out of the surface" "outcome.md" "$OUT"
chk_absent "cwd report artifact kept out of the surface" "report.md" "$OUT"
chk_absent "cwd state artifact kept out of the surface" "spar.local.md" "$OUT"
chk_absent "cwd ledger artifact kept out of the surface" "spar-ledger.md" "$OUT"
chk_absent "cwd temp file kept out of the surface" ".spar-report-" "$OUT"

# ── 15. mixed dirs → each group's name filter applies only to its own dir ──
fresh
mkdir -p myrev
printf -- '---\nreason: converged\nreview_id: %s\nrounds: 1\nreviewer: codex\nsweep: not-run\n---\n' \
  "$ID" > "myrev/spar-${ID}-outcome.md"
printf -- '---\nactive: true\nround: 1\nreviewer: codex\nsweep_result: not-run\n---\n' \
  > spar.local.md
printf '# decisions\n' > spar-ledger.md
# A real project file whose name collides with the review-artifact pattern. Review
# artifacts live under myrev/, so this must NOT be filtered.
printf 'helper\n' > "spar-${ID}-helper.py"
printf 'brand new\n' > newmod.py
bash "$GEN" "$ID" none myrev . >/dev/null 2>&1
OUT="$(cat "myrev/spar-${ID}-report.md" 2>/dev/null)"
chk "mixed dirs → report written" "- outcome: converged" "$OUT"
chk "mixed dirs → real untracked file listed" "- newmod.py" "$OUT"
chk "mixed dirs → id-shaped project file still listed" "- spar-${ID}-helper.py" "$OUT"
chk_absent "mixed dirs → cwd state file filtered" "spar.local.md" "$OUT"
chk_absent "mixed dirs → cwd ledger filtered" "spar-ledger.md" "$OUT"
chk_absent "mixed dirs → reviews dir filtered" "myrev/" "$OUT"

# ── 16. reviews-dir=. → every artifact shape filtered, id-shaped code kept ──
fresh
printf -- '---\nreason: converged\nreview_id: %s\nrounds: 1\nreviewer: codex\nsweep: not-run\n---\n' \
  "$ID" > "spar-${ID}-outcome.md"
printf 'STATUS: FINDINGS\n' > "spar-${ID}-r1.md"
printf '### F1-1: FIXED — done\n' > "spar-${ID}-r1-response.md"
printf 'RULING: UPHELD\n' > "spar-${ID}-judge-1.md"
printf 'SWEEP: CLEAN\n' > "spar-${ID}-sweep.md"
printf 'SAME\n' > "spar-${ID}-matcher-r2.md"
printf 'bad\n' > "spar-${ID}-r2.md.invalid-1"
printf '## pending\n' > spar-pending.md
# Real project files that merely start like a review artifact — must stay listed.
printf 'helper\n' > "spar-${ID}-helper.py"
printf 'runner\n' > "spar-${ID}-runtime.md"
printf 'brand new\n' > newmod.py
bash "$GEN" "$ID" none . >/dev/null 2>&1
OUT="$(cat "spar-${ID}-report.md" 2>/dev/null)"
chk "reviews-dir=. → report written" "- outcome: converged" "$OUT"
chk "reviews-dir=. → real untracked file listed" "- newmod.py" "$OUT"
chk "reviews-dir=. → id-shaped project file listed" "- spar-${ID}-helper.py" "$OUT"
chk "reviews-dir=. → r-prefixed project file listed" "- spar-${ID}-runtime.md" "$OUT"
chk_absent "round review filtered" "-r1.md" "$OUT"
chk_absent "set-aside review filtered" ".invalid-1" "$OUT"
chk_absent "judge ruling filtered" "judge-1.md" "$OUT"
chk_absent "sweep artifact filtered" "sweep.md" "$OUT"
chk_absent "matcher artifact filtered" "matcher-r2.md" "$OUT"
chk_absent "pending queue filtered" "spar-pending.md" "$OUT"
chk_absent "outcome filtered" "outcome.md" "$OUT"
chk_absent "report filtered" "report.md" "$OUT"
chk_absent "temp file filtered" ".spar-report-" "$OUT"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
