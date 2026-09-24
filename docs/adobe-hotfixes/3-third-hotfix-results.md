# Adobe v3 hotfix (`hf202300-4232227-adobe-v3.jar`): test results

Date: 2026-09-22. Static analysis and the predictions made before any run are in
[ADOBE_V3_HOTFIX_STATIC_ANALYSIS.md](3-third-hotfix-static-analysis.md). Raw output for every
table is under `benchmark-results-u23/adobe-v3/day1-mixed/` (gitignored; the directory named in each
section). Later rounds land in `benchmark-results-u23/adobe-v3/<profile>/`. The two short-profile
passes of the same evening are in `short-run1/` (first pass, copied aside) and `short/` (second
pass; the construction summaries of both passes sit side by side there, timestamped).

## Verdict

**v3 does not fix the bug. It is faster than v1 on the real workload, but only because the
real workload is limited by the database; the lock itself is still a single global queue.**

1. **A freshly started server still fails under load.** In 8 of 12 fresh starts (4 of 8 on the
   first day, 4 of 4 in the two short-profile passes), a fresh JVM hit with
   the standard concurrent burst went to 100% HTTP 500 and stayed there until restart, with the
   same failure signatures as stock Update 23 (`getKeyString` NullPointerException, `Element NAME
   is undefined`). Adobe's v1 did the same in 9 of 10 today. Our own `concmap-v1` build, run the same day on the same machine, was 0 for 3.
2. **The steady-state leak is still there.** In the sessions that survived the fresh start,
   2 of 320,000 requests contaminated (`VARIABLES_SCOPE_CORRUPTION`: an entity's `variables`
   scope holding another instance's QueryBuilder), 6 minutes apart, so not a first-seconds
   artifact. 80,000 warmed-up requests (four sessions) were clean. v1 was 0 in 20,000 warmed-up requests today
   and 1 in 20,000 in August.
3. **One class can get two locks.** The lock key is the file path as the caller spelled it.
   `models.torture.SlowLeafA` and `MODELS.TORTURE.slowleafa` construct in parallel on v3 and one
   after the other on v1. Correction, 2026-09-24: a standalone page with the same spelling
   differences (through a mapping, a web-root path and a relative name) got one shared lock, so
   the gap depends on how the path is resolved. It reproduces inside this application, not for
   every differently-cased reference.
4. **It can deadlock permanently.** Two components whose pseudo-constructors lazily construct
   each other park two threads on each other's `ReentrantLock` forever. The JVM reports
   `Found one Java-level deadlock`, `lock()` cannot be interrupted, and only a restart frees
   them (lock stress test P2: 2 of 2 in one request, 1 of 2 across two requests). Stock and
   v1 complete the same probe.
5. **On the real workload it is v1's global lock with a different name.** Under `/repro`
   load, 100% of v3's waiting threads (31.6 of 64 per thread dump; v1: 40.2) queue on ONE lock:
   the one for Quick's query builder, which is constructed once per query and is three classes
   and about 230 methods deep. The per-class design turns the busiest transient class in an
   application into a global lock. Every request also takes an `Application.cfc` construction
   lock.
6. **Throughput** (short profile, two passes). Real workload: v3 at 0.93x of stock at 8
   connections and 0.83x of the no-lock server at 32; v1 at 0.56 to 0.60x and 0.49 to 0.51x. With
   the database out of the way the lock cost shows. One class built repeatedly: v3 and v1 both
   about 0.45x of stock. Classes sharing a base: v3 0.27x, v1 0.33 to 0.36x, so v3 is worse. Only
   unrelated classes spread over at least 4 locks come close to stock on v3.

## Test servers

The five ColdFusion test servers are ACF 2023 installs that share one webroot, one `.cfconfig-bench-db.json`, one JDK
(Eclipse Adoptium 17.0.20.1) and one SQL Server database, and differ only by update level and
the jar in `lib/updates`. Identity was asserted from `/benchmark/engine` before every run
(`engine-<test server>.json`): which jar each of six classes loaded from, the runtime lock fingerprint
read off `TemplateProxyFactory`'s static fields, and the SHA256 of the deployed jar.

| Test server | Port | Engine | Jar (SHA256 prefix) | `TemplateProxyFactory` from | `TemplateProxy`/`UDFMethod`/`Closure` from | Lock fingerprint |
|---|---|---|---|---|---|---|
| `u23` | 60843 | 2023.0.23 | none | `chf20230023.jar` | stock | `none` |
| `lock-u23` | 60844 | 2023.0.23 | adobe-v1 (`7b586d55`) | hotfix jar | hotfix jar | `global` |
| `buggy` | 60845 | 2023.0.21 | none | `chf20230021.jar` | stock | `none` |
| `perclass-u23` | 60848 | 2023.0.23 | adobe-v3 (`efb0aa56`) | hotfix jar | **stock** (v3 does not ship them) | `perclass` |
| `concmap-u23` | 60849 | 2023.0.23 | concmap-v1 (`4943e46a`, ours) | hotfix jar | hotfix jar | `global` |
| `lucee6` | 60850 | Lucee 6.2.8.20, JDK 17.0.20.1 | none | n/a | n/a | n/a |
| `boxlang` | 60851 | BoxLang 1.17.5 + `bx-compat-cfml` + `bx-mssql`, JDK 21.0.12.1 | none | n/a | n/a | n/a |

The two comparison engines have no construction lock and no contamination bug. They run the
same app, database and heap. Every smoke-test endpoint and all eight construction shapes answered
`ok:true` on both before any measurement; no CFML-compatibility gap had to be worked around.
BoxLang ran the first short pass with its own `.cfconfig.json`, which lacks the template-cache
settings the other test servers get, so it re-checked every template on disk. From the second
pass on it uses `.cfconfig-bench-db.json` and `-Dboxlang.trustedCache=true` (about 2x on
construction, little change on the real workload). Use its second-pass numbers.

Application side: ColdBox 8.1.0, stock Quick 12.0.12 (reinstalled from ForgeBox for this
test run; the local patches under `patches/quick/` are NOT applied), qb 13.3.1 as Quick's
transitive dependency (August's runs had qb 13.1.0; the same-day `concmap-u23` calibration
shows the cold trigger behaves the same under 13.3.1). `modules/quick/models/BaseEntity.cfc`
SHA256 `54c3fdd663ec4da051fad01e6e32126fbd42afb03b3bfea4fd62d06f8539d075`.

## 1. contamination test

`scripts/Test-Contamination.ps1`: `/repro/alpha` and `/repro/bravo` driven at the same
time, 20 connections each, fixed request count. Every session counts bombardier's HTTP 5xx,
its transport errors (a hung test server shows there), completed requests against the target, the
classified counter from `/repro/status`, and new lines in `logs/contamination_log.txt` and
`logs/repro_errors.txt` with a signature histogram. Cold = the JVM is killed and started
fresh, the first traffic it sees is the burst. Warm = fresh JVM, 2,000 serial single-connection
requests discarded, then the burst. Directory: `contamination test-<test server>-<label>/`.

### Known-bad check and the fresh-start trigger (same day)

| Test server | Label | Sessions | Requests | HTTP 5xx | Classified | Log lines | Signatures | Verdict |
|---|---|---|---|---|---|---|---|---|
| `buggy` (2023.0.21) | warm | 1 | 20,000 | 815 (4.1%) | 405 | 1,227 | 598 `TABLE_NAME_CONTAMINATION`, 217 `VARIABLES_SCOPE_CORRUPTION` | reproduces: the harness is valid today |
| `u23` (stock) | cold | 1 | 100,000 | 100,000 (100%) | 0 | 100,000 errors | 99,960 NPE, 40 `getKeyString` NPE | failure of every request until restart: the cold trigger fires today |

### The new hotfix server and the servers it is compared with

| Test server | Label | Sessions | Requests | Sessions that failed every request until restart | HTTP 5xx | Classified | Log contamination | Signatures | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| **`perclass-u23` (v3)** | cold | 3 | 300,000 | **0 of 3** | 2 | 0 | 2 | 2 `VARIABLES_SCOPE_CORRUPTION` (`setalphaChildren` / `setbravoChildren` on a QueryBuilder), session 1, 18:47 and 18:53 | leak, no failure of every request until restart |
| **`perclass-u23` (v3)** | cold, second batch | 3 | 120,000 | **3 of 3** | 120,000 (100%) | 0 | 0 | 79,920 NPE; 39,996 `Element NAME is undefined in THISITEM`; 80 `getKeyString` NPE; 4 `PERSISTENT`/`NULLVALUE undefined in ATTR` | **failure of every request until restart** |
| **`perclass-u23` (v3)** | cold, round at 13:30 | 2 | 40,000 | **1 of 2** | 20,000 (50%) | 0 | 0 | 19,998 `Element NAME is undefined in THISITEM`; 2 `NAME undefined in ATTR` (no `getKeyString` this time) | session 1 clean; session 2 **failure of every request until restart** |
| **`perclass-u23` (v3)** | warm | 2 | 40,000 | 0 of 2 | 0 | 0 | 0 | | clean (12:12 and 13:37) |
| `lock-u23` (v1) | cold | 1 | 100,000 | 1 of 1 | 100,000 (100%) | 0 | 0 | 99,960 NPE, 40 `getKeyString` | **failure of every request until restart** |
| `lock-u23` (v1) | cold, second batch | 3 | 120,000 | 3 of 3 | 120,000 (100%) | 0 | 0 | 119,835 NPE, 159 `getKeyString`, 4 `PERSISTENT`, 2 `NULLVALUE` | **failure of every request until restart** |
| `lock-u23` (v1) | cold, round at 13:34 | 2 | 40,000 | 2 of 2 | 40,000 (100%) | 0 | 0 | 19,998 `Element NAME is undefined in THISPARENTITEM`; 19,913 NPE; 87 `getKeyString`; 2 `NAME undefined in ATTR` | **failure of every request until restart** |
| `lock-u23` (v1) | warm | 1 | 20,000 | 0 of 1 | 0 | 0 | 0 | | clean |
| `concmap-u23` (ours) | cold | 3 | 120,000 | **0 of 3** | 0 | 0 | 0 | | clean |
| **`perclass-u23` (v3)** | cold, short pass 1 (14:52) | 2 | 40,000 | **2 of 2** | 40,000 (100%) | 0 | 0 | 39,920 NPE, 80 `getKeyString` | **failure of every request until restart** |
| **`perclass-u23` (v3)** | cold, short pass 2 (16:39) | 2 | 40,000 | **2 of 2** | 40,000 (100%) | 0 | 0 | 39,920 NPE, 80 `getKeyString` | **failure of every request until restart** |
| **`perclass-u23` (v3)** | warm, short passes 1 and 2 | 2 | 40,000 | 0 of 2 | 0 | 0 | 0 | | clean |
| `lock-u23` (v1) | cold, short pass 1 (14:54) | 2 | 40,000 | 2 of 2 | 40,000 (100%) | 0 | 0 | 39,920 NPE, 80 `getKeyString` | **failure of every request until restart** |
| `lock-u23` (v1) | cold, short pass 2 (16:41) | 2 | 40,000 | 1 of 2 | 20,000 (50%) | 0 | 0 | 19,949 NPE, 51 `getKeyString` | session 1 clean (no leak); session 2 **failure of every request until restart** |
| `lucee6` | warm check, both passes | 2 | 40,000 | 0 of 2 | 0 | 0 | 0 | | clean (no bug, as expected) |
| `boxlang` | warm check, both passes | 2 | 40,000 | 0 of 2 | 0 | 0 | 0 | | clean (no bug, as expected) |

The known-bad check ran twice: 815 of 20,000 failing (4.1%) at 11:43 and 916 of 20,000 (4.6%;
691 `TABLE_NAME_CONTAMINATION`, 225 `VARIABLES_SCOPE_CORRUPTION`) at 13:30, then 1,510 (7.6%)
and 1,508 (7.5%) in the two short passes. The harness reproduced the bug every time.

Raw files: the round that started at 13:24 wrote into the same folders as the morning runs. In
`gate-perclass-u23-cold/` and `gate-lock-u23-cold/`, sessions s1 and s2 are the round's and s3 (v3
only) is the morning's; the morning v3 sessions 1 and 2 (the 2 leaks) survive only in
`logs/archive/gate-perclass-u23-warm-20260922-121202/contamination_log.txt` (18:47:41 and
18:53:09 UTC). `gate-buggy-control/` and `gate-perclass-u23-warm/` also hold the round's run.

Cold-start tally for the day, all test servers killed and restarted the same way, same burst:

| Build | Fresh JVMs that failed every request until restart |
|---|---|
| stock Update 23 | 1 of 1 |
| Adobe v1 (global lock) | 9 of 10 |
| **Adobe v3 (per-class locks)** | **8 of 12** |
| our v1 + concurrent `CaseInsensitiveMap` | 0 of 3 |

Reading: the fresh-start failure (race 1: a torn `CaseInsensitiveMap` read by Quick's metadata
`duplicate()` while a construction writes it) is a coin flip on v3 and worse than that on v1
today. Neither Adobe design serializes the reader; only the concurrent map does. The
August record has v1 surviving one cold start with one leak; that was the other side of the
coin. The per-class design does not make race 1 better or worse in any way this test can
resolve; it leaves it open.

Race 2 (the ~4% steady-state cross-instance contamination on unpatched engines) is reduced by
v3 to the same order as v1: 2 in 320,000 cold-survivor requests, 0 in 80,000 warm. The
`VARIABLES_SCOPE_CORRUPTION` signature is the production symptom's sibling (the entity's
`variables` scope holding a different instance's builder), so the "per-instance fixes" v1
shipped and v3 dropped did not change the residual, but the residual is not zero.

Throughput observed during the contamination tests (20 connections per endpoint, alpha+bravo, real ORM path;
same machine, same hour; indicative only, the test below is the measurement):

| Test server | Requests/s |
|---|---|
| `buggy` (no lock, 4% failing) | 249 |
| `perclass-u23` (v3) | 213 to 224 |
| `lock-u23` (v1) | 135 |
| `concmap-u23` (ours, global lock) | 117 to 127 |

## 2. Lock-identity matrix (lock stress test P1)

`/torture/p1?pair=all&ms=200&reps=3`: two `cfthread`s construct two components after a
`CountDownLatch`, each pseudo-constructor sleeps 200 ms. Wall time about 200 ms means the two
constructions overlapped ("parallel"); about 400 ms means one waited for the other
("serial"). Directory: `torture-<test server>/p1-all-smoke.json`.

| Pair | What it tests | `u23` | `lock-u23` (v1) | `perclass-u23` (v3) | v3 as predicted? |
|---|---|---|---|---|---|
| `same` | the same class twice | parallel 211 | serial 409 | serial 405 | yes |
| `unrelated` | two classes, no `extends` | parallel 214 | serial 404 | **parallel 201** | yes: the only case v3 improves |
| `siblings` | two classes sharing a base | parallel 214 | serial 414 | **serial 416** | yes: the base lock is held for the whole construction |
| `outer` | a class whose constructor constructs another | parallel 215 | serial 413 | serial 428 | yes |
| `mapping` | same file via `models.x` and the `app.models.x` mapping | parallel 212 | serial 404 | serial 416 | yes |
| `alias` | same file as `models.torture.SlowLeafA` vs `MODELS.TORTURE.slowleafa` | parallel 214 | serial 417 | **parallel 215** | **no: two locks for one class** |
| `slowinit` | sleep in `init()` instead of the constructor | parallel 213 | parallel 203 | parallel 201 | yes: `init()` runs outside every lock |

The `alias` row is a correctness hole specific to v3: the lock key is `File.getPath()` of the
spelling the caller used, and Windows resolves both spellings to the same file. ColdFusion
component names are case-insensitive. Correction, 2026-09-24: the standalone page in
`hotfixrepro/` did not reproduce the split with the same spelling differences through a
mapping, a web-root dotted path or a relative name, so it is narrower than "ordinary code". It
reproduces reliably inside this application's `/torture/p1?pair=alias` probe.

## 3. Real-workload throughput

`scripts/Invoke-RealWorkloadBenchmark.ps1`, short profile: `/repro/alpha` and `/repro/bravo`
together, 2 runs of 10 s per point, test servers alternated per measurement, every server
restarted and serially warmed first. Ratios are median requests per second against stock
Update 23. Stock has no lock, so the steady-state bug fires on it (6.7% to 10.5% HTTP 5xx). At
32 connections pass 1 marks it invalid (above 10%), so that row is read against `buggy`
(Update 21, no lock, the same no-lock speed). Summaries: `repro-throughput/summary-20260922-152650.md`
(pass 1, in `short-run1/`) and `summary-20260922-171620.md` (pass 2).

| Connections | v1 / stock | v3 / stock | v3 / v1 | Lucee 6 / stock | BoxLang / stock |
|---|---|---|---|---|---|
| 1 | 1.01, 0.94 | 0.99, 1.00 | 0.98, 1.07 | 0.56, 0.58 | 0.44, 0.47 |
| 8 | 0.60, 0.56 | 0.93, 0.93 | 1.57, 1.67 | 0.15, 0.14 | 0.34, 0.37 |
| 32 (against `buggy`) | 0.51, 0.49 | 0.83, 0.83 | 1.64, 1.68 | 0.14, 0.14 | 0.46, 0.42 |

Pass 1 first, pass 2 second. p99 at 32 connections, same session: v1 741 and 748 ms, v3 470 and
511 ms, `buggy` 463 and 462 ms. v1 and v3 had 0 HTTP 5xx throughout.

Reading: v3 gets about two thirds more through than v1 on this workload, and at low concurrency
it costs nothing. It still loses 17% against a no-lock server at 32 connections, which is the
query-builder lock of section 5; the database round trips hide the rest. The two passes agree
within 7% on every Adobe ratio.

Lucee 6 and BoxLang are correct (section 1) but slow here. Lucee stays flat at about 30 requests
per second from 8 connections up, with multi-second p99s. It is fast on plain construction
(section 4), so the cost is on the Quick, qb and database path. We did not diagnose it. On this
workload the two are correctness references, not speed references.

## 4. Synthetic construction throughput

`scripts/Invoke-ConstructionBenchmark.ps1`, short profile: no database, each request constructs
200 components (50 entity + builder pairs for `quickconstruct`), 2 runs of 10 s per point.
Shapes: `narrow` = one class over and over (worst case for any lock), `fanout` = 16 unrelated
classes (best case for per-class locks), `siblings` = 16 classes sharing one base. Ratios
against stock at 32 connections, pass 1 then pass 2. Directories: `construct/`, `quickconstruct/`,
`construct-widths/`.

| Shape, 32 connections | v1 / stock | v3 / stock | `buggy` / stock (noise gauge, should be 1.0) |
|---|---|---|---|
| `narrow` | 0.49, 0.43 | 0.47, 0.42 | 1.05, 0.91 |
| `fanout` | 0.44, 0.43 | 1.10, 0.93 | 1.02, 0.94 |
| `siblings` | 0.36, 0.33 | **0.28, 0.27** | 1.19, 0.95 |
| `quickconstruct` (Quick entity + builder) | 0.41, 0.38 | 0.77, 0.63 | 0.93, 0.83 |

Fanout width at 32 connections. Pass 2 only: pass 1 ran this at 1 connection because of a
profile bug, since fixed, and is not usable.

| Unrelated classes | v1 / stock | v3 / stock |
|---|---|---|
| 1 | 0.39 | 0.34 |
| 4 | 0.42 | 0.81 |
| 16 | 0.44 | 0.92 |

Reading:
- One class under load costs the same on v3 as on v1: about half of stock. Per-class locking only
  helps when the load is spread over several unrelated classes. At 4 classes it recovers most of
  stock, at 16 nearly all of it.
- Classes that share a base class are slower on v3 than on v1 in both passes. Every one of them
  also takes the base lock, so they serialize on it anyway, and v3 adds the cost of holding two
  locks. Every Quick entity shares `BaseEntity`, so this is the ORM case.
- At 1 connection the ratios swing by up to 40% between passes (10-second runs of about 100
  requests per second). Nothing contends there, so those rows are left out.
- The noise gauge moved by up to 20% between passes, more than the 10% set in advance for a
  quiet machine. Background CPU was small (under one core of 24), but the Backblaze uploader
  held 3 GB and was active. The direction of every Adobe comparison is the same in both passes.
  Treat the second digit as noise until the long profile is in.
- Lucee 6 runs at 0.42 to 0.84x of stock across the shapes, but `quickconstruct` at 0.07x with
  p99 at the 5 s client timeout: the same Quick-path slowness as section 3. BoxLang runs at 0.1
  to 0.2x even after the template-cache fix. Neither is a speed reference on this machine.

## 5. Lock evidence

`scripts/Get-LockEvidence.ps1`: 32 connections per target for 30 s while `jcmd <pid> Thread.print -l`
is sampled 20 times, one second apart. v1's `synchronized` shows as `BLOCKED (on object monitor)`;
v3's `ReentrantLock` shows as `WAITING (parking)` on a `ReentrantLock$NonfairSync`, and the
`-l` listing of owned synchronizers maps each contended lock address to the thread that holds
it and the CFC frame that thread is in. Every test server was restarted fresh and serially warmed
before the `/repro` and `quickconstruct` runs (a JVM left in the failed every request until restart state from a cold
contamination test dies before it reaches Quick, which mis-attributes the waits). Directory: `lock-evidence/`.

| Test server | Load | Threads waiting on `resolveName` per dump (64 in flight) | Distinct locks contended | Share on the busiest lock | Who holds the busiest lock |
|---|---|---|---|---|---|
| `u23` (stock) | `/repro` alpha+bravo | 0 | 0 | | nothing: the control |
| `lock-u23` (v1) | `/repro` alpha+bravo | **40.2** BLOCKED | 1 monitor | 100% | any construction (global) |
| `perclass-u23` (v3) | `/repro` alpha+bravo | **31.6** parked | **1** | **100%** | a thread constructing Quick's **`QuickQB`** (extends qb `QueryBuilder` extends `JsonQueryBuilderSupport`), holding all three locks of that chain, in `registerUDFs` of a 196-method class |
| `perclass-u23` (v3) | `quickconstruct` (entity + builder, no DB) | 14.7 parked | 2 | 99.3% | the same `QuickQB` chain |
| `lock-u23` (v1) | construct `siblings` | 24.1 BLOCKED | 1 monitor | 99.8% | any construction (global) |
| `perclass-u23` (v3) | construct `siblings` | 25.6 parked | 57 | 25.8% | a `Sib*` leaf holding two locks (its own and `SibBase`'s): the ancestor lock |
| `perclass-u23` (v3) | construct `fanout` | 4.1 parked | 17 | 45.1% | a thread in **`Application.cfc` line 34** (`expandPath` inside `this.javaSettings`), holding one lock |

Where the 632 `/repro` waiters on v3 were when they queued: 364 inside `QuickQB.cfc` line 956
(`clone()`, which constructs a new `QuickQB`) and 268 inside WireBox `Builder.cfc` line 223
(`createObject` for `newQuery()`). Every Quick query constructs a builder, so every query in
every request queues on this one lock, and the lock is held for the whole construction of a
three-class chain with about 230 methods to register.

Both short passes repeated the `/repro` measurement with 10 dumps each. v3: 45.4 and 43.8 parked
threads per dump, 99.6% and 99.3% on one lock held inside the `QuickQB` construction chain. v1:
55.0 and 56.6 blocked on its one monitor (`short-run1/lock-evidence/`, `short/lock-evidence/`).

**Mechanism.** The per-class design makes the hottest transient class in the application a
global lock. In a Quick application that class is the query builder, constructed once per
query, and its construction is expensive precisely because qb's `QueryBuilder` is large. v1
serialized this and everything else; v3 serializes this and its ancestors, which on this
workload is nearly the same queue (31.6 vs 40.2 threads waiting per dump). Entity
constructions (`AlphaChild` and `BravoChild` through `BaseEntity`) did not register as a
separate contended lock because they wait behind the builder lock inside the same request.

**Every request also takes the `Application.cfc` lock.** ColdFusion constructs `Application.cfc`
for every request through the same `resolveName`, so v3 gives every request in the JVM a
per-request lock held while the `Application.cfc` pseudo-constructor runs (`this.*` settings,
`expandPath`, the ColdBox bootstrap properties). On the `/repro` workload it is invisible behind
the builder lock; on the `fanout` shape, where constructions are cheap and spread over 16
unrelated classes, it is the busiest lock (45% of waits). Any application with an
`Application.cfc` pays it.

## 6. lock stress tests P2 to P7

`scripts/Invoke-LockStressTests.ps1` runs the probes in `handlers/Torture.cfc` on stock, v1 and
v3. Both short passes gave identical results except where noted. Per-probe JSON and thread
dumps: `torture-<test server>/`. The P2 run rewrites `torture-summary.json`, so the P3 to P7
verdicts are read from the per-probe files.

| Probe | What it does | stock | v1 | v3 |
|---|---|---|---|---|
| **P2 in one request** | two `cfthread`s released together, one constructs `MutualA` and one `MutualB`; each pseudo-constructor lazily constructs the other | completes | completes | **deadlock, 2 of 2**: the JVM reports `Found one Java-level deadlock`, each thread parked on the other's `ReentrantLock$NonfairSync` at `TemplateProxyFactory.resolveName:237` |
| **P2 across two requests** | the same, one side per HTTP request | completes | completes | **deadlock in pass 1**, JVM-reported. In pass 2 the second request started after the first had finished its window and both completed: timing-dependent, as a production deadlock would be |
| P3, holder is a component, same target | a component under construction holds named lock L; a second thread constructs a component whose pseudo-constructor takes L | ok | ok | **`cflock` timeout** (new on v3) |
| P3, holder is plain code, same target | request code holds L while constructing; the other thread constructs the same class | ok | `cflock` timeout | `cflock` timeout |
| P3, holder is plain code, unrelated target | as above, a different class | ok | `cflock` timeout | ok |
| P4 | exceptions and `abort` from pseudo-constructors and `extends` resolution, then one clean construction of each with a 10 s deadline | ok | ok | ok: no leaked lock |
| P5, same class or sibling | a pseudo-constructor spawns a `cfthread` that constructs the same class or a sibling and joins it | ok | join timeout, recovers | join timeout, recovers |
| P5, unrelated class | the same with an unrelated class | ok | join timeout, recovers | ok |
| P6 | `duplicate()` against concurrent construction of the same class | ok | ok | ok |
| P7 | construct 64 distinct classes once each | ok | ok | ok; the lock map grows by 64 and is never evicted |

P1 (section 2) repeated in both passes with the same verdict on every pair, including `alias`.

Reading: v3 trades v1's cross-class serialization (P3 and P5 on unrelated classes now pass) for
a new failure class. Any two components that construct each other lazily, in either order, can
now hang two threads for the life of the JVM. `ReentrantLock.lock()` ignores interrupts, so the
request timeout does not free them, and every later request that needs either class queues
behind them. The probe widens the window with a 100 ms sleep; in production the window is the
pseudo-constructor's own run time. The P3 row with a component as the holder is also new: a
named lock taken during construction now interlocks with the construction lock of the same
class.

## 7. endurance test

`scripts/Invoke-LockSoak.ps1`, short profile: 5 one-minute slices of mixed load (`/repro/alpha` and
`/repro/bravo` at 16 connections each, `fanout` and `quickconstruct` at 8 each), with a thread
dump, heap reading and lock-map size every 20 s. v3 ran in both short passes. Two 5-minute control
runs were added between the passes, on v1 and on `buggy` (no lock), to tell a lock effect from a
machine effect. Directories: `soak-<test server>/`.

| Test server | Requests/s, first to last minute | HTTP 5xx | Waiting threads per dump | Lock map | Verdict |
|---|---|---|---|---|---|
| v3, pass 1 | 368 to 246 | 0 | 6.5 to 24.5, no trend | 173, flat | script says FAIL on throughput |
| v3, pass 2 | 372 to 249 | 0 | 5 to 26, no trend | 173, flat | script says FAIL on throughput |
| v1 (control) | 94 to 98 | 0 | 40 to 44, flat | n/a | PASS |
| `buggy`, no lock (control) | 349 to 242 | 4,228 (the bug) | 0 | n/a | same throughput fall as v3 |

Reading: v3 held up for the length of the test. No errors, no deadlock in 20 dumps, the lock
map levelled off at 173 entries, the heap cycled normally, and the waiter count did not grow.
The throughput fall of about a third is not the lock's doing. The no-lock server falls by
the same amount under the same load in the same five minutes, and v3's waiters do not rise
while it falls. v1 stays flat only because its lock caps it at a rate below whatever slows
the others. The cause is on the machine or database side and was not isolated. The
endurance throughput check therefore needs a no-lock control next to it on this machine; the
long profile's 45-minute run should be read the same way.

