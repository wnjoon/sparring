# Task: paginate

Implement `paginate(items: list, page_size: int, page: int) -> list` in
`paginate.py` (a single function).

`page` is **1-indexed**. Return the sublist of `items` for that page.

Requirements:
- `paginate([1..10], 3, 1)` → `[1,2,3]`; page 2 → `[4,5,6]`.
- Last partial page: `paginate([1..10], 3, 4)` → `[10]`.
- Page beyond the range → empty list: `paginate([1..10], 3, 5)` → `[]`.
- `page_size` larger than len → full list on page 1: `paginate([1..10],100,1)` → `[1..10]`.
- Empty items → `[]`.
- `page_size < 1` or `page < 1` → raise `ValueError`.

Do not read or assume any hidden test file. Implement exactly to this spec.
