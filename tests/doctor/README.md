# Doctor D002 fixtures (not executed by `corpus_gates.py suite`, which scans only tests/suite)

Manual check with a built compiler:

```
orbit doctor tests/doctor
```

`D002` is scoped to one program: two routes collide only when one program's
import closure reaches both files. So each pair here is a real program:
`d002_dup_b.orb` declares `main` and imports `d002_dup_a.orb`.

Expected:

- exactly one D002 (GET /dup in d002_dup_b.orb, first seen in d002_dup_a.orb).
  The typecheck also reports the duplicate route, so `D008` accompanies it.
- GET /items + POST /items must NOT flag: different methods share a path
  legitimately.
- Exit code 1.

`scripts/doctor_gates.py cli-probe` pins the same two halves automatically
(`doctor-separate-programs`, `doctor-one-program`), so this directory is a
readable example rather than the only coverage.
