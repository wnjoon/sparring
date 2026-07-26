#!/usr/bin/env bash
# Register sparring's two hooks with Codex. Installed ONCE: Codex pins hook trust
# to a content hash, so rewriting this file per run would re-prompt every loop.
# The hooks self-disable when no loop is active, so an idle registration is free.
# Usage: install.sh [--scope user|project] [--target <hooks.json>]
#   --scope  places both the hook registration and the skills (user:
#            CODEX_HOME/HOME, project: the working tree).
#   --target relocates ONLY the hooks.json. Skills keep following --scope,
#            since Codex looks for them at fixed paths.
# Exit: 0 installed or already current; 2 usage; 3 unsafe path or I/O failure.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF_DIR/../../plugins/spar" && pwd)" || {
  echo "error: cannot locate plugins/spar next to this installer" >&2; exit 3; }

scope=user; target=""; target_given=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scope) scope="${2-}"; shift 2 || exit 2 ;;
    --target) target="${2-}"; target_given=1; shift 2 || exit 2 ;;
    *) echo "usage: install.sh [--scope user|project] [--target <hooks.json>]" >&2; exit 2 ;;
  esac
done

# Validate the scope whether or not --target was supplied: an unknown scope is a
# usage error even when it does not end up selecting the path.
case "$scope" in
  user|project) ;;
  *) echo "error: --scope must be user or project" >&2; exit 2 ;;
esac

# An explicitly empty --target must not silently fall back to the user default:
# an unset variable in a caller's script would otherwise rewrite ~/.codex/hooks.json.
if [ "$target_given" = 1 ] && [ -z "$target" ]; then
  echo "error: --target requires a path" >&2; exit 2
fi
if [ -z "$target" ]; then
  case "$scope" in
    user)    target="${CODEX_HOME:-$HOME/.codex}/hooks.json" ;;
    project) target=".codex/hooks.json" ;;
  esac
fi
case "$target" in -*) target="./$target" ;; esac

# A symlinked target is always refused. Symlinked ANCESTORS are refused only for a
# relative path — the project tree, which may be untrusted: a repository can ship
# `.codex` as a link and redirect the whole write, and `mkdir -p` would create
# directories through it before any later check could notice. An absolute path is
# one the user typed (or the user-scope default under their own HOME), where a
# symlinked `~/.codex` is a normal dotfiles setup and refusing it would be a dead
# end with no way out.
reject_unsafe_path() {
  local p="$1"
  [ -L "$p" ] && { echo "error: target is a symlink: $p" >&2; exit 3; }
  case "$p" in
    /*) ;;                       # user-chosen absolute path: their own tree
    *)
      local anc="$p"
      while :; do
        anc=$(dirname "$anc")
        { [ "$anc" = "." ] || [ "$anc" = "/" ]; } && break
        [ -L "$anc" ] && {
          echo "error: symlinked ancestor: $anc" >&2
          echo "       (pass --target with the resolved path if this is intentional)" >&2
          exit 3; }
      done
      ;;
  esac
  [ -e "$p" ] && [ ! -f "$p" ] \
    && { echo "error: target is not a regular file: $p" >&2; exit 3; }
  return 0
}

reject_unsafe_path "$target"
mkdir -p "$(dirname "$target")" || exit 3
reject_unsafe_path "$target"

command -v python3 >/dev/null 2>&1 \
  || { echo "error: python3 is required to merge hooks.json safely" >&2; exit 3; }

TEMPLATE="$SELF_DIR/hooks.json.template"
[ -f "$TEMPLATE" ] || { echo "error: missing $TEMPLATE" >&2; exit 3; }

PLUGIN_ROOT="$PLUGIN_ROOT" TEMPLATE="$TEMPLATE" TARGET="$target" python3 - <<'PY' || exit 3
import json, os, re, shlex, sys, tempfile

root = os.environ["PLUGIN_ROOT"]
target = os.environ["TARGET"]

# Build the command strings here rather than substituting into quoted template
# text. A checkout path containing a single quote would otherwise produce
# malformed shell — and, inside a hook the user has already trusted, a
# command-injection vector. shlex.quote handles any path; json.dump handles the
# JSON escaping on top of it.
def hook_command(script):
    return "CLAUDE_PLUGIN_ROOT=%s %s" % (
        shlex.quote(root),
        shlex.quote(os.path.join(root, "hooks", script)),
    )

COMMANDS = {
    "@@STOP_COMMAND@@": hook_command("stop-fight.sh"),
    "@@SESSION_COMMAND@@": hook_command("session-start.sh"),
}

ours = json.load(open(os.environ["TEMPLATE"]))
for groups in ours["hooks"].values():
    for group in groups:
        for hook in group.get("hooks", []):
            placeholder = hook.get("command")
            if placeholder not in COMMANDS:
                print("error: template carries an unrecognised command placeholder: "
                      f"{placeholder!r}", file=sys.stderr)
                sys.exit(3)
            hook["command"] = COMMANDS[placeholder]

existing = {"hooks": {}}
if os.path.exists(target):
    try:
        existing = json.load(open(target))
    except Exception:
        print(f"error: {target} exists but is not valid JSON; refusing to overwrite",
              file=sys.stderr)
        sys.exit(3)
    if not isinstance(existing, dict):
        print(f"error: {target} is not a JSON object", file=sys.stderr); sys.exit(3)
existing.setdefault("hooks", {})
# Refuse shapes we cannot merge rather than mangling them. Iterating a string
# would rewrite "echo x" as ["e","c","h","o"...], and a non-dict "hooks" would
# surface as a Python traceback — both unacceptable in a tool whose whole stance
# is never to clobber a file it does not fully understand.
if not isinstance(existing["hooks"], dict):
    print(f'error: {target}: "hooks" is not a JSON object; refusing to rewrite it',
          file=sys.stderr)
    sys.exit(3)

OUR_SCRIPTS = {os.path.join(root, "hooks", s)
               for s in ("stop-fight.sh", "session-start.sh")}

ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

def is_our_hook(hook):
    """True only for a command that actually INVOKES one of our two scripts.

    Two narrower rules than they look. A substring test on the plugin root would
    claim a user's own command living under the same tree, or under a path merely
    sharing that prefix. Testing the last token would claim `echo <our script>`,
    which mentions the path without running it. So: skip leading VAR=value
    assignments, and require the executable itself to be one of our scripts.
    Splitting the way a shell does also recognises registrations written by an
    earlier quoting scheme, so a re-run replaces them instead of duplicating."""
    if not isinstance(hook, dict):
        return False
    try:
        parts = shlex.split(hook.get("command") or "")
    except ValueError:
        return False
    i = 0
    while i < len(parts) and ASSIGNMENT.match(parts[i]):
        i += 1
    return i < len(parts) and parts[i] in OUR_SCRIPTS

def without_ours(groups):
    """Drop only OUR hook entries, never a whole group. A user may have put their
    own command in the same group, and removing the group would delete it."""
    kept = []
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            kept.append(group)              # a shape we do not own; leave it alone
            continue
        theirs = [h for h in group["hooks"] if not is_our_hook(h)]
        if len(theirs) == len(group["hooks"]):
            kept.append(group)              # nothing of ours in here
        elif theirs:                        # keep the group, minus our entries
            trimmed = dict(group)
            trimmed["hooks"] = theirs
            kept.append(trimmed)
        # else: the group held only our entries — drop it, ours is re-added below
    return kept

changed = False
for event, groups in ours["hooks"].items():
    current = existing["hooks"].get(event, [])
    if not isinstance(current, list):
        print(f"error: {target}: hooks.{event} is not a JSON array; "
              "refusing to rewrite it", file=sys.stderr)
        sys.exit(3)
    merged = without_ours(current) + groups
    if existing["hooks"].get(event) != merged:
        existing["hooks"][event] = merged
        changed = True

if not changed:
    print(f"sparring hooks already current in {target}")
    sys.exit(0)

# Exclusive, same-directory temp file. A predictable "<target>.tmp" would follow a
# symlink an untrusted project could plant there and truncate whatever it points
# at; mkstemp opens with O_CREAT|O_EXCL and never follows one.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target) or ".", prefix=".hooks.json.")
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(existing, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, target)
except Exception as exc:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    print(f"error: could not write {target}: {exc}", file=sys.stderr)
    sys.exit(3)
print(f"sparring hooks installed in {target}")
PY

# Skills — the author-seat command surface. They live beside the hooks: user scope
# under CODEX_HOME/HOME, project scope in the working tree. Copied only when the
# rendered content differs, so a re-run is a genuine no-op.
SKILLS_SRC="$SELF_DIR/skills"
if [ -d "$SKILLS_SRC" ]; then
  case "$scope" in
    user)    SKILLS_DEST="${CODEX_HOME:-$HOME/.codex}/skills" ;;
    project) SKILLS_DEST=".codex/skills" ;;
  esac
  # --target moves the hooks FILE and nothing else. Skills stay on the scope
  # default, because Codex discovers them at fixed locations: a copy next to an
  # arbitrary hooks.json (say /tmp/skills) is a copy nothing will ever load.

  # Every skill calls helper scripts under plugins/spar. The installed copy must
  # carry the resolved path: an installed skill is read far from this checkout,
  # and a guessed default would send it looking somewhere nothing was ever put.
  # SPAR_PLUGIN_ROOT still wins at runtime, so a user who relocates the plugin can
  # override without reinstalling.
  # The path is substituted into a shell script the user will run, so it is
  # shell-quoted first — the same reason the hook commands go through
  # shlex.quote. A checkout under a directory containing `$(...)`, a backtick or
  # a double quote would otherwise execute at activation time, inside a block the
  # user has no reason to inspect. The placeholder therefore stands alone on the
  # right-hand side of an assignment (`SPAR_ROOT=@@…@@`), never nested inside an
  # already-quoted expansion, so the quoting shlex produces is the whole story.
  render_skill() {                     # render_skill <src> <out>
    SRC="$1" OUT="$2" ROOT="$PLUGIN_ROOT" python3 - <<'PY'
import os, shlex, sys
text = open(os.environ["SRC"], encoding="utf-8").read()
text = text.replace("@@SPAR_PLUGIN_ROOT@@", shlex.quote(os.environ["ROOT"]))
if "@@" in text:
    print(f"error: {os.environ['SRC']}: unsubstituted @@placeholder@@ remains",
          file=sys.stderr)
    sys.exit(3)
open(os.environ["OUT"], "w", encoding="utf-8").write(text)
PY
  }

  installed=0
  RENDER_TMP="$(mktemp)" || exit 3
  trap 'rm -f "$RENDER_TMP"' EXIT
  for src in "$SKILLS_SRC"/*/SKILL.md; do
    [ -f "$src" ] || continue
    name="$(basename "$(dirname "$src")")"
    dest="$SKILLS_DEST/$name/SKILL.md"
    # The same rule as the hooks target, for the same reason: under project scope
    # these paths are relative and live in a tree the repository controls, so a
    # `.codex/skills` symlink would redirect every installed skill out of the
    # project — and `mkdir -p` would traverse it before any later check could
    # notice. Unsafe is fatal, not skipped: an installer that reports success
    # while leaving skills unwritten is worse than one that stops.
    reject_unsafe_path "$dest"
    mkdir -p "$(dirname "$dest")" || exit 3
    reject_unsafe_path "$dest"
    render_skill "$src" "$RENDER_TMP" || exit 3
    if [ -f "$dest" ] && cmp -s "$RENDER_TMP" "$dest"; then continue; fi
    cp "$RENDER_TMP" "$dest" || exit 3
    installed=$((installed + 1))
  done
  rm -f "$RENDER_TMP"; trap - EXIT
  if [ "$installed" -gt 0 ]; then
    echo "sparring skills installed in $SKILLS_DEST ($installed updated)"
  else
    echo "sparring skills already current in $SKILLS_DEST"
  fi
fi

cat <<EOF
Codex asks you to trust a hook the first time it runs after a change. Accept it
once; the registration is not rewritten per run, so it will not ask again.
Choosing "Continue without trusting" means the hooks do not run and the review
loop is NOT enforced for that session — the spar-fight skill refuses to start in
that case rather than running an unenforced loop.
EOF
