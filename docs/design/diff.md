# Design note: diff, denoise, cluster, report (M3)

Status: **accepted for M3**. Related: ADR 0005 (three-way noise), ADR 0006 (static
report), ADR 0017 (Nokogiri), ADR 0018 (severity rules), ADR 0019 (mask and fingerprint),
ADR 0020 (planted fixtures), `docs/formats/findings.md`, `docs/formats/run.md`.

## Goal

`doubletrack run APP` replays every session on control A, control A′ (both on the
current Rails) and candidate B (the next Rails). It writes the raw traces, then
normalizes them and diffs A against A′ (which gives noise) and A against B (which gives
candidate findings). A-vs-B differences that fall under the noise mask are dropped. The
rest are fingerprinted and clustered into findings, and each finding gets a severity.
The result is written as `findings.json` and `run.json`, plus a static HTML report.
Exit code: 0 for no findings, 1 for findings, 2 for a Doubletrack error.

**Exit check:**
* `doubletrack run fixtures/apps/shop` produces a report;
* `make eval` matches every planted finding in `fixtures/apps/planted/changes` and finds
  nothing in `fixtures/apps/planted/clean`.

Both run in CI.

## Pipeline

```
sessions/*.jsonl ─▶ Session.load_dir
                    │
spawn A, A′, B ─────┤ (parallel boot; A and A′ must report the same Rails, B a different one)
A: prepare_snapshot ┤ (one template for everyone)
for each session:   │ run on A, A′, B concurrently (one thread per twin; twins are processes)
                    ▼
results/<run_id>/traces/<session>/{control_a,control_a_prime,candidate_b}.json   (raw)
                    ▼
Normalize::Trace (per trace) ─▶ Diff::Structural(A, A′) ─▶ NoiseMask
                              └▶ Diff::Structural(A, B)  ─▶ minus mask ─▶ Fingerprint ─▶ Cluster ─▶ Severity
                    ▼
results/<run_id>/{run.json, findings.json}  ─▶  Report::Site ─▶ results/<run_id>/report/*.html
```

`doubletrack report RESULTS_DIR` re-runs the analysis and the report from the stored
raw traces, without any twins.

## Normalization (extends M2's `Normalize::Trace`)

All rules are pure, idempotent and property-tested.

| Channel | Rule |
|---|---|
| Response body | By `content-type`. **JSON**: parsed, keys sorted recursively, numbers kept as parsed (`1.50` and `1.5` compare equal; `1` and `1.0` don't, because clients see the type). Result: `{"json": tree}`. **HTML**: parsed with Nokogiri (ADR 0017) into a tree of `{"tag", "attrs" (sorted), "children"}`. Text is whitespace-collapsed, whitespace-only text nodes and comments are dropped, and volatile tokens are stripped (`meta[name=csrf-token]` content, `input[name=authenticity_token]` value, `nonce` attributes). Result: `{"html": tree}`. **Other text**: `{"text": s}`. **Binary**: `{"sha256": hex}`. **`Content-Encoding: gzip`** (M6): the decoded content, by the rules above, since a gzip header holds a C-level timestamp the frozen clock doesn't reach; falls back to the sha256 of the bytes if it doesn't decode to UTF-8 text. The header itself is still compared. |
| SQL writes | `sql` canonicalized: whitespace collapsed, identifier quotes (`"x"`, `` `x` ``) removed, placeholders (`?`, `$1`) unified to `?`, and inline literals replaced by `?`. The literals move to `sql_literals` (in order). `binds` are compared by column, with configured `ignored_columns` removed. `name` (e.g. `"Order Create"`) is dropped, since it describes how the write was issued, not what was written. |
| Mail | `html_body` is normalized like HTML and serialized back to canonical HTML text. `text_body` has trailing whitespace trimmed per line. |
| Headers | M2 rules, plus `ignored_headers` from config. `etag` and `content-length` are dropped: both are derived from the body, which is compared directly. |
| Not compared | `route`, `time`, `duration_ms`, `deprecations`, `request`. `route` and `time` are kept as evidence in the raw trace. |

## Structural diff

```ruby
Diff::Structural.call(a, b) # => [Difference]
Difference = Data.define(:path, :op, :a, :b) # path: Array<String|Integer>; op: "changed"|"added"|"removed"
```

* Hashes are compared key by key: a key only in B is `added`, a key only in A is
  `removed`.
* Arrays are compared index by index; extra trailing elements are `added`/`removed`.
  There's no sequence alignment in M3: one inserted SQL write early in a request shifts
  everything after it, and the report shows those shifted diffs. Alignment is future work.
* A type change at a node (e.g. a body that was JSON and is now HTML) is a single
  `changed` at that node. The diff doesn't descend into it.
* Path strings: `sql_writes[0].binds.total_cents`. The generalized form replaces indices
  with `[*]`: `sql_writes[*].binds.total_cents`.

## Noise mask (ADR 0005, ADR 0019)

```ruby
mask = Diff::NoiseMask.new
mask.add(route_key, differences_a_vs_a_prime)
mask.masked?(route_key, path)  # true if a recorded noise path equals `path` or is a prefix of it
mask.paths(route_key)          # for the report (RISKS R11: masked paths are always shown)
```

* The key is `(route_key, concrete path)`, unioned over every session. `route_key` is
  `"VERB pattern"` from A's trace route, e.g. `"POST /orders(.:format)"`, or
  `"UNROUTED GET /path"`.
* Concrete paths keep array indices. Noise at `performed_jobs[0].mail[0].html_body` must
  not hide a change at `performed_jobs[0].mail[1].subject`.
* Prefix semantics run in one direction only. Noise at `x.y` masks `x.y.z`, but not `x`
  (a change at the parent replaces the whole subtree, which is not noise).
* Stats: A/A′ differences seen (noise observed), A/B differences suppressed (noise
  filtered), and masked paths per route.

## Fingerprint and clustering (ADR 0019)

```ruby
Diff::Fingerprint.call(route_key:, difference:)  # => "f-" + 12 hex chars
```

Fingerprint = SHA-256 over `[kind, route_key, generalized_path, op, shape]`, where:
* `kind` is the channel: `response`, `exception`, `session`, `sql_writes`, `jobs`,
  `mail`, `cache`, `http`, or `performed_jobs.<channel>`;
* `shape` is `[type(a), type(b)]`. For **enumerated leaves**, the actual values are
  included instead, because there a different value usually means a different cause.
  The enumerated leaves are `response.status`, `exception.class`, `*.statement`,
  `*.table`, `*.job_class`, `*.queue_name`, `*.mailer`, `*.method`, `*.op`, and the
  `content-type` header.

**HTML bodies are one location.** Every difference inside `response.body.html` is filed
under `response.body.html changed` for its route. The concrete tree paths are kept as
occurrences. Index paths in a document tree mean nothing to a reader, and one inserted
element shifts every later index. The first shop run turned one changed page into 23
findings before this rule existed (ADR 0021).

Identical fingerprints form one finding. Its count is the number of distinct sessions it
appears in, and it keeps up to 20 occurrences (`session_id`, `request_index`, concrete
`path`, `a`, `b`) as evidence. The finding id is the fingerprint, so `doubletrack accept
f-…` (M4, ADR 0024) is stable across runs.

## Severity (ADR 0018)

`Diff::Severity.classify(path)` implements the brief's rules in one module, with one
documented deviation: **cache writes count as data-changing**, because a cached value
outlives the request.

| Path (first segments) | Severity |
|---|---|
| `sql_writes…` (except `sql_writes[*].sql`), `jobs…`, `mail…`, `http…`, `cache…`, `performed_jobs…` (except `performed_jobs[*].sql_writes[*].sql`) | `data-changing` |
| `sql_writes[*].sql`: SQL text changed, but the binds and literals didn't | `cosmetic` |
| `response` (the response appeared or disappeared), `response.status`, `response.headers.location`, `response.headers.content-type`, `response.body…`, `response.set_cookies…`, `exception…`, `session…` | `user-visible` |
| everything else (other headers, ...) | `cosmetic` |

Order: `data-changing` > `user-visible` > `cosmetic`. The verdict is "Not ready to ship"
if there's any data-changing or user-visible finding. Otherwise it's "Ready to ship",
with any cosmetic differences listed.

## Coverage

Routes come from B's `hello.routes`, falling back to A's. A route counts as hit if any
request in A or B recorded it in `trace.route`. Coverage is hits over app routes. The
report shows it on the overview, next to the finding counts, and lists unhit routes on
the coverage page.

## Results layout (`docs/formats/run.md`, `docs/formats/findings.md`)

```
<out>/<run_id>/run.json              # seed, versions, timings, coverage, noise stats, snapshot sha256
<out>/<run_id>/findings.json         # clustered findings with evidence pointers
<out>/<run_id>/traces/<session>/<role>.json
<out>/<run_id>/report/index.html     # overview
                     /findings.html  # all findings, grouped by severity
                     /findings/<id>.html
                     /coverage.html
                     /noise.html
                     /style.css /enhance.js
```

`<out>` defaults to `<app>/tmp/doubletrack`. `run_id` is
`<UTC yyyymmddThhmmssZ>-<seed>`, and `--seed` reproduces a run.

## Report (ADR 0006)

Static HTML and CSS, plus one small vanilla-JS file. Everything is local: no CDN, no
fonts, no network. Every page works with JS disabled; JS only adds severity filters and
copy buttons. Semantic HTML: `lang`, one `h1`, landmarks, `th scope`, a skip link. A
print stylesheet hides navigation, and `forced-colors` keeps the marks visible. axe runs
in CI on a generated report (light theme).

**Visual design (post-M5).** Cards on a neutral plane, a dark app bar, light and dark
themes from `prefers-color-scheme` (each selected separately, not inverted). Color
encodes only two things, and never alone:

| Role | Light | Dark | Paired with |
|---|---|---|---|
| Data-changing | `#d03b3b` | `#bd3138` | dot + "Data-changing" label |
| User-visible | `#ec835a` | `#d9782e` | dot + "User-visible" label |
| Cosmetic | `#2a78d6` | `#3987e5` | dot + "Cosmetic" label |
| Old / new line in a diff | red / green wash | darker washes | − / + marker in `<del>` / `<ins>` |

The severity triple was checked with the data-viz palette validator (lightness band,
chroma, color-vision-deficiency and normal-vision separation, contrast), all pairs, in
both modes: light passes with one contrast warning (orange on white, 2.57:1), relieved
by the visible labels and the count tiles; dark passes every check. Text never takes a
severity color; badges are neutral pills with a colored dot. The overview's severity
bar is a thin segmented bar (8 px, 2 px gaps, zero parts not drawn) with an accessible
name listing every count and share; the tiles under it are its legend and its table.
Coverage is a meter (blue fill on a lighter blue track).

What each page puts first (post-M5 UX pass):
* **Overview:** the verdict with the counts of new findings by severity and a link to
  them; then the counts, coverage, sessions and noise; then the top findings.
* **Findings:** each finding as a plain-language description ("Email: subject, in a job
  performed after the request changed"), its technical path underneath, and whether its
  reproduction was verified.
* **Finding page:** the technical title, then the plain sentence; the values that
  changed (with a note when they differ only in whitespace); then the side-by-side
  sections with a line-level diff (`Report::LineDiff`: LCS after trimming the common
  prefix and suffix; unchanged stretches folded, keeping 3 lines of context). The
  accept command names `--results`/`--baseline` when the run didn't use the defaults.

Finding detail sections:
1. Summary.
2. What changed (path, A value, B value) for each occurrence.
3. Old vs new side by side for the first occurrence's request: status, headers, body,
   and each side-effect channel.
4. The session timeline: every request with its A/B status, the affected request marked.
5. Noise evidence: A and A′ agreed at this path, and the route's masked paths.
6. Deprecations A emitted during that request.
7. Bisect: "not available until layer L1".
8. The reproduction spec (built in M4; `docs/design/specgen.md`).
9. A copyable `doubletrack accept <id> --reason "…"` command. The command itself arrives
   in M4.

## Planted fixtures and eval (ADR 0020)

`fixtures/apps/planted/changes` and `fixtures/apps/planted/clean` are the same Rails app,
dual-booted on 8.0/8.1. The only difference is `config/initializers/planted.rb`:
`Planted::ENABLED = true` in `changes`, `false` in `clean`. When enabled, a planted
behavior switches on only under Rails ≥ 8.1. That's how an upgrade that changes
behavior is simulated, without depending on what Rails itself happens to change.
`changes/doubletrack/expected.yml` lists each plant with its expected findings (route,
generalized path prefix, severity). Both apps also plant **noise** (`SecureRandom` in a
response) and **irrelevant changes** (HTML attribute order and whitespace) that must
*not* become findings.

`make eval` (`eval/run.rb`) runs both apps.
* Recall: the share of plants with at least one matching finding.
* Precision: the share of findings matched to some plant.
* The clean app must have zero findings.

Results are written to `eval/results/<date>.json`. The exit code is non-zero if
recall < 1, precision < 1, or the clean app has any finding. CI runs it.

## Tests written before the implementation

1. `spec/doubletrack/normalize/{json,html,sql}_spec.rb`, each with properties:
   * idempotence;
   * invariance (JSON key order and whitespace; HTML attribute order, inter-tag
     whitespace, comments and CSRF tokens; SQL whitespace and identifier quoting);
   * sensitivity: a real value change is still visible.
2. `spec/doubletrack/diff/structural_spec.rb`: ops and paths, with these properties:
   `diff(x, x) == []`, and applying the diff to A reproduces B.
3. `spec/doubletrack/diff/noise_mask_spec.rb`: prefix semantics in one direction, the
   route scoping, and the property that a mask built from A/A′ never hides a difference
   at an unrelated path.
4. `spec/doubletrack/diff/severity_spec.rb`: exhaustive over every channel and the
   documented exceptions.
5. `spec/doubletrack/diff/fingerprint_spec.rb` and `cluster_spec.rb`: values at
   non-enumerated leaves don't affect the fingerprint (so 300 sessions give one finding);
   enumerated values do; indices are generalized.
6. `spec/doubletrack/diff/analyzer_spec.rb`: hand-built A/A′/B traces give the expected
   findings, masked counts and coverage.
7. `spec/doubletrack/report/site_spec.rb`: pages exist, links resolve, there are no
   external URLs, and nothing needs JS.
8. Integration: `spec/integration/run_spec.rb` (`doubletrack run` on shop writes the
   results and report, with exit 0 or 1) and `spec/integration/eval_spec.rb` (the
   planted expectations).
