#!/usr/bin/env bash
# Read model-economics settings for one family. Prints four key=value lines and
# always exits 0 — an economics setting that cannot be read must degrade to the
# behaviour the loop had before Phase 7, never stop a review. Every caller can
# therefore use the output without checking a status.
# Usage: spar-config.sh <family> <changed-line-count>
# Output: model=…  effort=…  writer=…  source=config|default
set -uo pipefail

FAMILY="${1-}"; LINES="${2-0}"
case "$LINES" in ''|*[!0-9]*) LINES=0 ;; esac
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${SPAR_CONFIG_FILE:-$DIR/../shared/config.toml}"

# `source=default` is the signal callers key on: it means nothing here was read
# from a file, so they must add no flags at all rather than pass an empty one.
emit_default() { printf 'model=\neffort=\nwriter=\nsource=default\n'; exit 0; }

# Only families the engine actually resolves. The ladder is family-independent,
# so without this an unknown name would come back with source=config and a real
# effort — a caller would then add flags for a CLI that is never invoked. The
# engine validates REVIEWER and AUTHOR to the same two names.
case "$FAMILY" in claude|codex) ;; *) emit_default ;; esac

# A symlink is refused for the same reason the loop refuses one anywhere else:
# this file decides which model runs, and a link is a way to point that at
# something the repository did not put there.
{ [ -f "$CFG" ] && [ ! -L "$CFG" ]; } || emit_default
command -v python3 >/dev/null 2>&1 || emit_default

# -I: no PYTHONPATH, no user site. tomllib is 3.11+; on anything older a module
# of that name is not the standard library's, and this is not the place to let an
# unknown parser decide what model gets invoked.
OUT="$(CFG="$CFG" FAMILY="$FAMILY" LINES="$LINES" python3 -I - 2>/dev/null <<'PY' 
import os, sys

if sys.version_info < (3, 11):
    sys.exit(1)
try:
    import tomllib
except Exception:
    sys.exit(1)
try:
    with open(os.environ["CFG"], "rb") as fh:
        cfg = tomllib.load(fh)
except Exception:
    sys.exit(1)
if not isinstance(cfg, dict):
    sys.exit(1)

fam, lines = os.environ["FAMILY"], int(os.environ["LINES"])

def s(table, key):
    """A string value for this family, or "" — wrong types are dropped rather
    than stringified, so a `model = 42` cannot become a flag."""
    t = cfg.get(table)
    if not isinstance(t, dict):
        return ""
    f = t.get(fam)
    if not isinstance(f, dict):
        return ""
    v = f.get(key)
    return v if isinstance(v, str) and v.strip() else ""

# Highest threshold at or below the diff size wins. A malformed ladder, or one
# with no row at or below the size, leaves this EMPTY: an unconfigured effort must
# produce no flag at all, or a config that sets only a model would quietly change
# how hard the reviewer thinks.
effort = ""
ladder = cfg.get("effort", {}).get("ladder") if isinstance(cfg.get("effort"), dict) else None
if isinstance(ladder, list):
    picked = None
    for row in ladder:
        if (isinstance(row, list) and len(row) == 2
                and isinstance(row[0], int) and not isinstance(row[0], bool)
                and isinstance(row[1], str) and row[1].strip()
                and lines >= row[0]
                and (picked is None or row[0] >= picked[0])):
            picked = row
    if picked:
        effort = picked[1]

# A newline in any value would forge an extra key=value line in the caller's
# read loop, so the whole result is refused rather than partially emitted.
vals = (("model", s("reviewer", "model")), ("effort", effort),
        ("writer", s("writer", "tier")), ("source", "config"))
for _, v in vals:
    if "\n" in v or "\r" in v:
        sys.exit(1)
sys.stdout.write("".join("%s=%s\n" % kv for kv in vals))
PY
)" || OUT=""

[ -n "$OUT" ] || emit_default
printf '%s\n' "$OUT"
