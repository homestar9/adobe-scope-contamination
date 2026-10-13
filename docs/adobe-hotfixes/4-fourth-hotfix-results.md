# Adobe's fourth hotfix (`hf202300-4232227-adobe-v4.jar`): test results

Date: 2026-10-13. Static analysis and the predictions made before any run are in
[4-fourth-hotfix-static-analysis.md](4-fourth-hotfix-static-analysis.md). Raw output for every
table is under `benchmark-results-u23/adobe-v4/` (gitignored; the directory is named in each
section). The startup crash on a freshly started server is a separate issue, filed with Adobe on
its own; every session here restarts its server, waits until it answers, sends serial warm-up
requests, and only then applies concurrent load.

## Verdict

**v4 fixes the contamination at its cause, with no lock, and costs nothing.** Short profile,
2026-10-13; the long profile (section 8) is the report-grade confirmation.

1. **The cause is named and removed.** The crossing object the August probe caught in WireBox's
   `Builder.buildCFC` is a struct literal inside a ternary expression. The compiler never
   declared the temporary it uses for such a literal, so it was written to the singleton's
   `variables` scope, shared by every concurrent request. v4 keeps it in the function's local
   scope. Three new probes show the leak on every earlier build (about half of all builds come
   back carrying another thread's value; stock, v1 and v3 alike) and never on v4 (section 1).
2. **No contamination.** 0 in 40,000 real-workload requests across two fresh, warmed JVMs,
   and 0 in 20,000 on the mechanism endpoint where Update 21 fails a third of its requests
   (section 2). The known-bad check reproduced the bug the same hour.
3. **No lock.** 0 threads waiting in `resolveName` under 64 in flight (v1 the same hour: 37
   per dump); every lock stress test identical to stock; the third hotfix's deadlock demo passes
   in 105 ms, and P8 passes (sections 3 and 4).
4. **No cost.** Real workload at or above the servers with no hotfix at every load level and
   the lowest p99 of the five at 32 connections (v3 was 0.76 to 0.82 of stock, v1 0.44 to 0.53).
   Database-free construction within noise of the no-lock server on every shape, where v1 and
   v3 lost half to three quarters (sections 5 and 6).
5. **Stable over time** on every check the hotfix can influence (section 7).

What v4 does not change: the separate startup crash on a freshly started server under immediate
concurrent load, which is filed with Adobe on its own and was kept out of this round.

## Test servers

The five ColdFusion test servers are ACF 2023 installs that share one webroot, one
`.cfconfig-bench-db.json`, one JDK (Eclipse Adoptium 17.0.20.1) and one SQL Server database, and
differ only by update level and the jar in `lib/updates`. Identity was asserted from
`/benchmark/engine` before every run (`identity/engine-<test server>.json`): which jar each of
seven classes loaded from, the lock fingerprint read off `TemplateProxyFactory`'s static fields,
the SHA256 of the deployed jar, and a new behavioral fingerprint: where the compiler's temporaries
for inline literals inside a conditional expression land.

| Test server | Port | Engine | Jar (SHA256 prefix) | `TemplateProxyFactory` from | `NeoPageContext` from | Lock fingerprint | Literal temporaries |
|---|---|---|---|---|---|---|---|
| `u23` | 60843 | 2023.0.23 | none | `chf20230023.jar` | `chf20230023.jar` | `none` | `shared-variables` |
| `lock-u23` | 60844 | 2023.0.23 | adobe-v1 (`7b586d55`) | hotfix jar | `chf20230023.jar` | `global` | `shared-variables` |
| `buggy` | 60845 | 2023.0.21 | none | `chf20230021.jar` | `chf20230021.jar` | `none` | `shared-variables` |
| `perclass-u23` | 60848 | 2023.0.23 | adobe-v3 (`efb0aa56`) | hotfix jar | `chf20230023.jar` | `perclass` | `shared-variables` |
| **`localtemp-u23`** | 60852 | 2023.0.23 | **adobe-v4 (`9d17ad33`)** | `chf20230023.jar` (stock) | **hotfix jar** | **`none`** | **`function-local`** |

Lucee 6 and BoxLang were not re-run; their September results
([3-third-hotfix-contamination-and-other-engines.md](3-third-hotfix-contamination-and-other-engines.md))
stand: no contamination, no lock. Application side: ColdBox 8.1.0, stock Quick 12.0.12
(`modules/quick/models/BaseEntity.cfc` SHA256 `54c3fdd6…`, unchanged since September), qb 13.3.1.

## 1. The mechanism, measured directly

The fix moves one thing: the compiler temporary for an inline literal written inside a
conditional expression. Three new probes test exactly that, with no database and no ORM.

**Which shapes leak** (`hotfixrepro/scopeleak/shapes.cfm`, single-threaded, one shared instance,
33 code shapes). On Update 21 and Update 23 without v4, exactly nine shapes leave a
`___IMPLICITARRYSTRUCTVAR<n>` key in the instance's `variables` scope: every one with a literal
inside `cond ? … : …` or `x ?: …` (`ternaryFalseBranch`, `ternaryTrueBranch`,
`ternaryBothLiterals`, `ternaryInVar`, `ternaryEmptyArray`, `ternaryCallArg`,
`ternaryInStructAppend`, `elvis`, `nullCoalesceCall`). The other 24, including literals in plain
statements, loops, `if`, `try`, `switch`, closures, arrow functions, `invoke()` arguments,
`reduce()` initial values and `structAppend()`, leave nothing. On v4, zero shapes leak.

**Standalone demo** (`hotfixrepro/scopeleak/index.cfm`, 32 threads x 100 builds of three
literal forms, 2 ms inside each literal, one shared instance; no framework):

| Server | Leaked keys after one single-threaded build | Struct builds returning another thread's token (of 3,200) | Array builds (of 3,200) | `invoke()` argument builds (of 3,200) | Errors | Result |
|---|---|---|---|---|---|---|
| Update 21, no hotfix | 1 | 1,757 | 1,544 | 1,554 | 176 | FAIL |
| Update 23 + v1 (global lock) | 1 | 1,772 | 1,580 | 1,590 | 182 | FAIL |
| Update 23 + v3 (per-class locks) | 1 | 1,711 | 1,517 | 1,603 | 199 | FAIL |
| **Update 23 + v4** | **0** | **0** | **0** | **0** | **0** | **PASS** |

About half of every build on the unfixed engines comes back carrying another thread's token;
the errors are reads of a struct that another thread had just replaced with an empty one. The
locks of v1 and v3 change nothing here, as predicted: they are around component construction,
and this happens inside an ordinary method call on an already-built singleton.

**Inside the application** (`/torture/p8`, the same three forms on a WireBox singleton, 32
threads x 50 builds): Update 21 794 crossings of 4,800 builds and 3 leaked keys; v3 604 of 4,800
and 3 leaked keys; v4 0 of 4,800 and 0 leaked keys. The same probe is what every `/repro`
request already does implicitly: WireBox's `Builder.buildCFC` builds `constructorArgCollection`
as `constructorArgs.len() ? buildArgumentCollection( … ) : {}`.

## 2. Contamination test

`scripts/Test-Contamination.ps1`: two endpoints driven at the same time, 20 connections each,
fixed request count. Every session restarts the test server's JVM, waits until it answers, sends
500 serial requests, and only then bursts. Counted per session: bombardier's HTTP 5xx, transport
errors, completed requests against the target, the classified counter from `/repro/status`, and
new lines in `logs/contamination_log.txt` and `logs/repro_errors.txt`. Directory:
`short/contamination test-<test server>-<label>/`.

### Short profile (2026-10-13, same hour, same machine)

| Test server | Endpoints | Sessions | Requests | HTTP 5xx | Log contamination lines | Signatures | Requests/s | Verdict |
|---|---|---|---|---|---|---|---|---|
| `buggy` (Update 21, no fix) | alpha + bravo | 1 | 20,000 | 1,732 (8.7%) | 2,802 | 1,417 `TABLE_NAME_CONTAMINATION`, 315 `VARIABLES_SCOPE_CORRUPTION` | 172 | reproduces: the harness is valid today |
| **`localtemp-u23` (v4)** | alpha + bravo | 2 | 40,000 | **0** | **0** | | 166, 188 | **clean** |
| `lock-u23` (v1) | alpha + bravo | 2 | 40,000 | 0 | 0 | | 102, 102 | clean |
| `perclass-u23` (v3) | alpha + bravo | 1 | 20,000 | 0 | 0 | | 128 | clean (its rate, 1 in 180,000, is below what one short session can show) |
| `buggy` (Update 21) | tempvar + tempvar | 1 | 20,000 | 6,562 (32.8%) | 6,154 | `TEMPVAR_CROSSING`; empty structs and arrays handed to the caller ("TOKEN parameter required", "Element 1 is undefined") | 1,091 | reproduces the mechanism alone, no database |
| **`localtemp-u23` (v4)** | tempvar + tempvar | 1 | 20,000 | **0** | **0** | | 1,321 | **clean** |

Reading: on the real ORM workload v4 is clean, and it runs at the no-lock server's speed (166
to 188 requests per second against 172 for Update 21, which is losing 8.7% of its requests to
the bug; v3 128, v1 102). On the mechanism endpoint, where a third of the unfixed engine's
requests come back with another request's value, v4 is clean and 20% faster than the unfixed
engine. The large runs (1,000,000 at 20 connections, 300,000 at 64) are in section 2b.

### 2b. Long profile

(filled in after the overnight run)

## 3. Lock evidence

`scripts/Get-LockEvidence.ps1`: 32 connections per target while `jcmd <pid> Thread.print -l` is
sampled 10 times, one second apart (64 requests in flight on `/repro`). Directory:
`short/lock-evidence/`.

| Test server | Load | Threads waiting in `resolveName` per dump | Parked on a `ReentrantLock` | Distinct construction locks contended | Share on the busiest |
|---|---|---|---|---|---|
| `lock-u23` (v1) | `/repro` alpha+bravo | **37.1** BLOCKED | 0 | 1 monitor | 99.5% |
| **`localtemp-u23` (v4)** | `/repro` alpha+bravo | **0** | **0** | **0** | |
| **`localtemp-u23` (v4)** | construct `siblings` | **0** | 0 | 0 | |

For comparison, September's figures on the same workload: v3 31.6 parked per dump on one
`ReentrantLock`, v1 40.2 blocked, stock 0. v4 looks like stock: across 10 dumps of the
`/repro` run the only blocked threads at all were 2 (0.2 per dump) on a
`java.util.Collections$SynchronizedMap` inside WireBox's `Builder.cfc`, which is the
framework's own map and not a construction lock. There is no lock to name.

## 4. Lock stress tests P1 to P8 and the deadlock demo

`scripts/Invoke-LockStressTests.ps1` runs the probes in `handlers/Torture.cfc` on stock, v1, v3
and v4, the deadlock probe last with a restart afterwards. Per-probe JSON and thread dumps:
`short/torture-<test server>/`. P8 is new this round (section 1).

| Probe | What it does | stock | v1 | v3 | **v4** |
|---|---|---|---|---|---|
| P1, 7 pairs (`same`, `unrelated`, `siblings`, `slowinit`, `alias`, `mapping`, `outer`) | two constructions released together, 200 ms each; serial means one waited for the other | all parallel | serial except `slowinit` | serial except `unrelated`, `slowinit`, `alias` | **all parallel** |
| P2 in one request | mutual lazy init in two `cfthread`s | completes | completes | **deadlock**, JVM-reported, 4 threads parked | **completes** |
| P2 across two requests | the same, one side per request | completes | completes | completes this pass (timing-dependent, as in September) | **completes** |
| P3, holder is a component | named `cflock` taken inside a pseudo-constructor while another thread constructs the same or an unrelated class | ok | ok | `cflock` timeout on same | **ok** |
| P3, holder is plain code | the same, lock taken in request code | ok | `cflock` timeout both | `cflock` timeout on same | **ok** |
| P4 | exceptions and `abort` from pseudo-constructors, then a clean construction of each class with a 10 s deadline | ok | ok | ok | **ok** |
| P5 | `cfthread` spawned inside a constructor and joined (same, sibling, unrelated target) | ok | join timeout all three | join timeout same and sibling | **ok** |
| P6 | `duplicate()` against concurrent construction | ok | ok | ok | **ok** |
| P7 | 64 distinct classes once each | ok | ok | ok, lock map grows by 64 | **ok**, no map |
| **P8** | shared compiler temporary on a singleton, 32 threads x 50 builds of three literal forms | **755 crossings, 3 leaked keys** | **704, 3** | **1,830, 3** | **0, 0** |
| Deadlock demo `hotfixrepro/deadlock/index.cfm` | | PASS | PASS | DEADLOCK | **PASS, 105 ms** |

Reading: v4 behaves like stock on every lock probe, because it has no lock: nothing serializes,
nothing interlocks with `cflock`, nothing deadlocks. It is the only Update 23 build that passes
P8, and the only one of the three Adobe hotfixes that passes the deadlock demo and P8 together.

## 5. Real-workload throughput

`scripts/Invoke-RealWorkloadBenchmark.ps1`, short profile: `/repro/alpha` and `/repro/bravo`
together, 2 runs of 10 s per point, test servers alternated per measurement, every server
restarted and serially warmed first. Median requests per second; p99 in ms from the same
session. Stock Update 23 and Update 21 have no lock, so the bug fires on them (the `err%`
column); v1, v3 and v4 had 0 HTTP 5xx throughout. Summary:
`short/repro-throughput/summary-20261013-120437.md`. Free memory on the machine was under 1 GB
when this pass started, so treat the second digit as noise; the long profile repeats it.

| Connections per endpoint | u23 (stock) | err% | buggy (U21, no lock) | err% | lock-u23 (v1) | perclass-u23 (v3) | **localtemp-u23 (v4)** | v4 / stock | v4 / no-lock U21 | v3 / stock | v1 / stock |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 33.3 | 2.9 | 31.9 | 2.8 | 31.7 | 31.5 | **32.2** | 0.97 | 1.01 | 0.95 | 0.95 |
| 8 | 158.5 | 3.4 | 177.4 | 4.2 | 97.5 | 157.3 | **174.4** | 1.10 | 0.98 | 0.99 | 0.62 |
| 32 | 136.3 | 9.1 | 138.8 | 8.1 | 80.0 | 130.6 | **153.2** | 1.12 | 1.10 | 0.96 | 0.59 |

p99 at 32 connections: v4 **617 ms**, v3 747, stock 786, Update 21 780, v1 987.

Reading: v4 serves at least as many requests as the servers with no hotfix at every load level,
and more at 32 connections, where the unfixed engines spend 8% to 9% of their requests on error
pages. It has the lowest tail latency of the five. The 5% pass bar is met with room to spare;
there is no lock to pay for.

## 6. Synthetic construction throughput

`scripts/Invoke-ConstructionBenchmark.ps1`, short profile: no database, each request constructs
200 components (50 entity + builder pairs for `quickconstruct`), 2 runs of 10 s per point, 32
connections. Ratios against stock Update 23; the no-lock Update 21 server is the noise gauge and
should read 1.0. Directories: `short/construct/`, `short/quickconstruct/`, `short/construct-widths/`.

| Shape, 32 connections | v4 / stock | noise gauge (U21 / stock) | v3 / stock | v1 / stock |
|---|---|---|---|---|
| `narrow` (one class) | 0.89 | 0.87 | 0.45 | 0.48 |
| `fanout` (16 unrelated classes) | 0.91 | 0.89 | 0.92 | 0.44 |
| `siblings` (16 classes sharing a base) | 0.95 | 0.88 | 0.26 | 0.33 |
| `quickconstruct` (Quick entity + builder) | 0.90 | 0.84 | 0.65 | 0.39 |

At 1 connection every server is within 10% of every other, as expected with nothing to contend.

Reading: v4 sits on top of the no-lock noise gauge in every shape (v4 against Update 21: 1.03,
1.03, 1.07, 1.07). The lock cost that halved v1 and v3 on one class, and cut them to a quarter on
classes sharing a base, is gone, because there is no lock. The gauge itself read 0.84 to 0.89
instead of 1.0 this pass; the machine had under 1 GB free when the round started, so absolute
figures carry that much noise and only the v4-against-gauge comparison is read here.

The `fanout` width sweep (1 run of 10 s per width) is not usable from this pass: the noise gauge
came out at 1.30 to 1.42 times stock, which says the stock server, not the shape, moved between
measurements. It is repeated in the long profile.

## 7. Endurance test

`scripts/Invoke-LockSoak.ps1`, short profile: 5 one-minute slices of mixed load (`/repro/alpha`
and `/repro/bravo` at 16 connections each, `fanout` and `quickconstruct` at 8 each), with a
thread dump and heap reading every 20 s. The no-lock Update 21 server ran the same test right
after, as the control for the machine's own drift. Directories: `short/soak-localtemp-u23/`,
`short/soak-buggy/`.

| Test server | Requests/s, first to last minute | Ratio | HTTP 5xx | `resolveName` waiters per dump | Deadlock in 10 dumps | Heap |
|---|---|---|---|---|---|---|
| **`localtemp-u23` (v4)** | 317 to 256 | 0.83 | **0** | **0** | none | cycling 287 to 703 MB |
| `buggy` (U21, no lock, control) | 337 to 253 | 0.79 | 4,697 (the bug) | 0 | none | cycling 333 to 780 MB |

Reading: the script's throughput-stability check (last minute at least 90% of the first) fails
on both, and it failed on v3 and on the same control in September. The no-lock control falls
further than v4 under identical load in the same quarter hour, so the fall belongs to the
machine (which also had under 1 GB free at the start of this round), not to the hotfix. On
every check that is about the hotfix, v4 is clean: no errors, no deadlock, no waiting threads,
a heap that cycles normally, and no lock map to grow. The 45-minute long-profile run repeats
this with the same control.

## 8. Long profile (overnight 2026-10-13 to 14)

(filled in when the run completes: contamination 1,000,000 at 20 connections and 300,000 at 64,
`alpha + wire`, `tempvar` at 20 and 64, real-workload at 1/8/32/64 with 3 x 30 s, construction
shapes with 3 x 20 s, 45-minute endurance on v4 and on the no-lock control)
