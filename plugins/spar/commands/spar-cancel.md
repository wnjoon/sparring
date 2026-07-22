---
description: "Cancel the active sparring loop and clean up its state"
---

Run this cleanup command, then confirm cancellation to the user:

```bash
rm -f .claude/spar.local.md .claude/spar-run-reviewer.sh .claude/spar-reviewer-prompt.txt .claude/spar-retries .claude/spar-ledger.md .claude/spar-registry.tsv .claude/spar-registry-round .claude/spar-run-judge.sh .claude/spar-judge-prompt.txt .claude/spar-judge-pending .claude/spar-judge-seq .claude/spar-judge-retries .claude/spar-gate-manifest.tsv .claude/spar-gate.md .claude/spar-gate-seq .claude/spar-run-matcher.sh .claude/spar-matcher-prompt.txt .claude/spar-matcher-pending .claude/spar-matcher-manifest.tsv .claude/spar-matcher-round .claude/spar-matcher-retries .claude/spar-aliases.tsv
echo "Sparring loop cancelled. Review artifacts in reviews/ were kept."
```
