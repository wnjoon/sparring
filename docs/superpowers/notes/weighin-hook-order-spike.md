# Weigh-in hook-ordering spike — findings

**Question:** can `/spar-weighin` rely on registering a *second* Stop hook that
runs **after** `spar`'s `stop-hook.sh`, observes its side effects (the removal of
`.claude/spar.local.md`), and keeps the session alive when either hook blocks?

**Answer: NO.** Verified against the Claude Code hooks documentation:

- Multiple Stop hooks all run (no short-circuit) — good.
- **Execution order is NOT guaranteed** for Stop hooks; they may run in
  parallel, not in listed array order.
- **Decision aggregation across Stop hooks is not documented** — "block wins"
  is only an inference from PreToolUse's "most restrictive" rule, not a
  guaranteed Stop-hook contract.
- **Cross-hook side-effect visibility is not documented** — hook B is not
  guaranteed to observe a file hook A deleted.

The two-ordered-hooks design has a fatal race: at a task's convergence event,
`spar`'s hook removes `.claude/spar.local.md` and approves. If the weigh-in hook
runs *before* it (order not guaranteed), it still sees the state present, defers
(approves), and the session exits before the weigh-in can advance to the next
task.

## Decision: single combined dispatcher hook

Register exactly ONE Stop hook (the weigh-in dispatcher). It runs `spar`'s
`stop-hook.sh` as a **subroutine in the same process**, captures its decision,
and only then applies weigh-in logic:

1. Feed the received hook stdin to `stop-hook.sh`; capture its stdout JSON.
   Because this is a plain sequential subprocess call, `spar`'s side effects
   (state cleanup, outcome write) have completed before step 2 — no ordering
   or visibility assumptions needed.
2. If a weigh-in is inactive → print `spar`'s decision verbatim (behavior
   identical to today; `spar`-only users are unaffected).
3. If a weigh-in is active AND `spar` decided `approve` (a task loop just
   terminated) → run the weigh-in advance/finish/stop logic and print its
   decision (usually `block` to launch the next task). Otherwise print
   `spar`'s decision verbatim (e.g. `spar` blocked mid-round → pass through).

`spar`'s `stop-hook.sh` is unchanged; the dispatcher only *calls* it. This is
strictly more robust than two ordered hooks and removes the race entirely.
