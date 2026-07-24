---
description: "Cancel the active sparring loop and clean up its state"
---

Run this cleanup command, then confirm cancellation to the user:

```bash
if [ -f .claude/spar.local.md ]; then
  SPAR_SWEEP_RESULT="$(sed -n 's/^sweep_result: *//p' .claude/spar.local.md | head -1)"
  case "$SPAR_SWEEP_RESULT" in
    not-run|not-triggered|pending|clean|findings|error) ;;
    *) SPAR_SWEEP_RESULT=not-run ;;
  esac
  "${CLAUDE_PLUGIN_ROOT}/commands/spar-record-outcome.sh" cancelled .claude/spar.local.md "$SPAR_SWEEP_RESULT" || true
fi
if [ -f .claude/spar-weighin.local.md ]; then
  echo "Weigh-in state cleared."
fi
rm -f .claude/spar-weighin.local.md .claude/spar-weighin.log .claude/spar-weighin-task.txt
rm -f .claude/spar.local.md .claude/spar-run-reviewer.sh .claude/spar-reviewer-prompt.txt .claude/spar-retries .claude/spar-ledger.md .claude/spar-registry.tsv .claude/spar-registry-round .claude/spar-run-judge.sh .claude/spar-judge-prompt.txt .claude/spar-judge-pending .claude/spar-judge-seq .claude/spar-judge-retries .claude/spar-gate-manifest.tsv .claude/spar-gate.md .claude/spar-gate-seq .claude/spar-run-matcher.sh .claude/spar-matcher-prompt.txt .claude/spar-matcher-pending .claude/spar-matcher-manifest.tsv .claude/spar-matcher-round .claude/spar-matcher-retries .claude/spar-aliases.tsv .claude/spar-diff.txt .claude/spar-intent-pointers.txt .claude/spar-run-sweep.sh .claude/spar-sweep-prompt.txt .claude/spar-sweep-retries
rmdir .claude/spar-sweep.lock 2>/dev/null || true
echo "Sparring loop cancelled. Review artifacts in reviews/ were kept."
```
