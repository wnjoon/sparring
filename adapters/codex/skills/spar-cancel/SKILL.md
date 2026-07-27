---
name: spar-cancel
description: Clear an active sparring loop and/or a prepared plan, recording an honest cancelled outcome.
---

# spar-cancel

```bash
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-}"
[ -n "$SPAR_ROOT" ] || SPAR_ROOT=@@SPAR_PLUGIN_ROOT@@
if [ -f .claude/spar.local.md ]; then
  SW="$(sed -n 's/^sweep_result: *//p' .claude/spar.local.md | head -1)"
  case "$SW" in not-run|not-triggered|pending|clean|findings|error) ;; *) SW=not-run ;; esac
  "$SPAR_ROOT/commands/spar-record-outcome.sh" cancelled .claude/spar.local.md "$SW" || true
fi
rm -f .claude/spar-plan.local.md .claude/spar-fight.log .claude/spar-fight-task.txt
rm -f .claude/spar.local.md .claude/spar-run-reviewer.sh .claude/spar-reviewer-prompt.txt \
      .claude/spar-retries .claude/spar-ledger.md .claude/spar-registry.tsv \
      .claude/spar-registry-round .claude/spar-run-judge.sh .claude/spar-judge-prompt.txt \
      .claude/spar-judge-pending .claude/spar-judge-seq .claude/spar-judge-retries \
      .claude/spar-gate-manifest.tsv .claude/spar-gate.md .claude/spar-gate-seq \
      .claude/spar-run-matcher.sh .claude/spar-matcher-prompt.txt .claude/spar-matcher-pending \
      .claude/spar-matcher-manifest.tsv .claude/spar-matcher-round .claude/spar-matcher-retries \
      .claude/spar-aliases.tsv .claude/spar-diff.txt .claude/spar-intent-pointers.txt \
      .claude/spar-run-sweep.sh .claude/spar-sweep-prompt.txt .claude/spar-sweep-retries \
      .claude/spar-fix-brief.md
rmdir .claude/spar-sweep.lock 2>/dev/null || true
echo "Sparring cancelled. Review artifacts in reviews/ were kept."
```

The hook registration is **not** touched: it is installed once and self-disables
when no loop is active, and rewriting it would reset Codex's hook trust.
