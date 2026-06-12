# ACF 2023 — CFC `variables`-scope contamination under concurrency

Under concurrent request load, Adobe ColdFusion 2023 intermittently lets a transient CFC's
`variables`-scoped state get overwritten by a different concurrent instance. In production
this overwrote a Quick ORM query builder's table name, so an `UPDATE` ran against the wrong
table (`UPDATE [user_type] ...` instead of `UPDATE [remote_app_remote_carrier] ...`).

This is a self-contained reproduction: stock ColdBox + Quick ORM against SQL Server,
exercising the same code path as production. The fastest way to see it is the quick start
below. The forensic write-up is in [docs/](docs/).

## Prerequisites

- Adobe ColdFusion 2023 (production runs Update 18 / build 330879; any 2023 build works).
- SQL Server reachable from the CF server.
- CommandBox (for the quick start). The SQL Server driver is installed automatically on
  first server start.
- [bombardier](https://github.com/codesenberg/bombardier) (recommended) — drives the concurrent-HTTP load test.

## Quick start (CommandBox)

1. Install dependencies (ColdBox + Quick are not committed to git):

   ```bat
   box install
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

6. Reproduce it. Hit the stress endpoint once per entity (no extra tools needed):

   ```text
   http://localhost:60830/repro/stress?entity=alpha&iterations=200
   http://localhost:60830/repro/stress?entity=bravo&iterations=200
   ```

   Each spawns up to 500 concurrent `cfthread`s building fresh transients. The JSON response
   reports `threadErrors` and `contaminations`. Locally this reproduces at roughly 4–7% of
   constructions.

## Reading the result

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
[docs/LOCAL_REPRODUCTION_RESULTS.md](docs/LOCAL_REPRODUCTION_RESULTS.md) for why a run can show
`threadErrors: 9, contaminations: 0` and still be a positive hit.

`logs/repro_errors.txt` separately captures every request/thread failure (classified or not)
with exception type and stack trace, so unrelated problems (dead datasource, wedged servlet)
aren't silently swallowed.

If you see nothing after sustained load, the timing window isn't opening on that hardware.
Note CPU core count, bare-metal vs VM, request volume, and duration; the docs stand on their own.

## Alternative: IIS / standalone ACF, with HTTP load

The defect is request-scoped, so concurrent HTTP requests against both entities is the test
that most closely matches production.

To deploy on IIS instead of CommandBox: run `box install`, copy the whole folder (including
`coldbox/` and `modules/`) to the webroot, then add a datasource in the ColdFusion
Administrator. The application reads `this.datasource = "adobe-temp"` from `Application.cfc`,
so the datasource name **must be `adobe-temp`**: SQL Server driver, your host/port/credentials,
database `adobe-temp`. (To use a different name, change `this.datasource` and the target DB to
match.)

Then drive both endpoints at once with [bombardier](https://github.com/codesenberg/bombardier)
in two terminals (replace `<base>` with `http://localhost` on IIS or
`http://localhost:60830` on CommandBox):

```bat
:: Terminal 1
bombardier -c 20 -n 3000 -t 30s "<base>/repro/alpha"
:: Terminal 2
bombardier -c 20 -n 3000 -t 30s "<base>/repro/bravo"
```

This reproduces at ~1–2% of requests. These endpoints write and contend on the same rows, so
more concurrency does not mean more hits — past ACF's max-simultaneous-request limit, requests
just time out. `-c 20` per endpoint is the sweet spot; tuning details are in
[docs/LOCAL_REPRODUCTION_RESULTS.md](docs/LOCAL_REPRODUCTION_RESULTS.md).

## Repository layout

```
Application.cfc                     ColdBox bootstrap; this.datasource = "adobe-temp"
config/Coldbox.cfc                  pins SqlServerGrammar@qb; registers the detector
config/Router.cfc                   /repro/* routes
models/AlphaParent|AlphaChild       entity pair A  (alpha_child.alpha_parent_id)
models/BravoParent|BravoChild       entity pair B  (bravo_child.bravo_parent_id)
handlers/Repro.cfc                  alpha / bravo / status / stress endpoints + logging
interceptors/ContaminationDetector  preQBExecute table/column-prefix mismatch detector
resources/schema.sql                SQL Server schema + seed
logs/                               contamination_log.txt + repro_errors.txt (created at runtime)
docs/                               forensic write-up
```

## Documentation

- [docs/PRODUCTION_EVIDENCE.md](docs/PRODUCTION_EVIDENCE.md) — real SQL, stack trace, environment.
- [docs/BUG_EXPLANATION.md](docs/BUG_EXPLANATION.md) — root-cause analysis.
- [docs/LOCAL_REPRODUCTION_RESULTS.md](docs/LOCAL_REPRODUCTION_RESULTS.md) — observed rates and tuning.
- [docs/INVESTIGATION_LOG.md](docs/INVESTIGATION_LOG.md) — discovery timeline.

## Notes

- ColdBox and Quick are the unmodified ForgeBox releases, so the behavior here is the
  engine's, not a local patch.
- The same application code runs without these issues on Lucee Server.
- Questions or additional captures (FusionReactor, thread/heap dumps) on request:
  <dave@angrysam.com>
