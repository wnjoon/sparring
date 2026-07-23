# sparring effect benchmark (living report)

Does the enforced review loop actually improve the shipped artifact versus the
author's un-reviewed first pass? This is a small, honest **demonstration** — not
a statistically rigorous study. It is updated as phases land (see *How to update*).

**Last run:** 2026-07-23 · Phase 3 (single-agent mode) merged on `dev`.

## Method

Paired comparison, one shared starting artifact per task:

- **P0** — the author's first-pass implementation (a `claude` **sonnet** subagent,
  given only the task `spec.md`, never the oracle). Sonnet is a deliberately
  fallible-but-capable author so review has a fair chance to matter.
- **A (no review)** — grade P0 as-is.
- **B_cross** — start from P0, run the sparring loop with **Claude author ↔ Codex
  reviewer** to a fix, grade the result.
- **B_single** — start from the same P0, run the loop with **Claude author ↔ Claude
  reviewer** (Phase 3 single-agent mode), grade the result.

**Oracle:** each task has a hidden reference test suite (`oracle.py`) the author and
the reviewer never see. It is the objective grader. `spec.md` states the
requirements (including edge cases) in prose; the oracle checks them.

**Why the oracle is hidden but the spec is explicit:** the reviewer works from the
*same spec* as the author. So review cannot catch a requirement nobody was told
about — its job is to catch where the **code fails the spec the author was given**
(implementation bugs), not to invent unstated requirements.

Tasks live in `tasks/<t>/` (`spec.md`, `oracle.py`, and for the planted-bug runs
`planted_bug.py`). Grade any candidate file with:
`python3 tasks/<t>/oracle.py <path-to-implementation.py>`

## Results

### 1. Natural first pass on well-specified tasks — review had nothing to catch

| Task | Natural P0 (A) |
|---|---|
| t1 duration parser | 12/12 ✅ |
| t2 paginate | 8/8 ✅ |
| t3 LRU cache | 4/4 ✅ |
| t4 semver compare (hard: pre-release precedence) | 12/12 ✅ |

A capable author reading an explicit spec got **all four** correct on the first
pass — even the deliberately tricky semver task. On these, the loop correctly adds
nothing: it would converge with no findings (or only style/test nits). **Review is
a safety net, not a quality multiplier on already-correct code.**

### 2. Planted-bug first pass — review reliably caught and fixed the defect

To measure the safety net when the author *does* err, each of t1–t3 was seeded with
a plausible hasty-author bug (`planted_bug.py`), then run through both loops.

| Task | planted bug | A (no review) | B_cross (Claude↔Codex) | B_single (Claude↔Claude) |
|---|---|---|---|---|
| t1 duration | `findall` w/o full-string match → accepts `"1h30"`, `"-5s"` | 10/12 | **12/12** | **12/12** |
| t2 paginate | 1-indexing off-by-one (`page*size`) | 4/8 | **8/8** | **8/8** |
| t3 LRU | `get` doesn't update recency | 3/4 | **4/4** | **4/4** |
| **total** | | **17/24 (71%)** | **24/24 (100%)** | **24/24 (100%)** |

Both reviewers independently named the exact planted defect every time
(e.g. Codex: *"Page offset is calculated as zero-indexed"*; Claude: *"`get` does not
update recency"*), plus flagged missing tests. One review→fix round took the
artifact from **71% → 100%**.

### 3. Cross-model vs single-model

Identical here (both 100%). These planted bugs are clear-cut spec violations that
any competent **blind, fresh** reviewer catches, regardless of vendor. The
cross-vendor-diversity advantage (invariant 4's motivation) would show on
**subtler bugs that sit in one vendor's blind spot** — which this suite does not yet
contain. Building such cases is the main open task for this benchmark.

## What this shows (and doesn't)

- **Shows:** when the author ships a real defect, the enforced loop catches and
  fixes it — 3/3 planted bugs, 71%→100%, with either reviewer family. The Phase 3
  single-agent (Claude↔Claude) loop is as effective as cross-model on clear defects,
  so a Codex-less user still gets the safety net.
- **Doesn't show (yet):** a natural-bug delta (a capable author's first pass was
  already correct on all 4 tasks), or the cross-vs-single gap (needs subtle,
  vendor-blind-spot bugs).

## Limits (read before quoting numbers)

- Small N (3–4 tasks), **1 trial**, LLM nondeterminism → illustrative, not
  statistical.
- Planted bugs are a **proxy** for author error, not natural ones — clearly labeled.
- Author tier = sonnet; a stronger author errs less (smaller safety-net effect), a
  weaker/rushed one errs more.
- Review cannot catch **unspecified** requirements (reviewer shares the spec).
- Each B is **one** review→fix round; the real loop iterates to reviewer-declared
  convergence, so B is a lower bound on the loop's effect.
- The natural first passes were correct partly *because the tasks are small and
  well-specified*; larger/underspecified real work is where natural bugs live.

## How to update (per phase)

1. Re-run the planted-bug suite (§2) after changes to the loop/hook to confirm the
   safety net still fires (regression guard for the review machinery itself).
2. **Add harder/larger tasks** aimed at inducing *natural* first-pass bugs (multi-file
   changes, stateful/concurrent logic, gotcha-heavy algorithms) — this is where a
   natural-bug delta would appear.
3. **Add subtle, vendor-blind-spot bugs** to expose the cross-vs-single gap (§3).
4. When a new phase adds a capability (e.g. the design gate, the sweep), add a task
   that exercises it and record whether the loop's outcome improves.
5. Bump *Last run* and append results; keep the *Limits* honest.

*(This is a demonstration harness. Grading is automated via `oracle.py`; the P0
generation and loop steps were orchestrated manually this run and are not yet a
one-command runner — promoting them to `bench/run.sh` is a good future step.)*
