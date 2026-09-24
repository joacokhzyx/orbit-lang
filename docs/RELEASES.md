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

The exact compiler is `clang` on Windows and `gcc` on Ubuntu. The verification refreshes the release contract before emitting the platform compiler.

## Consumer Verification

After downloading a release:

1. Confirm that the filename matches the target platform.
2. Run `orbit --help` to verify that the executable starts.
3. Build a small Orbit program from [Getting Started](GETTING_STARTED.md).
4. Keep `orbit_bootstrap.c` with the release records when independent verification is required.

For source-level verification, compare the published canonical C hash with the `PUBLISHED_C` contract in `scripts/verify_seed.py`, then run the seed verification command with a locally available C compiler.

## Release Types

- A normal `vMAJOR.MINOR.PATCH` tag publishes a regular release.
- A tag containing `-rc` publishes a release candidate.
- Manual workflow dispatch builds artifacts but does not publish a GitHub release unless it is invoked through a tagged release flow.

Versioning and compatibility rules are defined in [Versioning and Compatibility](VERSIONING.md). Platform support is defined in [Platform Support](SUPPORT.md).
