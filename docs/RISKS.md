# Risks

Each risk has a likelihood/impact estimate (L/M/H), a mitigation, and the status of that
mitigation. Review at every milestone.

| # | Risk | L / I | Mitigation | Status |
|---|---|---|---|---|
| R1 | Bundler environment leaking between coordinator and twins (`BUNDLE_*`, `RUBYOPT=-rbundler/setup`, `GEM_HOME`) | H / H | Spawn inside `Bundler.with_unbundled_env`; set `BUNDLE_GEMFILE` explicitly; strip `RUBYOPT`/`RUBYLIB`; `hello` reports the Rails version actually loaded so a leak is visible, not silent | M0: mitigated + checked by the spike (versions must differ). **Materialized once** in CI run 41552751273: a coordinator without Bundler loaded passed `bundle exec`'s `GEM_HOME` to twins. Fixed by always using `Bundler.with_unbundled_env`; regression spec in `twin_process_spec.rb` |
| R2 | Apps writing to stdout and corrupting the protocol | H / H | Dedicated fds 3/4 (ADR 0003); twin redirects fds 1/2 to a log before boot | M0: mitigated; covered by the fake-twin "noisy stdout" spec |
| R3 | Nondeterminism beyond time and randomness (unordered queries, thread timing, cache state, `SecureRandom`) | H / M | Three-way noise mask (ADR 0005); per-session snapshot restore; cache cleared per session | M2–M3 |
| R4 | `after_commit` semantics differ if isolation ever uses transactions | M / H | Never use rollback isolation (ADR 0004) | Decided |
| R5 | Snapshot cost on large databases; boot time of large apps | M / M | Twins boot once; `VACUUM INTO` template; measure and report; later reflink/copy-on-write copies | M2 |
| R6 | Outbound HTTP libraries bypassing `Net::HTTP` interception (`httpx`, `curb`, `typhoeus`/libcurl, raw sockets) | M / H | Intercept `Net::HTTP`; detect other libraries in the bundle and warn in `doctor`; later, socket-level guard that fails closed | M2 |
| R7 | Multiple databases, non-SQLite adapters, custom job backends | H / M | MVP is SQLite-only and says so; `doctor` detects and refuses clearly | M2 / docs |
| R8 | Secrets in captured sessions | M / H | Mandatory, tested scrubbing; never log request bodies by default | M5 |
| R9 | Licensing and etiquette when publishing findings about open-source apps | M / M | Contact maintainers before publishing; publish only reproducible findings; respect licenses | M6 |
| R10 | Scope creep | H / H | M0–M4 must be done before any later layer starts; PROGRESS.md reviewed each session | Ongoing |
| R11 | Noise mask hides a real B-only difference at a path that was also noisy between A and A′ | L / M | Report masked paths and counts per finding detail; optional repeated controls | M3 |
| R12 | `doubletrack` env overlay (ADR 0009) behaves differently from the app's `test` env (code branching on `Rails.env.test?`, gems with env-specific config) | M / M | Document; `doctor` lists `Rails.env.test?` branches; fallback option to run under `test` | M0: observed; revisit M2 |
| R13 | No native Windows support (fd mapping) | – / L | WSL documented (ADR 0003) | Accepted |
