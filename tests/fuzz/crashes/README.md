# Fuzzer crashes not yet fixed

`scripts/fuzz_frontend.py` found these three inputs. Each one makes
`orbit check` exit with 0xC00000FD (3221225725): a stack overflow in the
front end. No gate runs them yet. A fix turns each into a test under
`tests/negative` or `tests/suite` and deletes it from here.

The fuzzer writes new crashes to `.orbit/fuzz_crashes/`, which git ignores.
