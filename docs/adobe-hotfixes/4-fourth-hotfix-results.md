# Adobe's fourth hotfix (`hf202300-4232227-adobe-v4.jar`): test results

Date: 2026-10-13, confirmed by a second full run on 2026-10-14 (section 9). Static analysis and
the predictions made before any run are in
[4-fourth-hotfix-static-analysis.md](4-fourth-hotfix-static-analysis.md). Raw output for every
table is under `benchmark-results-u23/adobe-v4/` (gitignored; the directory is named in each
section). The startup crash on a freshly started server is a separate issue, filed with Adobe on
its own; every session here restarts its server, waits until it answers, sends serial warm-up
requests, and only then applies concurrent load.

## Verdict

**v4 fixes the contamination at its cause, with no lock, and costs nothing on the real
workload.** Short profile and long profile on 2026-10-13 (sections 1 to 8), **confirmed by a
second full run** on freshly started test servers on 2026-10-14 (section 9): every line of the
pass bar held again. The first run's one open item is resolved. One long-profile sweep had v4 at
0.6 to 0.9 of stock on the three database-free plain-construct shapes; in the second run that
deficit came and went on the same processes within an hour, moved from shape to shape, and
appeared at the same size on stock, which has no hotfix. It is per-process variation of those
shapes, not the hotfix (section 9a).

1. **The cause is named and removed.** The crossing object the August probe caught in WireBox's
   `Builder.buildCFC` is a struct literal inside a ternary expression. The compiler never
   declared the temporary it uses for such a literal, so it was written to the singleton's
   `variables` scope, shared by every concurrent request. v4 keeps it in the function's local
   scope. Three new probes show the leak on every earlier build (about half of all builds come
   back carrying another thread's value; stock, v1 and v3 alike) and never on v4 (section 1).
2. **No contamination.** 0 in 1,300,000 real-workload requests across 13 fresh, warmed JVMs at
   20 and 64 connections per endpoint, and 0 in 240,000 on the probe endpoints where Update 21
   fails a third of its requests (sections 2 and 8a). The same afternoon, on the same machine,
   v1 leaked 1 in 100,000 and v3 6 in 200,000, and the unfixed engines 6.7% to 10.9%. The
   second run repeated all of it: 0 in another 1,540,000 on v4, v1 again 1 in 100,000, the
   unfixed engines 7.9% to 12.1% (section 9d).
3. **No lock.** 0 threads waiting in `resolveName` under 64 in flight (v1 the same hour: 37
   per dump); every lock stress test identical to stock; the third hotfix's deadlock demo passes
   in 105 ms, and P8 passes (sections 3 and 4).
4. **No cost.** Real workload at or above the servers with no hotfix at every load level and
   the lowest p99 of the five at 32 connections (v3 was 0.76 to 0.82 of stock, v1 0.44 to 0.53).
   Database-free construction within noise of the no-lock server on every shape, where v1 and
   v3 lost half to three quarters (sections 5 and 6); those shapes move by 30% to 40% between
   sweeps on servers with no hotfix too (section 9a).
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

In section 8a (first run) and section 9d (second run).

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

## 8. Long profile (2026-10-13, 12:45 onwards)

`scripts/Invoke-ScopeContaminationRound.ps1 -NewHotfixServer localtemp-u23`, then the
45-minute endurance tests. Dropbox stopped for the whole run, Backblaze paused. Raw results:
`benchmark-results-u23/adobe-v4/scope-round/` and `long/`.

### 8a. Contamination, 1,300,000 requests on v4

Every session restarts its server, waits until it answers, sends 500 serial requests, then
bursts. Same machine, same afternoon, for every row.

| Test server | Endpoints | Connections per endpoint | Sessions | Requests | Contaminated requests | Rate | Requests/s |
|---|---|---|---|---|---|---|---|
| **`localtemp-u23` (v4)** | alpha + bravo | 20 | 10 | **1,000,000** | **0** | | 162 to 203 |
| **`localtemp-u23` (v4)** | alpha + bravo | 64 | 3 | **300,000** | **0** | | 140 to 151 |
| **`localtemp-u23` (v4)** | alpha + wire | 20 | 1 | 40,000 | **0** | | 531 |
| **`localtemp-u23` (v4)** | tempvar + tempvar | 20 | 1 | 100,000 | **0** | | 1,112 |
| **`localtemp-u23` (v4)** | tempvar + tempvar | 64 | 1 | 100,000 | **0** | | 1,150 |
| `lock-u23` (v1, global lock) | alpha + bravo | 20 | 1 | 100,000 | 1 (a wrong-table `UPDATE`) | 1 in 100,000 | 108 |
| `perclass-u23` (v3, per-class locks) | alpha + bravo | 20 | 2 | 200,000 | 6 (4 wrong-table `UPDATE`s, 2 relationship setters on a query builder) | 1 in 33,000 | 154, 160 |
| `u23` (stock Update 23) | alpha + bravo | 20 | 2 | 40,000 | 2,665 | 6.7% | 212, 214 |
| `buggy` (Update 21) | alpha + bravo | 20 | 2 | 40,000 | 2,733 | 6.8% | 207, 214 |
| `buggy` (Update 21) | alpha + bravo | 64 | 1 | 20,000 | 2,181 | 10.9% | 182 |
| `buggy` (Update 21) | tempvar + tempvar | 20 | 1 | 20,000 | 8,009 | 40% | 1,290 |

Reading:

- **v4 is clean in 1,540,000 requests**, 1,300,000 of them on the production ORM path at normal
  and heavy load. Zero in 1,300,000 rules out any rate above about 1 in 430,000 (95%), which is
  far below what v1 and v3 showed the same afternoon.
- **v1 leaked today.** Its one failure is the production symptom: an `UPDATE` compiled against
  the wrong table. September's 0 in 550,000 was the other side of the coin (it also leaked once
  in 20,000 in August). The global lock narrows the window but does not close it, because the
  shared slot is written outside the locked region.
- **v3 leaked 6 in 200,000**, a worse rate than September's 5 in 900,000, with the same
  signatures.
- The unfixed engines are at their usual 6.7% to 6.8% at 20 connections and 10.9% at 64; on
  the mechanism endpoint Update 21 fails 40% of requests.

### 8b. Real-workload and construction throughput, 3 runs per point

**Real workload** (`/repro/alpha` + `/repro/bravo`, 3 runs of 30 s per point, servers alternated
per measurement, each restarted and warmed with 300 serial requests first). Median requests per
second; a server losing more than 10% of its requests to the bug is marked invalid and its raw
runs are quoted instead. Summary: `scope-round/repro-throughput/summary-20261013-165052.md`.

| Connections per endpoint | u23 (stock) | err% | buggy (U21, no lock) | err% | lock-u23 (v1) | perclass-u23 (v3) | **localtemp-u23 (v4)** | p99 v4 | p99 stock | p99 v1 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 36.4 | 3.0 | 41.0 | 2.2 | 35.1 | 29.9 | 28.3 | 113 ms | 73 ms | 77 ms |
| 8 | 186.8 | 5.7 | 179.8 | 4.9 | 99.9 | 181.9 | **196.9** | 132 ms | 147 ms | 234 ms |
| 32 | invalid (10.6% failing; runs 159, 158, 173) | 10.6 | 172.0 | 9.0 | 91.2 | 150.9 | **172.0** | 592 ms | 672 ms | 899 ms |
| 64 | invalid (10.8%; runs 176, 169, 180) | 10.8 | invalid (10.6%; runs 177, 166, 169) | 10.6 | 88.5 | 141.8 | **176.8** | 1,223 ms | 1,150 ms | 1,710 ms |

Raw runs at 32 connections: v4 166 / 172 / 183, Update 21 172 / 157 / 175, stock 159 / 158 / 173.
At 64: v4 182 / 149 / 177, stock 176 / 169 / 180, Update 21 177 / 166 / 169.

Reading:

- **From 8 connections up, v4 serves as many requests as the servers with no hotfix, or more,
  with 0 failures where they lose 5% to 11% to the bug**: 1.05 times stock at 8, level with the
  no-lock server at 32 and 64. v1 is at 0.5; v3 at 0.8 to 0.97. The 5% pass bar is met.
- **The 1-connection row is machine drift, not the hotfix.** At one connection throughput is
  pure latency, and every server's three runs there swing by up to two to one (stock 36 / 43 /
  25, v1 35 / 41 / 20, v3 43 / 29 / 30, v4 38 / 28 / 21). v4 was measured last in each round and
  its later runs fell in a slow period; its first run equals stock's. The short profile the same
  morning had v4 at 0.97 of stock at one connection, and nothing can contend there.

**Database-free construction** (3 runs of 20 s per point, 32 and 64 connections; the no-lock
Update 21 server is the noise gauge). Summaries: `scope-round/construct/summary-20261013-173938.md`,
`scope-round/quickconstruct/summary-20261013-175554.md`.

| Shape | v4 / stock at 32, 64 | gauge (U21 / stock) | v1 / stock | v3 / stock |
|---|---|---|---|---|
| `quickconstruct` (Quick entity + builder, the ORM path) | **0.90, 1.00** | 0.84, 0.95 | 0.37, 0.29 | 0.64, 0.51 |
| `narrow` (one class) | 0.71, 0.91 | 1.08, 0.94 | 0.43, 0.53 | 0.46, 0.55 |
| `fanout` (16 unrelated classes) | 0.62, 0.76 | 1.01, 1.06 | 0.45, 0.54 | 1.01, 1.00 |
| `siblings` (16 classes sharing a base) | 0.76, 0.83 | 1.06, 0.99 | 0.33, 0.41 | 0.27, 0.35 |

Reading:

- On the ORM construction path, `quickconstruct`, v4 sits on the no-lock gauge at every load
  level (1.06 of stock at one connection, 0.90 at 32, 1.00 at 64), as it did in the short
  profile. v1 is at a third, v3 at half to two thirds.
- **The three plain-construct shapes show a deficit for v4 in this one sweep that the evidence
  does not explain**: 0.62 to 0.91 of stock with the gauge at 1.0, steady across all three runs of
  every point, including one connection, where nothing contends. The same shapes on the same
  JVM the same morning (section 6) had v4 on the gauge (0.89 to 0.95 against 0.84 to 0.89), and
  `quickconstruct`, measured on the same JVM immediately after this sweep, shows no deficit. The
  five JVMs' launch lines, heap state, JIT code-cache state, residency and CPU time were compared
  during the sweep and are alike; the probe models contain nothing on the path the fix changes
  (their only literals are plain statements, which the compiler already declares as locals). A
  re-measurement on freshly restarted JVMs with v4 first in the order was started at 19:27 and
  stopped by the machine's memory guard before it produced numbers. **Resolved by the second
  run (section 9a):** the deficit is per-process variation of these database-free shapes, which
  hits servers with no hotfix just as hard; the figures above stand as that set of processes.

### 8c. Endurance, 45 minutes, v4 and the no-lock control

`scripts/Invoke-LockSoak.ps1 -Profile long`: 9 five-minute slices of mixed load (`/repro/alpha`
and `/repro/bravo` at 16 connections each, `fanout` and `quickconstruct` at 8 each), a thread
dump and heap reading every 60 s, v4 first and the no-lock Update 21 server straight after.
Directories: `long/soak-localtemp-u23/`, `long/soak-buggy/`.

| Test server | Requests | Requests/s, slice 1 to 9 | HTTP 5xx | `resolveName` waiters per dump | Deadlock in 36 dumps | Heap |
|---|---|---|---|---|---|---|
| **`localtemp-u23` (v4)** | 480,396 | 292, 218, 189, 175, 181, 169, 171, 177, 177 | **0** | **0** | none | cycling 333 to 778 MB |
| `buggy` (U21, no lock, control) | 480,270 | 293, 214, 196, 179, 175, 175, 175, 177, 167 | 36,969 (7.7%, the bug) | 0 | none | cycling 301 to 774 MB |

Reading: the two curves are the same, slice for slice, on a server with the hotfix and on one
with nothing, so the fall over the first 15 minutes is the machine's (the same drift the
September runs saw), not the hotfix's. On every check the hotfix can influence, v4 is clean over
45 minutes and 480,000 requests: no errors, no deadlock, no waiting threads, a cycling heap.

## 9. Second run (2026-10-14)

An independent repeat of the whole set of tests on the same jar, started after midnight on
2026-10-14 on freshly started test servers: the open item from section 8b first, then the short
profile, then the long profile. Same machine, same four test servers (`u23`, `lock-u23`,
`buggy`, `localtemp-u23`); the third hotfix's server was left out, as were Lucee and BoxLang.
Raw output for every table is under `benchmark-results-u23/adobe-v4-run2/` (the folder for each
table is named under it). The pre-flight passed before anything ran: every test server loaded
the classes its row in the test server table says, the v4 jar's SHA256 starts `9d17ad33`, Quick's
`BaseEntity.cfc` starts `54c3fdd6`, v4 reported `function-local` literal temporaries and no
lock, and the other three reported `shared-variables` (`identity/`).

Two script changes were needed to run this as specified, and are committed with this section:
the test server list now keeps the order it is given in (before, every script measured the
servers in table order, so "v4 first" and "v4 last" were the same run), and the long-profile
round leaves out the third hotfix's server unless `-IncludeThirdHotfix` is passed.

### 9a. The open item: plain-construct shapes on fresh JVMs

Run one's long-profile sweep had v4 at 0.62 to 0.91 of stock on the three database-free shapes
with the Update 21 gauge at 1.0 (section 8b). Run two measured the same shapes three times on
one set of freshly started JVMs: v4 first in the order, then quickconstruct, then the same sweep
with the order reversed. 3 runs of 20 s per point, 10 s warm-up, Dropbox stopped. The figure is
v4 divided by the no-lock Update 21 gauge measured in the same sweep, at 1 / 32 / 64
connections; 1.00 means v4 is on the gauge.

| Shape | Run one, long profile (v4 last) | Run two, v4 first (00:27) | Run two, v4 last (01:20) | Run two, short profile (03:07) |
|---|---|---|---|---|
| `narrow` | 0.68 / 0.65 / 0.96 | 0.96 / 1.01 / 0.95 | 1.10 / 1.04 / 0.95 | 0.91 / 0.88 / n/a |
| `fanout` | 0.72 / 0.61 / 0.72 | 0.97 / **0.75 / 0.79** | 1.00 / 1.13 / 1.02 | 0.92 / 0.93 / n/a |
| `siblings` | 0.77 / 0.72 / 0.84 | 0.78 / **1.43 / 1.29** | 1.01 / 0.98 / 1.07 | 0.93 / 0.89 / n/a |
| `quickconstruct` (v4 / stock) | 1.07 / 0.90 / 1.00 | 0.98 / 0.96 / 0.92 | | 1.03 / 1.02 / n/a |

Raw: `open-item/construct-v4-first/`, `open-item/construct-v4-last/`,
`open-item/quickconstruct-v4-first/`, `short/construct/`, `short/quickconstruct/`; run one
`adobe-v4/scope-round/construct/`.

The servers with no hotfix moved just as much in the same hour, on the same processes:

| Same JVM, same shape, 32 connections | v4 first (00:27) | v4 last (01:20) |
|---|---|---|
| Update 21 gauge, `fanout` | 913 requests/s | 606 requests/s |
| stock, `siblings` | 658 | 921 |
| v4, `siblings` | 935 | 868 |
| v4, `fanout` | 681 | 686 |

At one connection, single 20 s runs on one process flip between two speeds about a factor of
two apart, on stock and on v4 alike (stock `siblings` 49 / 89 / 87, v4 `siblings` 41 / 41 / 92).
The short profile's width test, run minutes after that short sweep, put v4 at 1.53 to
1.60 times stock and 1.39 to 1.47 times the gauge on `fanout`.

**Profile.** Java Flight Recorder, 60 s of `narrow` at 32 connections, one test server under load
at a time, on the same JVMs right after the reversed sweep (`jfr/`; `*.views.txt` holds the hot
methods, CPU load, GC pauses, deoptimizations and lock contention of each recording):

| Recording | Requests/s under the recorder | Machine CPU | Hot methods |
|---|---|---|---|
| stock, 01:59 | 616 | 73% | date parsing and hashing under CacheBox's eviction sort (below) |
| v4, 02:00 | **296** | **93%** | the same path, but with `FastArray.addElement` and `StructSort` on top |
| Update 21, 02:01 | 733 | not recorded | the same path as stock |
| v4 again, 02:21 | 463 | 88% | the same as stock, line for line |
| stock again, 02:22 | 523 | 85% | the same as the first stock recording |

Without the recorder, between the two pairs: stock 876 and 697, v4 858 and 665, Update 21 932
and 794 (two alternating rounds of 20 s, `open-item/cookie-ab-samejvm/`). No recording shows a
lock: no thread waiting in `resolveName`, no construction monitor, the same handful of
deoptimizations on every server, and GC pauses of 1 to 2.6 s per minute everywhere. The one slow
v4 recording ran while Dropbox, restarted by the benchmark script at 01:58:57, was starting up
and the machine was at 93% CPU; ten minutes later the same v4 process profiled like stock.

The recordings also show what these shapes spend their time on. On every server 35% to 63% of
CPU samples are in ColdBox, not in construction: with `sessionManagement` off, ColdBox keeps the
flash scope in CacheBox, the load tool sends no cookies, so every request saves a new flash key
into a cache that is full at 300 objects, and every save runs CacheBox's LRU eviction, which
sorts all the cache's keys by date. That code is identical on every test server, and sending a
fixed `CFID`/`CFTOKEN` cookie did not change any server's throughput, so it does not favour one
server, but it makes the database-free shapes a measurement of framework housekeeping as much as
of construction, which is why they move by 30% to 40% between sweeps on servers with no hotfix.

**Resolution.** The deficit is not real and not order dependent. On fresh JVMs with v4 first, one
shape (`fanout`) came in below the gauge, another (`siblings`) came in 43% above it, and the
third on it; an hour later on the same processes, in the reversed order, all three were on it,
while the no-hotfix servers moved by up to 40% on single shapes. Run one's long-profile sweep was
v4 last and showed the deficit; run two's reversed sweep was v4 last and did not. It is
process-instance and time-dependent variation of these database-free shapes, which hits every
server, and run one's 17:39 sweep (section 8b) stands as that process instance's figure. The
re-measurement started at 19:27 on 2026-10-13 never produced numbers (the memory guard stopped it
during the restart), so there are none to record from it. On the ORM construction path,
quickconstruct, v4 was at 0.90 of stock or better in every sweep of both runs.

### 9b. The mechanism

**Standalone demo** (`hotfixrepro/scopeleak/index.cfm`, 32 threads x 100 builds of each of three
literal forms, one shared instance). Builds that came back carrying another thread's token, of
3,200 per form, as struct / array / `invoke()` argument, then errors and leaked keys after one
single-threaded build. Run one did not run it on stock.

| Run | stock | v1 | v4 | Update 21 |
|---|---|---|---|---|
| One (2026-10-13) | not run | 1,772 / 1,580 / 1,590; 182 errors; 1 key; FAIL | **0 / 0 / 0; 0; 0; PASS** | 1,757 / 1,544 / 1,554; 176 errors; 1 key; FAIL |
| Two (2026-10-14, 08:53) | 1,631 / 1,497 / 1,420; 242 errors; 1 key; FAIL | 1,623 / 1,441 / 1,413; 246 errors; 1 key; FAIL | **0 / 0 / 0; 0; 0; PASS** | 1,641 / 1,444 / 1,359; 282 errors; 1 key; FAIL |

Raw: `demos/scopeleak-<test server>.html`.

**P8 inside the application** (`/torture/p8`, 32 threads x 50 builds on a WireBox singleton):
crossings of 4,800 builds, and leaked keys.

| Run | stock | v1 | v4 | Update 21 |
|---|---|---|---|---|
| One | 755, 3 | 704, 3 | **0, 0** | 794, 3 |
| Two | 982, 3 | 609, 3 | **0, 0** | 784, 3 |

Raw: `short/torture-<test server>/`, `demos/p8-buggy.json`.

### 9c. Contamination test, short profile

Every session ran on a server that had been restarted, answered `/benchmark/engine` and taken
serial warm-up requests before the burst (the known-bad and `tempvar` checks run right after the
test run's own restart and 100 serial requests). HTTP 5xx of requests sent; requests per second
in brackets. The short profile does not run stock.

| Run | Endpoints | stock | v1 | v4 | Update 21 |
|---|---|---|---|---|---|
| One | alpha + bravo | not run | 0 of 40,000 (102, 102) | **0 of 40,000** (166, 188) | 1,732 of 20,000, 8.7% (172) |
| Two | alpha + bravo | not run | 0 of 40,000 (66, 68) | **0 of 40,000** (155, 155) | 1,749 of 20,000, 8.7% (146) |
| One | tempvar + tempvar | | | **0 of 20,000** (1,321) | 6,562 of 20,000, 32.8% (1,091) |
| Two | tempvar + tempvar | | | **0 of 20,000** (1,214) | 6,824 of 20,000, 34.1% (1,109) |

Raw: `short/contamination test-<test server>-<label>/`. The known-bad check's signatures in run
two: 1,450 `TABLE_NAME_CONTAMINATION`, 299 `VARIABLES_SCOPE_CORRUPTION`.

### 9d. Contamination test, long profile

`Invoke-ScopeContaminationRound.ps1`, every session restarting its server, waiting for it to
answer, sending 500 serial requests, then bursting. Contaminated requests (HTTP 5xx) of requests
sent.

| Run | Test | stock | v1 | v4 | Update 21 |
|---|---|---|---|---|---|
| One | alpha + bravo, 20 conns | 2,665 of 40,000, 6.7% | 1 of 100,000 (wrong-table `UPDATE`) | **0 of 1,000,000** (10 sessions) | 2,733 of 40,000, 6.8% |
| Two | alpha + bravo, 20 conns | 3,176 of 40,000, 7.9% | 1 of 100,000 (wrong-table query) | **0 of 1,000,000** (10 sessions) | 3,175 of 40,000, 7.9% |
| One | alpha + bravo, 64 conns | | | **0 of 300,000** | 2,181 of 20,000, 10.9% |
| Two | alpha + bravo, 64 conns | | | **0 of 300,000** | 2,423 of 20,000, 12.1% |
| One | alpha + wire, 20 conns | | | **0 of 40,000** | |
| Two | alpha + wire, 20 conns | | | **0 of 40,000** | |
| One | tempvar, 20 and 64 conns | | | **0 of 200,000** | 8,009 of 20,000, 40% (20 conns) |
| Two | tempvar, 20 and 64 conns | | | **0 of 200,000** | 6,705 of 20,000, 33.5% (20 conns) |

Raw: `scope-round/contam-<test server>-<label>/`. v4's sessions ran at 144 to 154 requests per
second at 20 connections and 134 to 143 at 64 (run one: 162 to 203 and 140 to 151). Every server
was about a quarter slower in absolute terms in run two, the unfixed engines included. v1's one
failure in run two is the production symptom again: a query for an `alpha_child` entity compiled
against the other entity's table (`Invalid column name 'alpha_parent_id'`).

Across both runs v4 is clean in 3,080,000 warmed requests, 2,600,000 of them on the real
workload. Zero in 2,600,000 rules out any rate above about 1 in 870,000 (95%).

### 9e. Lock evidence

32 connections per target, 10 thread dumps one second apart. Threads waiting in
`TemplateProxyFactory.resolveName` per dump. Stock and Update 21 are not part of this test
(September: 0).

| Run | Load | stock | v1 | v4 | Update 21 |
|---|---|---|---|---|---|
| One | `/repro` alpha + bravo | | 37.1, one monitor, 99.5% | **0** | |
| Two | `/repro` alpha + bravo | | 51.1, one monitor, 99.8% | **0** | |
| One | construct `siblings` | | | **0** | |
| Two | construct `siblings` | | | **0** | |

Raw: `short/lock-evidence/`. The only blocked threads on v4 in run two (0.8 per dump during
`siblings`) were waiting on a `cflock` (`coldfusion.runtime.RWLock`, which CacheBox takes) and on
ColdFusion's locale manager class, not on construction.

### 9f. Lock stress tests and the deadlock demo

Both runs gave the same verdict on every probe. Where a count differs, both are shown as
"run one; run two". Update 21 is not part of the stress tests apart from P8 (section 9b).

| Probe | stock | v1 | v4 |
|---|---|---|---|
| P1, 7 pairs | all parallel | serial except `slowinit` | **all parallel** |
| P2 in one request, and across two | completes | completes | **completes** |
| P3, holder is a component | ok | ok | **ok** |
| P3, holder is plain code | ok | `cflock` timeout both | **ok** |
| P4 | ok | ok | **ok** |
| P5 | ok | join timeout all three | **ok** |
| P6, P7 | ok | ok | **ok** |
| P8 crossings | 755; 982 | 704; 609 | **0; 0** |
| Deadlock demo | PASS; PASS in 101 ms | PASS; PASS in 201 ms | **PASS in 105 ms; PASS in 101 ms** |

Raw: `short/torture-<test server>/`, `demos/deadlock-<test server>.html`.

### 9g. Real-workload throughput

Median requests per second for `/repro/alpha` + `/repro/bravo`, servers alternated per
measurement, each restarted and serially warmed first. A server losing more than 10% of its
requests to the bug is marked invalid and its raw runs are given. The last column counts only
stock's successful requests, which is how the pass bar is defined (for an invalid stock row, the
median of its raw runs).

**Short profile** (2 runs of 10 s per point; raw `short/repro-throughput/`):

| Run | Conns | stock (err%) | v1 | v4 | Update 21 (err%) | v4 / stock, successful only |
|---|---|---|---|---|---|---|
| One | 1 | 33.3 (2.9) | 31.7 | 32.2 | 31.9 (2.8) | 1.00 |
| Two | 1 | 22.4 (7.5) | 22.0 | 21.9 | 22.0 (4.7) | 1.06 |
| One | 8 | 158.5 (3.4) | 97.5 | 174.4 | 177.4 (4.2) | 1.14 |
| Two | 8 | 169.0 (6.3) | 80.7 | 165.4 | 161.8 (4.9) | 1.04 |
| One | 32 | 136.3 (9.1) | 80.0 | 153.2 | 138.8 (8.1) | 1.24 |
| Two | 32 | invalid, 10.2% (164, 161) | 65.8 | 163.8 | 145.6 (7.6) | 1.12 |

**Long profile** (3 runs of 30 s per point; raw `scope-round/repro-throughput/`):

| Run | Conns | stock (err%) | v1 | v4 | Update 21 (err%) | v4 / stock, successful only |
|---|---|---|---|---|---|---|
| One | 1 | 36.4 (3.0) | 35.1 | 28.3 | 41.0 (2.2) | 0.80 |
| Two | 1 | 37.9 (3.8) | 35.0 | 38.8 | 37.6 (3.1) | 1.06 |
| One | 8 | 186.8 (5.7) | 99.9 | 196.9 | 179.8 (4.9) | 1.12 |
| Two | 8 | 252.0 (3.2) | 141.1 | 236.2 | 252.3 (4.0) | 0.97 |
| One | 32 | invalid, 10.6% (159, 158, 173) | 91.2 | 172.0 | 172.0 (9.0) | 1.21 |
| Two | 32 | 197.2 (8.8) | 107.2 | 195.1 | 199.1 (9.2) | 1.09 |
| One | 64 | invalid, 10.8% (176, 169, 180) | 88.5 | 176.8 | invalid, 10.6% | 1.13 |
| Two | 64 | invalid, 10.1% (180, 181, 177) | 98.3 | 185.6 | invalid, 10.2% | 1.15 |

Reading: v4 passes the 5% bar at 8, 32 and 64 connections in both runs. The one figure that
reads lower in run two is the long profile at 8 connections: 0.94 of stock's raw rate (run one
1.05), 0.97 counting only stock's successful requests. v4's three runs there were 255, 236 and
236, and Update 21 dropped to 214 in the same middle run, so the dip is the machine's. From about
07:50 onwards, during this table's last points and everything after it, the machine was also in
use for other work. v1 is at 0.48 to 0.56 of stock, as in run one.

### 9h. Database-free construction

Ratios against stock at 32 and 64 connections (short profile: 32 only). Read with section 9a:
these shapes move by 30% to 40% between sweeps on servers with no hotfix.

| Run | Shape | v1 | v4 | Update 21 (the gauge) |
|---|---|---|---|---|
| One, short | `narrow` | 0.48 | 0.89 | 0.87 |
| Two, short | `narrow` | 0.47 | 0.92 | 1.04 |
| One, short | `fanout` | 0.44 | 0.91 | 0.89 |
| Two, short | `fanout` | 0.39 | 0.96 | 1.04 |
| One, short | `siblings` | 0.33 | 0.95 | 0.88 |
| Two, short | `siblings` | 0.25 | 0.94 | 1.05 |
| One, short | `quickconstruct` | 0.39 | 0.90 | 0.84 |
| Two, short | `quickconstruct` | 0.34 | 1.02 | 0.96 |
| One, long | `narrow` | 0.43, 0.53 | 0.71, 0.91 | 1.08, 0.94 |
| Two, long | `narrow` | 0.62, 0.74 | 0.91, 1.02 | 0.93, 1.05 |
| One, long | `fanout` | 0.45, 0.54 | 0.62, 0.76 | 1.01, 1.06 |
| Two, long | `fanout` | 0.75, 0.78 | 1.53, 1.41 | 1.55, 1.48 |
| One, long | `siblings` | 0.33, 0.41 | 0.76, 0.83 | 1.06, 0.99 |
| Two, long | `siblings` | 0.39, 0.41 | 0.69, 0.80 | 0.96, 1.01 |
| One, long | `quickconstruct` | 0.37, 0.29 | 0.90, 1.00 | 0.84, 0.95 |
| Two, long | `quickconstruct` | 0.42, 0.29 | 1.02, 1.40 | 0.99, 1.02 |

Raw: `short/construct/`, `short/quickconstruct/`, `scope-round/construct/`,
`scope-round/quickconstruct/`, width test `short/construct-widths/`.

Reading: in run two's long sweep (v4 last, as in run one, on a machine in use) v4 came in below
the gauge again, but on a different shape: `siblings` (0.72 and 0.79 of Update 21), with `narrow`
and `fanout` on the gauge. This time stock was also an outlier: on `fanout` it ran 35% slower
than both Update 21 and v4, which also made v1 look like 0.75 of stock instead of its usual 0.45.
A server with no hotfix showing a drop of the same size on one shape is the clearest sign that
this is per-process variation and not the hotfix. The width test (1 run of 10 s per width) had
v4 at 1.53 to 1.60 of stock and the gauge at 1.06 to 1.14. On the ORM construction path,
`quickconstruct`, v4 is at 0.92 of stock or better in every sweep of run two. v1 still loses a quarter to
three quarters on every shape.

### 9i. Endurance test

Mixed load (`/repro/alpha` and `/repro/bravo` at 16 connections each, `fanout` and
`quickconstruct` at 8 each), v4 first and the no-lock Update 21 server straight after. Requests
per second in the first and last slice.

**Short profile** (5 one-minute slices; raw `short/soak-<test server>/`):

| Run | v4 | Update 21 (no-lock control) |
|---|---|---|
| One | 317 to 256 (0.83); 0 HTTP 5xx; 0 waiters; no deadlock | 337 to 253 (0.79); 4,697 HTTP 5xx; 0 waiters; no deadlock |
| Two | 271 to 212 (0.78); 0 HTTP 5xx; 0 waiters; no deadlock | 261 to 215 (0.82); 3,549 HTTP 5xx; 0 waiters; no deadlock |

**Long profile** (9 five-minute slices, a thread dump and heap reading every 60 s; raw
`long/soak-<test server>/`):

| Run | v4 | Update 21 (no-lock control) |
|---|---|---|
| One | 480,396 requests; 292 to 177 (0.61); **0 HTTP 5xx**; 0 waiters; no deadlock in 36 dumps; heap cycling 333 to 778 MB | 480,270 requests; 293 to 167 (0.57); 36,969 HTTP 5xx (7.7%); 0 waiters; no deadlock; heap cycling 301 to 774 MB |
| Two | 441,000 requests; 267 to 154 (0.58); **0 HTTP 5xx**; 0 waiters; no deadlock in 36 dumps; heap cycling 342 to 827 MB | 396,841 requests; 258 to 136 (0.53); 18,576 HTTP 5xx (4.7%); 0 waiters; no deadlock; heap cycling 273 to 723 MB |

Slice by slice in run two, v4: 267, 205, 182, 172, 178, 152, 179, 162, 154; the control: 258,
210, 163, 152, 148, 149, 146, 152, 136.

Reading: the same curve as run one on both servers, and v4 at or above the no-lock control in
eight of nine slices, so the fall over the first 15 minutes is again the machine's and the pass
bar ("no worse than the no-lock control") holds. The whole long endurance pair ran while the
machine was in use for other work (08:53 to 10:25), which is why both servers' absolute figures
are lower than in run one.

### 9j. The pass bar, both runs

| Line of the pass bar (static analysis) | Run one | Run two |
|---|---|---|
| 0 contaminated in at least 1,000,000 warmed requests | pass, 0 in 1,540,000 | pass, 0 in 1,540,000 |
| Real workload within 5% of stock at 8, 32 and 64 connections | pass | pass (0.97, 1.09, 1.15 counting stock's successful requests) |
| Plain-construct shapes within noise of the Update 21 gauge | open item | pass: the variation hits servers with no hotfix just as hard (9a) |
| 0 threads waiting in `resolveName` | pass | pass |
| P1 to P8 identical to stock, P2 completes, deadlock demo passes | pass | pass |
| Endurance curve no worse than the no-lock control | pass | pass |
