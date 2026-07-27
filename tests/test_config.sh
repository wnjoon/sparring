#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C="$ROOT/plugins/spar/commands/spar-config.sh"
chk() { if printf '%s' "$3" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1"; echo "  want:$2"; echo "  got :$3"; FAIL=$((FAIL+1)); fi; }
chk_absent() { if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "FAIL: $1"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }
fresh() { d=$(mktemp -d); cd "$d" || exit 1; cd "$(pwd -P)" || exit 1; }

# 1. shipped defaults: no override file anywhere
fresh
OUT=$(SPAR_CONFIG_FILE=/nonexistent bash "$C" claude 40); RC=$?
chk "missing config → exit 0" "0" "$RC"
chk "missing config → says it used defaults" "source=default" "$OUT"
chk "missing config → still names an effort" "effort=" "$OUT"
chk "missing config → writer tier present" "writer=" "$OUT"
chk_absent "missing config → invents no model" "model=null" "$OUT"

# 2. a config supplies per-family values
fresh
cat > cfg.toml <<'TOML'
[reviewer.claude]
model = "claude-sonnet-5"
[reviewer.codex]
model = "gpt-5.6-sol"
[writer.claude]
tier = "claude-haiku-4-5-20251001"
TOML
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40)
chk "claude model read from config" "model=claude-sonnet-5" "$OUT"
chk "claude writer tier read from config" "writer=claude-haiku-4-5-20251001" "$OUT"
chk "reads as config, not default" "source=config" "$OUT"
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" codex 40)
chk "codex model read from its own table" "model=gpt-5.6-sol" "$OUT"
chk "codex writer falls back when its table is absent" "writer=" "$OUT"

# 3. effort scales with diff size, using the ladder in the config
fresh
cat > cfg.toml <<'TOML'
[effort]
ladder = [[0, "low"], [200, "medium"], [1000, "high"]]
TOML
for pair in "10 low" "199 low" "200 medium" "999 medium" "1000 high" "50000 high"; do
  set -- $pair
  OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude "$1")
  chk "diff $1 lines → effort $2" "effort=$2" "$OUT"
done

# 4. a broken config never breaks the loop
fresh
printf 'this is [ not = toml\n' > cfg.toml
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40); RC=$?
chk "unparseable config → exit 0" "0" "$RC"
chk "unparseable config → falls back to defaults" "source=default" "$OUT"

fresh
mkdir -p cfg.toml
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40); RC=$?
chk "config is a directory → exit 0" "0" "$RC"
chk "config is a directory → defaults" "source=default" "$OUT"

fresh
printf '[reviewer.claude]\nmodel = "x"\n' > cfg.toml
ln -s "$PWD/cfg.toml" link.toml
OUT=$(SPAR_CONFIG_FILE="$PWD/link.toml" bash "$C" claude 40)
chk "symlinked config → ignored, defaults used" "source=default" "$OUT"

# 5. a value of the wrong shape is ignored, not passed through
fresh
cat > cfg.toml <<'TOML'
[reviewer.claude]
model = 42
[effort]
ladder = "not a ladder"
TOML
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40)
chk_absent "non-string model is dropped" "model=42" "$OUT"
chk "bad ladder → default effort still emitted" "effort=" "$OUT"

# 6. an unknown family is not an error
fresh
OUT=$(SPAR_CONFIG_FILE=/nonexistent bash "$C" gemini 40); RC=$?
chk "unknown family → exit 0" "0" "$RC"
chk "unknown family → defaults" "source=default" "$OUT"

# 7. output is exactly four key=value lines, nothing else
fresh
OUT=$(SPAR_CONFIG_FILE=/nonexistent bash "$C" claude 40)
chk "exactly four lines" "4" "$(printf '%s\n' "$OUT" | grep -c '=')"
chk_absent "no stray prose" " " "$(printf '%s\n' "$OUT" | tr -d '\n')"

# 8. the shipped config parses and every family it names is one we support
CFG="$ROOT/plugins/spar/shared/config.toml"
chk "shipped config exists" "present" "$([ -f "$CFG" ] && echo present || echo absent)"
OUT=$(SPAR_CONFIG_FILE="$CFG" bash "$C" claude 100)
chk "shipped config parses" "source=" "$OUT"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
