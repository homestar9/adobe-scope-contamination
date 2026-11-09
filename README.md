# Adobe ColdFusion 2023: CFC scope contamination under concurrent load

When many requests run at once, Adobe ColdFusion 2023 can hand one request an object that was
built for another request. Nothing errors at that moment. With the Quick ORM it shows up as a
query or `UPDATE` compiled against the wrong entity's table:

```text
Error Executing Database Query. Invalid column name 'alpha_parent_id'.
  at cfQuickBuilder2ecfc$funcUPDATEALL.runFunction(QuickBuilder.cfc:441)
  at cfHasOneOrMany2ecfc$funcAPPLYSETTER.runFunction(HasOneOrMany.cfc:273)
```

The `WHERE` clause is right for the entity you meant; only the table belongs to an unrelated
entity that another request was using at the same moment. It happens a few times a day under
real load, never on a single request, and not on Lucee or BoxLang.

> **Status (November 2026): solved and archived.** Adobe's fourth hotfix fixes it at the cause,
> with no lock and no speed cost. It is available from Adobe support, not in a public update yet.
> This repository is kept as the record. The full dated research notes are at git tag
> [`research-notes-2026-10`](https://github.com/homestar9/adobe-scope-contamination/tree/research-notes-2026-10/docs).

## Am I affected?

Probably, if you run ColdFusion 2023 with WireBox (ColdBox) under concurrent load. The cause is a
compiler detail: the temporary variable ColdFusion creates for a struct or array literal written
**inside a conditional expression** (`cond ? { ... } : { ... }` or `x ?: { ... }`) is not
declared as a local. Inside a component used by many requests at once (a singleton), it lands in
that component's shared `variables` scope, where concurrent requests overwrite each other's
half-built struct. WireBox's `Builder.buildCFC` builds every constructor argument collection that
way, so any object WireBox builds without constructor arguments can be handed another request's
data. Your own singletons can hit it too.

Seen on Update 18 in production and measured on Updates 19, 21 and 23. The class Adobe's fix
replaces is byte-identical in Update 25. ColdFusion 2025 was not tested. Lucee 6 and BoxLang 1
are not affected.

## Check your server

Copy [`hotfixrepro/`](hotfixrepro/) into the web root of any ColdFusion 2023 server and open
`/hotfixrepro/scopeleak/index.cfm`. It needs no framework or database and answers in a few
seconds: **FAIL** means the server has the bug (about half the builds come back carrying another
thread's value), **PASS** means it does not. `/hotfixrepro/scopeleak/shapes.cfm` lists which code
shapes leak, so you can look for them in your own code. Use this page to check whether a later
public update includes the fix.

## The fix

Ask Adobe support for hotfix **`hf202300-4232227`, fourth build** ("PatchVersion4"). All four of
Adobe's builds for this case carry the same name, so check what you receive:

- SHA256 `9d17ad33bb1d845d0303346905a2c0e8ca3fa6d4e2e087a45590c3feae4c5e81`, 24,210 bytes.
- It contains only `coldfusion/runtime/NeoPageContext.class` and its nine inner classes. If the jar
  contains `TemplateProxyFactory`, it is the first or third build, both of which add construction
  locks (see below).
- Built for Update 23. On a later update, ask Adobe for a matching build.

Put it in `<cfusion>/lib/updates/` and restart, then run the scope-leak page: it should PASS.

There is no tested workaround without the hotfix. In your own code, writing such a literal in an
`if`/`else` that assigns to a `var`-declared variable avoids the shape.

## Every build at a glance

| Build | Contaminated requests under concurrent load | Cost |
|---|---|---|
| ColdFusion 2023 Update 23, no hotfix | about 1 in 15 | none |
| + Adobe's first hotfix (one global construction lock) | rare: 0 in 550,000 in one round, 1 in 20,000 to 1 in 100,000 in the others | throughput roughly halved; `cflock` and `cfthread` join timeouts |
| + Adobe's third hotfix (one lock per class) | about 1 in 180,000 | 18% to 24% slower, and a new permanent deadlock |
| **+ Adobe's fourth hotfix** | **none in 2,900,000** | **none: no lock, same speed as no hotfix** |
| Lucee 6.2 / BoxLang 1.17 | none in 70,000 / 160,000 | no lock needed |

Adobe's second build changed only a class that was already identical in Update 23, so it behaves
exactly like no hotfix. Details, jar hashes and the stock-against-fourth-hotfix comparison are in
[docs/results.md](docs/results.md).

ColdFusion also has a separate startup bug: a freshly started server under immediate concurrent
load can corrupt a shared metadata map and then fail every request until restart. None of these
hotfixes change it. It has its own reproduction and fix:
[homestar9/acf-startup-npe-repro](https://github.com/homestar9/acf-startup-npe-repro).

## Documentation

| Document | What it covers |
|---|---|
| [docs/root-cause.md](docs/root-cause.md) | The cause, read from the fourth hotfix's bytecode, and why it explains every earlier result |
| [docs/results.md](docs/results.md) | Every hotfix measured, and the final comparison of stock Update 23 against the fourth hotfix |
| [docs/history.md](docs/history.md) | How the cause was found, May to October 2026, including the theories that turned out wrong |
| [hotfixrepro/README.md](hotfixrepro/README.md) | The two standalone pages: the scope leak and the third hotfix's deadlock |

## Reproduce it with the full application

The full reproduction is a stock ColdBox 8.1.0 + Quick 12.0.12 (qb 13.3.1) application on SQL
Server, both unmodified, running the same relationship path that failed in production.

1. Install [CommandBox](https://www.ortussolutions.com/products/commandbox), then the dependencies
   (ColdBox and Quick are not committed to git):

   ```bat
   box install
   box install commandbox-fusionreactor
   ```

2. Copy `.env.example` to `.env` and set your SQL Server host and credentials.

3. Create an empty database named `adobe-temp` and load the schema:

   ```bat
   sqlcmd -S localhost,1433 -U sa -P <password> -d adobe-temp -i resources\schema.sql
   ```

   The schema creates two parent/child pairs with differently-named foreign-key columns
   (`alpha_child.alpha_parent_id`, `bravo_child.bravo_parent_id`). A contaminated `UPDATE`
   retargeted to the wrong child table references a column that table doesn't have, so SQL Server
   raises `Invalid column name ...` instead of silently updating the wrong rows.

4. Start the server (port `60830`, engine `adobe@2023`): `box server start`

5. Sanity check: `http://localhost:60830/repro/alpha` and `/repro/bravo` each return
   `{"ok":true,"childCount":3,...}`.

6. Drive both endpoints at once with [bombardier](https://github.com/codesenberg/bombardier) in
   two terminals:

   ```bat
   bombardier -c 20 -n 3000 -t 30s "http://localhost:60830/repro/alpha"
   bombardier -c 20 -n 3000 -t 30s "http://localhost:60830/repro/bravo"
   ```

   Or, with no extra tools, open `/repro/stress?entity=alpha&iterations=200` and
   `/repro/stress?entity=bravo&iterations=200`, which start up to 500 concurrent `cfthread`s and
   report `threadErrors` and `contaminations`.

On Update 21 to 23 this contaminates several percent of requests. More concurrency does not mean
more hits: these endpoints write and contend on the same rows, and past ColdFusion's limit on
simultaneous requests the extra requests only queue. Twenty connections per endpoint works best.

**Reading the results.** A run is positive if any request failed, `/repro/status` shows a
non-zero count, or `logs/contamination_log.txt` has any line. The clearest evidence is the line
`interceptors/ContaminationDetector.cfc` writes at qb's `preQBExecute`, before SQL Server sees the
statement; note the table and the `SET` column disagree:

```text
CONTAMINATION #1 {"targetTable":"alpha_child","setColumn":"bravo_parent_id",
"sql":"UPDATE [alpha_child] SET [bravo_parent_id] = ?, [name] = ? WHERE ([alpha_child].[id] = ?)", ...}
```

`VARIABLES_SCOPE_CORRUPTION` lines are the same bug failing earlier, before any SQL runs: an
entity's `variables` scope holding another instance's value. `logs/repro_errors.txt` records every
failed request with its stack trace. With FusionReactor, the failed queries also appear under
JDBC > Error History.

## Re-run the comparison

The harness that produced [docs/results.md](docs/results.md) compares two independent ColdFusion
2023 Update 23 installs that differ only by the fourth hotfix's jar. It needs Windows PowerShell,
CommandBox, the SQL Server database from above, and the jar (not committed: it is Adobe's).

```powershell
# One time: bombardier (pinned version, SHA256 checked) into tools\
.\scripts\Get-BenchmarkTools.ps1

# Put hf202300-4232227-adobe-v4.jar in hotfixes\, then install both test servers, place the jar
# and prove each server is what it claims (which jar each class loads from, the jar's SHA256,
# where literal temporaries land). It refuses to continue on any mismatch.
.\scripts\Install-TestServers.ps1 -ClearFelixCache -Servers u23,localtemp-u23

# About 5 minutes: proves every step works
.\scripts\Invoke-FinalComparison.ps1 -Round final-dryrun -StockRequests 2000 -TempvarRequests 2000 -ContaminationRequests 2000 -Sessions 1 -WarmRequests 50 -SpeedRuns 1 -SpeedDuration 5s

# About 40 minutes: the full comparison
.\scripts\Invoke-FinalComparison.ps1 -Round my-run
```

Results and `summary.md` land in `benchmark-results-u23\<round>\`. A good run says
`Steps that failed: 0`, stock Update 23 shows contamination, and the fourth hotfix shows none.
Stock must show the bug; if it does not, a clean result on the other server proves nothing. For a
single server, `.\scripts\Test-Contamination.ps1 -Server localtemp-u23 -ColdStart` restarts it
before each session, warms it with 500 serial requests, then applies the concurrent load. A
burst against a server that has not been warmed is refused, because it would hit the separate
startup crash. Speed numbers here are only meaningful on a quiet machine; `-StopDropbox` pauses
the Dropbox client for the run.

The other test servers in `scripts/TestServers.ps1`: `buggy` (Update 21, no hotfix, an extra
known-bad check), `lucee6` and `boxlang`. Name them with `-Servers` to install them. All of them
share `.cfconfig-bench-db.json`, which pins the settings that would otherwise decide the result:
`inspectTemplate` never, `maxTemplateRequests` 100 (the default 25 queues everything at 32
connections), a large template cache, and saved class files.

## Repository layout

```text
Application.cfc, config/            ColdBox application; config/Coldbox.cfc pins SqlServerGrammar@qb and registers the detector
models/Alpha*, models/Bravo*        the two Quick entity pairs
models/wire/                        six unrelated WireBox components for /repro/wire (never contaminates)
models/torture/TempVarProbe.cfc     the shared-temporary probe behind /repro/tempvar and /torture/p8
handlers/Repro.cfc                  alpha / bravo / wire / tempvar / status / stress endpoints and logging
handlers/Benchmark.cfc              /benchmark/engine (server identity) and /benchmark/quickconstruct
handlers/Torture.cfc                /torture/p8, the shared-temporary probe inside the application
interceptors/ContaminationDetector  catches a wrong-table UPDATE before SQL Server does
hotfixrepro/                        the standalone scope-leak and deadlock pages
resources/schema.sql                SQL Server schema and seed data
scripts/                            the comparison harness
server.json, server-bench-*.json    one CommandBox config per server
hotfixes/                           Adobe's jar goes here (not committed)
docs/                               root cause, results, history
```

## Notes

- ColdBox, Quick and qb are the unmodified ForgeBox releases (`box.json` pins ColdBox 8.1.0 and
  Quick 12.0.12, which installs qb 13.3.1), so the behaviour is the engine's, not a local patch.
- Questions: <dave@angrysam.com>
