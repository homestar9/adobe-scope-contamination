# Hotfix performance results

> **Commands below use the script names of the time.** The current equivalents are in
> [the testing guide](../guides/TESTING_GUIDE.md) (`Invoke-ContaminationGate.ps1` is now `Test-Contamination.ps1`,
> `Install-BenchmarkArms.ps1` is now `Install-TestServers.ps1`).

Measured impact of `hf202300-4232227.jar` on CFC construction throughput.

**Verdict: the hotfix serializes all CFC construction on a single process-wide monitor.
Throughput stops scaling with concurrency and flattens at a hard ceiling. On a
Quick-entity-weight component the ceiling is roughly a quarter of unpatched throughput.**

The bytecode change that causes this is described in
[HOTFIX_STATIC_ANALYSIS.md](1-first-hotfix-static-analysis.md).

## Setup

| | |
|---|---|
| Machine | Windows 11, 24 logical cores |
| ColdFusion | 2023.0.22.330928 (Update 22), both arms |
| JVM | OpenJDK 17.0.20+8, fixed 2 GB heap (min = max), both arms |
| FusionReactor | Disabled on both arms |
| Engine settings | `.cfconfig-bench.json`, identical on both arms. `neo-runtime.xml` diffed clean apart from install paths and the machine key. |
| Load tool | bombardier v2.0.2, `--http1 -t 5s -l -p r -o json` |
| Endpoint | `/benchmark/construct?count=200&shape=...` |
| Runs | 3 per cell, 30 s each, arms alternated per data point |
| Errors | **Zero** non-2xx or timeouts in all 78 measurements |

Both arms were confirmed to load the four patched classes from different jars before
measuring:

| Class | Patched arm | Baseline arm |
|---|---|---|
| `TemplateProxyFactory` | `hf202300-4232227.jar` | `chf20230022.jar` |
| `TemplateProxy` | `hf202300-4232227.jar` | `cfusion.jar` |
| `UDFMethod` | `hf202300-4232227.jar` | `chf20230022.jar` |
| `Closure` | `hf202300-4232227.jar` | `cfusion.jar` |

Throughput below is total 2xx responses divided by elapsed time.

## Throughput

### `shape=wide` — two-level extends chain, ~15 methods, roughly a Quick entity

| Connections | Baseline RPS | Patched RPS | Change | Baseline p99 | Patched p99 |
|---|---|---|---|---|---|
| 1 | 29.6 | 30.2 | +2% | 49.2 ms | 50.0 ms |
| 4 | 114.5 | 128.3 | +12% | 49.0 ms | 50.6 ms |
| 8 | 290.0 | 124.8 | **−57%** | 39.8 ms | 95.9 ms |
| 16 | 421.6 | 133.6 | **−68%** | 51.8 ms | 192.6 ms |
| 32 | 450.5 | 126.7 | **−72%** | 144.2 ms | 393.8 ms |

The patched arm returns the same throughput at 8, 16, and 32 connections. Adding concurrency
buys nothing at all past 8 — it only adds queueing, which is why p99 latency grows from 96 ms
to 394 ms across that range while throughput stays flat.

Independently re-measured afterwards at 15 s per run, which reproduced it slightly harder:

| Connections | Baseline RPS | Patched RPS | Ratio |
|---|---|---|---|
| 8 | 364.2 / 370.6 | 116.8 / 108.8 | 0.32 / 0.29 |
| 16 | 450.6 / 480.6 | 125.8 / 114.8 | 0.28 / 0.24 |
| 32 | 498.6 / 467.8 | 124.4 / 110.5 | 0.25 / 0.24 |

### `shape=narrow` — three methods, no parent

| Connections | Baseline RPS | Patched RPS | Change | Baseline p99 | Patched p99 |
|---|---|---|---|---|---|
| 1 | 65.4 | 69.6 | +6% | 21.9 ms | 19.7 ms |
| 4 | 244.1 | 228.3 | −6% | 22.8 ms | 25.9 ms |
| 8 | 282.5 | 249.0 | −12% | 41.1 ms | 48.8 ms |
| 16 | 368.3 | 288.9 | **−22%** | 72.0 ms | 95.9 ms |
| 32 | 414.3 | 327.0 | **−21%** | 185.1 ms | 227.0 ms |

Same shape of result, smaller magnitude. A tiny component is resolved quickly, so the lock is
held briefly and less of the total request time is spent waiting for it. Component size
therefore predicts how much the hotfix costs: the bigger the CFC, the longer the lock is
held, and the lower the ceiling.

### Scaling efficiency

`rps(c) / (c × rps(1))`. 1.0 would be perfect scaling.

| Connections | Baseline wide | Patched wide | Baseline narrow | Patched narrow |
|---|---|---|---|---|
| 1 | 1.000 | 1.000 | 1.000 | 1.000 |
| 4 | 0.967 | 1.062 | 0.933 | 0.820 |
| 8 | 1.225 | 0.517 | 0.540 | 0.447 |
| 16 | 0.890 | 0.276 | 0.352 | 0.259 |
| 32 | 0.476 | 0.131 | 0.198 | 0.147 |

## Which hypothesis this supports

The two candidate explanations make different predictions, and the data picks one cleanly.

| | Extra work per construction | Serialization on a lock |
|---|---|---|
| Predicts at 1 connection | Patched measurably slower | Patched the same |
| Observed at 1 connection | — | **Same (+2% wide, +6% narrow)** |
| Predicts under load | Constant percentage gap | Gap widens; patched hits a fixed ceiling |
| Observed under load | — | **Widens to −72%; patched flat at ~127 RPS across 8/16/32** |

An uncontended Java monitor costs tens of nanoseconds, which is why the lock is invisible at
one connection. Extra work would have shown up there immediately. It did not.

## Direct evidence

Thread dumps sampled with `jcmd Thread.print` during a 32-connection `shape=wide` run,
15 samples per arm:

| | Patched | Baseline |
|---|---|---|
| Blocked-thread observations | **383** | 1 |
| ...in `TemplateProxyFactory.resolveName` | **383 (100%)** | **0** |
| Distinct monitors responsible | 1 (`java.lang.Object` at `0x…828f4ce0`), 381 of 383 | — |
| Average threads blocked per dump | **25.5 of 32** | 0.1 |

Every single blocked thread on the patched arm was blocked at
`coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:202)`, on one
`java.lang.Object` instance. That object is `CONSTRUCTION_LOCK`, which the hotfix declares as
`private static final Object` and initialises with `new Object()` in the static initialiser.

With 25.5 of 32 worker threads parked on that monitor at any instant, and only one permitted
inside `resolveName`, the flat throughput ceiling is fully accounted for.

The baseline arm shows zero blocking on this path, which is expected: its only lock there is
double-checked on the per-component metadata object and is skipped entirely once a component's
metadata is initialised.

### The lock spans the whole `extends` chain

Exactly one thread holds the monitor at any instant, and its stack contains
`- locked <0x…828f4ce0>` **three times**:

```text
	at coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:204)
	- locked <0x00000000828f4ce0> (a java.lang.Object)
	at coldfusion.runtime.TemplateProxyFactory.resolveComponentHelper(TemplateProxyFactory.java:427)
	at coldfusion.runtime.TemplateProxyFactory.resolveNameLocked(TemplateProxyFactory.java:301)
	at coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:204)
	- locked <0x00000000828f4ce0> (a java.lang.Object)
	...
```

`resolveNameLocked` calls `resolveComponentHelper`, which calls back into `resolveName`, which
reacquires the same monitor. Java monitors are reentrant so this cannot deadlock, but the lock
is held continuously from the first parent to the last. `WideProbe` has two parents, which is
where the three holds come from. A deeper hierarchy holds it longer.

### Application CFML executes while the lock is held

Reading further down the same holder stack:

```text
	at coldfusion.runtime.LocalScope.putInternal(LocalScope.java:375)
	at coldfusion.runtime.CfJspPage._structSetAt(CfJspPage.java:3945)
	at cfWideProbeRoot2ecfc3956415.runPage(...\models\WideProbeRoot.cfc:11)   <-- user CFML
	at coldfusion.runtime.CfJspPage.invoke(CfJspPage.java:251)
	at coldfusion.runtime.TemplateProxyFactory.resolveComponentHelper(TemplateProxyFactory.java:624)
	at coldfusion.runtime.TemplateProxyFactory.resolveNameLocked(TemplateProxyFactory.java:301)
	at coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:204)
	- locked <0x00000000828f4ce0> (a java.lang.Object)
```

`resolveComponentHelper` line 624 calls `CfJspPage.invoke`, which runs the component's
pseudo-constructor — the CFML in the component body — inside the global lock.

**This means the hold time is not bounded by engine work.** It is bounded by whatever the
slowest component body in the application does. The probes here only assign a few `variables`
keys, so the hold is short and predictable. A component whose body runs a query, reads a file,
or calls a web service would hold this monitor for that entire duration, blocking every other
CFC construction in the JVM.

The throughput figures above should therefore be read as close to the **best** case for this
lock, not the worst.

## What is not reliable here

**Disregard the `ConstructNs` column in `summary.csv`.** It subtracts the control endpoint's
latency from the construct endpoint's to estimate per-construction cost, which only works if
the control endpoint is stable. It was not — the control endpoint varied by **42%** between
repeat runs on the same server, and re-measuring it at one connection gave 30, 47, 94 and 95
RPS on the baseline arm and 35, 36, 34 and 86 on the patched arm across four consecutive
alternating runs.

Two things follow:

1. The control endpoint failed its job as an overhead baseline. In the main run it reported
   the patched arm as 2.4x faster on an endpoint that constructs nothing, and reported
   baseline `control` p50 latency (23.4 ms) as *slower* than baseline `construct` p50
   (14.5 ms) — constructing 200 CFCs cannot be faster than not constructing them. That is
   noise, not a real difference.
2. The noise is bidirectional and similar on both arms, so it does not explain the construct
   results. It cannot produce a value pinned at 109–126 RPS across three concurrency levels
   and nine separate runs while the other arm climbs to 499.

`Get-BenchmarkSummary.ps1` now measures this spread and prints a warning telling you to
ignore `ConstructNs` when it exceeds 20%.

The likely cause of the instability is that ~10–30 ms of every request is ColdBox and HTTP
overhead unrelated to construction, and the application lives inside a Dropbox-synced
directory, so background file-system activity lands on the request path. Anyone repeating
this should run from a directory that is not being synced or virus-scanned, and should treat
the throughput curve and thread dumps as the primary evidence.

## Suggested question for Adobe

The correctness part of this fix looks sound and does not depend on the lock: `TemplateProxy`
gained per-instance `boundSuperScopeLevel0` / `boundSuperScopesByLevel` fields (the latter a
`ConcurrentHashMap`), `UDFMethod` gained `resolveInvocationSuperScope`, and `Closure` gained
`capturedOwner` / `capturedVarScope`. Those changes stop instances sharing scope state, and
they carry no contention cost.

The global `CONSTRUCTION_LOCK` around `resolveName` appears to be a separate, conservative
guard. It is worth asking whether it can be narrowed to the metadata-initialisation window
the unpatched code already guarded — which was per component and skipped entirely in steady
state — rather than held across the whole of `resolveNameLocked`, including `getCFCInstance`
and the full `extends`-chain resolution.

Reproduce with:

```powershell
.\scripts\Get-BenchmarkTools.ps1
.\scripts\Install-BenchmarkArms.ps1
.\scripts\Invoke-Benchmark.ps1
.\scripts\Get-BenchmarkSummary.ps1
.\scripts\Get-LockEvidence.ps1 -Arm patched
.\scripts\Get-LockEvidence.ps1 -Arm baseline
```
