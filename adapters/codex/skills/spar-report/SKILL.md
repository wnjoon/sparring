---
name: spar-report
description: Show the final report of a completed sparring run — outcome, rounds, findings tally, decisions, and changed files.
---

# spar-report

Run this, replacing `RUN_ID` with the run id the user named — letters, digits
and hyphens only, which is all a run id ever contains. Leave it empty when they
named none, and when they said something that is not a run id. Then present what
it prints:

```bash
SPAR_ROOT="${SPAR_PLUGIN_ROOT:-}"
[ -n "$SPAR_ROOT" ] || SPAR_ROOT=@@SPAR_PLUGIN_ROOT@@
"$SPAR_ROOT/commands/spar-report-show.sh" "$(printf '%s' 'RUN_ID' | tr -d '[:space:]')" || true
```

With no id it shows the most recent run. Then summarize, in this order: the
outcome and round count, the findings tally, any decision still pending, and the
changed files.

Read-only — never edit, regenerate, or reinterpret the report; it is frozen at the
end of the run it describes. Reports exist for `converged`, `blocked-pending-user`,
`cap`, `sweep-findings-at-cap`, and `skipped`; an internal-error bypass or an
explicit cancel writes none. If nothing was printed, say so plainly.
