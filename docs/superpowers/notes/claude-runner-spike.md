# Task 19 spike — verified read-only, isolated `claude -p` reviewer invocation

Result: **the mechanism works.** Verified E2E against a scratch repo with a planted bug and a write-temptation.

## Verified command

```bash
claude -p --safe-mode --tools Read Grep Glob  < <prompt-file>  > <output-file>
```

- **Prompt via stdin** (`< file`), NOT as a positional argument.
- **`--tools` values as separate args** (`Read Grep Glob`), NOT one quoted string.
- Output captured via **stdout redirect** (`> out`); `-p` prints the final message to stdout.
- `claude --version` at verification: (run `claude --version` to record; installed CLI: 2.1.218 (Claude Code)).

## Two gotchas found (would have broken a naive runner)

1. **`--tools` / `--disallowedTools` are variadic** (`<tools...>`). A positional prompt after them is greedily consumed as tool names — the prompt words showed up as "Permission deny rule '…' matches no known tool", and `claude -p` then errored with "Input must be provided through stdin or as a prompt argument". **Fix: feed the prompt on stdin** so no positional arg exists for the variadic flag to eat.
2. **`--tools "Read Grep Glob"`** (one quoted string) is a single tool literally named "Read Grep Glob". **Fix: pass them as separate args** `--tools Read Grep Glob`.

## Evidence (all four properties)

| Property | Result |
|---|---|
| A. single-writer — no `PROOF.txt` written despite being told to attempt it | PASS — claude reported "no write-capable tools available (only Glob, Grep, and Read)" |
| B. output captured, first line is the protocol status | PASS — `STATUS: FINDINGS`, and it caught the planted `a-b` → `a+b` bug |
| C. no hang in `-p` | PASS — `exit=0`, returned cleanly |
| D. no recursion into spar's hook | PASS — `--safe-mode` loaded no plugins/hooks; zero `.claude/spar*` artifacts created |

## Consequences for the runner (Task 20)

- `--tools Read Grep Glob` alone makes the reviewer read-only **by construction** (no Edit/Write/Bash tool exists) — `--disallowedTools` is redundant and can be omitted.
- No `Bash` ⇒ the reviewer cannot run `git diff` itself ⇒ **the hook must provide the change surface** (diff + untracked) appended to the stdin prompt. Confirmed in the spike by inlining the file under review.
- `--safe-mode` is required, not optional: it is what prevents recursion (loading spar's own Stop hook) and debate-leak via shared CLAUDE.md/memory.

## Not covered here (later)
- Judge and matcher use the same `claude -p --safe-mode --tools Read Grep Glob` mechanism with their own prompts.
- Full same-family loop E2E is Task 23.
