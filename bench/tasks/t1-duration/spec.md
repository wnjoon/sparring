# Task: parse_duration

Implement `parse_duration(s: str) -> int` in `duration.py` (a single function).

Return the total number of **seconds** for a duration string built from
number+unit segments, where units are `h` (hours), `m` (minutes), `s` (seconds).

Requirements:
- Single segment: `"1h"` → 3600, `"30m"` → 1800, `"45s"` → 45.
- Multiple segments combine (any order not required — segments appear h→m→s):
  `"1h30m"` → 5400, `"1h30m10s"` → 5410.
- Numbers are not capped to a unit's normal range: `"90m"` → 5400.
- `"0s"` → 0.
- Invalid input raises `ValueError`: empty string, a number with no unit
  (`"1h30"`), an unknown unit (`"10x"`), a negative number (`"-5s"`),
  or non-numeric junk (`"abc"`).

Do not read or assume any hidden test file. Implement exactly to this spec.
