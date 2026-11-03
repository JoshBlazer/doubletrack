# Planted fixture (Doubletrack eval)

Doubletrack's evaluation corpus (ADR 0020, `docs/design/diff.md`). A copy of
`fixtures/apps/shop`, dual-booted on Rails 8.0 / 8.1, with planted behavior changes that
switch on only under Rails >= 8.1 when `Planted::ENABLED` is true
(`config/initializers/planted.rb`).

* `planted/changes`: `ENABLED = true`. Expected findings: `doubletrack/expected.yml`.
* `planted/clean`: identical code with `ENABLED = false`. It must yield zero findings.

Both apps also contain planted noise (`request_token`, a `SecureRandom` value in
`GET /orders/:id.json`) that the A/A' noise mask must absorb. `changes` also has an
irrelevant HTML change (attribute order and whitespace in the index) that normalization
must ignore.

Run the eval from the repository root with `make eval`.
