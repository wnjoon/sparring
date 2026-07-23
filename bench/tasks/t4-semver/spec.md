# Task: semver_compare

Implement `semver_compare(a: str, b: str) -> int` in `semver.py` (single function).
Return -1 if a < b, 0 if equal, 1 if a > b, per the Semantic Versioning 2.0.0
precedence rules.

Rules:
- Compare `MAJOR.MINOR.PATCH` numerically first.
- A version WITH a pre-release (e.g. `1.0.0-alpha`) has LOWER precedence than the
  same version without one (`1.0.0`).
- Pre-release precedence: split the pre-release string on `.` into identifiers,
  compare left to right:
  - numeric identifiers compared numerically (so `2` < `11`, NOT lexically);
  - a numeric identifier is LOWER than a non-numeric one;
  - non-numeric identifiers compared lexically (ASCII);
  - if all shared identifiers are equal, the version with MORE identifiers is higher
    (`alpha` < `alpha.1`).
- Build metadata (anything after `+`) is IGNORED for precedence (`1.0.0+x` == `1.0.0`).

Assume well-formed input. Do not read or assume any hidden test file.
