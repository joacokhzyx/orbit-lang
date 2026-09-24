#!/usr/bin/env python3
"""Visual specimen of the repo output grammar (style 3 + variant B).

Prints static examples of what each tool sounds like, so tone can be
reviewed without running a 10-minute bootstrap. Nothing here executes
a gate; see docs/COMMANDS.md ("Script output conventions") for the
contract these examples follow.
"""

SPECIMEN = """\
--- suite -----------------------------------------------
Testing arith ... exit 0 as expected
Failed notes_write: got exit 1, want 0
Finished suite: 20/21 pass

--- parity ----------------------------------------------
Checking r1_route_only ... match (C)
Failed r12_route_err: mismatch (line 2: expected 'kind=DIAG' got 'kind=C')
Finished parity: 30/31 match goldens

--- cli-probe -------------------------------------------
Probing build-quiet ... ok
Failed check-missing: rc=0 (want 1)
Finished cli-probe: 34/35 pass

--- verify / bootstrap ----------------------------------
Running build seed from canonical C ...
Verified seed C fixed point (seed C == canonical C) ... ok
Finished bootstrap: converged (matches canonical).

--- load / gates ----------------------------------------
Loading 127.0.0.1:4102 /health x2 (source ips: 0) ...
  completed=200 ok_2xx=200 transport_errors=0 error_rate=0.000% elapsed=20.03s
Phase B passed: ok=5 denied=20 retry_after='1' elapsed=0.21s
Finished kynx gate: PASS

--- orbit build, C step fails (variant B) ---------------
orbit build: couldn't finish the C step - this one is on me, not your code.
  Your program translated cleanly; the C compiler rejected my output:
  <build>:35703:12: error: assignment to integer from pointer without a cast
  ... 34 more lines (full log: <tmp>/orbit_build.cc.log)
  Tip: run `orbit check app.orb` first - if that passes, file an issue
  with the .orb file and I'll read it.
"""


def main() -> int:
    print(SPECIMEN, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
