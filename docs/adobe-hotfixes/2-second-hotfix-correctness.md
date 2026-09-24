# Update 23 correctness gate — the v2 fix does not hold under load

> **Commands below use the script names of the time.** The current equivalents are in
> [the testing guide](../guides/TESTING_GUIDE.md) (`Invoke-ContaminationGate.ps1` is now `Test-Contamination.ps1`,
> `Install-BenchmarkArms.ps1` is now `Install-TestServers.ps1`).

Date: 2026-08-18

This is the run that answers the question static analysis could not: does Update 23
(which is what Adobe's v2 patch delivers) actually stop the scope contamination under
concurrent load?

**It does not.** Under real concurrent application load, stock Update 23 still corrupts
shared state, and it fails worse than the un-fixed engine — once the corruption hits, it
throws a `NullPointerException` inside ColdFusion's own object duplication and every
later request on that JVM fails.

## The three arms

All three run the same app, same webroot, same SQL Server database, same JVM
(Adoptium 17.0.20), differing only by the ColdFusion engine bytes:

| Arm | Engine | TemplateProxyFactory loaded from | What it represents |
|---|---|---|---|
| `buggy` | ACF 2023.0.21 | `chf20230021.jar` | pre-fix engine (the bug) |
| `u23` | ACF 2023.0.23 | `chf20230023.jar` | stock Update 23 = Adobe's lock-free fix = what v2 delivers |
| `lock-u23` | ACF 2023.0.23 + v1 hotfix jar | `hf202300-4232227.jar` | Update 23 base with the original v1 runtime fix + global lock |

`u23` and `lock-u23` differ **only** by the four runtime classes (`TemplateProxyFactory`,
`TemplateProxy`, `UDFMethod`, `Closure`) — Update 23's lock-free versions versus the v1
hotfix's locked versions. Both carry Update 23's `ExprAssembler` compiler change. This
isolates the effect of Adobe's new runtime fix.

## Correctness gate results

Load: bombardier driving `/repro/alpha` and `/repro/bravo` at the same time, 20
connections each. These endpoints run the exact production code path
(`entity.setXChildren(...)` → Quick `applySetter` → `updateAll` → `UPDATE`).

| Arm | Requests | HTTP 500 | Classified contamination | Outcome |
|---|---|---|---|---|
| `buggy` | 20,000 | 1,032 (5.2%) | 461 (2.3%) | contamination happens, engine keeps serving |
| `u23` | 300,000 | **300,000 (100%)** | 0* | **catastrophic — see below** |
| `lock-u23` | 20,000 | **0** | **0** | clean |

\* The u23 failures are bare `NullPointerException`s, which the app's classifier does
not tag as a known contamination signature, so the "classified" counter reads 0. That 0
does **not** mean clean — every single request failed. Reading only the classified
counter would be a dangerous false pass.

### What the u23 failure actually is

On a fresh JVM, the first `/repro` request on u23 succeeds. Under concurrent load the
corruption hits almost immediately, and from then on every request throws:

```
java.lang.NullPointerException: Cannot invoke "coldfusion.util.Key.getKeyString()" because "this.key" is null
  at coldfusion.util.CaseInsensitiveMap$ScopeIterator$ScopeEntry.getKey(CaseInsensitiveMap.java:482)
  at coldfusion.runtime.ObjectDuplicator._duplicate(ObjectDuplicator.java:156)
  at coldfusion.runtime.ObjectDuplicator.duplicate(ObjectDuplicator.java:80)
  ... (recursive duplicate) ...
  at coldfusion.runtime.CFPage.Duplicate(CFPage.java:10902)
  at cfBaseEntity...funcMETADATAINSPECTION(.../modules/quick/models/BaseEntity.cfc:2727)
  at coldfusion.runtime.UDFMethod.invoke(UDFMethod.java:668)
```

This is the exact engine-level signature documented for the original bug: one thread
duplicating a `CaseInsensitiveMap` (Quick's entity metadata) while another thread mutates
it, so an entry's key is null mid-iteration. It is the scope contamination — the shared
`variables`-scoped metadata is still being shared and mutated across concurrent transient
instances on Update 23.

Why 100% after the first hit: the corruption leaves a cached metadata map with a null
key, so `metadataInspection` fails for every following request on that JVM. The bug went
from "occasional wrong result" (on the pre-fix engine) to "one corruption poisons the
whole JVM" (on Update 23).

### The decisive control

`lock-u23` is the same Update 23 base with the same compiler change, differing only by
the four runtime classes. It ran the identical load with **0 failures and 0
contamination**. So the problem is specifically Update 23's lock-free runtime fix. The
original v1 global lock does prevent the contamination (by serializing construction); the
new lock-free approach does not.

## Throughput (why the synthetic benchmark is misleading)

Load: bombardier on `/benchmark/construct?shape=wide` (a synthetic CFC extends chain, no
database), 20 connections, 20 s.

| Arm | rps | 5xx | Note |
|---|---|---|---|
| `buggy` | 757 | 0 | fast |
| `u23` | 758 | 0 | fast — looks perfect here |
| `lock-u23` | 138 | 0 | ~5.5x slower — the global lock penalty |

This is the trap. On the synthetic construction benchmark, u23 is as fast as the clean
baseline with zero errors — it looks like Adobe fixed the bug and removed the lock. But
that synthetic probe does not reproduce the production contamination. The real
application path (Quick ORM metadata duplication) does, and it breaks u23 completely.

The lock penalty on `lock-u23` (~5.5x) also confirms the original regression is real and
persists on the Update 23 base.

## Bottom line

- The v2 patch = Update 23's `ExprAssembler`, byte-identical (see
  `HOTFIX_V2_UPDATE23_ANALYSIS.md`). It carries no lock.
- Update 23's lock-free fix does **not** stop the scope contamination on the real
  production code path. Under concurrent load it corrupts shared metadata and then fails
  every request on the JVM with an `ObjectDuplicator` NPE.
- The only build that stayed clean under load is the one with the original v1 global
  lock — which costs ~5.5x throughput.
- Do not deploy the v2 patch / Update 23 expecting the contamination to be fixed. The
  synthetic construction benchmark will say it is fine; the real workload proves it is
  not.

## Reproduce

```
.\scripts\Install-U23BenchmarkArms.ps1
.\scripts\Invoke-ContaminationGate.ps1 -Arm buggy   -Port 60845 -TotalRequests 20000
.\scripts\Invoke-ContaminationGate.ps1 -Arm u23     -Port 60843 -ConfigFile server-bench-u23.json -TotalRequests 100000 -Sessions 3 -RestartBetweenSessions
.\scripts\Invoke-ContaminationGate.ps1 -Arm lock-u23 -Port 60844 -TotalRequests 20000
```

To capture the full NPE stack (defeat HotSpot's fast-throw), add
`-XX:-OmitStackTraceInFastThrow` to the u23 JVM args, restart, and drive a short load.
