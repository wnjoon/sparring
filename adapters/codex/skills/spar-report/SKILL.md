---
name: spar-report
description: Show the final report of a completed sparring run — outcome, rounds, findings tally, decisions, and changed files.
---

# spar-report

```bash
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-$HOME/.codex/sparring/plugins/spar}"
"$SPAR_ROOT/commands/spar-report-show.sh" "$(printf '%s' "$1" | tr -d '[:space:]')" || true
```

With no argument it shows the most recent run. Then summarize, in this order: the
outcome and round count, the findings tally, any decision still pending, and the
changed files.

Read-only — never edit, regenerate, or reinterpret the report; it is frozen at the
end of the run it describes. Reports exist for `converged`, `blocked-pending-user`,
`cap`, `sweep-findings-at-cap`, and `skipped`; an internal-error bypass or an
explicit cancel writes none. If nothing was printed, say so plainly.
