# Testing guide

How the test servers are set up, what each test measures, and how to run them. For the results,
see [docs/README.md](../README.md).

## The contamination test

`scripts/Test-Contamination.ps1` is the only test that decides correctness. It drives two
`/repro` endpoints at the same time and counts HTTP 5xx, transport errors, the classified counter
from `/repro/status`, and new lines in `logs/contamination_log.txt` and `logs/repro_errors.txt`.

| Option | What it does |
|---|---|
| `-Endpoints alpha,bravo` | The default: the two Quick entity workloads that share `BaseEntity` |
| `-Endpoints alpha,wire` or `wire,wire` | `wire` builds six unrelated WireBox components per request and checks every value; it tests whether contamination can cross between classes that share no parent (it never has) |
| `-Endpoints tempvar,tempvar` | `tempvar` asks a shared singleton to build three inline literals around the request's token, no database. It is the exact mechanism Adobe's fourth hotfix changes (a compiler temporary shared through the singleton's `variables` scope) |
| `-ColdStart` | Restarts the test server before each session, waits until it answers, and warms it with 500 single requests (`-WarmRequests` to change the count). A burst against a freshly started, un-warmed server is refused: the startup crash is a separate issue |
| `-WarmRequests N` | Sends N single requests before the concurrent load |
| `-Sessions`, `-TotalRequests`, `-Connections` | Size of the test; `-Connections` is per endpoint |
| `-OutputDir` | Pass an absolute path |

`scripts/Invoke-ScopeContaminationRound.ps1` runs the full overnight round used for the
September 2026 results: large warmed contamination tests on every test server at 20 and 64
connections per endpoint, then real-workload and construction throughput on all six. Since
October 2026 it runs stock, v1, Update 21 and the new hotfix server; add `-IncludeThirdHotfix`
for the third hotfix's server and `-IncludeOtherEngines` for Lucee 6 and BoxLang. Every script
measures the test servers in the order given to `-Servers`, so `-Servers localtemp-u23,u23`
puts the new hotfix server first.

## Test servers

The hotfix lives in the engine directory, not the application, so every comparison uses
independent ACF 2023 installs that differ only by the update level and the jar. The test servers are
defined once in `scripts/TestServers.ps1`:

| Test server | Port | Engine home | Engine | Jar in `lib/updates` (always deployed as `hf202300-4232227.jar`) | Role |
|---|---|---|---|---|---|
| `u23` | 60843 | `.engine/bench-u23` | 2023.0.23 | none | stock reference |
| `lock-u23` | 60844 | `.engine/bench-lock-u23` | 2023.0.23 | adobe-v1 | v1: the correctness bar and the rejected global-lock cost |
| `buggy` | 60845 | `.engine/bench-buggy` | 2023.0.21 | none | known-bad check; no-lock speed reference |
| `perclass-u23` | 60848 | `.engine/bench-perclass-u23` | 2023.0.23 | adobe-v3 | v3: per-class locks, rejected in September 2026; opt-in since October (`-Servers perclass-u23`) |
| `localtemp-u23` | 60852 | `.engine/bench-localtemp-u23` | 2023.0.23 | adobe-v4 | v4: no lock, compiler temporaries kept in the function local scope; the new hotfix server |
| `lucee6` | 60850 | `.engine/bench-lucee6` | Lucee 6 | none | no contamination bug; cross-engine performance reference |
| `boxlang` | 60851 | `.engine/bench-boxlang` | BoxLang 1 + bx-compat-cfml | none | no contamination bug; cross-engine performance reference (needs Java 21) |
| `concmap-u23` | 60849 | `.engine/bench-concmap-u23` | 2023.0.23 | concmap-v1 (ours) | opt-in calibration for the fresh-start contamination test; `-Servers concmap-u23` |

Lucee 6 and BoxLang do not have the bug ([docs/root-cause/how-lucee-and-boxlang-avoid-it.md](../root-cause/how-lucee-and-boxlang-avoid-it.md)),
so they show what the same application costs on an engine that never needed a construction
lock. They are compared as engines, not as same-JVM test servers: BoxLang runs on Java 21, the Adobe
test servers on the one pinned Java 17. A test server whose engine is not installed is left out of the
default set automatically; install one with `Install-TestServers.ps1 -Servers lucee6,boxlang`.

Every test server shares [.cfconfig-bench-db.json](../../.cfconfig-bench-db.json), which pins the settings that
would otherwise decide the result rather than the hotfix. BoxLang also runs with
`-Dboxlang.trustedCache=true -Dboxlang.clearClassFilesOnStartup=true` (its equivalent of
template caching, plus a clean class cache on each start so code edits are never ignored):

| Setting | Value | Why |
|---|---|---|
| `inspectTemplate` | `never` | The ACF default is `always`, which stats the CFC file on every request and buries the thing being measured. |
| `maxTemplateRequests` | `100` | The default is `25`. At 32 connections requests would queue at the throttle on **every** test server, flattening all curves and faking a null result. |
| `templateCacheSize` | `4096` | Stops ColdBox and the probes evicting each other mid-run. |
| `componentCacheEnabled` | `true` | Production default; pinned so it cannot drift between test servers. |
| `saveClassFiles` | `true` | Avoids recompilation during a run. |

The server configs also pin the same JDK, the same fixed heap (min = max), and disable
FusionReactor, which instruments method entry and would tax the exact path under test.

## Endpoints

| Endpoint | What it does |
|---|---|
| `/benchmark/control?count=N` | The request and loop with no CFC construction. The overhead baseline. |
| `/benchmark/construct?count=N&shape=S[&n=W][&ms=M]` | Constructs `count` fresh CFCs and reads each instance's `variables` scope. |
| `/benchmark/quickconstruct?count=N` | Constructs a fresh Quick entity and query builder per iteration, no database. Every Quick entity extends `BaseEntity`, so this is the shared-ancestor case. |
| `/benchmark/engine` | Reports the ColdFusion build, JVM, update jars, which jar each patched class was loaded from, the runtime lock fingerprint (`global` / `perclass` / `none`, read off `TemplateProxyFactory`'s static fields), and where inline-literal temporaries land (`shared-variables` before v4, `function-local` with v4). |
| `/torture/*` | Lock stress tests (deadlock, named-lock interlock, lock leak, thread-in-constructor) and `p8`, the shared-compiler-temporary probe; see `handlers/Torture.cfc` and `scripts/Invoke-LockStressTests.ps1`. |
| `/repro/tempvar` | One request = three inline literals built by a shared singleton; HTTP 500 and a `TEMPVAR_CROSSING` log line when a value comes back carrying another request's token. |

`shape` selects the probe. The original three construct the same class on every iteration,
which is the worst case for any construction lock:

| Shape | Model | Isolates |
|---|---|---|
| `narrow` | `ConstructionProbe` | three methods, no parent |
| `wide` | `WideProbe` | a two-level extends chain, ~15 methods, roughly a Quick entity's weight |
| `closure` | `ClosureProbe` | closures built and called during construction |

The lock-probe shapes (generated into `models/lockprobe/` by `scripts/New-LockProbeModels.ps1`)
spread construction over `n` distinct classes (1-16, default 16), so a per-class lock can be
told apart from a global one, and show what holding every ancestor's lock costs:

| Shape | Models | Isolates |
|---|---|---|
| `fanout` | `Leaf01..16`, no extends | independent locks: the best case for a per-class design |
| `siblings` | `Sib01..16 extends SibBase` | each construction also takes the shared base lock (the ColdBox/Quick pattern) |
| `deep` | `Deep5 extends Deep4 ... Deep1` | five nested locks per construction |
| `slowfanout`, `slowsiblings` | as above, `sleep(ms)` in the pseudo-constructor | the lock is held while the constructor runs; `ms` defaults to 3 |
| `slowinit` | `SlowInit`, `sleep(ms)` in `init()` | `init()` runs after construction returns, outside the lock |

Every construct request returns a deterministic checksum for its `count`; the lock-probe shapes
also verify each instance reports the identity of the class that was asked for. A mismatch
returns HTTP 500, so a load tool's non-2xx count doubles as a tripwire. That tripwire is **not**
the contamination test: the synthetic path never exercises Quick's metadata duplication or
WireBox's concurrent builds, and it has given a clean result on engines that fail 100% of real
requests. Only `Test-Contamination.ps1` decides correctness.

## Running it

Every script defaults to the **`short` profile**: each test finishes in about five minutes or
less, which is enough to rank the test servers and catch a regression. Pass `-Profile long` for
the report-grade form (30 s runs, five connection levels, 3 x 100k sessions from a fresh start,
45 min endurance test). Any parameter given explicitly wins over the profile. The profiles live
in `scripts/TestServers.ps1`.

```powershell
# One time: fetch bombardier (pinned version, SHA256 verified) into ./tools
.\scripts\Get-BenchmarkTools.ps1

# One time per test run: install the engines, place each test server's jar, prove each test server's identity
.\scripts\Install-TestServers.ps1 -ClearFelixCache
# The comparison engines are only picked up by default once installed; install them by name the first time
.\scripts\Install-TestServers.ps1 -Servers lucee6,boxlang

# The whole test run in one go (about 80 minutes on the short profile with all six test servers): fresh test servers, contamination tests,
# lock evidence, throughput, lock stress tests, endurance test. -Phases picks a subset.
.\scripts\Invoke-AdobeV3TestRun.ps1
.\scripts\Invoke-AdobeV3TestRun.ps1 -Profile long -StopDropbox
.\scripts\Invoke-AdobeV3TestRun.ps1 -Phases contamination,lockwaits

# Or step by step. Correctness first: the known-bad check must show contamination.
.\scripts\Test-Contamination.ps1 -Server buggy -Sessions 1
.\scripts\Test-Contamination.ps1 -Server localtemp-u23 -ColdStart                 # fresh JVM per session, 500 serial requests, then the burst
.\scripts\Test-Contamination.ps1 -Server localtemp-u23 -Endpoints tempvar,tempvar  # the mechanism alone, no database

# Throughput: the real workload, then the synthetic shapes
.\scripts\Invoke-RealWorkloadBenchmark.ps1 -StopDropbox
.\scripts\Invoke-ConstructionBenchmark.ps1 -StopDropbox
.\scripts\Invoke-ConstructionBenchmark.ps1 -Endpoint quickconstruct
.\scripts\Invoke-ConstructionBenchmark.ps1 -Widths 1,4,16

# Name the lock (or show there is none), then try to break it
.\scripts\Get-LockEvidence.ps1 -Server localtemp-u23 -Endpoint repro
.\scripts\Invoke-LockStressTests.ps1 -Server localtemp-u23
.\scripts\Invoke-LockStressTests.ps1 -Server localtemp-u23 -Probes p2      # deadlock probe: restarts the test server afterwards
.\scripts\Invoke-LockSoak.ps1 -Server localtemp-u23
```

Every burst in every test hits a server that is online and warmed. The separate startup crash
(a freshly started server failing every request under immediate concurrent load) is filed with
Adobe on its own and is not measured here; `Test-Contamination.ps1` refuses a cold burst.
`Invoke-AdobeV3TestRun.ps1` restarts every test server and warms it up with single requests
before any throughput or lock-evidence step. Do the same when running steps by hand
(`Invoke-RealWorkloadBenchmark.ps1` does its own warm-up).

`Install-TestServers.ps1` refuses to continue unless every test server loads the classes its
table row says (v1 must carry `TemplateProxy`/`UDFMethod`/`Closure`; v3 must not), reports the
matching lock fingerprint, and holds a jar whose SHA256 equals the pinned constant. Dropping
a jar into `lib/updates` is assumed to override the shipped class, but nothing guarantees which
update jar wins the classloader order, and every jar is deployed under the same name. If two
test servers are the same server, every number collected from them is noise. The tests repeat the check
before measuring.

`bombardier.exe` is not committed to this repository. `scripts/tool-versions.json` pins the
version and SHA256 instead, which makes results traceable to an exact tool build.

## How the measurement is designed

1. **Warm-up.** Each test server gets 20 seconds at 8 connections against every target before anything
   is recorded. Stock Update 23 is additionally warmed serially (one connection) because a cold
   concurrent burst kills it. A cold JVM is indistinguishable from a slow one.
2. **Alternating test servers.** Test servers are measured back to back for every single data point, rather
   than all of one test server and then all of the other, so CPU thermals and background Windows work
   hit every test server equally.
3. **`count=200`, not 25.** At a low count most of the request is HTTP and ColdBox overhead,
   which dilutes construction and gives a lock little to contend over. A high count keeps each
   request's thread inside the construction loop, which is the condition that makes contention
   visible.
4. **One test server under load at a time.** The test servers share the SQL Server rows and the CPU; two load
   phases at once change the odds of hitting the race and charge one test server's work to another.

The control endpoint is a sanity check, not a data point. It constructs nothing, so it must come
out the same on every test server.

## Reading the results

Each test writes a timestamped `summary-*.md` and `manifest-*.json` under
`benchmark-results-u23/<round>/` (`adobe-v4` since October 2026; September's v3 results stay
under `adobe-v3`). A repeat of a round goes next to the first, never over it: set
`$env:BENCH_ROUND = 'adobe-v4-run2'` in the shell before running the scripts and every one of
them writes under that folder. Medians across repeat runs are used rather than means so one
Windows hiccup cannot skew a cell. Throughput is bombardier's `rps.mean`. This tree is synced by
Dropbox, so latency figures and any latency-subtraction metric are unreliable here: compare RPS
ratios within one session, and thread-dump evidence, and nothing else.

| Pattern | Diagnosis |
|---|---|
| Equal at 1 connection, rising with concurrency on every test server | no serialization |
| Equal at 1 connection but flat with concurrency on one test server only | **serialization**: the cost grows with load |
| `fanout` tracks stock while `siblings` tracks v1 | the per-class lock works only until classes share an ancestor |
| `slowsiblings` capped at the same rate regardless of connections | one lock is held for the whole constructor: a global lock partitioned by hierarchy |

An uncontended lock costs tens of nanoseconds, so a lock is nearly invisible at one connection
and only bites under load. Measuring only at high concurrency cannot tell "extra work" from
"serialization"; the one-connection column is what makes this work.

## Direct lock evidence

A throughput curve is circumstantial. `Get-LockEvidence.ps1` names the lock: it drives load at
one test server while sampling `jcmd <pid> Thread.print -l`, then counts threads waiting on the
construction path and groups them by lock. Two signatures matter:

- v1 uses a `synchronized` block: contention appears as `BLOCKED (on object monitor)` with
  `TemplateProxyFactory.resolveName` on the stack, all on one `java.lang.Object`.
- v3 uses `ReentrantLock`: contention appears as `WAITING (parking)` on
  `ReentrantLock$NonfairSync`, and the report shows how many **distinct** locks are contended and
  which CFC the owner of each is inside. One dominating address whose owner sits in
  `BaseEntity` is a global lock in disguise.

`jcmd` comes from the JDK the test servers already pin (`box java install openjdk17_jdk`). For
contention too brief to land in a dump sample, Java Flight Recorder catches it:

```powershell
jcmd <pid> JFR.start name=lk settings=profile duration=60s filename=perclass.jfr
jfr print --events jdk.ThreadPark --stack-depth 20 perclass.jfr      # v3
jfr print --events jdk.JavaMonitorEnter --stack-depth 20 lock.jfr    # v1
```

## Optional fixed-rate latency check

Bombardier is closed-loop: each client waits for a response before sending the next request,
so when the server slows down the offered load quietly drops and the latency figures flatter
it. [oha](https://github.com/hatoo/oha) answers a more production-like question: at the *same*
request rate, how much worse is p99?

```powershell
winget install hatoo.oha

$targetRps = 500 # 70-80% of the slower test server's measured capacity

oha --http-version 1.1 -c 24 -z 60s -q $targetRps `
    --latency-correction --no-tui `
    --output-format json -o "benchmark-results-u23/adobe-v3/perclass-oha.json" `
    "http://127.0.0.1:60848/benchmark/construct?count=200&shape=siblings"
```

Use the same target rate for both test servers.
