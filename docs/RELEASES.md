# Release Artifacts

Releases publish a fixed-point compiler and the source you need to verify its trust root. The workflow lives in `.github/workflows/release.yml`. If verification fails, the release fails - I don't publish what I can't reproduce.

## Published Platforms

| Artifact | Platform | Built with |
|---|---|---|
| `orbit-windows-x86_64.exe` | Windows x86-64 | Clang on `windows-latest` |
| `orbit-linux-x86_64` | Linux x86-64 | GCC on `ubuntu-latest` |

The current release workflow does not publish a macOS compiler artifact. macOS users can build the compiler locally with the POSIX bootstrap scripts described in [Platform Support](SUPPORT.md).

## Release Files

A release contains:

- a platform-specific fixed-point compiler;
- `orbit_bootstrap.c`, the amalgamated C bootstrap source;
- `orbit_seed*`, the seed compiler artifacts produced by verification when available;
- generated release notes from the tagged revision.

The fixed-point compiler is built only after the self-host chain and canonical C source pass their verification steps. The release job fails if the expected compiler artifact is missing.
## Verification Before Publication

The release workflow performs these operations for each published platform:

```sh
python scripts/build_selfhost.py --cc <compiler> --check-stale
python scripts/verify_seed.py --release --refresh \
  --emit-fixed-point dist/<platform-asset>
```

The exact compiler is `clang` on Windows and `gcc` on Ubuntu. The verification
refreshes the release contract before emitting the platform compiler.

## The release does not ship `std/`, so the verification has to prove it knows that

A `std/...` import resolves against three roots, in order: the compiler
binary's directory, that directory's parent, then the **current working
directory** (`compiler/resolver.orb:69-90`). The release contains the platform
binary, `orbit_bootstrap.c` and the seed artifacts. There is no `std/` in it
and no install step that puts one next to the binary.

So a verification that only builds a program which imports nothing from `std/`
proves nothing about what a user can do with the artifact they just downloaded.
The step that matters is this one, and it belongs in the release check:

```sh
# from a directory with no std/ and no runtime/ anywhere above it
FP=dist/orbit-linux-x86_64
printf 'import "std/string/string.orb"\nfn main() -> int { return 0 }\n' > /tmp/std_probe.orb
"$FP" check /tmp/std_probe.orb          # must FAIL: Import error
"$FP" lsp 2>/dev/null                    # must FAIL: Unknown command
"$FP" --version                          # must succeed
```

`check` needs no C compiler; `build` does, and `build` additionally requires a
`runtime/` directory in the working directory, because the generated C is
compiled with the relative include path `-I"runtime"`. Both facts are
assumptions about the filesystem that only a user outside the repository hits,
which is why running from the repository root - as every CI gate does - cannot
find them.

Until the release ships `std/` (or the resolver grows a search-path
environment variable), a release check that does not exercise a `std/` import
from outside the source tree is not verifying the artifact. The rule and the
workaround are written up in [Writing a library others can
import](LIBRARIES.md#4-std-resolves-against-three-roots-and-that-is-the-install-trap).

## Consumer Verification

After downloading a release:

1. Confirm that the filename matches the target platform.
2. Run `orbit --help` to verify that the executable starts.
3. Build a small Orbit program from [Getting Started](GETTING_STARTED.md).
4. If you want to use `std/`, put a copy of `std/` beside the binary or beside
   its parent directory first. A downloaded compiler cannot resolve a `std/`
   import on its own, and `orbit check` will tell you so with
   `Import error: Could not read imported module: ...` rather than crashing.
5. Run `orbit build` from a directory that contains `runtime/`, or copy the
   runtime headers next to your project. The generated C is compiled with a
   relative `-I"runtime"`.
6. Keep `orbit_bootstrap.c` with the release records when independent
   verification is required.

For source-level verification, compare the published canonical C hash with the `PUBLISHED_C` contract in `scripts/verify_seed.py`, then run the seed verification command with a locally available C compiler.

## Release Types

- A normal `vMAJOR.MINOR.PATCH` tag publishes a regular release.
- A tag containing `-rc` publishes a release candidate.
- Manual workflow dispatch builds artifacts but does not publish a GitHub release unless it is invoked through a tagged release flow.

Versioning and compatibility rules are defined in [Versioning and Compatibility](VERSIONING.md). Platform support is defined in [Platform Support](SUPPORT.md).
