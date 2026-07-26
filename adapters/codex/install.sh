#!/usr/bin/env bash
# Register sparring's two hooks with Codex. Installed ONCE: Codex pins hook trust
# to a content hash, so rewriting this file per run would re-prompt every loop.
# The hooks self-disable when no loop is active, so an idle registration is free.
# Usage: install.sh [--scope user|project] [--target <hooks.json>]
# Exit: 0 installed or already current; 2 usage; 3 unsafe path or I/O failure.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SELF_DIR/../../plugins/spar" && pwd)" || {
  echo "error: cannot locate plugins/spar next to this installer" >&2; exit 3; }

scope=user; target=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scope) scope="${2-}"; shift 2 || exit 2 ;;
    --target) target="${2-}"; shift 2 || exit 2 ;;
    *) echo "usage: install.sh [--scope user|project] [--target <hooks.json>]" >&2; exit 2 ;;
  esac
done
if [ -z "$target" ]; then
  case "$scope" in
    user)    target="${CODEX_HOME:-$HOME/.codex}/hooks.json" ;;
    project) target=".codex/hooks.json" ;;
    *) echo "error: --scope must be user or project" >&2; exit 2 ;;
  esac
fi
case "$target" in -*) target="./$target" ;; esac

[ -L "$target" ] && { echo "error: target is a symlink: $target" >&2; exit 3; }
[ -e "$target" ] && [ ! -f "$target" ] \
  && { echo "error: target is not a regular file: $target" >&2; exit 3; }
mkdir -p "$(dirname "$target")" || exit 3

command -v python3 >/dev/null 2>&1 \
  || { echo "error: python3 is required to merge hooks.json safely" >&2; exit 3; }

TEMPLATE="$SELF_DIR/hooks.json.template"
[ -f "$TEMPLATE" ] || { echo "error: missing $TEMPLATE" >&2; exit 3; }

PLUGIN_ROOT="$PLUGIN_ROOT" TEMPLATE="$TEMPLATE" TARGET="$target" python3 - <<'PY' || exit 3
import json, os, sys

root = os.environ["PLUGIN_ROOT"]
target = os.environ["TARGET"]
ours = json.loads(open(os.environ["TEMPLATE"]).read().replace("@@PLUGIN_ROOT@@", root))

existing = {"hooks": {}}
if os.path.exists(target):
    try:
        existing = json.load(open(target))
    except Exception:
        print(f"error: {target} exists but is not valid JSON; refusing to overwrite", file=sys.stderr)
        sys.exit(3)
    if not isinstance(existing, dict):
        print(f"error: {target} is not a JSON object", file=sys.stderr); sys.exit(3)
existing.setdefault("hooks", {})

def is_ours(group):
    return any(root in (h.get("command") or "") for h in group.get("hooks", []))

changed = False
for event, groups in ours["hooks"].items():
    kept = [g for g in existing["hooks"].get(event, []) if not is_ours(g)]
    merged = kept + groups
    if existing["hooks"].get(event) != merged:
        existing["hooks"][event] = merged
        changed = True

if not changed:
    print(f"sparring hooks already current in {target}")
    sys.exit(0)

tmp = target + ".tmp"
with open(tmp, "w") as fh:
    json.dump(existing, fh, indent=2)
    fh.write("\n")
os.replace(tmp, target)
print(f"sparring hooks installed in {target}")
PY

cat <<EOF
Codex asks you to trust a hook the first time it runs after a change. Accept it
once; the registration is not rewritten per run, so it will not ask again.
Choosing "Continue without trusting" means the hooks do not run and the review
loop is NOT enforced for that session.
EOF
