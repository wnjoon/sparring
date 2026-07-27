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
chk "missing config → names no effort" "effort=" "$OUT"
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
chk "bad ladder → no effort emitted" "effort=" "$OUT"

# 5b. an effort the CLIs do not know is dropped, not passed through.
# claude accepts `--effort banana` with exit 0, warns on stderr and runs at its
# DEFAULT effort — indistinguishable from a working ladder unless someone reads
# the terminal. A typo here must therefore produce no flag at all.
fresh
cat > cfg.toml <<'TOML'
[effort]
ladder = [[0, "hgih"]]
TOML
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40)
chk_absent "a misspelt effort is not passed through" "hgih" "$OUT"
WANT_NO_EFFORT="$(printf 'model=\neffort=\nwriter=\nsource=config')"
chk "a misspelt effort emits no effort at all" "identical" \
  "$([ "$OUT" = "$WANT_NO_EFFORT" ] && echo identical || printf 'differs: %s' "$OUT")"

# Every documented word still works, or the guard is a blocklist by accident.
fresh
for lvl in low medium high xhigh max; do
  printf '[effort]\nladder = [[0, "%s"]]\n' "$lvl" > cfg.toml
  OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40)
  chk "effort $lvl survives the whitelist" "effort=$lvl" "$OUT"
done

# A valid rung below an invalid one still wins on its own terms: the guard drops
# the value, it does not fall back to a different rung.
fresh
cat > cfg.toml <<'TOML'
[effort]
ladder = [[0, "low"], [10, "enormous"]]
TOML
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 5)
chk "a rung below the bad one is unaffected" "effort=low" "$OUT"
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 50)
chk_absent "and the bad rung emits nothing rather than the lower one" "effort=low" "$OUT"

# 6. an unknown family is not an error — and must not pick up a real config.
# Tested against a VALID config: with a nonexistent one the check passes whether
# or not the family is validated, which is how this was missed the first time.
fresh
cat > cfg.toml <<'TOML'
[reviewer.claude]
model = "claude-sonnet-5"
[effort]
ladder = [[0, "low"], [200, "high"]]
TOML
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" gemini 40); RC=$?
chk "unknown family with a valid config → exit 0" "0" "$RC"
chk "unknown family with a valid config → defaults" "source=default" "$OUT"
WANT_DEFAULT="$(printf 'model=\neffort=\nwriter=\nsource=default')"
chk "unknown family → the whole default line set, not just some of it" "identical" \
  "$([ "$OUT" = "$WANT_DEFAULT" ] && echo identical || printf 'differs: %s' "$OUT")"
chk_absent "unknown family → no model leaks from another family" "claude-sonnet-5" "$OUT"
OUT=$(SPAR_CONFIG_FILE=/nonexistent bash "$C" gemini 40)
chk "unknown family with no config → defaults too" "source=default" "$OUT"
# The two supported families still read the same config.
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" claude 40)
chk "claude still reads it" "source=config" "$OUT"
OUT=$(SPAR_CONFIG_FILE="$PWD/cfg.toml" bash "$C" codex 40)
chk "codex still reads it" "source=config" "$OUT"

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
# Out of the box nothing is enabled: the file exists so it can be edited, but it
# must not change a single flag until someone uncomments a line. Compared whole —
# chk is a substring match, so "model=" alone passes for "model=claude-sonnet-5"
# and would pin nothing.
WANT="$(printf 'model=\neffort=\nwriter=\nsource=config')"
chk "shipped config enables nothing at all" "identical" \
  "$([ "$OUT" = "$WANT" ] && echo identical || printf 'differs: %s' "$OUT")"

echo; echo "PASS=$PASS FAIL=$FAIL"; exit "$FAIL"
