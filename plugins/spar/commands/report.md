---
description: "Report: show the final report of a completed sparring run"
argument-hint: "[review-id]"
allowed-tools:
  - Bash
  - Read
---

Run this, then present the report to the user:

```bash
SPAR_REPORT_ID="$(printf '%s' "$ARGUMENTS" | tr -d '[:space:]')"
"${CLAUDE_PLUGIN_ROOT}/commands/spar-report-show.sh" "$SPAR_REPORT_ID" || true
```

Then summarize what it says, in this order: the outcome and round count, the
findings tally, any decision still pending, and the changed files. Read-only —
never edit, regenerate, or reinterpret the report; it is frozen at the end of
the run it describes. If nothing was printed, tell the user plainly that no
report exists for that run (reports are written only for runs that reached a
terminal path with this feature installed).
