# Contributing to Orbit

Orbit is built to do more with less: less energy, less complexity, same speed.
This guide covers how to propose changes, open pull requests, and keep quality
high across the compiler and C runtime. The documentation map is
[docs/README.md](docs/README.md); branches and releases are in
[the branch rules](#branches); security reports follow
[SECURITY.md](SECURITY.md).

---

## The contract

What a change has to satisfy, before the sections below explain how to run
and check it.

**Names.** A component, file, document and test is named for what it does.
No codename is invented or kept: the admission layer used to be called
`Kynx`, and the optimizer experiments used to be called `Superluminal`. A
stable identifier (`D001`, `F-000N`) is kept, and is defined in
[`docs/internals/DEFECTS.md`](docs/internals/DEFECTS.md) before it appears
in code or in a message. Retired debt slugs stay retired.

**Documentation.** [`docs/README.md`](docs/README.md) is the map: ten pages
that answer a reader's question, and `docs/internals/` for the measurements
behind a claim. New material goes into an existing page first; a new page
arrives with its row in the map in the same commit. Every claim about the
tree carries the command and the number that produced it.

**Dependencies.** Python 3.10 or later, standard library only. A C compiler
(gcc, clang or MSVC) and GNU `ld` for the C backend; R6 for the native
backend. SQLite is vendored under `runtime/vendor/`. There is no package
manager, no `requirements.txt`, and no third-party Python import.

**Commits.** Subject `area: what changed`, imperative, under 60 characters,
no period. The body says why; the diff says what. No batch, phase or ticket
label, and no `D-` or `F-` code in the message: a code belongs in
`DEFECTS.md`. End with an Evidence block, one line per command and what it
printed. One defect, one commit.

## Code of Conduct

All contributors are expected to adhere to the [Orbit Code of Conduct](CODE_OF_CONDUCT.md). Please treat all members of the community with respect and professionalism.

---

## Development Environment Setup

### Prerequisites

To build and test Orbit locally, ensure you have the following installed:

1. **C Compiler**: GCC, Clang, or MSVC (set `ORBIT_CC` if autodetection fails).
2. **Python 3.10+** (required for the bootstrap/verification scripts).

No toolchain vendor is involved: a C compiler plus a stock `python3` are the
whole dependency list. The compiler bootstraps itself from the committed
canonical C (see [docs/internals/SOVEREIGNTY.md](docs/internals/SOVEREIGNTY.md)).

### Building from Source

Clone the repository and run the one entry point. It owns `TEMP`/`TMP`,
`ORBIT_CCACHE_DIR`, the fixed-point binary and each gate's flags:

```bash
git clone https://github.com/joacokhzyx/orbit-lang.git
cd orbit-lang
python3 scripts/dev.py fp     # build the fixed-point compiler and print its version
python3 scripts/dev.py dev    # gates proportionate to what the working tree touched
```

The `make` targets are one-line aliases of the same calls, for people who
type them faster. `make` is a convenience, not a requirement: Windows has it
only when it is installed, and CI calls `scripts/dev.py` directly. Do not
export the variables above by hand and do not pass `--cc`/`--compiler` by
hand.

End users who just want Orbit installed take the CI release wizard
(`Orbit-Setup-<version>.exe`, built from `installer/orbit.iss` as described
in [Releases](#releases)), not a source checkout.

---

## Running Tests & Gates

`scripts/dev.py` is the single authority for verification; the `make` targets
are aliases of it. Do not invoke the scripts in `scripts/`
by hand with `--cc`/`--compiler`:

```bash
make dev    # gates proportionate to what the working tree touched
make check  # T0..T2 unconditionally (language + static analysis)
make all    # T0..T3, including the root of trust (run before promoting)
make fp     # just the fixed-point compiler, and print its version
make list   # show what dev would run, without running it
```

A green `make dev` is not a green CI (`dev.py` prints the tiers it skipped).
A rule change or anything touching `compiler/**/*.orb` needs `make check`.
Before a commit that promotes the canonical, run `make all`.

When one thing is broken and the rest is noise, use the single-gate targets
(`make doctor`, `make suite`, `make parity`, `make werror`, `make negative`,
`make report`) instead of retyping gate commands. The runtime C tests run
inside these tiers (via `scripts/runtime_c_tests.py`).

`scripts/corpus_gates.py werror` is the strict warning gate. The bootstrap
deliberately builds without `-Wall` because it costs 5.7x on the compiler's own
multi-megabyte output unit. See [Performance notes](docs/internals/PERF.md). Set
`ORBIT_BOOTSTRAP_WARNINGS=1` to get warnings back while hacking.

Every gate runs on a C compiler plus a stock `python3`. There is nothing to
install.

Ensure all gates pass before submitting a pull request.

---

## Coding Standards & Guidelines

Orbit follows a fixed diagnostic format and a plain voice: direct, no hype, no
superiority.

### 1. Diagnostic Formatting & Error Messages

Diagnostics decide how Orbit feels at 3am, so they follow the brand rule: clear header, helpful body.

- **No borders or emojis**: clean text, no decorative boxes or emojis.
- **English suggestions**: write all hints and explanations in English with contractions where natural (`can't`, `doesn't`, `here's`).
- **Header states fact + fix**: `Port 3000 is already in use. Change it in X.orb and try again.` Never hide the action behind metaphor. Orbital language stays out of headers.
- **Body helps first, warms second**: add a tip with the exact next command. Example: `Tip: change the port declaration in the entry file and retry. Small fix - you'll be running in seconds.` One warm line max, never cheesy, never blaming you.
- **When Orbit broke it, own it**: no humor to deflect. Say what failed, give a workaround, and note the fix in progress.
- **Verbose enough to act**: explain what happened and how to continue, rather than a cryptic code alone.
- **Consistent color styling**: red for errors, yellow for warnings, cyan for line numbers.

### 2. Code Formatting

- **Orbit Compiler Sources**: Keep `compiler/**/*.orb` consistent with the existing style. Any change must converge to a new fixed point (`make promote`, reviewed with `make promote-diff`).
- **C Runtime Engine**: Keep C code in `runtime/` idiomatic, const-correct, and free of compiler warnings (`-Wall -Wextra`).
- **Documentation Comments**: Use triple-slash doc comments (`///`) for public functions, structs, and module APIs.

---

## Pull Request Process

1. **Create a Feature Branch**:
   ```bash
   git checkout -b feature/your-feature-name
   ```
2. **Commit Changes**: Write clear, descriptive commit messages.
3. **Run Verification Suite**:
   ```bash
   make check   # T0..T2; use make all before a commit that promotes the canonical
   ```
4. **Submit PR**: Open a pull request against the `develop` branch with a clear description of the problem solved or feature added.

---

## Branches

Orbit uses a light Git Flow: `main`, `develop` and short-lived `feature/*`
branches. The same rules hold in `orbit-lang` and in `orbit-r6`.

### The branches

| Branch | Holds | Receives | Gate before the merge |
|---|---|---|---|
| `main` | Released states only. Every commit on it is tagged `vMAJOR.MINOR.PATCH`. | A `--no-ff` merge of `develop` | The release gate, from a clean clone |
| `develop` | The integration line. Every commit on it passed its gates. | `--no-ff` merges of `feature/*` | The full gate of the repo |
| `feature/<topic>` | One piece of work: a feature, a fix, a cleanup or a document. | Commits, one decision each (AGENTS.md) | Cheap checks while writing; the full gate before it merges |

A topic name is lowercase words joined by hyphens: `feature/runtime-strings`,
`feature/cli-orbital`, `feature/remove-lib-dir`.

### Gates

| Repo | Full gate (merge into `develop`) | Release gate (merge into `main`) |
|---|---|---|
| `orbit-lang` | `python scripts/dev.py all` and `python scripts/trust.py verify --cc <gcc>`, with `ORBIT_R6` set so `suite_native` runs | The full gate from a clean clone of `develop` |
| `orbit-r6` | `scripts\ci.ps1 -Diff -Corpus -Selfhost` | The same, from a clean clone of `develop` |

A merge commit is gated as well: the tree after the merge is what the gate
runs on. When `develop` moved while a feature branch was open, merge `develop`
into the feature branch first and re-run the full gate there.

CI does not set `ORBIT_R6`, so `.github/workflows/ci-gate.yml` skips
`suite_native`, `suite_std_native` and `runtime_module_native` on every run.
A green CI covers the gates it ran and does not include the native path. That
half is the local full gate in the row above.

### A feature, start to end

```bash
git switch develop
git pull --ff-only
git switch -c feature/<topic>
# commits, one decision each
git switch develop
git merge --no-ff feature/<topic> -m "Merge branch 'feature/<topic>': <what it adds>"
git push origin develop
git branch -d feature/<topic>
```

The merge subject says what the branch adds, in the same imperative style as a
commit subject. A pushed commit is a record: fix forward, never rewrite
`develop` or `main`.

### A release

1. Check that `develop` is green from a clean clone (the release gate).
2. Merge it into `main` with `--no-ff`.
3. Tag the merge commit with an annotated tag, `git tag -a v0.2.0 -m "..."`.
   The message lists what changed since the previous tag.
4. Push `main`, then the tag.

There are no `release/*` branches: a release is a merge of a green `develop`.
A fix for a released version goes through `develop` and ships in the next
patch release.

### The pin between the two repos

R6 pins an `orbit-lang` commit (`orbit-r6/docs/PIN.md`).

- The pin is a commit on `orbit-lang` `develop` that is pushed. A pin to a
  commit no remote has cannot be reproduced.
- A pin move pushes the language commit first, then the R6 commit that moves
  the pin.
- Before an R6 release, the pin moves to the commit of the latest `orbit-lang`
  release tag, so a released R6 names a released language.
- `orbit-lang` releases name the R6 commit they ship in
  `.github/workflows/release.yml` (`R6_COMMIT`), which is a commit on R6
  `main`.

### Settings outside the repository

GitHub branch protection is a repository setting, not a file. For both repos
it is: `main` and `develop` accept no force push and no deletion, and the
default branch is `develop`.

## Releases

Releases publish a fixed-point compiler and the source you need to verify its trust root. The workflow lives in `.github/workflows/release.yml`. If verification fails, the release fails: nothing is published that cannot be reproduced.

### Published Platforms

| Artifact | Platform | Built with |
|---|---|---|
| `orbit-windows-x86_64.exe` | Windows x86-64 | Clang on `windows-latest` |
| `orbit-linux-x86_64` | Linux x86-64 | GCC on `ubuntu-latest` |

The current release workflow does not publish a macOS compiler artifact. macOS users can build the compiler locally with the POSIX bootstrap scripts described in [Platform Support](SUPPORT.md).

Linux additionally ships `orbit-linux-x86_64.tar.gz`: the same binary bundled
with `std/` + `runtime/` beside it (plus `LICENSE.txt`), so Linux users who
take the bundle skip the install trap entirely. Windows users get the equivalent
via the Setup Wizard below.

### Release Files

A release contains:

- a platform-specific fixed-point compiler;
- on Windows, `Orbit-Setup-<version>.exe`: the Setup Wizard (per-user, no
  admin) that installs `orbit.exe` on PATH, registers the `.orb` icon and
  `orbit check` double-click verb, and ships `std/` + `runtime/` beside the
  binary so imports and builds work outside a source checkout, plus `lib/`
  with the prebuilt runtime archives, and `bin\r6.exe`, the native backend
  (`orbit build --backend=native`, see [Commands](COMMANDS.md#backends-c-and-native));
- on Linux, `orbit-linux-x86_64.tar.gz`: the same compiler bundled with `std/`
  + `runtime/` + `lib/` beside the binary (extract and run, nothing to copy);
- `SHA256SUMS`: SHA-256 hashes of every other file in the release, generated
  in the publish job before upload - check your download against it;
- `orbit_bootstrap.c`, the amalgamated C bootstrap source;
- `orbit_seed*`, the seed compiler artifacts produced by verification when available;
- generated release notes from the tagged revision.

The fixed-point compiler is built only after the self-host chain and canonical C source pass their verification steps. The release job fails if the expected compiler artifact is missing.
### Verification Before Publication

The release workflow performs these operations for each published platform:

```sh
python scripts/trust.py build --cc <compiler> --check-stale
python scripts/trust.py verify --release --refresh \
  --emit-fixed-point dist/<platform-asset>
```

The exact compiler is `clang` on Windows and `gcc` on Ubuntu. The verification
refreshes the release contract before emitting the platform compiler.

### Windows installer

`installer/orbit.iss` is the Inno Setup source. CI compiles it on tag after
the seed chain passes (`iscc /DOrbitVersion=<tag-v-stripped>
installer\orbit.iss`). Validate locally with
`iscc /DOrbitVersion=0.0.0-dev installer\orbit.iss` against a `dist/`
holding `orbit-windows-x86_64.exe`. Verified end to end on 2026-10-12:
silent per-user install, `orbit --version` on PATH, `.orb` association +
icon in HKCU, `check`/`build`/`run` of a `std/`-importing program from
outside the repo, and uninstall removing binary, keys and PATH entry.

Layout under the install dir (mirrors the repo, which is why resolution works):

```console
orbit.exe  orbit.ico  LICENSE.txt  std\  runtime\  lib\  bin\r6.exe
```

The install trap below applies to the raw `orbit-windows-x86_64.exe`
download, not to a wizard install: the wizard is what closes it. `ovm`
(Orbit Version Manager) will own upgrades later. There is intentionally no
`orbit install` command.

### The raw binary does not ship `std/`, so the verification has to prove it knows that

A `std/...` import resolves against three roots, in order: the compiler
binary's directory, that directory's parent, then the **current working
directory** (`compiler/front/resolver.orb:69-90`). The raw platform binary ships
alone: no `std/` in it and no install step that puts one next to the binary.
(The Windows wizard install and the Linux bundle tarball both close this trap
by placing `std/` + `runtime/` beside the binary - the trap below is about the
bare-binary download only.)

So a verification that only builds a program which imports nothing from `std/`
proves nothing about what a user can do with the artifact they just downloaded.
The step that matters is this one, and it belongs in the release check:

```sh
# from a directory with no std/ and no runtime/ anywhere above it
FP=dist/orbit-linux-x86_64
printf 'import "std/string/string.orb"\nfn main() -> int { return 0 }\n' > /tmp/std_probe.orb
"$FP" check /tmp/std_probe.orb          # must FAIL: Import error
printf 'Content-Length: 58\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | "$FP" lsp | grep -q textDocumentSync     # must answer initialize with capabilities
"$FP" --version                          # must succeed
```

`check` needs no C compiler. `build` does, and `build` additionally requires a
`runtime/` directory in the working directory, because the generated C is
compiled with the relative include path `-I"runtime"`. Both facts are
assumptions about the filesystem that only a user outside the repository hits,
which is why running from the repository root - as every CI gate does - cannot
find them.

Until the release ships `std/` (or the resolver grows a search-path
environment variable), a release check that does not exercise a `std/` import
from outside the source tree is not verifying the artifact. The rule and the
workaround are written up in [Writing a library others can
import](LANGUAGE_REFERENCE.md#4-std-resolves-against-three-roots-and-that-is-the-install-trap).

### Consumer Verification

After downloading a release:

1. Check the hashes. Every release publishes a `SHA256SUMS` file alongside the
   assets - verify your download against it before running anything:
   ```sh
   sha256sum -c SHA256SUMS   # from the directory holding the downloads
   ```
   On Windows, `certutil -hashfile <file> SHA256` prints the hash to compare
   by eye against the `SHA256SUMS` entry.
2. Confirm that the filename matches the target platform.
3. Run `orbit --help` to verify that the executable starts.
4. Build a small Orbit program from [Getting Started](GETTING_STARTED.md).
5. Keep `orbit_bootstrap.c` with the release records when independent
   verification is required.

Then pick your path:

#### Wizard path (trap closed, nothing to copy)

- **Windows:** run `Orbit-Setup-<version>.exe`. It puts `std/` + `runtime/`
  beside `orbit.exe`, so `std/` imports and `orbit build` work out of the box.
- **Linux:** extract `orbit-linux-x86_64.tar.gz` and use the `orbit` inside:
  `std/` + `runtime/` sit beside it for the same reason.
- No hand-copying, no `Import error` workaround. If a `std/` import fails on
  this path, that is a bug - report it.

#### The prebuilt runtime archive

The wizard and the bundle ship `lib/libruntime_net.a` and
`lib/libruntime_net.a.stamp` beside `runtime/`. CI builds both with
`python scripts/mklib_runtime.py --cc gcc` from the tagged checkout, so the
stamp digests equal the shipped `runtime/` sources. `orbit build` links the
archive for a program without a database: `examples/hello.orb` builds in
about 1.3 s instead of 3.4 s. The archive has one member per runtime module.
A C compiler other than gcc can link it. If it fails to link with your
compiler, set `ORBIT_LINK_RUNTIME=0` for the unity build. Edit anything in
`runtime/` and the stamp no longer matches; the build then uses the unity
build, and `--verbose` says so. Deleting `lib/` has the same effect. The
Linux release job checks that the extracted bundle links the archive.

#### Raw-binary path (trap applies, hand-copy workaround)

If you downloaded the bare `orbit-windows-x86_64.exe` or
`orbit-linux-x86_64` instead of the wizard/bundle:

1. If you want to use `std/`, put a copy of `std/` beside the binary or beside
   its parent directory first. A bare downloaded compiler cannot resolve a
   `std/` import on its own, and `orbit check` will tell you so with
   `Import error: Could not read imported module: ...` rather than crashing.
2. Run `orbit build` from a directory that contains `runtime/`, or copy the
   runtime headers next to your project. The generated C is compiled with a
   relative `-I"runtime"`.

For source-level verification, compare the published canonical C hash with the `PUBLISHED_C` contract in `scripts/trust.py`, then run the seed verification command with a locally available C compiler.

### Release Types

- A normal `vMAJOR.MINOR.PATCH` tag publishes a regular release.
- A tag containing `-rc` publishes a release candidate.
- Manual workflow dispatch builds artifacts but does not publish a GitHub release unless it is invoked through a tagged release flow.

Versioning and compatibility rules are defined in [Versions and compatibility](SUPPORTED.md#versions-and-compatibility). Platform support is defined in [Platform Support](SUPPORT.md).

## Style

- Preserve existing shapes: 4-space, no `var` vs `val` concessions; comments explain why code is like this, not what the code says. No new comments unless they say something the code cannot.
- Name things by what they are. Files, doc sections, examples and tests carry descriptive names; a component is named after what it does, never after a codename. A commit message names the change or the mechanism, never the plan that produced it. Diagnostic and defect codes (`D001`, `F-000N`) are stable identifiers: keep them, and define a new identifier in docs before using it in code. Retired debt-table IDs (`STAB-N`, `PAR-N`, ...) stay retired; do not mint new ones.
  - Day-0 read: a codename is never invented and never kept in new text; a stable identifier is kept (e.g. `D001`, `F-000N`); a retired slug stays retired (e.g. `STAB-N`).
- Changes to the emitted C need the whole-prelude byte-diff check: track one program byte-for-byte; only expected fragments (one register renumber, one removed line) should differ.
- `gh` is the source of truth for CI state: `gh run list --limit 3; gh run view <id> --log` for the failing step's name. The failing step name is the finding; the step text is often as enough.
- Register-name number shifts (`r_N`) in emitted C are benign renumbering; hash goldens will still flip, which is one probe, not a proof.

## Writing

Write for the maintainer who joined yesterday. They read English; they do not read our history.

- Documentation is impersonal. The page says what was measured, not who measured it. A commit body may say "I".
- One idea per sentence. Average under 22 words, none over 40. A semicolon usually means two sentences.
- Write what the reader can act on. A row in `docs/internals/DEFECTS.md` holds a defect, its measurement and its decision. It is not a diary, and the list of everything checked is not the finding.
- A table is for more than two columns. Two facts are a sentence.
- Name the thing. "The 99 `return ""` sites", not "the surface". "What is left", not "the residual". "The line the gate checks", not "the witness".
- Every claim carries a command, a number or a line. "Faster", "cleaner" and "more robust" carry nothing.
- "Honest" describes the author, not the code. Write "measured", "unchecked" or "the reason". A measurement is enough; a confession is not a finding.
- No hedges. "Should", "likely" and "probably" become a measurement or a question.
- Do not explain the sentence you are about to write, or the one you just wrote. Delete the first sentence of a section if it only announces the section.

Banned in new text: shape, surface, lane, load-bearing, battery, premise, clause, witness, residual, honest. They are our own metaphors, and a reader cannot look them up. Generic AI vocabulary is not the problem here: counting this repository on 2026-10-19 found none of it, so do not spend lines banning it.

Defined once, used freely: **contract** (`docs/internals/DEFECTS.md` and `ENGINEERING.md` §8, which a change must not contradict), **gate** (a check that fails the build), **row** (one line of the `DEFECTS.md` table), **ceiling** (a measured upper bound on a named machine).

## Commits

Commits are how a change is found again, reviewed and undone. One defect, one commit.

- Branches, merges and releases follow `CONTRIBUTING.md#branches`: work happens on `feature/<topic>`, it merges into `develop` after the full gate, and `main` receives only tagged releases.
- Commit when the change is small, verified and complete. A correction that changes behaviour or a document's claim gets its own commit, even if it is one line.
- Do not wait for the rest of the work. A verified fix left in the working tree is a fix nobody can find in the history.
- Do not mix. A code change and a documentation change are two commits, unless the document is the reason the code changed.
- Do not commit a state you have not gated. The evidence block names the gate.
- The exception is the root of trust: a promote commits the sources, `compiler/selfhost/stage3.exe.c`, the refreshed goldens and `PUBLISHED_C` together. They are one file in four copies, and a commit that splits them describes a tree that never existed.
- A pushed commit is a record. Fix forward: the next commit carries the correction and says what it corrects. Do not rewrite history to make an old message tidy.
- A commit is not a checkpoint or a diary. If the message needs "also", it is two commits.

Message:

- Subject: `area: what changed`, imperative, under 60 characters, no period.
- The body says why. The diff says what.
- No batch, phase or ticket label (`E2`, `B3`, `WT-1`, `wave4`) in the subject or the body. The message describes the change, not the plan that produced it.
- One claim per sentence. Every number is one the reader can reproduce.
- End with an Evidence block: one line per command and what it printed.
- If something is unmeasured or left undone, one sentence says so, with the reason.
- Never: "this commit", "as requested", a list of the files, or a summary of the diff.

---

## License

By contributing to Orbit, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
