# Planted-behavior evaluation corpus

Ground truth for Doubletrack's precision and recall (ADR 0020, `docs/design/diff.md`).

| App | `Planted::ENABLED` | Expected |
|---|---|---|
| [`changes/`](changes/) | `true` | the findings in [`changes/doubletrack/expected.yml`](changes/doubletrack/expected.yml). Its 9 plants cover SQL, jobs, job mail, outbound HTTP, cache, status, JSON body, redirect, and a cosmetic header |
| [`clean/`](clean/) | `false` | zero findings |

Both apps are the same code, a copy of `fixtures/apps/shop` dual-booted on Rails 8.0/8.1.
The only file that differs between them is `config/initializers/planted.rb`. Each plant
switches on only under Rails ≥ 8.1, so it simulates an upgrade that changes behavior.
Both apps also contain noise that must **not** be reported (a `SecureRandom` token in a
JSON response). `changes` also contains an irrelevant HTML change (attribute order and
whitespace).

```sh
make eval          # replays both apps and writes eval/results/<date>.json; non-zero exit on regression
```
