# Adobe ColdFusion 2023: CFC scope contamination under concurrent load

When many requests run at once, Adobe ColdFusion 2023 can let one request's component pick up
an object that belongs to another request. Nothing errors at that moment. In production this
made a Quick ORM query builder carry the wrong table name, so an `UPDATE` ran against the wrong
table (`UPDATE [user_type] ...` instead of `UPDATE [remote_app_remote_carrier] ...`).

This repository is a self-contained reproduction (ColdBox + Quick ORM + SQL Server, both
unmodified) and the record of every test run against Adobe's hotfixes.

## Status (September 2026)

| Engine | Contaminated requests under concurrent load | Cost |
|---|---|---|
| ColdFusion 2023 Update 23, no hotfix | about 1 in 15 | none |
| + Adobe's first hotfix | none seen in 550,000 | throughput roughly halved |
| + Adobe's second hotfix | same as no hotfix | none |
| + Adobe's third hotfix | about 1 in 180,000 (5 in 900,000) | 18% to 24% slower, and a new permanent deadlock |
| Lucee 6.2 | none in 70,000 | no construction lock needed |
| BoxLang 1.17 | none in 160,000 | no construction lock needed |

ColdFusion also has a separate startup bug: a freshly started server under immediate
concurrent load can throw a `NullPointerException` and then fail every request until restart.
None of Adobe's hotfixes change it. A one-line change, verified here, fixes it without a lock
([details](docs/root-cause/contamination-investigation-and-startup-crash-fix.md)).

## History

- **May 2026: found in production.** On ColdFusion 2023 Update 18, a few `UPDATE` statements a
  day ran against the wrong table under load. The same code ran cleanly on Lucee. This
  reproduction was built and the issue reported to Adobe.
  ([production evidence](docs/background/PRODUCTION_EVIDENCE.md),
  [how it was narrowed down](docs/background/INVESTIGATION_LOG.md))
- **July 2026: the first hotfix.** It made every component construction in the server wait for
  every other one (a single global lock), plus some per-instance changes. Contamination stopped,
  but under load the server did about half the work. The startup crash was unchanged.
  ([analysis](docs/adobe-hotfixes/1-first-hotfix-static-analysis.md),
  [performance](docs/adobe-hotfixes/1-first-hotfix-performance.md))
- **August 2026: the second hotfix.** It dropped the lock, but the class it shipped turned out
  to be identical to one already in Update 23. Contamination was back at the unpatched rate.
  ([analysis](docs/adobe-hotfixes/2-second-hotfix-static-analysis.md),
  [test results](docs/adobe-hotfixes/2-second-hotfix-correctness.md))
- **August 2026: the root cause work.** We traced the startup crash to a map ColdFusion
  shares without synchronization, and verified a one-line fix using a class ColdFusion already
  ships. We also measured how Lucee and BoxLang avoid the contamination without any lock.
  ([startup crash and contamination analysis](docs/root-cause/contamination-investigation-and-startup-crash-fix.md),
  [how Lucee and BoxLang avoid it](docs/root-cause/how-lucee-and-boxlang-avoid-it.md))
- **September 2026: the third hotfix.** One lock per component class instead of one for the
  whole server. Contamination dropped to about 1 request in 180,000, but did not stop. In an
  ORM application the busiest class, the query builder, is built on every query, so its lock
  still acts like a global one. And two components that create each other during construction
  can now wait on each other forever.
  ([analysis](docs/adobe-hotfixes/3-third-hotfix-static-analysis.md),
  [results](docs/adobe-hotfixes/3-third-hotfix-results.md),
  [contamination and other engines](docs/adobe-hotfixes/3-third-hotfix-contamination-and-other-engines.md))
- **Next.** We have asked Adobe for a fix that stops construction state being shared between
  requests, the way Lucee and BoxLang work, instead of locking around it.

In these documents "v1", "v2" and "v3" mean Adobe's first, second and third hotfix
(`hf202300-4232227`). The August research notes in `docs/research-log/` also used "v3" to "v5"
for our own experimental builds; each of those notes says which it means.

## Reproduce it

### Quick start (CommandBox)

1. Install dependencies (ColdBox + Quick are not committed to git):

   ```bat
   box install
   box install commandbox-fusionreactor
   ```

2. Copy `.env.example` to `.env` and set your SQL Server host and credentials.

3. Create an empty database named `adobe-temp` and load the schema:

   ```bat
   sqlcmd -S localhost,1433 -U sa -P <password> -d adobe-temp -i resources\schema.sql
   ```

   The schema creates two parent/child pairs with differently-named FK columns
   (`alpha_child.alpha_parent_id`, `bravo_child.bravo_parent_id`). That difference is what
   makes contamination obvious: an `UPDATE` retargeted to the wrong child table references a
   column that table doesn't have, so SQL Server raises `Invalid column name ...`.

4. Start the server (listens on port `60830`, engine `adobe@2023`):

   ```bat
   box server start
   ```

5. Sanity check first — open these in a browser. Each returns `{"ok":true,"childCount":3,...}`:

   ```text
   http://localhost:60830/repro/alpha
   http://localhost:60830/repro/bravo
   ```

6. Reproduce it. See below.

### Method 1: bombardier

The defect is request-scoped, so concurrent HTTP requests against both entities is the test that most closely matches production.

Drive both endpoints at once with [bombardier](https://github.com/codesenberg/bombardier)
in two terminals (replace `<base>` with `http://localhost` on IIS or
`http://localhost:60830` on CommandBox):

```bat
:: Terminal 1
bombardier -c 20 -n 3000 -t 30s "<base>/repro/alpha"
:: Terminal 2
bombardier -c 20 -n 3000 -t 30s "<base>/repro/bravo"
```

On ColdFusion 2023 Update 21 to 23 this contaminates several percent of requests (6.5% on Update 23 in September 2026). These endpoints write and contend on the same rows, so
more concurrency does not mean more hits — past ACF's max-simultaneous-request limit, requests
just time out. `-c 20` per endpoint is the sweet spot; tuning details are in
[docs/background/LOCAL_REPRODUCTION_RESULTS.md](docs/background/LOCAL_REPRODUCTION_RESULTS.md).

### Method 2: built-in stress endpoint (cfthread)

Hit the stress endpoint once per entity (no extra tools needed):

```text
http://localhost:60830/repro/stress?entity=alpha&iterations=200
http://localhost:60830/repro/stress?entity=bravo&iterations=200
```

Each spawns up to 500 concurrent `cfthread`s building fresh transients. The JSON response
reports `threadErrors` and `contaminations`. Locally this reproduces at roughly 4–7% of
constructions.  You can also quickly view the contaminated queries in the FusionReactor dashboard (easiest method).

### Reading the results

A reproduction is positive if any of these is true: `threadErrors` is non-zero, `/repro/status`
shows a non-zero count, or `logs/contamination_log.txt` has any line. A single, non-concurrent
request never triggers it.

`logs/contamination_log.txt` is the clean signal, one JSON object per line:

- `TABLE_NAME_CONTAMINATION` — an `UPDATE` hit the wrong table (the production symptom).
  Caught proactively by `interceptors/ContaminationDetector.cfc` at qb's `preQBExecute`.
- `VARIABLES_SCOPE_CORRUPTION` — a transient's `variables` property held another instance's
  value (e.g. the injected `_str` helper, or cached `_meta`). These fail before any SQL runs.

The clearest evidence is the interceptor line, which captures the contaminated SQL before SQL
Server errors — note the table and the SET column disagree:

```
CONTAMINATION #1 {"targetTable":"alpha_child","setColumn":"bravo_parent_id",
"sql":"UPDATE [alpha_child] SET [bravo_parent_id] = ?, [name] = ? WHERE ([alpha_child].[id] = ?)",
"thread":"XNIO-1 task-43","detectedAt":"..."}

TABLE_NAME_CONTAMINATION {"type":"TABLE_NAME_CONTAMINATION","context":"bravo_child",
"detail":"...Invalid column name 'bravo_parent_id'.","thread":"XNIO-1 task-43"}
```

The `contaminations` counter only tracks `TABLE_NAME_CONTAMINATION`; the variables-scope
faces surface in `threadErrors` and the log instead. See
[docs/background/LOCAL_REPRODUCTION_RESULTS.md](docs/background/LOCAL_REPRODUCTION_RESULTS.md) for why a run can show
`threadErrors: 9, contaminations: 0` and still be a positive hit.

`logs/repro_errors.txt` separately captures every request/thread failure (classified or not)
with exception type and stack trace, so unrelated problems (dead datasource, wedged servlet)
aren't silently swallowed.

If you see nothing after sustained load, the timing window isn't opening on that hardware.

You can also quickly view the contaminated queries in the FusionReactor dashboard (see below).

### Viewing the results in FusionReactor

If you are using FusionReactor (recommended), you can see the scope contamination by opening the FusionReactor dashboard (right-click on the taskbar's CF server icon and select "Open FusionReactor"). Then, using the left-hand menu, select JDBC > Error History.  You will see the contaminated queries appear there.

For large, repeatable measurements across test servers, use the harness described in
[docs/guides/TESTING_GUIDE.md](docs/guides/TESTING_GUIDE.md).

## The third hotfix's deadlock, in four files

[`hotfixrepro/deadlock/`](hotfixrepro/deadlock/) needs no ColdBox, ORM or database. Put the
`hotfixrepro` folder in the web root of a ColdFusion 2023 server and open
`/hotfixrepro/deadlock/index.cfm`. It passes on Update 23 and on the first hotfix. On the third
hotfix it reports `DEADLOCK` after 10 seconds, and `jcmd <pid> Thread.print -l` shows
`Found one Java-level deadlock` in `TemplateProxyFactory.resolveName`. Restart ColdFusion
afterwards. Details in [hotfixrepro/README.md](hotfixrepro/README.md).

## Documentation

Start with [docs/README.md](docs/README.md). In short:

| Folder | What is in it |
|---|---|
| [docs/background/](docs/background/) | The production evidence, a technical explanation, how the bug was narrowed down, and the first local reproduction |
| [docs/adobe-hotfixes/](docs/adobe-hotfixes/) | Analysis and test results for each of Adobe's three hotfixes, numbered in order |
| [docs/root-cause/](docs/root-cause/) | What we measured about the cause, the startup-crash fix, and how Lucee and BoxLang avoid the bug |
| [docs/guides/](docs/guides/) | How to run every test ([TESTING_GUIDE.md](docs/guides/TESTING_GUIDE.md)) and how to read the thread dumps |
| [docs/research-log/](docs/research-log/) | Dated notes from the August investigation, kept so every number stays traceable |

## Repository layout

```
Application.cfc                     ColdBox bootstrap; this.datasource = "adobe-temp"
config/Coldbox.cfc                  pins SqlServerGrammar@qb; registers the detector
config/Router.cfc                   /repro/*, /benchmark/* and /torture/* routes
models/AlphaParent|AlphaChild       entity pair A  (alpha_child.alpha_parent_id)
models/BravoParent|BravoChild       entity pair B  (bravo_child.bravo_parent_id)
models/wire/                        six unrelated WireBox components for /repro/wire
handlers/Repro.cfc                  alpha / bravo / wire / status / stress endpoints + logging
handlers/Benchmark.cfc              database-free construction endpoints and /benchmark/engine
handlers/Torture.cfc                lock stress tests for the hotfixes (deadlock, cflock, leaks, threads)
interceptors/ContaminationDetector  catches a wrong-table UPDATE before SQL Server does
models/lockprobe/, models/torture/  components the construction and lock tests build
hotfixrepro/deadlock/               standalone deadlock reproduction for the third hotfix
resources/schema.sql                SQL Server schema + seed
scripts/                            the test harness (see docs/guides/TESTING_GUIDE.md)
patches/quick/                      optional defensive Quick patches from an earlier line of work; not used in hotfix tests
server-bench-*.json                 one CommandBox config per test server
hotfixes/                           Adobe's hotfix jars go here (not committed; SHA256 pinned in scripts/TestServers.ps1)
logs/, benchmark-results-u23/       created at runtime (not committed)
```

## Notes

- ColdBox, Quick and qb are the unmodified ForgeBox releases (tested with ColdBox 8.1.0,
  Quick 12.0.12, qb 13.3.1), so the behavior is the engine's, not a local patch.
- The same application runs without contamination on Lucee 6 and BoxLang 1.
- Questions: <dave@angrysam.com>
