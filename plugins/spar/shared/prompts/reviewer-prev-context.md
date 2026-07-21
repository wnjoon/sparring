## Previous round

Read `{{PREV_REVIEW}}` (your previous findings) and `{{PREV_RESPONSE}}` (the
author's per-finding response), then verify against the current diff:

- For each finding marked FIXED: confirm the fix is real and complete.
  Re-raise it (same ID, new number) if it is not.
- For each finding marked REJECTED: judge the stated reason on its merits
  against the code and the task requirements. Do not cave to confident
  wording. Re-raise if the reason does not hold; otherwise accept and drop it.
