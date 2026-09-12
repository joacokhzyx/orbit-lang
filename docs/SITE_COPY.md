# Site Copy Pack (for the site track)

Final copy blocks for site pages, in brand voice: calm, plain
English, contractions, facts over adjectives. I-voice for
intention and doubt; Orbit for technical fact; no "we". No
Tier-1 words anywhere (brand system section 13 holds the list).
Every number placeholder needs machine + method before publishing.

Paste-ready. The site track owns layout, tokens, and markup.

---

## Learn page

**Headline:** Do more with less.

**Subhead:** Orbit is a statically typed language for APIs and
microservices. It compiles fast and needs little to run, so it
stays fast even under load.

**30-minute tour blurb:**
You'll write, build, and run real code — functions, models,
routes, and a live service with measured telemetry. Every
snippet shows its expected output, and anything unverified is
marked instead of asserted. [Start the tour →]

**Tutorials (cards):**

- Blog API with auth — List posts, search by author, publish
  through a key-checked route. Runnable example with expected
  outputs included.
- File server and uploads — List files, serve content, accept
  uploads with measured receipts. Honest scope: raw bodies,
  not multipart yet.
- Deploy a single binary — From build to a running service on
  Windows and Linux, plus two instances on one box.
- Troubleshooting — Ports, silent exits, slow first boots, and
  the failure branches your handlers should keep.

**Limits strip (link to docs):**
Orbit 0.1.0 reads well and writes poorly — persistent writes,
bearer auth, and path parameters aren't there yet. The full
list, with workarounds, is public. [Read the limits →]

---

## Foundation page (philosophy)

**Headline:** Software is physical.

**Body:**
Every request costs energy, usually from non-renewable sources.
Scaling by adding compute because we can is clumsy. I'm building
Orbit to test a simple idea: servers and APIs shouldn't need so
much energy to be fast. We're still measuring how far it can go.

Orbit tries to need less: less to install (a C compiler and
Python), less to run (one binary, memory reclaimed per
request), and less to believe (every claim ships with method,
and limits ship next to features).

Ecological is the result aimed for, never the slogan. I don't
claim an improvement until it's measured — and I publish the
bad numbers too.

**Proof strip (placeholders — fill with method links):**
`orbit run` with no giant dependencies / compiles in X on a
modest laptop / N req/s with M memory + methodology link.

**Founder note:**
I created Orbit because I didn't have an exceptional machine. I
needed a language that needs little. Built by Joaquín —
Argentina. Early research.

---

## Changelog page

**Headline:** What changed, plainly.

**Intro:** Every entry comes from the git history. No
reconstructed memory, no marketing. Versions follow the
compatibility policy; 0.x may still break things with notice.

**0.1.0 (draft) — first versioned development release.**
Does: self-hosted compiler, HTTP runtime with SQLite reads,
run/check/fmt/doctor/cluster commands, live telemetry and
cost ledger, runnable docs. Fixes: honest startup errors, live
logs, result try/catch. Still can't: persistent writes,
bearer auth, path parameters, multipart uploads, migrations.
[Release notes →] [Known limitations →]

**0.1.0-rc.2 cycle — commands and hardening.**
run/check/help, token-based fmt, doctor checks, single-host
cluster v1, real system telemetry, cost ledger, graceful
shutdown, Result handlers.

**August — stabilization.**
Behavior suite blocking in CI, Kynx 2.0 admission control,
runtime security fixes, Zig-free bootstrap, parity battery,
release workflow.

**July and earlier — bootstrap.**
Self-hosting fixed point, HTTP runtime and arenas, SQLite
integration, editors, benchmark scaffolding.

---

## Docs page

**Headline:** Read the docs.

**Intro:** Start with the question you're trying to answer. If
you're new, the tour runs your first program in 30 minutes.

**Links (one line each):**

- Tour — 30 minutes, runnable snippets, expected outputs.
- Getting started — build the compiler, run a service.
- Tutorials — blog API, file server, deploy, troubleshooting.
- Guides — migrations (honest story), benchmark methodology.
- FAQ — twenty questions, hard ones included.
- Known limitations — what 0.1.0 can't do, with workarounds.
- Language reference — the full contract.
- Commands — every command with its contract.
- Changelog / Release notes — what changed, plainly.

**Footer (all pages):** Built by Joaquín — Argentina. Early research.
