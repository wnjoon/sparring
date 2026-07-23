# Task: LRUCache

Implement class `LRUCache` in `lru.py`:
- `LRUCache(capacity: int)` — fixed positive capacity.
- `get(key)` → the value, or `None` if absent. A `get` counts as a use
  (makes the key most-recently-used).
- `put(key, value)` — insert/update. A `put` counts as a use. If inserting a
  new key exceeds capacity, evict the **least-recently-used** key first.
  Updating an existing key does NOT evict; it updates the value and marks it
  most-recently-used.

Requirements (recency must be tracked correctly):
- capacity 2: put(a,1), put(b,2), get(a) [a now MRU], put(c,3) evicts b →
  get(b) is None, get(a)==1, get(c)==3.
- updating existing: put(a,1), put(b,2), put(a,9) [a now MRU], put(c,3)
  evicts b → get(a)==9, get(b) is None.
- capacity 1: put(a,1), put(b,2) → get(a) is None, get(b)==2.

Do not read or assume any hidden test file. Implement exactly to this spec.
