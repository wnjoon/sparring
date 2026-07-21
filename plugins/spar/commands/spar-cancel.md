---
description: "Cancel the active sparring loop and clean up its state"
---

Run this cleanup command, then confirm cancellation to the user:

```bash
rm -f .claude/spar.local.md .claude/spar-run-reviewer.sh .claude/spar-reviewer-prompt.txt .claude/spar-retries
echo "Sparring loop cancelled. Review artifacts in reviews/ were kept."
```
