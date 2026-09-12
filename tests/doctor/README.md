# Doctor D002 fixtures (not executed by test_suite.py, which scans only tests/suite)

Manual check with a built compiler:

```
orbit doctor tests/doctor
```

Expected: exactly one D002 (GET /dup in d002_dup_b.orb, first seen in
d002_dup_a.orb). GET /items + POST /items must NOT flag (different
methods share a path legitimately). Exit code 1.
