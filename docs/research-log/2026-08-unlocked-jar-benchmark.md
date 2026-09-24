# Three-arm benchmark: Adobe's hotfix vs. the de-locked rebuild

Measured 11 August 2026. Raw data in `benchmark-results-3arm/`.

Adobe's hotfix `hf202300-4232227.jar` fixes the `variables`-scope contamination bug, but it
also wraps **all** CFC name resolution in one process-wide `synchronized` block. This run
measures what that lock costs, and whether removing it gets the performance back.

Three servers, identical except for the bytes of one jar:

| Arm | Port | What it runs |
|---|---|---|
| `baseline` | 60841 | Vanilla ACF 2023 Update 22. No hotfix. Has the bug. |
| `patched` | 60840 | Adobe's hotfix, unmodified. Bug fixed, global lock present. |
| `unlocked` | 60842 | The de-locked rebuild. Same correctness fix, global lock removed. |

---

## Scorecard

| Question | Answer |
|---|---|
| Does the de-locked jar remove the global lock? | **Yes.** 0 of 640 sampled threads blocked in `resolveName`, versus 535 on Adobe's hotfix. |
| Does throughput return to vanilla ACF levels? | **Yes, essentially.** 86–100% of baseline across the sweep. |
| How much faster than Adobe's hotfix? | **4.4× at 32 connections** on the `wide` shape; 2.3–4.4× from 4 connections up. |
| Does the per-component "stripe" fallback also recover? | **No.** Only 1.17× over Adobe's hotfix on this workload. See "The stripe variant". |
| Did anything break during measurement? | **No.** 0 errors in 1,161,835 requests. Every response passed its checksum. |
| Is this ready for production? | **No.** The contamination correctness test has not been run. See "What this does not prove". |

The single number: on the component shape that resembles a Quick entity, at 32 concurrent
connections, Adobe's hotfix serves **102.8 requests/sec** and the de-locked rebuild serves
**455.7 requests/sec**.

---

## Throughput — `shape=wide`

The `wide` probe is a three-level `extends` chain with about 15 methods, built to weigh
roughly what a Quick entity weighs. Constructing one forces ColdFusion to resolve three
components through the code path the hotfix locks. Numbers are medians of 3 runs × 30 s,
200 CFCs constructed per request.

| Connections | Baseline | Adobe patched | De-locked | De-locked ÷ patched | Patched vs baseline | De-locked vs baseline |
|---|---|---|---|---|---|---|
| 1 | 72.4 | 73.0 | 72.4 | 0.99× | +0.8% | 0.0% |
| 4 | 262.1 | 110.6 | 251.2 | **2.27×** | −57.8% | −4.2% |
| 8 | 414.3 | 108.0 | 384.7 | **3.56×** | −73.9% | −7.1% |
| 16 | 498.1 | 105.9 | 426.3 | **4.03×** | −78.7% | −14.4% |
| 32 | 501.5 | 102.8 | 455.7 | **4.43×** | −79.5% | −9.1% |

Three things to notice:

1. **All three arms agree at 1 connection** (72.4 / 73.0 / 72.4). A lock nobody is competing
   for costs nothing. This is the check that the arms are otherwise identical — and they are.
2. **Adobe's hotfix stops responding to concurrency.** From 4 connections to 32 — eight times
   the offered load — its throughput moves only between 110.6 and 102.8, and it moves *down*.
   That flat line is the signature of a serialized section: one thread at a time, so adding
   threads adds queueing, not work.
3. **The de-locked rebuild tracks baseline.** It climbs the same curve vanilla ColdFusion
   climbs, ending within 9% of it.

## Throughput — `shape=narrow`

The `narrow` probe is a minimal component: one property, three methods, no parent. Less
name resolution per request, so less to serialize and a smaller effect.

| Connections | Baseline | Adobe patched | De-locked | De-locked ÷ patched | Patched vs baseline |
|---|---|---|---|---|---|
| 1 | 90.6 | 83.9 | 91.0 | 1.08× | −7.4% |
| 4 | 318.9 | 242.4 | 311.7 | 1.29× | −24.0% |
| 8 | 468.7 | 252.8 | 493.3 | 1.95× | −46.1% |
| 16 | 519.7 | 292.9 | 581.0 | 1.98× | −43.6% |
| 32 | 507.4 | 412.4 | 528.8 | 1.28× | −18.7% |

The de-locked arm reads slightly *above* baseline at 8, 16 and 32 connections (+5.2%, +11.8%,
+4.2%). Those gaps sit inside this cell's run-to-run variation (5.5–13.8%), so the honest
reading is "matches baseline", not "beats baseline".

The penalty on Adobe's hotfix is real here but roughly half what the `wide` shape shows. The
heavier the component, the more the lock costs — which fits the mechanism, because a heavier
component holds the lock longer.

## Scaling efficiency

Efficiency is `rps(c) / (c × rps(1))`. A value of 1.0 means doubling connections doubles
throughput. Falling toward 0 means threads are waiting on something shared.

| Connections | Baseline wide | Patched wide | De-locked wide | Baseline narrow | Patched narrow | De-locked narrow |
|---|---|---|---|---|---|---|
| 1 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |
| 4 | 0.905 | **0.379** | 0.868 | 0.880 | 0.723 | 0.856 |
| 8 | 0.715 | **0.185** | 0.664 | 0.647 | 0.377 | 0.678 |
| 16 | 0.430 | **0.091** | 0.368 | 0.359 | 0.218 | 0.399 |
| 32 | 0.216 | **0.044** | 0.197 | 0.175 | 0.154 | 0.182 |

On `wide` at 32 connections, Adobe's hotfix converts 4.4% of the available parallelism into
throughput. Baseline and the de-locked rebuild convert about 20%. All three decline as
concurrency rises — that is ordinary saturation on a 24-core machine — but the patched arm
declines about five times faster.

## Latency (p99, milliseconds)

| Connections | Baseline wide | Patched wide | De-locked wide |
|---|---|---|---|
| 1 | 32.6 | 25.7 | 32.7 |
| 4 | 23.5 | 50.9 | 23.3 |
| 8 | 28.7 | 112.1 | 30.7 |
| 16 | 43.8 | 237.2 | 50.5 |
| 32 | 139.1 | 467.8 | 142.3 |

At 32 connections Adobe's hotfix puts the 99th-percentile request at **467.8 ms** against
baseline's 139.1 ms. The de-locked rebuild lands at 142.3 ms, within 2% of baseline. This is
the number a user would feel.

---

## Lock evidence — naming the bottleneck

Throughput curves let you *infer* serialization. Thread dumps *name* it. Each arm received
32-connection `wide` load while 20 thread dumps were taken one second apart, all three arms in
the same session.

| | Baseline | Adobe patched | De-locked |
|---|---|---|---|
| Thread dumps sampled | 20 | 20 | 20 |
| Threads blocked on a monitor, all samples | 9 | **535** | **2** |
| ...blocked inside `TemplateProxyFactory.resolveName` | **0** | **535 (100%)** | **0** |
| Average threads blocked per dump | 0.45 | **26.75 of 32** | 0.10 |
| Single monitor responsible | — | one `java.lang.Object`, 533 of 535 | — |

On Adobe's hotfix, **every single blocked thread** was blocked at
`TemplateProxyFactory.resolveName(TemplateProxyFactory.java:202)`, and 533 of the 535 were
waiting on the same one `java.lang.Object` monitor. On average 26.75 of the 32 worker threads
were stopped at that line at any instant.

On the de-locked rebuild, 2 threads were blocked across all 20 dumps, neither in `resolveName`,
and there is no dominant monitor. That is *cleaner than vanilla baseline*, which showed 9.

This evidence does not depend on timing, so background activity on the machine cannot produce
or hide it.

---

## The stripe variant does not work for this workload

`hotfixes/hf202300-4232227-stripe.jar` is the fallback design. Instead of removing the lock, it
replaces Adobe's one global monitor with a **per-component** monitor, so that two threads building
*different* components do not block each other. It was measured as a separate screening pass:
`shape=wide`, 1/8/32 connections, 2 runs of 30 s, all three arms re-measured together. Raw data in
`benchmark-results-stripe/`.

| Connections | Baseline | Adobe patched | Stripe | Stripe ÷ patched | De-locked ÷ patched (for comparison) |
|---|---|---|---|---|---|
| 1 | 70.7 | 65.9 | 69.8 | 1.06× | 0.99× |
| 8 | 426.6 | 103.8 | 120.2 | **1.16×** | 3.56× |
| 32 | 639.2 | 102.4 | 120.1 | **1.17×** | 4.43× |

**The stripe jar flattens just like Adobe's hotfix.** It sits at 120.2 and 120.1 requests/sec at 8
and 32 connections while baseline climbs to 639.2. It recovers 17% where full lock removal recovers
343%.

The thread dumps explain why:

| | Adobe patched | Stripe | De-locked |
|---|---|---|---|
| Threads blocked, 20 dumps | 535 | **569** | 2 |
| ...inside `resolveName` | 535 | **569 (100%)** | 0 |
| Average blocked per dump | 26.75 | **28.45 of 32** | 0.10 |
| Distinct monitors contended | 1 | **1** | — |

Across all 20 dumps of the stripe arm, threads waited on exactly **one** monitor address, 566 times.
A per-component lock only spreads contention if concurrent threads want *different* components.
This benchmark's `buildProbe` returns `new models.WideProbe()` on every one of the 200 iterations
per request, so all 32 threads compete for the same component's monitor. The per-component design
collapses to a global lock, and behaves like one.

**The design is working as written; the workload defeats it.** `UNLOCKED_JAR_BUILD.md` anticipated
this as a "possible small gap versus full-removal only when many threads hammer the *same*
component". The measurement shows the gap is not small — it is nearly the whole benefit.

This matters for the production case that started this investigation. The bug appeared in Quick
entities under concurrent load, which is many simultaneous requests constructing the *same* entity
type. That is the shape of workload where a per-component lock helps least.

**Scope of this result.** The stripe jar was measured only on a same-component workload. A workload
building many *distinct* components concurrently should do better, and was not measured. But it
cannot be recommended as a drop-in fallback on the strength of this data.

**The stripe jar is also not byte-reproducible.** Building it twice produced SHA256 `1DC0A369…`
and then `6F01EA3A…`, and neither matches the `D9CA0715…` recorded in `UNLOCKED_JAR_BUILD.md`.
Comparing two builds: 55 entries, **zero differ in content**, exactly one differs in timestamp —
the added `coldfusion/runtime/ConstructionLockSupport.class`, whose zip entry time is the build
time. The jar's behaviour is deterministic but it cannot be pinned by hash for deployment. The
de-locked jar has no such problem and reproduced `1674130D…` exactly. Setting a fixed entry time
in `scripts/archive/java/PatchHotfix.java` would fix it.

---

## What to trust in these numbers, and what to ignore

**The environment was deliberately left as-is.** Dropbox continued syncing this folder, and
other applications kept running. Total CPU at the start of the sweep was 16%, with Node, VS
Code and Chrome the largest consumers. That is a real noise source, so here is what it does
and does not affect.

**Run-to-run variation.** Every cell was measured 3 times. Excluding the first run of each cell,
the median spread within a cell is **4.3%** and the worst is **14.7%**. The effect being
measured at 32 connections is **343%** (4.43×). The effect is far larger than the noise.

**One cold-start artifact, and why it is harmless.** The `wide` shape at 1 connection shows
53–61% spread. The cause is run 1: baseline 34.1, patched 34.3, de-locked 33.1 requests/sec,
against 72–78 in runs 2 and 3. The JVM had not finished warming for that shape. It struck all
three arms within 4% of each other, because the harness alternates arms for every single data
point rather than measuring one arm then the next. The median of three runs rejects the outlier,
so the reported figures and the efficiency denominators are unaffected.

**Ignore the `ns/CFC` column in `summary.csv`.** It subtracts control-endpoint latency from
construct latency to estimate per-construction cost, which only works if the control endpoint is
stable. It is not. It varied 39% between repeat runs, and it reported the patched arm serving
111.7 requests/sec against baseline's 51.3 on an endpoint that constructs nothing at all. That
is noise, not a finding.

**Bombardier's `rps.percentiles` is never used.** Those are per-second bucket counts, not a
throughput distribution. On one steady single-connection run they reported p50 50.6 and p99
102.1 requests/sec for a test whose true rate was 70.0. All throughput here comes from
`rps.mean`.

**Absolute numbers do not carry between sessions.** Compared with the July 29 two-arm run on
this same machine, baseline at 1 connection `wide` measured 29.6 requests/sec then and 72.4 now.
Only within-session comparisons are valid — which is exactly why all three arms are measured
back-to-back for every data point.

### Does the earlier run reproduce?

| Connections (wide) | Baseline Jul 29 | Baseline now | Patched Jul 29 | Patched now | Ratio Jul 29 | Ratio now |
|---|---|---|---|---|---|---|
| 1 | 29.6 | 72.4 | 30.2 | 73.0 | 0.98× | 0.99× |
| 8 | 290.0 | 414.3 | 124.8 | 108.0 | 2.32× | 3.84× |
| 16 | 421.6 | 498.1 | 133.6 | 105.9 | 3.16× | 4.70× |
| 32 | 450.5 | 501.5 | 126.7 | 102.8 | 3.56× | 4.88× |

The qualitative result reproduces exactly. In both sessions the arms agree at 1 connection, the
patched arm settles onto a narrow plateau (124.8–133.6 then, 102.8–110.6 now) and stops
responding to load, and baseline keeps climbing. The measured penalty is larger in this session
than in July.

---

## Methodology

**Arms.** Three separate ACF 2023 installs. The hotfix lives in the engine directory, not the
application, so each arm is a full install differing only in `WEB-INF/cfusion/lib/updates/`. All
three use the same filename `hf202300-4232227.jar` so classloader precedence is identical; only
the bytes differ.

| Arm | ColdFusion | JVM | `TemplateProxyFactory` loaded from |
|---|---|---|---|
| baseline | 2023,0,22,330928 | 17.0.20 | `chf20230022.jar` |
| patched | 2023,0,22,330928 | 17.0.20 | `hf202300-4232227.jar` (Adobe, SHA256 `7B586D55…`) |
| unlocked | 2023,0,22,330928 | 17.0.20 | `hf202300-4232227.jar` (de-locked, SHA256 `1674130D…`) |

**Identity checks before measuring.** The harness calls `/benchmark/engine` on each arm and
refuses to run unless patched and baseline load `TemplateProxyFactory` from different jars. The
de-locked arm is confirmed by SHA256 of the deployed jar, because it shares a filename with
Adobe's. All three reported the same ColdFusion build and the same JVM.

**Endpoints.** `/benchmark/construct?count=200&shape=…` builds 200 components per request and
reads each one's `variables` scope. It is deliberately database-free: the `/repro` endpoints run
Quick queries and contended SQL Server writes, which would hide or exaggerate an engine-level
difference. Every response carries a deterministic checksum and returns HTTP 500 on mismatch, so
the load tool's non-2xx count doubles as a contamination detector.

**Parameters.** Connections 1, 4, 8, 16, 32. Three runs of 30 s per cell. `count=200`. Shapes
`narrow` and `wide`. 20 s warm-up per arm per target before anything is recorded. Load tool
bombardier v2.0.2, invoked `--http1 -c <n> -d 30s -t 5s -l -p r -o json`.

**Why these choices matter.** A cold JVM is indistinguishable from a slow one, so every target is
warmed. Anything that drifts across the hour — CPU thermals, background work — is charged
equally to all three arms because they alternate per data point. `count=200` rather than a low
count keeps the request dominated by construction rather than by HTTP and ColdBox overhead.

**Engine settings**, identical on all three arms via `.cfconfig-bench.json`: `inspectTemplate=never`
(the default re-checks the CFC file on every request and buries what is being measured),
`maxTemplateRequests=100` (the ACF default of 25 would queue requests at the throttle on *all*
arms at 32 connections and fake a null result), `templateCacheSize=4096`, `componentCacheEnabled=true`,
`saveClassFiles=true`. Fixed 2 GB heap with minimum equal to maximum. FusionReactor off.

### A setup problem found and fixed before measuring

On first startup the unlocked arm failed to install three OSGi packages that the other two
installed — `felixclassloader`, `adminapi` and `administrator`. Its bundle registry read
`packages=sqlserver` alone, against all four on the other arms.

The cause was a corrupted OSGi cache in that server's home: `felix-cache/bundle0/bundle.id` read
57 there against 9 on the other two arms, so repeated failed install and uninstall cycles had
drifted the bundle-ID counter and every start collided with the cache and dropped packages.

**This was not caused by the de-locked jar.** Putting Adobe's *original* jar into the same home
and starting it alone reproduced the identical failure. Clearing `felix-cache` on all three arms
fixed it. After the fix, all 75 ColdFusion startup service lines are byte-identical across the
three arms and no bundle errors remain.

Worth recording because the direction of the error mattered: `felixclassloader` is the OSGi
classloader bridge, and an arm running without it would plausibly have been *faster*, which would
have inflated the de-locked arm's result — the exact direction that would have flattered the
conclusion.

---

## What this does not prove

**The correctness test has not been run.** Everything above is throughput and lock behaviour.
The construct endpoint is database-free and does not exercise the Quick and qb `variables`-scope
write patterns that trigger the original bug. The 0 errors across 1,161,835 requests is a real
but weak correctness signal: it shows no component came back with another instance's data on
this workload.

Before any production use, the de-locked jar needs the contamination test described in
`UNLOCKED_JAR_BUILD.md`: SQL Server connected, the `/repro` endpoints, a positive control showing
baseline *does* contaminate while patched and de-locked do not, and **0 contamination events
across at least 300,000 requests**, split alpha/bravo, over at least 3 sessions with a fresh JVM
restart between them — the cold class-initialisation window being the highest-risk case. At the
observed 1–2% unpatched rate, zero events in 300,000 requests bounds any remaining rate below
about 1 in 100,000 at 95% confidence.

**Running a modified Adobe jar is very likely outside the Adobe EULA and support agreement.**
That is a business decision, not something this measurement settles.

---

## Reproducing this

```powershell
.\scripts\Build-UnlockedJar.ps1          # must print SHA256 1674130D…0BC85
.\scripts\Install-BenchmarkArms.ps1 -SkipInstall
.\scripts\Invoke-Benchmark.ps1 -OutputDir benchmark-results-3arm
.\scripts\Get-BenchmarkSummary.ps1 -ResultsDir benchmark-results-3arm `
    -CsvPath benchmark-results-3arm\summary.csv -MarkdownPath benchmark-results-3arm\summary.md
.\scripts\Get-LockEvidence.ps1 -Arm baseline -OutputDir benchmark-results-3arm
.\scripts\Get-LockEvidence.ps1 -Arm patched  -OutputDir benchmark-results-3arm
.\scripts\Get-LockEvidence.ps1 -Arm unlocked -OutputDir benchmark-results-3arm
```

The stripe screening pass (the `unlocked` arm label means *stripe* in this pass):

```powershell
.\scripts\Build-UnlockedJar.ps1 -Stripe
# stop the unlocked arm, copy hotfixes\hf202300-4232227-stripe.jar over
# .engine\bench-unlocked\WEB-INF\cfusion\lib\updates\hf202300-4232227.jar, restart it
.\scripts\Invoke-Benchmark.ps1 -Connections 1,8,32 -Runs 2 -Shapes wide `
    -ControlConnections 8 -OutputDir benchmark-results-stripe
.\scripts\Get-LockEvidence.ps1 -Arm unlocked -OutputDir benchmark-results-stripe
# then restore hotfixes\hf202300-4232227-unlocked.jar
```

Two notes for anyone repeating this on this machine:

- `box server start` fails if a server home holds a stale `.pid.txt`. CommandBox checks whether
  that PID is alive with `cmd /c tasklist`, and in this sandboxed shell `cmd` cannot resolve
  executables by bare name from directories that are already on PATH, nor from its own working
  directory. Two fixes work, and either is enough:
  1. **Targeted:** delete `.pid.txt` and `serverInfo.json` from the server home before starting.
     With no PID recorded, CommandBox never calls `tasklist`. This is what the run above used.
  2. **General:** write a `tasklist.bat` shim that forwards to
     `C:\Windows\System32\tasklist.exe %*`, and **prepend its directory to `$env:PATH` in the
     same tool call** as the `box` command. Prepending within the call is the part that matters
     — a shim sitting in a directory that was already on PATH does not resolve.
- `Get-BenchmarkSummary.ps1` prints the heading for its three-arm comparison table but does not
  write that table into `summary.md`. The underlying data is complete in `summary.csv`, which has
  all three arms.
