# Branches

Orbit uses a light Git Flow: `main`, `develop` and short-lived `feature/*`
branches. The same rules hold in `orbit-lang` and in `orbit-r6`.

## The branches

| Branch | Holds | Receives | Gate before the merge |
|---|---|---|---|
| `main` | Released states only. Every commit on it is tagged `vMAJOR.MINOR.PATCH`. | A `--no-ff` merge of `develop` | The release gate, from a clean clone |
| `develop` | The integration line. Every commit on it passed its gates. | `--no-ff` merges of `feature/*` | The full gate of the repo |
| `feature/<topic>` | One piece of work: a feature, a fix, a cleanup or a document. | Commits, one decision each (AGENTS.md) | Cheap checks while writing; the full gate before it merges |

A topic name is lowercase words joined by hyphens: `feature/runtime-strings`,
`feature/cli-orbital`, `feature/remove-lib-dir`.

## Gates

| Repo | Full gate (merge into `develop`) | Release gate (merge into `main`) |
|---|---|---|
| `orbit-lang` | `python scripts/dev.py all` and `python scripts/verify_seed.py --cc <gcc>`, with `ORBIT_R6` set so `suite_native` runs | The full gate from a clean clone of `develop` |
| `orbit-r6` | `scripts\ci.ps1 -Diff -Corpus -Selfhost` | The same, from a clean clone of `develop` |

A merge commit is gated as well: the tree after the merge is what the gate
runs on. When `develop` moved while a feature branch was open, merge `develop`
into the feature branch first and re-run the full gate there.

## A feature, start to end

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

## A release

1. Check that `develop` is green from a clean clone (the release gate).
2. Merge it into `main` with `--no-ff`.
3. Tag the merge commit with an annotated tag, `git tag -a v0.2.0 -m "..."`.
   The message lists what changed since the previous tag.
4. Push `main`, then the tag.

There are no `release/*` branches: a release is a merge of a green `develop`.
A fix for a released version goes through `develop` and ships in the next
patch release.

## The pin between the two repos

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

## Settings outside the repository

GitHub branch protection is a repository setting, not a file. For both repos
it is: `main` and `develop` accept no force push and no deletion, and the
default branch is `develop`.
