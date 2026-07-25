# Spike — does Codex have a blocking Stop hook? (2026-07-25)

**Question.** Phase 6 was designed around the assumption that Codex has no
session-exit hook, so enforcement had to weaken to a git pre-commit hook. Is that
still true?

**Answer: no.** `codex-cli 0.144.1` has a `Stop` hook that honors
`decision:block`, so the Codex seat can keep the same enforcement strength as the
Claude seat. Everything below is reproducible; re-run it when Codex changes.

## What the CLI exposes

```
$ codex features list | grep -E '^(hooks|plugin_hooks) '
hooks                                stable             true
plugin_hooks                         removed            false
```

Hooks are stable and on by default. **Plugins cannot register hooks**
(`plugin_hooks` removed), so hook registration is a standalone `hooks.json`, not
something a packaged plugin can carry.

Event names, from the wire enum in the binary:

```
preToolUse  permissionRequest  postToolUse  preCompact  postCompact
sessionStart  userPromptSubmit  subagentStart  subagentStop  stop
```

Config shape matches Claude Code's exactly — verified against a `hooks.json`
already in use on this machine:

```json
{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "…" } ] } ] } }
```

`HookMetadata` fields: `eventName`, `handlerType`, `matcher`, `timeoutSec`,
`statusMessage`, `sourcePath`, `displayOrder`, `isManaged`, `currentHash`,
`trustStatus`. Trust states: `untrusted` / `trusted` / `modified` / `managed`.
Config requirements include `allowManagedHooksOnly`, so a managed environment can
forbid user hooks.

## The reproduction

Scratch git repo, a Stop hook that blocks its first invocation and allows the
second:

```bash
cat > .codex/stop-hook.sh <<'EOF'
#!/usr/bin/env bash
IN=$(cat)
N=$(cat .codex/count 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > .codex/count
{ echo "--- invocation $N"; printf '%s\n' "$IN"; } >> .codex/hook.log
if [ "$N" -eq 1 ]; then
  printf '{"decision":"block","reason":"Not done yet: create a file named PROOF.txt containing the word BLOCKED, then stop."}\n'
else
  printf '{}\n'
fi
exit 0
EOF
chmod +x .codex/stop-hook.sh
cat > .codex/hooks.json <<'EOF'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "./.codex/stop-hook.sh" } ] } ] } }
EOF

codex exec --dangerously-bypass-hook-trust --sandbox workspace-write \
  --skip-git-repo-check "Read note.txt and tell me what it says. Nothing else."
```

**Result:** hook fired twice; `PROOF.txt` was created containing `BLOCKED`. The
model had finished its answer, was blocked, read the `reason`, carried out the
instruction inside it, and only then stopped. The binary also carries the guard
string `hook returned decision:block without a non-empty reason` — the same
contract Claude Code enforces.

## The payload

```json
{"session_id":"…","turn_id":"…","transcript_path":"…","cwd":"…",
 "hook_event_name":"Stop","model":"gpt-5.6-sol",
 "permission_mode":"bypassPermissions","stop_hook_active":false,
 "last_assistant_message":"hello"}
```

Near-identical to Claude Code's Stop payload, including the `stop_hook_active`
loop guard. `plugins/spar/hooks/stop-hook.sh` consumes stdin and discards it, so
**the payload difference costs nothing** — the gatekeeper is portable as-is.

## Consequences for the design

1. Enforcement for the Codex seat is the Stop hook. The pre-commit hook — and the
   "weaker guarantee" caveat that came with it — is dropped.
2. One gatekeeper serves both hosts. No fork of `stop-hook.sh`.
3. Registration is a standalone `hooks.json`, installed **once**: changing the
   file resets trust to `modified`, so per-run install/remove would re-prompt for
   trust every loop. The hook already no-ops when there is no state file, so an
   idle registration is free.
4. Two new honesty obligations: if the hook is untrusted or policy-disabled, the
   loop never engages, so activation must detect that and refuse rather than let an
   author believe they are being reviewed.

## Also learned, not used here

`~/.codex/prompts/` (the entry point named in `docs/design-decisions.md`) does not
appear to exist in 0.144.1. Codex **skills** do: `~/.codex/skills/<name>/SKILL.md`,
with a `.codex/skills` project path. Codex additionally has an
`external_agent_config` importer that reads `.claude/settings.json`, `CLAUDE.md`,
and Claude commands/subagents/hooks/skills — not relied on by this design, but it
explains why the hook schema matches.
