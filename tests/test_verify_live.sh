#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$ROOT/adapters/codex/verify-live.sh"
chk() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent() { if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }
# Each case gets its own tree AND its own HOME/CODEX_HOME, so a bug in the
# harness's own isolation cannot reach the developer's real Codex home from here.
fresh() { d=$(mktemp -d); cd "$d" || exit 1; cd "$(pwd -P)" || exit 1
  export HOME="$PWD/.testhome" CODEX_HOME="$PWD/.testcodex"; }

# 1. no subcommand → usage, exit 2
fresh
OUT=$(bash "$V" 2>&1); RC=$?
chk "no subcommand → exit 2" "2" "$RC"
chk "no subcommand → prints usage" "usage:" "$OUT"

# 2. setup builds the workspace
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
chk "setup → workspace marker" "spar-live-verify" "$(cat ./ws/.spar-live-workspace 2>/dev/null)"
chk "setup → isolated home has hooks.json" "stop-fight.sh" "$(cat ./ws/home/hooks.json 2>/dev/null)"
chk "setup → all four skills installed" "4" \
  "$(ls ./ws/home/skills 2>/dev/null | wc -l | tr -d ' ')"
chk "setup → scratch repo is a git repo" "true" \
  "$(git -C ./ws/repo rev-parse --is-inside-work-tree 2>/dev/null)"
chk "setup → planted bug present" "range(1, n)" "$(cat ./ws/repo/sum_to.py 2>/dev/null)"
chk "setup → task description present" "sum_to" "$(cat ./ws/repo/TASK.md 2>/dev/null)"
chk "setup → checklist saved" "trust" "$(cat ./ws/checklist.md 2>/dev/null)"

# 3. the real CODEX_HOME is never a target
fresh
OUT=$(CODEX_HOME="$PWD/.testcodex" bash "$V" setup --dir "$PWD/.testcodex/ws" 2>&1); RC=$?
chk "target inside the real CODEX_HOME → exit 3" "3" "$RC"
chk "target inside the real CODEX_HOME → says so" "refusing" "$OUT"
chk_absent "target inside the real CODEX_HOME → nothing written" "ws" \
  "$(ls "$PWD/.testcodex" 2>/dev/null)"

# 3b. containment is a resolved-path question, not a string-prefix one
fresh
mkdir -p ./.testcodex
OUT=$(bash "$V" setup --dir "$PWD/nowhere/../.testcodex/ws" 2>&1); RC=$?
chk "dot-dot into the real CODEX_HOME → exit 3" "3" "$RC"
chk "dot-dot into the real CODEX_HOME → says refusing" "refusing" "$OUT"
chk_absent "dot-dot into the real CODEX_HOME → nothing written" "ws" \
  "$(ls ./.testcodex 2>/dev/null)"

fresh
mkdir -p ./.testcodex
ln -s ./.testcodex ./alias
OUT=$(bash "$V" setup --dir ./alias/ws 2>&1); RC=$?
chk "symlink alias of the real CODEX_HOME → exit 3" "3" "$RC"
chk_absent "symlink alias → nothing written through it" "ws" \
  "$(ls ./.testcodex 2>/dev/null)"

# 3c. a symlinked ANCESTOR of an otherwise-fine target is resolved, not trusted
fresh
mkdir -p ./real-elsewhere
ln -s ./real-elsewhere ./link
bash "$V" setup --dir ./link/ws >/dev/null 2>&1
chk "symlinked ancestor outside CODEX_HOME → still allowed" "spar-live-verify" \
  "$(cat ./real-elsewhere/ws/.spar-live-workspace 2>/dev/null)"

# 3d. a CODEX_HOME that resolves to the filesystem root contains everything
fresh
OUT=$(CODEX_HOME=/ bash "$V" setup --dir ./ws 2>&1); RC=$?
chk "CODEX_HOME=/ → any target refused" "3" "$RC"
chk "CODEX_HOME=/ → says refusing" "refusing" "$OUT"
chk_absent "CODEX_HOME=/ → nothing written" "present" \
  "$([ -e ./ws ] && echo present || echo absent)"
OUT=$(CODEX_HOME=/ bash "$V" clean --dir ./ws 2>&1); RC=$?
chk "CODEX_HOME=/ → clean refused too" "3" "$RC"

# 3e. the workspace being exactly CODEX_HOME is refused, not just a descendant.
# Deliberately NOT pre-created: if the directory existed, the "not a harness
# workspace" guard would refuse it too and this check would pass even with the
# containment test broken.
fresh
OUT=$(bash "$V" setup --dir ./.testcodex 2>&1); RC=$?
chk "workspace equal to CODEX_HOME → exit 3" "3" "$RC"
chk "workspace equal to CODEX_HOME → refused for containment, not existence" \
  "refusing" "$OUT"

# 3f. a newline in a path would shift the resolver's fields, so it is refused
fresh
mkdir -p ./victim && printf 'precious\n' > ./victim/keep.txt
OUT=$(bash "$V" setup --dir "$(printf './victim\n/elsewhere')" 2>&1); RC=$?
chk "newline in --dir → exit 3" "3" "$RC"
chk "newline in --dir → says so" "must not contain a newline" "$OUT"
chk "newline in --dir → the shorter path was NOT touched" "precious" \
  "$(cat ./victim/keep.txt 2>/dev/null)"
chk_absent "newline in --dir → no workspace created there" "spar-live-workspace" \
  "$(ls -a ./victim 2>/dev/null)"

# The dangerous shape: the prefix the fields would collapse to is ALREADY a
# harness workspace, so the "not ours" guard would wave it through and only the
# newline refusal stands between it and rm -rf.
fresh
bash "$V" setup --dir ./victim >/dev/null 2>&1
printf 'irreplaceable\n' > ./victim/keep.txt
OUT=$(bash "$V" clean --dir "$(printf './victim\n/elsewhere')" 2>&1); RC=$?
chk "newline collapsing onto a real workspace → refused" "3" "$RC"
chk "newline collapsing onto a real workspace → it survives" "irreplaceable" \
  "$(cat ./victim/keep.txt 2>/dev/null)"
OUT=$(CODEX_HOME="$(printf '/tmp/a\n/b')" bash "$V" setup --dir ./ws 2>&1); RC=$?
chk "newline in CODEX_HOME → exit 3" "3" "$RC"

# 3g. a newline the INPUT never had, introduced by resolving a symlink. The
# prefix it would collapse to is a real workspace, so only this guard protects it.
fresh
NL_DIR="$(printf 'tgt\nX')"
mkdir -p "./$NL_DIR"
bash "$V" setup --dir ./tgt >/dev/null 2>&1
printf 'irreplaceable\n' > ./tgt/keep.txt
ln -s "$PWD/$NL_DIR" ./nl-link
OUT=$(bash "$V" clean --dir ./nl-link/ws 2>&1); RC=$?
chk "newline via a resolved symlink → exit 3" "3" "$RC"
chk "newline via a resolved symlink → says the RESOLVED path is at fault" \
  "resolved" "$OUT"
chk "newline via a resolved symlink → the collapsed workspace survives" \
  "irreplaceable" "$(cat ./tgt/keep.txt 2>/dev/null)"
OUT=$(bash "$V" setup --dir ./nl-link/ws 2>&1); RC=$?
chk "newline via a resolved symlink → setup refuses too" "3" "$RC"
chk "newline via a resolved symlink → setup did not wipe it" \
  "irreplaceable" "$(cat ./tgt/keep.txt 2>/dev/null)"

# 4. re-running is safe: same marker, no duplication
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf 'stale\n' > ./ws/repo/leftover.txt
bash "$V" setup --dir ./ws >/dev/null 2>&1; RC=$?
chk "re-run → exit 0" "0" "$RC"
chk "re-run → stale file gone" "absent" \
  "$([ -e ./ws/repo/leftover.txt ] && echo present || echo absent)"
chk "re-run → workspace still valid" "spar-live-verify" "$(cat ./ws/.spar-live-workspace 2>/dev/null)"

# 5. a directory that is not ours is refused rather than wiped
fresh
mkdir -p ./notours && printf 'precious\n' > ./notours/keep.txt
OUT=$(bash "$V" setup --dir ./notours 2>&1); RC=$?
chk "non-workspace dir → exit 3" "3" "$RC"
chk "non-workspace dir → file untouched" "precious" "$(cat ./notours/keep.txt)"

# 6. the checklist names all four items and does not claim to automate them
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
CL="$(cat ./ws/checklist.md)"
for item in "trust" "scope" "SessionStart" "CONVERGED"; do
  chk "checklist covers $item" "$item" "$CL"
done
chk "checklist tells the human to run codex themselves" "codex" "$CL"
chk "checklist prints the isolated home to use" "CODEX_HOME=" "$CL"
# 6b. Phase 9 added a plan path to this seat and the checklist went a whole
# release without mentioning it — items 1-4 all drive spar-fight with a task,
# which is the single-task path.
chk "the checklist drives the plan path" "spar-ready" "$CL"
chk "and names the flag it must print" "plan-review=required" "$CL"
chk "and asks for the seat-correct refusal" "spar-cancel" "$CL"
# The one thing artifacts cannot show, so the human is asked for it explicitly.
# Anchored on wording unique to this item: "refuse" alone already appears in
# item 3's text, so a bare match passed before the item existed.
chk "and asks the human whether fight refused first" "did spar-fight refuse" "$CL"
# A CLEAN review has no missing disposition and cannot produce a refusal, so the
# item has to say what to do then rather than leaving the human stuck.
chk "and says what to do when the review comes back clean" "CLEAN" "$CL"
# The escape hatch has a prerequisite: spar-ready refuses while a plan is ready or
# a loop is active, which is the state the item leaves the human in. Naming the
# command without naming that is an instruction that errors out.
chk "and names the prerequisite for re-running ready" "run spar-cancel FIRST" "$CL"
# And it says the FAILED verdict a cancelled workspace produces is correct, so it
# is not read as a defect in the harness.
chk "and explains the verdict after a bare cancel" "not a bug" "$CL"

# 6c. paths the human is told to TYPE are shell-quoted; a space must not break
# the commands and a $(...) must not run when they are pasted.
fresh
EVIL="$PWD/we ird \$(touch pwned) dir/ws"
bash "$V" setup --dir "$EVIL" >/dev/null 2>&1
CL="$(cat "$EVIL/checklist.md" 2>/dev/null)"
chk "quoted path → cd line is a single quoted argument" "cd '" "$CL"
chk "quoted path → CODEX_HOME assignment is quoted" "CODEX_HOME='" "$CL"
chk "quoted path → the check command is quoted" "--dir '" "$CL"
chk_absent "quoted path → no unsubstituted placeholder" "@@" "$CL"
# Run the two command lines in a sandbox shell and confirm nothing executed.
CMDS="$(printf '%s\n' "$CL" | grep -E "^    (cd |bash )" | sed 's/^    //')"
printf '%s\n' "$CMDS" | while IFS= read -r line; do
  bash -n <(printf '%s\n' "$line") 2>/dev/null || echo "UNPARSEABLE: $line"
done > ./parse.log
chk_absent "quoted path → every generated command parses" "UNPARSEABLE" "$(cat ./parse.log)"
chk "quoted path → command substitution did not run" "absent" \
  "$(ls "$PWD" 2>/dev/null | grep -qx pwned && echo present || echo absent)"

# 6d. a symlinked marker does not make a directory ours. It is the only thing
# standing between rm -rf and someone else's files.
fresh
bash "$V" setup --dir ./real-ws >/dev/null 2>&1
mkdir -p ./impostor && printf 'precious\n' > ./impostor/keep.txt
ln -s "$PWD/real-ws/.spar-live-workspace" ./impostor/.spar-live-workspace
OUT=$(bash "$V" clean --dir ./impostor 2>&1); RC=$?
chk "symlinked marker → clean refuses" "3" "$RC"
chk "symlinked marker → the directory survives" "precious" "$(cat ./impostor/keep.txt 2>/dev/null)"
OUT=$(bash "$V" setup --dir ./impostor 2>&1); RC=$?
chk "symlinked marker → setup refuses too" "3" "$RC"
chk "symlinked marker → setup did not wipe it" "precious" "$(cat ./impostor/keep.txt 2>/dev/null)"

# 6e. setup's own deliverable is the printed checklist; failing to print it is
# not a success. stdout is closed so only the final output can fail.
fresh
bash "$V" setup --dir ./ws >&- 2>./err.log; RC=$?
chk "unprintable checklist → exit 3" "3" "$RC"
chk "unprintable checklist → says where it was saved" "checklist.md" "$(cat ./err.log)"

# 6f. the workspace path is data, not template. A path containing @@ — even the
# literal text of a placeholder — must render correctly rather than be rejected
# or rewritten by a later substitution pass.
fresh
AT="$PWD/project@@copy/@@WS@@/ws"
bash "$V" setup --dir "$AT" >/dev/null 2>&1; RC=$?
chk "path containing @@ → setup succeeds" "0" "$RC"
CL="$(cat "$AT/checklist.md" 2>/dev/null)"
chk "path containing @@ → the literal path survives into the checklist" \
  "project@@copy" "$CL"
# Exact-line comparison, not substring: a later substitution pass rewriting the
# inserted value leaves text that still CONTAINS the original segment, so only
# the whole expected command distinguishes a correct render from a mangled one.
WANT_CD="cd $(WSX="$AT" python3 -c 'import os,shlex;print(shlex.quote(os.path.join(os.environ["WSX"],"repo")))')"
GOT_CD="$(printf '%s\n' "$CL" | grep -m1 '^    cd ' | sed 's/^    //')"
chk "path containing @@ → the cd line renders exactly once, correctly" \
  "$WANT_CD" "$GOT_CD"
chk_absent "path containing @@ → no template placeholder is left unrendered" \
  "@@REPOQ@@" "$CL"
chk_absent "path containing @@ → no error was printed" "error:" \
  "$(bash "$V" setup --dir "$AT" 2>&1 >/dev/null)"

# 6g. an unknown placeholder in the TEMPLATE still fails loudly
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
chk "template validation is keyed to known names" "@@" \
  "$(grep -o '@@[A-Z]*@@' "$V" | head -1)"

# 6h. a DANGLING symlink at the target is still someone else's entry. -e is false
# for one, so without an explicit -L test the ownership guard is skipped and the
# link is deleted to make room for a workspace.
fresh
ln -s ./nowhere-at-all ./ws
OUT=$(bash "$V" setup --dir ./ws 2>&1); RC=$?
chk "dangling symlink target → setup refuses" "3" "$RC"
chk "dangling symlink target → says it is not ours" "not a harness workspace" "$OUT"
chk "dangling symlink target → the link is still there" "present" \
  "$([ -L ./ws ] && echo present || echo absent)"
chk "dangling symlink target → still dangling, nothing created" "absent" \
  "$([ -e ./ws ] && echo present || echo absent)"
OUT=$(bash "$V" clean --dir ./ws 2>&1); RC=$?
chk "dangling symlink target → clean refuses rather than shrugging" "3" "$RC"
chk_absent "dangling symlink target → clean does not claim there is nothing there" \
  "nothing to clean" "$OUT"
chk "dangling symlink target → the link survives clean too" "present" \
  "$([ -L ./ws ] && echo present || echo absent)"

# 6i. the checklist is generated from what is true on this machine. The isolated
# home inherits neither credentials nor PATH, and both stopped a real run before
# the item they were blocking.
fresh
mkdir -p ./.testcodex && printf '{}\n' > ./.testcodex/auth.json
mkdir -p ./fakebin && printf '#!/bin/sh\nexit 0\n' > ./fakebin/claude && chmod +x ./fakebin/claude
PATH="$PWD/fakebin:$PATH" bash "$V" setup --dir ./ws >/dev/null 2>&1
CL="$(cat ./ws/checklist.md)"
chk "checklist warns the isolated home has no credentials" "CREDENTIALS" "$CL"
chk "checklist gives the copy command for the real auth.json" "auth.json" "$CL"
chk "checklist warns about the cross-model default" "CROSS-MODEL REVIEW" "$CL"
chk "checklist names the PATH that makes claude reachable" "fakebin" "$CL"
chk "checklist says a same-model run does not satisfy item 4" "does NOT satisfy item 4" "$CL"

# With claude absent the advice has to change, not just be omitted.
fresh
mkdir -p ./emptybin
OUT_PATH="$PWD/emptybin:/usr/bin:/bin"
PATH="$OUT_PATH" bash "$V" setup --dir ./ws >/dev/null 2>&1
CL="$(cat ./ws/checklist.md 2>/dev/null)"
chk "no claude on the machine → says so plainly" "was not found on this machine" "$CL"
chk_absent "no claude on the machine → no PATH command that would not work" "PATH=" "$CL"

# 7. clean removes exactly the workspace
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
bash "$V" clean --dir ./ws >/dev/null 2>&1
chk "clean → workspace gone" "absent" "$([ -e ./ws ] && echo present || echo absent)"
mkdir -p ./notours
OUT=$(bash "$V" clean --dir ./notours 2>&1); RC=$?
chk "clean refuses a directory that is not ours" "3" "$RC"

# 7b. a cleanup that cannot complete is an error, not a success.
# The failure is injected with a PATH shim rather than by dropping permissions:
# mode 500 does not stop root, so a container running tests as root would fail
# this check even though the error handling is correct.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
mkdir -p ./shim
printf '#!/bin/sh\nexit 1\n' > ./shim/rm; chmod +x ./shim/rm
OUT=$(PATH="$PWD/shim:$PATH" bash "$V" clean --dir ./ws 2>&1); RC=$?
chk "unremovable workspace → exit 3" "3" "$RC"
chk "unremovable workspace → says so" "could not remove" "$OUT"
chk_absent "unremovable workspace → never claims success" "removed " "$OUT"
chk "unremovable workspace → still there afterwards" "present" \
  "$([ -d ./ws ] && echo present || echo absent)"

# 6b. the checklist asks for the observations artifacts cannot supply
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
CL="$(cat ./ws/checklist.md)"
chk "checklist asks whether a prompt appeared" "were you asked at all" "$CL"
chk "checklist asks what the prompt said" "what did the prompt say" "$CL"
chk "checklist asks whether the hooks fired" "did the hooks fire" "$CL"
chk "checklist explains why the human answer is needed" "only you can" "$CL"
chk "checklist keeps the ordering observation" "which happened" "$CL"

# ── check ────────────────────────────────────────────────────────────────────
# Helpers that plant exactly the artifacts a real run would leave behind.
plant_marker() { # $1=workspace $2=session id
  local gd; gd="$(git -C "$1/repo" rev-parse --git-dir)"
  case "$gd" in /*) ;; *) gd="$1/repo/$gd" ;; esac
  printf '%s\n' "$2" > "$gd/spar-hook-live"
}
plant_trust() { # $1=workspace
  printf '[hooks.state."%s/home/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:deadbeef"\n' \
    "$1" > "$1/home/config.toml"
}
plant_state() { # $1=workspace $2=owner_session
  mkdir -p "$1/repo/.claude"
  printf -- '---\nactive: false\nauthor: codex\nreviewer: claude\nowner_session: %s\n---\n' \
    "$2" > "$1/repo/.claude/spar.local.md"
}
plant_report() { # $1=workspace $2=outcome [$3=pairing line] [$4=raised]
  mkdir -p "$1/repo/reviews"
  printf -- '- outcome: %s\n- rounds: 2\n- reviewer: %s\n- raised: %s\n' \
    "$2" "${3-claude — cross-model (codex author ↔ claude reviewer)}" "${4-2 (MECHANICAL 2, DESIGN 0)}" \
    > "$1/repo/reviews/spar-20260726-120000-aaaaaa-report.md"
}
# The plan path's artifacts: the review result, and the plan state carrying the
# stamps only the Codex seat's activation writes. The plan state is NOT deleted at
# a terminal path — cleanup() removes the loop state, and spar-cancel removes the
# plan state — so unlike plant_run this one leaves it behind.
plant_plan_run() { # $1=workspace [$2=first line of the result]
  mkdir -p "$1/repo/reviews" "$1/repo/.claude"
  printf '%s\n' "${2-PLAN-REVIEW: FINDINGS}" \
    > "$1/repo/reviews/spar-plan-20260726-110000-bbbbbb.md"
  printf -- '---\nactive: true\nphase: running\nauthor: codex\nreviewer: claude\nowner_session: %s\nplan_review: required\nplan_review_id: 20260726-110000-bbbbbb\n---\n' \
    "${3-sess-live-9}" > "$1/repo/.claude/spar-plan.local.md"
}

# What a REAL finished run leaves: round files, a response, an outcome and a
# report — and no .claude/spar.local.md, because cleanup() deletes it on every
# terminal path. Fixtures that planted the state file were modelling something
# the engine never produces.
plant_run() { # $1=workspace $2=outcome
  local r="$1/repo/reviews"
  mkdir -p "$r"
  printf 'STATUS: FINDINGS\n\n### F1-1 [MECHANICAL] off by one\n' > "$r/spar-20260726-120000-aaaaaa-r1.md"
  printf -- '### F1-1: FIXED — corrected the range\n' > "$r/spar-20260726-120000-aaaaaa-r1-response.md"
  printf 'STATUS: CONVERGED\n' > "$r/spar-20260726-120000-aaaaaa-r2.md"
  printf -- 'reason: %s\n' "$2" > "$r/spar-20260726-120000-aaaaaa-outcome.md"
  plant_report "$1" "$2"
  rm -f "$1/repo/.claude/spar.local.md"
  # Since Phase 9 a real run through this seat also goes through spar-ready and
  # its plan review, so what it leaves includes those. A fixture modelling a run
  # that SKIPPED the plan path removes them again, explicitly.
  plant_plan_run "$1"
}

# A python3 that answers the stdin-fed trust reader as an OLD interpreter would.
# Only the reader is intercepted; every other python3 call in the script (path
# resolution, checklist rendering) still runs normally, so these fixtures isolate
# the one thing under test.
#   $1 = directory to create the shim in
#   $2 = optional python prelude, e.g. making a shadow tomllib importable
py_shim() {
  local dir="$1" prelude="${2-}" real
  real="$(command -v python3)"
  mkdir -p "$dir"
  {
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = "-" ]; then\n'
    printf '    exec %s -c %s\n' "$real" "'$prelude
exec(__import__(\"sys\").stdin.read())'"
    printf '  fi\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$real"
  } > "$dir/python3"
  chmod +x "$dir/python3"
}

# 8. before the human has run anything, nothing is invented
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "check before a run → item 1 unresolved" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk "check before a run → item 2 unresolved" "ITEM 2: NEEDS YOUR ANSWER" "$OUT"
chk "check before a run → item 3 unresolved" "ITEM 3: NEEDS YOUR ANSWER" "$OUT"
chk "check before a run → item 4 unresolved" "ITEM 4: NEEDS YOUR ANSWER" "$OUT"
# Absence with no evidence of a run cannot tell "the human skipped item 5" from
# "no session ran", and check is documented to run before a session too — so it
# reports, it does not fail. Same shape item 3 already uses.
chk "check before a run → item 5 unresolved" "ITEM 5: NEEDS YOUR ANSWER" "$OUT"
chk "check before a run → says the marker is absent" "no liveness marker" "$OUT"
chk_absent "check before a run → never claims a pass" "CONFIRMED" "$OUT"
chk "check before a run → exit 0, nothing failed" "0" "$RC"

# 8b. trust is read from the isolated config.toml, not from the human
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "trusted_hash present → item 1 confirmed" "ITEM 1: CONFIRMED" "$OUT"
chk "trusted but no marker → item 2 failed, not unknown" "ITEM 2: FAILED" "$OUT"
chk "trusted but no marker → nonzero exit" "1" "$RC"

# 8c. a hook that ran without a trust record is a failure, not a pass
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_marker "$PWD/ws" sess-untrusted
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "marker without trust record → item 1 failed" "ITEM 1: FAILED" "$OUT"
chk "marker without trust record → nonzero exit" "1" "$RC"

# 9. the full happy path
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "happy path → item 1 confirmed" "ITEM 1: CONFIRMED" "$OUT"
chk "happy path → item 2 confirmed" "ITEM 2: CONFIRMED" "$OUT"
chk "happy path → item 3 confirmed" "ITEM 3: CONFIRMED" "$OUT"
chk "happy path → item 4 confirmed" "ITEM 4: CONFIRMED" "$OUT"
chk "happy path → item 3 rests on the run, not on deleted state" "spar-fight activated" "$OUT"
chk "happy path → item 4 evidence names the outcome" "converged" "$OUT"
chk "happy path → exit 0" "0" "$RC"

# 9b. the plan path, judged from its own artifacts
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged; plant_plan_run "$PWD/ws"
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "plan path present → item 5 confirmed" "ITEM 5: CONFIRMED" "$OUT"
# The refusal itself leaves nothing durable, so a pass here must not read as
# covering it. Said out loud in the verdict rather than left to the reader.
chk "and says the refusal cannot be judged from artifacts" \
  "no artifact records a refusal" "$OUT"
chk "plan path present → exit 0" "0" "$RC"

# 9c. a result that is not a plan review is a failure, not a pass. Without this
# fixture the marker assertion is a check that cannot fail.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged; plant_plan_run "$PWD/ws" 'STATUS: CONVERGED'
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a foreign marker in the plan result → item 5 failed" "ITEM 5: FAILED" "$OUT"
chk "a foreign marker → nonzero exit" "1" "$RC"

# 9d. the plan state must carry the stamps only this seat's activation writes.
# TWO fixtures, because the verdict is one compound condition: a state missing
# both stamps fails whichever half survives, so neither half would be pinned.
#
# (a) the wrong seat, with the owner present. This is the only fixture that dies
# when the author half is removed.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged
mkdir -p ./ws/repo/reviews ./ws/repo/.claude
printf 'PLAN-REVIEW: CLEAN\n' > ./ws/repo/reviews/spar-plan-20260726-110000-bbbbbb.md
printf -- '---\nactive: true\nphase: running\nauthor: claude\nreviewer: codex\nowner_session: sess-live-9\nplan_review_id: 20260726-110000-bbbbbb\n---\n' \
  > ./ws/repo/.claude/spar-plan.local.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a plan activated by the other seat → item 5 failed" "ITEM 5: FAILED" "$OUT"
# Anchored on the value read, not the word "author": plant_report's pairing line
# already puts "codex author" in item 4's evidence, so a bare match passes
# whatever item 5 says.
chk "and the evidence names the seat it found" "author: claude" "$OUT"

# (b) the right seat with no owner — which is exactly what spar-ready leaves
# BEFORE activation (spar-ready/SKILL.md:110-112 writes author: codex and a bare
# owner_session:), so the likeliest real near-miss is this one. Only this fixture
# dies when the owner half is removed.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged
plant_plan_run "$PWD/ws" 'PLAN-REVIEW: CLEAN' ''
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a prepared but unactivated plan → item 5 failed" "ITEM 5: FAILED" "$OUT"
chk "and the evidence says the owner is missing" "owner_session: none" "$OUT"

# 9e. a run happened and skipped the plan path entirely → failed, not unknown.
# The removal is the fixture: plant_run leaves the plan artifacts because a real
# run does, so a run that skipped item 5 is modelled by taking them away.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged
rm -f ./ws/repo/reviews/spar-plan-*.md ./ws/repo/.claude/spar-plan.local.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a run with no plan artifacts → item 5 failed" "ITEM 5: FAILED" "$OUT"
chk "and says the run happened without it" "left no plan-path artifacts" "$OUT"

# 9f. activation is the threshold: a loop state whose owner_session matches the
# marker is the same proof of activation item 3 treats it as, so a run that got
# that far without the plan path has skipped item 5. check is documented to be run
# when the session is over, so a mid-run reading is off-label and "item 5 is not
# done" is true there.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-mid; plant_state "$PWD/ws" sess-mid
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "mid-run activation is proof the run happened" "ITEM 3: CONFIRMED" "$OUT"
chk "so a missing plan path is a failure" "ITEM 5: FAILED" "$OUT"
chk "and the gate does not pass" "1" "$RC"

# 9f2. a round artifact alone is the same threshold, reached by the other route.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-r1
mkdir -p ./ws/repo/reviews
printf 'STATUS: FINDINGS\n' > ./ws/repo/reviews/spar-20260726-120000-aaaaaa-r1.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a round file with no plan path → item 5 failed" "ITEM 5: FAILED" "$OUT"
chk "a round file with no plan path → nonzero exit" "1" "$RC"

# 9i. a review on disk with no plan state, and NO other run evidence. The result
# is itself evidence the plan review ran, so this is not "did you get to item 5?"
# — it is "you got there and the plan was never activated through this seat".
# spar-cancel leaves exactly this shape, which the checklist warns about.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-orphan
mkdir -p ./ws/repo/reviews
printf 'PLAN-REVIEW: CLEAN\n' > ./ws/repo/reviews/spar-plan-20260726-110000-bbbbbb.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a review with no plan state → item 5 failed" "ITEM 5: FAILED" "$OUT"
chk "and says what is missing" "no plan state" "$OUT"
chk "a review with no plan state → nonzero exit" "1" "$RC"

# 9i2. a planted plan result with no state at all is still REPORTED. Tamper
# reporting must not depend on a state naming the file, which is what discovery
# keyed on the id alone would have made it depend on.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-orphan2
mkdir -p ./ws/repo/reviews
ln -s /dev/null ./ws/repo/reviews/spar-plan-20260726-110000-bbbbbb.md
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "an orphaned symlinked result is reported" "IGNORED EVIDENCE" "$OUT"
chk "and named" "spar-plan-20260726-110000-bbbbbb.md" "$OUT"
chk_absent "and never counted as a plan review" "ITEM 5: CONFIRMED" "$OUT"

# 9h. a stale review from an abandoned attempt must not vouch for the plan that
# actually ran. Item 5 tells the human to cancel and re-run spar-ready when the
# first review comes back CLEAN, and spar-cancel keeps the results — so a
# workspace with more than one spar-plan-*.md is expected, and picking whichever
# sorts last would let the earlier one stand in for a plan started with
# --no-plan-review.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged
mkdir -p ./ws/repo/reviews ./ws/repo/.claude
# a perfectly valid review from the abandoned first attempt…
printf 'PLAN-REVIEW: CLEAN\n' > ./ws/repo/reviews/spar-plan-20260726-090000-aaaaaa.md
# …and a properly stamped state naming a DIFFERENT review that is not there.
printf -- '---\nactive: true\nphase: running\nauthor: codex\nreviewer: claude\nowner_session: sess-live-9\nplan_review_id: 20260726-190000-cccccc\n---\n' \
  > ./ws/repo/.claude/spar-plan.local.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a stale review does not vouch for a later plan" "ITEM 5: FAILED" "$OUT"
chk "and the evidence names the id it looked for" "20260726-190000-cccccc" "$OUT"
chk "a stale review → nonzero exit" "1" "$RC"

# 9h3. a symlink TO A REGULAR FILE at the named path. The earlier symlink fixture
# used /dev/null, which is not regular and would be rejected by a plain [ -f ] too
# — so it could not catch a selection step that followed links. This one can.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged
rm -f ./ws/repo/reviews/spar-plan-*.md
printf 'PLAN-REVIEW: CLEAN\n' > ./ws/repo/reviews/elsewhere.txt
ln -s "$PWD/ws/repo/reviews/elsewhere.txt" ./ws/repo/reviews/spar-plan-20260726-110000-bbbbbb.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a symlink to a valid result is reported, not trusted" "IGNORED EVIDENCE" "$OUT"
chk_absent "and never confirms item 5" "ITEM 5: CONFIRMED" "$OUT"
chk "a symlinked valid result → nonzero exit" "1" "$RC"

# 9h4. two regular results, and the state names the EARLIER one. Selecting
# "whatever the candidate loop saw last" would miss it — and that is the shape the
# checklist's cancel-and-rerun path produces, with the second attempt abandoned.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged
rm -f ./ws/repo/reviews/spar-plan-*.md
printf 'PLAN-REVIEW: CLEAN\n' > ./ws/repo/reviews/spar-plan-20260726-090000-aaaaaa.md
printf 'PLAN-REVIEW: FINDINGS\n' > ./ws/repo/reviews/spar-plan-20260726-190000-cccccc.md
printf -- '---\nactive: true\nphase: running\nauthor: codex\nreviewer: claude\nowner_session: sess-live-9\nplan_review_id: 20260726-090000-aaaaaa\n---\n' \
  > ./ws/repo/.claude/spar-plan.local.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "the named result is found even when it is not the last" "ITEM 5: CONFIRMED" "$OUT"
chk "and the evidence names the one the state chose" "spar-plan-20260726-090000-aaaaaa.md" "$OUT"
chk "two results, the named one present → exit 0" "0" "$RC"

# 9h2. a state with no usable plan_review_id names nothing, so nothing can vouch.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-live-9
plant_run "$PWD/ws" converged
printf 'PLAN-REVIEW: CLEAN\n' > ./ws/repo/reviews/spar-plan-20260726-090000-aaaaaa.md
printf -- '---\nactive: true\nphase: running\nauthor: codex\nreviewer: claude\nowner_session: sess-live-9\nplan_review_id: junk\n---\n' \
  > ./ws/repo/.claude/spar-plan.local.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "an unusable review id → item 5 failed" "ITEM 5: FAILED" "$OUT"
chk "and says the state names nothing" "no usable plan_review_id" "$OUT"

# 9e2. an outcome file with no report. record_outcome runs first at every terminal
# path, so the outcome is the earlier of the two signals and the report writer can
# fail after it — a rule keyed on the report alone would let this escape.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-oc
mkdir -p ./ws/repo/reviews
printf 'STATUS: CONVERGED\n' > ./ws/repo/reviews/spar-20260726-120000-aaaaaa-r1.md
printf -- 'reason: converged\n' > ./ws/repo/reviews/spar-20260726-120000-aaaaaa-outcome.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "an ended run with no plan path → item 5 failed" "ITEM 5: FAILED" "$OUT"
chk "an ended run with no plan path → nonzero exit" "1" "$RC"

# 9g. a planted plan artifact is REPORTED, not silently skipped. Discovery has to
# happen before the IGNORED EVIDENCE block prints, or the note is written after
# the only place that shows it.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-link
plant_run "$PWD/ws" converged
rm -f ./ws/repo/reviews/spar-plan-*.md
ln -s /dev/null ./ws/repo/reviews/spar-plan-20260726-110000-bbbbbb.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a symlinked plan result is reported" "IGNORED EVIDENCE" "$OUT"
chk "and named" "spar-plan-20260726-110000-bbbbbb.md" "$OUT"
chk "and not counted as a plan review" "ITEM 5: FAILED" "$OUT"

fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-link2
plant_run "$PWD/ws" converged
rm -f ./ws/repo/.claude/spar-plan.local.md
ln -s /dev/null ./ws/repo/.claude/spar-plan.local.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "a symlinked plan state is reported" "spar-plan.local.md" \
  "$(printf '%s\n' "$OUT" | sed -n '/IGNORED EVIDENCE/,/^$/p')"
chk "and its stamps are not read from it" "ITEM 5: FAILED" "$OUT"

# 10. a marker naming a different session than the loop owned is a failure
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-A; plant_state "$PWD/ws" sess-B
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "mismatched session → item 3 failed" "ITEM 3: FAILED" "$OUT"
chk "mismatched session → evidence names both" "sess-B" "$OUT"
chk "mismatched session → nonzero exit" "1" "$RC"

# 11. a capped run is not a converged run
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-c; plant_run "$PWD/ws" cap
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "capped run → item 4 failed" "ITEM 4: FAILED" "$OUT"
chk "capped run → evidence names the cap" "cap" "$OUT"
chk "capped run → nonzero exit" "1" "$RC"

# 12. check refuses a directory that is not ours, and one inside CODEX_HOME
fresh
mkdir -p ./notours
OUT=$(bash "$V" check --dir ./notours 2>&1); RC=$?
chk "check on a foreign dir → exit 3" "3" "$RC"
OUT=$(CODEX_HOME=/ bash "$V" check --dir ./ws 2>&1); RC=$?
chk "check with CODEX_HOME=/ → exit 3" "3" "$RC"

# 13. trust belonging to a DIFFERENT hooks.json must not count as ours
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf '[hooks.state."/somewhere/else/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:x"\n' \
  > ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "foreign trust entry → item 1 still unresolved" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"

# 13b. a section header with no trusted_hash under it is not trust
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf '[hooks.state."%s/ws/home/hooks.json:stop:0:0"]\n# accepted? not recorded\n' "$PWD" \
  > ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "header without a hash → item 1 not confirmed" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk_absent "header without a hash → never claims a hash was recorded" "ITEM 1: CONFIRMED" "$OUT"

# 13c. a trusted_hash under SOMEONE ELSE's section does not carry over to ours
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf '[hooks.state."%s/ws/home/hooks.json:stop:0:0"]\n[hooks.state."/other/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:x"\n' \
  "$PWD" > ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "hash under a foreign section → item 1 not confirmed" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"

# 13d. an empty trusted_hash is not a hash
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf '[hooks.state."%s/ws/home/hooks.json:stop:0:0"]\ntrusted_hash = ""\n' "$PWD" \
  > ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "empty trusted_hash → item 1 not confirmed" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"

# 13e. a marker with no loop state proves the hook ran, not that anything read it
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-nostate
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "marker without loop state → item 2 confirmed (the hook did fire)" "ITEM 2: CONFIRMED" "$OUT"
chk "marker without loop state → item 3 unresolved, not confirmed" \
  "ITEM 3: NEEDS YOUR ANSWER" "$OUT"
chk "marker without loop state → says why" "no round artifact exists" "$OUT"

# 13f. planted evidence is ignored and said out loud. No genuine run writes any
# of these as a symlink, so a link means the artifact was placed, not observed.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"
mkdir -p ./outside
printf 'sess-planted\n' > ./outside/marker
GD="$(git -C ./ws/repo rev-parse --git-dir)"
case "$GD" in /*) ;; *) GD="$PWD/ws/repo/$GD" ;; esac
ln -s "$PWD/outside/marker" "$GD/spar-hook-live"
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "symlinked marker → announced as ignored" "IGNORED EVIDENCE" "$OUT"
chk "symlinked marker → names the file" "spar-hook-live is a symlink" "$OUT"
chk_absent "symlinked marker → item 2 not confirmed from it" "ITEM 2: CONFIRMED" "$OUT"
chk_absent "symlinked marker → item 3 not confirmed from it" "ITEM 3: CONFIRMED" "$OUT"
chk_absent "symlinked marker → its content never quoted as evidence" "sess-planted" "$OUT"

# 13g. a symlinked loop state cannot supply an owner_session
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-real
mkdir -p ./outside ./ws/repo/.claude
printf -- '---\nowner_session: sess-real\n---\n' > ./outside/state.md
ln -s "$PWD/outside/state.md" ./ws/repo/.claude/spar.local.md
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "symlinked loop state → announced as ignored" "spar.local.md is a symlink" "$OUT"
chk "symlinked loop state → item 3 unresolved" "ITEM 3: NEEDS YOUR ANSWER" "$OUT"

# 13h. a symlinked report cannot confirm the end-to-end item
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-r; plant_state "$PWD/ws" sess-r
mkdir -p ./outside ./ws/repo/reviews
printf -- '- outcome: converged\n' > ./outside/report.md
ln -s "$PWD/outside/report.md" ./ws/repo/reviews/spar-20260726-999999-zzzzzz-report.md
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "symlinked report → announced as ignored" "report.md is a symlink" "$OUT"
chk "symlinked report → item 4 not confirmed" "ITEM 4: NEEDS YOUR ANSWER" "$OUT"

# 13i. a real report alongside a planted one still decides the verdict
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-r; plant_run "$PWD/ws" cap
mkdir -p ./outside; printf -- '- outcome: converged\n' > ./outside/report.md
ln -s "$PWD/outside/report.md" ./ws/repo/reviews/spar-20260726-999999-zzzzzz-report.md
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "planted report does not override the real one" "ITEM 4: FAILED" "$OUT"
chk "planted report → real outcome still reported" "outcome: cap" "$OUT"
chk "planted report → still a nonzero exit" "1" "$RC"

# 13j. a foreign parent table that merely CONTAINS our key text is not our trust
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf '[other.hooks.state."%s/ws/home/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:x"\n' \
  "$PWD" > ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "foreign parent table → item 1 not confirmed" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk_absent "foreign parent table → never claims trust" "ITEM 1: CONFIRMED" "$OUT"

# 13j2. inside the RIGHT table, a key that merely contains our hooks.json path
# somewhere other than the start is a different registration, not ours. This is
# what separates a prefix test from a substring one; the case above is caught by
# TOML structure alone and would pass either way.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf '[hooks.state."/some/other/home/hooks.json:pre_tool_use:0:0 %s/ws/home/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:x"\n' \
  "$PWD" > ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "our path buried mid-key → item 1 not confirmed" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"

# 13k. a workspace path containing a double quote needs TOML escaping to match
fresh
QWS="$PWD/quo\"ted/ws"
bash "$V" setup --dir "$QWS" >/dev/null 2>&1
QWS_HOME="$QWS/home" python3 - "$QWS/home/config.toml" <<'GENPY'
import os, sys
key = os.environ["QWS_HOME"] + "/hooks.json:stop:0:0"
esc = key.replace("\\", "\\\\").replace('"', '\\"')
open(sys.argv[1], "w").write('[hooks.state."%s"]\ntrusted_hash = "sha256:abc"\n' % esc)
GENPY
OUT=$(bash "$V" check --dir "$QWS" 2>&1)
chk "quoted path → trust still recognised" "ITEM 1: CONFIRMED" "$OUT"

# 13l. a config.toml that is not valid TOML leaves item 1 unresolved, never failed
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf 'this is not = = toml\n' > ./ws/home/config.toml
plant_marker "$PWD/ws" sess-x
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "unparseable config → item 1 unresolved" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk "unparseable config → says why" "not valid TOML" "$OUT"
chk_absent "unparseable config → not reported as a trust failure" "ITEM 1: FAILED" "$OUT"

# 13m. a symlinked config.toml is ignored rather than read through
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
mkdir -p ./outside
printf '[hooks.state."%s/ws/home/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:x"\n' \
  "$PWD" > ./outside/config.toml
ln -s "$PWD/outside/config.toml" ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "symlinked config → item 1 unresolved" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk "symlinked config → says it was ignored" "symlink" "$OUT"

# 13n. the shape a REAL converged run leaves: cleanup() has deleted the loop
# state, so item 3 must stand on the durable round artifacts or it can never be
# confirmed after a finished run.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-done; plant_run "$PWD/ws" converged
chk "post-cleanup fixture really has no loop state" "absent" \
  "$([ -e ./ws/repo/.claude/spar.local.md ] && echo present || echo absent)"
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "post-cleanup run → item 3 confirmed" "ITEM 3: CONFIRMED" "$OUT"
chk "post-cleanup run → item 4 confirmed" "ITEM 4: CONFIRMED" "$OUT"
chk "post-cleanup run → exit 0" "0" "$RC"

# 13o. a mid-loop check still catches a marker that does not match the owner
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-A; plant_run "$PWD/ws" converged
plant_state "$PWD/ws" sess-B
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "live state disagreeing with the marker → item 3 failed" "ITEM 3: FAILED" "$OUT"
chk "live state disagreeing → outranks the run artifact" "sess-B" "$OUT"
chk "live state disagreeing → nonzero exit" "1" "$RC"

# 13p. an interpreter older than 3.11 defers, with the reason and the remedy —
# never confirmed from a guess, never blamed on the run.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-old
py_shim "$PWD/oldpy" 'import sys; sys.version_info = (3, 10, 0, "final", 0)'
OUT=$(PATH="$PWD/oldpy:$PATH" bash "$V" check --dir ./ws 2>&1); RC=$?
chk "old interpreter → item 1 unresolved" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk "old interpreter → names the reason and the remedy" "3.11 or newer" "$OUT"
chk_absent "old interpreter → never confirmed from a guess" "ITEM 1: CONFIRMED" "$OUT"
chk_absent "old interpreter → never blamed on the run" "ITEM 1: FAILED" "$OUT"
chk "old interpreter → the other items still work" "ITEM 2: CONFIRMED" "$OUT"
chk "old interpreter → exit stays 0" "0" "$RC"

# 13p2. the F5-1 case: an OLD interpreter where a tomllib IS importable. Testing
# the import alone would pass here — a module wearing that name on 3.10 is not
# the standard library, and it is not what decides this verdict.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-shadowold
mkdir -p ./fakelib
printf 'def load(fh):\n    return {"hooks": {"state": {}}}\n' > ./fakelib/tomllib.py
py_shim "$PWD/oldpy" \
  'import sys; sys.version_info = (3, 10, 0, "final", 0); sys.path.insert(0, "'"$PWD"'/fakelib")'
OUT=$(PATH="$PWD/oldpy:$PATH" bash "$V" check --dir ./ws 2>&1)
chk "old interpreter with an importable tomllib → still defers" \
  "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk_absent "old interpreter with an importable tomllib → never confirmed" \
  "ITEM 1: CONFIRMED" "$OUT"

# 13p3. on a current interpreter, a tomllib planted on PYTHONPATH must not be the
# parser. It grants trust for anything; -I is what keeps it out.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_marker "$PWD/ws" sess-liar
printf 'trusted_hash = "x"\n' > ./ws/home/config.toml   # a real file, no matching key
mkdir -p ./liar
printf 'def load(fh):\n    import os\n    k = os.environ["HOOKS"] + ":stop:0:0"\n    return {"hooks": {"state": {k: {"trusted_hash": "sha256:forged"}}}}\n' \
  > ./liar/tomllib.py
OUT=$(PYTHONPATH="$PWD/liar" bash "$V" check --dir ./ws 2>&1)
chk_absent "a planted tomllib cannot forge trust" "ITEM 1: CONFIRMED" "$OUT"

# 13p4. an answer the shell does not recognise lands in the catch-all rather than
# being mistaken for one of the known tokens.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-noisy
py_shim "$PWD/noisypy" 'import sys; sys.stdout.write("chatter\n")'
OUT=$(PATH="$PWD/noisypy:$PATH" bash "$V" check --dir ./ws 2>&1); RC=$?
chk "unrecognised reader output → item 1 unresolved" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk_absent "unrecognised reader output → never an accusation" "ITEM 1: FAILED" "$OUT"
chk_absent "unrecognised reader output → does not blame the config file" "not valid TOML" "$OUT"
chk "unrecognised reader output → says nothing is known either way" "either way" "$OUT"
chk "unrecognised reader output → exit stays 0" "0" "$RC"

# 13p5. an import that fails with something other than ImportError is still a
# missing tomllib, and is named with the remedy rather than the generic text.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-raise
py_shim "$PWD/raisepy" \
  'import builtins; _r = builtins.__import__; builtins.__import__ = lambda n, *a, **k: (_ for _ in ()).throw(RuntimeError("x")) if n == "tomllib" else _r(n, *a, **k)'
OUT=$(PATH="$PWD/raisepy:$PATH" bash "$V" check --dir ./ws 2>&1)
chk "import raising a non-ImportError → named as a missing tomllib" "3.11 or newer" "$OUT"
chk_absent "import raising a non-ImportError → never an accusation" "ITEM 1: FAILED" "$OUT"

# 13q. a child table under our key is not our trust record
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf '[hooks.state."%s/ws/home/hooks.json:stop:0:0".other]\ntrusted_hash = "sha256:x"\n' \
  "$PWD" > ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "child table → item 1 not confirmed" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"

# 13r. a plausible hash followed by malformed TOML is not accepted
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
printf '[hooks.state."%s/ws/home/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:x"\nthis is = = broken\n' \
  "$PWD" > ./ws/home/config.toml
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "hash then malformed TOML → item 1 unresolved" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk "hash then malformed TOML → says the file is invalid" "not valid TOML" "$OUT"

# 13s. a symlink is not the only thing a run cannot have written. A directory, a
# FIFO or anything else non-regular at an evidence path must be named too, not
# skipped in silence.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
rm -f ./ws/home/config.toml; mkdir -p ./ws/home/config.toml
plant_marker "$PWD/ws" sess-dir
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "directory as config.toml → named as ignored" "config.toml is not a regular file" "$OUT"
chk "directory as config.toml → item 1 unresolved" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
chk_absent "directory as config.toml → not blamed on the run" "ITEM 1: FAILED" "$OUT"

fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
rm -f ./ws/home/config.toml; mkfifo ./ws/home/config.toml 2>/dev/null || true
if [ -p ./ws/home/config.toml ]; then
  OUT=$(bash "$V" check --dir ./ws 2>&1)
  chk "fifo as config.toml → named as ignored" "config.toml is not a regular file" "$OUT"
  chk "fifo as config.toml → check does not hang or confirm" "ITEM 1: NEEDS YOUR ANSWER" "$OUT"
else
  echo "SKIP: mkfifo unavailable"; echo "SKIP: mkfifo unavailable"
fi

# 13t. a non-regular ROUND artifact is evidence for item 3, so it is named too
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-ra
mkdir -p ./outside ./ws/repo/reviews
printf 'STATUS: CONVERGED\n' > ./outside/r1.md
ln -s "$PWD/outside/r1.md" ./ws/repo/reviews/spar-20260726-120000-bbbbbb-r1.md
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "symlinked round artifact → named as ignored" "r1.md is a symlink" "$OUT"
chk "symlinked round artifact → cannot confirm item 3" "ITEM 3: NEEDS YOUR ANSWER" "$OUT"

fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-oa
mkdir -p ./ws/repo/reviews/spar-20260726-120000-cccccc-outcome.md
OUT=$(bash "$V" check --dir ./ws 2>&1)
chk "directory as an outcome artifact → named as ignored" \
  "outcome.md is not a regular file" "$OUT"
chk "directory as an outcome artifact → cannot confirm item 3" \
  "ITEM 3: NEEDS YOUR ANSWER" "$OUT"

# 13u. containment is a property of the whole path. A symlinked directory makes
# every artifact under it a regular file belonging to somewhere else, so the
# leaf checks alone are not enough.
mk_foreign() {  # builds ./foreign as a fully-populated fake workspace
  mkdir -p ./foreign/home ./foreign/repo/.claude ./foreign/repo/reviews
  printf '[hooks.state."%s/ws/home/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:x"\n' \
    "$PWD" > ./foreign/home/config.toml
  printf 'STATUS: CONVERGED\n' > ./foreign/repo/reviews/spar-20260726-120000-dddddd-r1.md
  printf -- '- outcome: converged\n' > ./foreign/repo/reviews/spar-20260726-120000-dddddd-report.md
}

for part in home repo; do
  fresh
  bash "$V" setup --dir ./ws >/dev/null 2>&1
  mk_foreign
  rm -rf "./ws/$part"; ln -s "$PWD/foreign/$part" "./ws/$part"
  OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
  chk "symlinked $part → exit 3" "3" "$RC"
  chk "symlinked $part → says the workspace is not self-contained" \
    "not self-contained" "$OUT"
  chk_absent "symlinked $part → no verdict is printed at all" "ITEM " "$OUT"
done

for part in reviews .claude .git; do
  fresh
  bash "$V" setup --dir ./ws >/dev/null 2>&1
  mk_foreign
  mkdir -p "./foreign/repo/$part"
  rm -rf "./ws/repo/$part"; ln -s "$PWD/foreign/repo/$part" "./ws/repo/$part"
  OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
  chk "symlinked repo/$part → exit 3" "3" "$RC"
  chk_absent "symlinked repo/$part → no verdict is printed" "ITEM " "$OUT"
done

# A foreign converged report reached through a symlinked reviews/ must never
# have produced a CONFIRMED — this is the whole point of the check above.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
mk_foreign
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-z
rm -rf ./ws/repo/reviews; ln -s "$PWD/foreign/repo/reviews" ./ws/repo/reviews
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "foreign reviews/ → refused before any verdict" "3" "$RC"
chk_absent "foreign reviews/ → never confirms item 4 from it" "ITEM 4: CONFIRMED" "$OUT"

# A real workspace with everything in place is still accepted.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-ok; plant_run "$PWD/ws" converged
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "self-contained workspace → still judged normally" "ITEM 4: CONFIRMED" "$OUT"
chk "self-contained workspace → exit 0" "0" "$RC"

# 13v. git searches upward. A workspace nested in another repository, with its
# own .git gone, would otherwise read the ENCLOSING repository's marker — and the
# default workspace path puts it inside a checkout of this very project, whose
# .git holds a spar-hook-live written by an unrelated session.
fresh
git init -q .
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m outer
printf 'sess-from-the-outer-repo\n' > ./.git/spar-hook-live
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"
rm -rf ./ws/repo/.git
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "no inner .git → exit 3" "3" "$RC"
# Named specifically, because the containment check that follows would also
# refuse this — the presence requirement has to be what produces the message,
# or it could be deleted without a test noticing.
chk "no inner .git → refused for the missing .git, not incidentally" \
  "has no .git of its own" "$OUT"
chk "no inner .git → names the hazard" "enclosing repository" "$OUT"
chk_absent "no inner .git → no verdict is printed" "ITEM " "$OUT"
chk_absent "no inner .git → the outer marker is never quoted" "sess-from-the-outer-repo" "$OUT"

# 13w. a workspace repo that is merely a SUBDIRECTORY of a larger repository is
# refused too — its own .git present but git reporting a different top.
fresh
git init -q .
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m outer
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-sub
mv ./ws/repo/.git ./ws/repo/.git-disabled
printf 'gitdir: %s/ws/repo/.git-disabled\n' "$PWD" > ./ws/repo/.git
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "repo/.git as a file, not a directory → exit 3" "3" "$RC"
chk_absent "repo/.git as a file → no verdict is printed" "ITEM " "$OUT"

# 13x. the git directory can sit inside the workspace while the repository is
# describing a working tree outside it (core.worktree). No evidence is redirected
# by that, but the scratch repo is then not the one setup created, so it is not a
# workspace this check should be ruling on.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-wt
mkdir -p ./elsewhere
git -C ./ws/repo config core.worktree "$PWD/elsewhere"
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "worktree pointing outside → exit 3" "3" "$RC"
chk "worktree pointing outside → says the repo is not its own top" "not the top" "$OUT"
chk_absent "worktree pointing outside → no verdict is printed" "ITEM " "$OUT"

# A nested but self-contained workspace is still fine: being inside another
# repository is not itself the problem, borrowing its git state is.
fresh
git init -q .
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m outer
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-nested; plant_run "$PWD/ws" converged
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "nested but self-contained → judged normally" "ITEM 4: CONFIRMED" "$OUT"
chk "nested but self-contained → exit 0" "0" "$RC"

# 13y. mid-run: the loop state exists and agrees with the marker, but no round
# file has been written yet. The state only exists because activation passed the
# marker gate, so telling the human "nothing activated" would be false.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-M; plant_state "$PWD/ws" sess-M
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "mid-run agreement → item 3 confirmed" "ITEM 3: CONFIRMED" "$OUT"
chk "mid-run agreement → evidence names the matching owner" "sess-M" "$OUT"
chk_absent "mid-run agreement → never claims nothing activated" "nothing activated" "$OUT"
# Item 5 makes this state nonzero now: activation without the plan path is a
# skipped item, and a mid-run reading is off-label (check is for when the session
# is over). Item 3's own verdict, which is what this fixture is about, is
# unchanged — the assertions above still pass untouched.
chk "mid-run agreement → nonzero once item 5 is missing" "1" "$RC"
chk_absent "mid-run agreement → never asks about a refusal that did not happen" \
  "did spar-fight refuse" "$OUT"
chk "mid-run agreement → item 4 still open, the loop has not finished" \
  "ITEM 4: NEEDS YOUR ANSWER" "$OUT"

# 13aa. converging is not the whole of item 4. This seat exists so that Codex
# authors and claude -p reviews; a same-model run proves the machinery turns, not
# the claim. A real session degraded to codex-reviews-codex and the old check
# counted it as a pass.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-same
plant_run "$PWD/ws" converged
plant_report "$PWD/ws" converged "codex — same-model (codex author ↔ codex reviewer)"
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "same-model convergence → item 4 failed" "ITEM 4: FAILED" "$OUT"
chk "same-model convergence → the pairing is named" "same-model" "$OUT"
chk "same-model convergence → nonzero exit" "1" "$RC"
chk_absent "same-model convergence → never confirmed" "ITEM 4: CONFIRMED" "$OUT"

# The cross-model pairing is what confirms it.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-cross
plant_run "$PWD/ws" converged
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "cross-model convergence → item 4 confirmed" "ITEM 4: CONFIRMED" "$OUT"
chk "cross-model convergence → evidence names the pairing" "cross-model" "$OUT"
chk "cross-model convergence → exit 0" "0" "$RC"

# A clean first round is a legitimate result, but it leaves the debate path
# unexercised — stated as a note, not scored as a failure.
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-nofind
plant_run "$PWD/ws" converged
plant_report "$PWD/ws" converged "claude — cross-model (codex author ↔ claude reviewer)" "0 (MECHANICAL 0, DESIGN 0)"
OUT=$(bash "$V" check --dir ./ws 2>&1); RC=$?
chk "zero findings → still confirmed" "ITEM 4: CONFIRMED" "$OUT"
chk "zero findings → the gap is stated" "was not exercised" "$OUT"
chk "zero findings → not scored as a failure" "0" "$RC"

# 14. every verdict carries its evidence, so no line stands unexplained
fresh
bash "$V" setup --dir ./ws >/dev/null 2>&1
plant_trust "$PWD/ws"; plant_marker "$PWD/ws" sess-e
OUT=$(bash "$V" check --dir ./ws 2>&1)
# Counted against the number of verdicts, not against a literal: a hardcoded 4
# had to be edited when item 5 was added, which is an edit that can be made by
# lowering the expectation instead of fixing the output.
N_ITEMS="$(printf '%s\n' "$OUT" | grep -c '^ITEM ')"
chk "check emits a verdict per item" "5" "$N_ITEMS"
chk "each verdict is followed by evidence" "$N_ITEMS" \
  "$(printf '%s\n' "$OUT" | grep -A1 '^ITEM ' | grep -c '^  [^ ]')"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
