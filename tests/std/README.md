# Standard library tests

Every file here is a `fn main() -> int` program; the process exit code
is the assertion (same convention as `tests/suite/`, optional first
line `// expect-exit <N>`, default 0). Run it with:

```sh
python scripts/test_suite.py --cc <gcc-or-clang> --compiler <orbit> --dir tests/std
```

Each std module earns its place with an example, tests here, and a
docs section. Helpers over builtins only: never redeclare `result`,
`list`, `map`, `string`, or `print`.
