# Bundled SQLite 3.53.4 (Windows x64)

Precompiled SQLite DLL + import library shipped with Orbit so DB-enabled
programs can be linked and run without a system-installed SQLite.

| File            | Origin                                                                 |
|-----------------|------------------------------------------------------------------------|
| `sqlite3.h`     | `sqlite-amalgamation-3530400.zip` (declarations only; not the impl)    |
| `win-x64/sqlite3.dll` | `sqlite-dll-win-x64-3530400.zip` (official 64-bit DLL)                 |
| `win-x64/sqlite3.lib` | import library generated once from the official `sqlite3.def`          |

Regenerate the import library:

```
zig dlltool -d sqlite3.def -D sqlite3.dll -l sqlite3.lib -m i386:x86-64
```

SQLite is in the public domain (redistribution is unrestricted).

The native backend emits a load-time import for `sqlite3.dll`, so a DB
program only needs `sqlite3.dll` findable at runtime (next to the exe or on
PATH); only the C backend additionally links `sqlite3.lib`. On Linux/macOS
the compiler falls back to the system `-lsqlite3` instead.