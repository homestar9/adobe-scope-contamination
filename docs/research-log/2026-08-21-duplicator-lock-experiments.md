# v3 hotfix correctness and performance results (2026-08-21)

> **Naming:** this note is about our own experimental "v3" builds (locks around `ObjectDuplicator`), not Adobe's third hotfix. See [the research log index](README.md).

Status: superseded in part. This doc covers the v3 ObjectDuplicator-LOCK attempts (all
failed). A later approach — making the metadata map CONCURRENT instead of locking, taken
from how Lucee/BoxLang are built — DID fix the cold-start cascade lock-free. See
**docs/root-cause/how-lucee-and-boxlang-avoid-it.md** for that result. Read the correction below first.

## Correction (2026-08-22): the cascade IS fixable lock-free

The "no lock-free fix can work" conclusion below was about LOCK-based fixes. It was wrong for
the more fundamental approach: the cold-start cascade (race 1) is a torn read of a
`CaseInsensitiveMap` backed by a plain `HashMap`. Making that backing a `ConcurrentHashMap`
(ACF already ships `CFConcurrentHashMap`; the `--concmap` overlay makes it the default) gives
a weakly consistent iterator that cannot tear — so the cascade is eliminated with NO lock, at
full throughput. Measured: cold, 3 fresh JVMs, 300,000 requests → 12,529 5xx (4.2%), ZERO
duplication NPEs, NO cascade (vs 300,000/300,000 for unpatched). This is exactly how BoxLang
(ConcurrentHashMap-backed structs) avoids it. The lock-based v3 conclusion below stands for
the LOCK approaches; it does not apply to the concurrent-map fix.

The remaining ~4% is race 2 (the scope-value contamination), which the concurrent map does
NOT fix — that part is architectural and still needs the construction lock. So: race 1
(cascade) is now fixable lock-free; race 2 (contamination) still needs v1's lock.

## Bottom line for the LOCK attempts (unchanged)

No v3 LOCK variant works. Every attempt to fix this bug with a LOCK other than Adobe's global
CONSTRUCTION lock fails the cold-start gate. The bytecode-level reason: **the cold-start
cascade is caused by a metadata WRITE that happens during construction, outside
ObjectDuplicator, so only a lock around construction (v1's) serializes it.** A lock inside
ObjectDuplicator cannot — a thread was caught throwing the tear NPE while it held the
Duplicate lock, proving the writer is elsewhere. The concurrent-map fix above sidesteps this
entirely by making the READ tear-proof rather than serializing the writer.

## The details (updated after testing)

Testing the ObjectDuplicator overlay revealed that the cold-start failure is actually TWO
separate races, not one:

1. **The metadata-duplication race** — ColdFusion's `Duplicate()`
   (`coldfusion.runtime.ObjectDuplicator`) reads and lazily writes the SOURCE object while
   deep-copying it. Concurrent duplicates of shared entity metadata tear it, throwing the
   `CaseInsensitiveMap...getKey` NullPointerException. This is what makes a COLD JVM cascade
   to 100% failure. **A global monitor inside ObjectDuplicator fixes this completely** (zero
   NPEs, no cascade).
2. **The variables-scope contamination** — the original bug: a transient entity's
   `variables`-scope property resolves to another concurrent instance's value, producing the
   SQL "Invalid column/object name" errors and the Quick "couldn't figure out what to do with
   [setAlphaChildren]" errors. This is a DIFFERENT race, in construction/scope-binding, NOT in
   ObjectDuplicator. The ObjectDuplicator overlay does not touch it, so it still leaks.

Two overlay variants were tested for race 1:

- **`synchronized (obj)` (per-object monitor)** — FAILED. Cold: 100% cascade, ~100,000
  ObjectDuplicator NPEs. Warm: 770 5xx / 360 classified per 20,000. The per-object lock does
  not exclude the thread that mutates the shared map from a non-duplicate path, so it barely
  helped. Dead.
- **`synchronized (ObjectDuplicator.class)` (global monitor)** — fixes race 1: ZERO
  ObjectDuplicator NPEs, no cascade. But race 2 remains: a cold 4,000-request probe showed
  159 5xx (4%) / 85 classified, all of them SQL table-name or Quick-setter contamination —
  none were the duplication NPE.

So the ObjectDuplicator fix is necessary (it stops the cascade) but NOT sufficient (the
scope contamination survives). Adobe's v1 hotfix stops BOTH races at once because its global
construction lock serializes all construction — which incidentally serializes the metadata
duplication (race 1) AND the scope binding (race 2). Its four per-instance class fixes
(TemplateProxy / UDFMethod / Closure) target race 2 specifically.

**The combined overlay was built and tested. It FAILED, and the failure is conclusive:**
v1's four per-instance scope fixes are COUPLED to v1's construction lock. Combining them
with the ObjectDuplicator global lock but WITHOUT the construction lock brings the cold
cascade straight back (4,000/4,000 on a cold probe, the ObjectDuplicator `getKey` NPE).

The captured stack proves why: the tearing thread is INSIDE the locked
`_duplicate`/`_duplicate0`, holding the global Duplicate monitor, yet the NPE still fires —
so another thread is structurally mutating the shared metadata map from OUTSIDE
ObjectDuplicator. That concurrent writer is absent with stock Update 23 core classes (the
standalone ObjectDuplicator lock had ZERO such NPEs), but present once the v1-era
per-instance classes are added. Those classes bind super-scopes during construction and
depend on v1's construction lock to serialize that work. Remove the lock and they actively
tear the duplication. This is almost certainly why Adobe ships the per-instance fixes and
the construction lock together — they cannot be separated.

Two lock-object variants were tried for the combined jar, both cascaded identically:
`synchronized (ObjectDuplicator.class)` and `synchronized ("interned-string")` (a JVM-wide
monitor immune to classloader-identity splits). The lock object is not the problem; the
unserialized external writer is.

**Conclusion for the engine-jar approach:** you cannot beat v1 by cherry-picking its pieces.
The ObjectDuplicator lock does not even reliably fix the cold cascade on its own — its one
clean run was a lucky cold start, and re-probing the same jar cold cascaded to 100% (see the
"Why no lock-free fix can work" section above). The construction-time writer runs outside any
lock a duplicator can take. v1's construction lock stays; it is the only thing that
serializes that writer.

## Why this is aimed differently from v1, unlocked, and stripe

- **v1 global lock** serializes ALL CFC construction in `resolveName`. It stops the
  corruption only as a side effect: the metadata duplication runs downstream of
  construction, so serializing construction also serializes the duplication. That is why
  it works and why it is slow.
- **unlocked / stripe** removed or narrowed that `resolveName` lock. Both failed because
  the race was never in `resolveName` to begin with — the shared object is the common
  `BaseEntity` metadata, duplicated from two different leaf components, so per-component
  locking cannot cover it and no lock closes it.
- **v3** tried to lock the duplication (the visible tear site) instead of construction. That
  is why it fails: the tear is caused by a WRITE elsewhere (construction), so locking the
  duplication is not enough. See `docs/research-log/2026-08-21-startup-crash-root-cause.md` for the captured stack.

## What v3 changes, exactly (the tooling, which is kept)

The overlay jar `hotfixes/hf202300-4232227-v3.jar` (current on-disk SHA256
`A87543CB9903DF2C987D718942F8473213AFC0D62081271DD52AD4937CF816AB`, the standalone
interned-string-lock build) contains ONE class: `coldfusion/runtime/ObjectDuplicator.class`,
patched — its private `_duplicate` renamed to `_duplicate0` and a new `_duplicate` that wraps
the call in a global monitor (`synchronized` on a JVM-wide interned String). Earlier variants
used `synchronized(obj)` and `synchronized(ObjectDuplicator.class)`; none reliably fixes the
cold cascade, for the reason in "Why no lock-free fix can work." The `-V3Combined` build adds
v1's four per-instance fixes on top (also fails). It deploys under the name
`hf202300-4232227.jar` next to `chf20230023.jar`. The bootstrap classloader loads `hf`
jars ahead of the `chf` update jar and `cfusion.jar`, so this one class wins and everything
else stays stock Update 23.

The patch: the private `_duplicate(Object, IdentityHashMap)` is renamed to `_duplicate0`,
and a new `_duplicate` with the same signature wraps the call in `synchronized (obj)`:

```
_duplicate(obj, refCache):
    monitorenter obj
    try { return _duplicate0(obj, refCache); }
    finally { monitorexit obj }
```

Built by `scripts/archive/Build-UnlockedJar.ps1 -V3`, which verifies the overlay has exactly one
entry, that it differs from the stock class, that the disassembly shows 1 monitorenter / 2
monitorexit, and that the class passes the JVM bytecode verifier before it is trusted. The
base `cfusion.jar` SHA is pinned so a changed engine refuses to build instead of guessing.

Runtime provenance is confirmed per arm: on v3-u23, `classSources` reports
`ObjectDuplicator` loading from `hf202300-4232227.jar` and `TemplateProxyFactory` loading
from stock `chf20230023.jar`.

## Correctness results

All runs 2026-08-21, same machine, same JVM (Temurin 17.0.20), same SQL Server database.
"Cold" = the JVM had never served a repro request before the concurrent load hit.
"Warm" = 20 sequential requests per endpoint ran first. Judge on the HTTP 500 count plus
the logs, never the classified counter alone (cascade errors pre-empt the SQL detector).

| Arm / build | State | Requests | HTTP 500s | Classified | Verdict |
|---|---|---|---|---|---|
| buggy (2023.0.21), no jar | warm | 20,000 | 978 (4.9%) | 476 | positive control OK |
| v1 lock (lock-u23) | cold | 20,000 | 1 (prior round) | 0 | the bar to beat |
| unlocked-u23 (prior round) | cold, 3 JVMs | 300,000 | 300,000 (cascade) | 0 | dead |
| stripe-u23 (prior round) | cold | 20,000 | 20,000 (cascade) | 0 | dead |
| v3, `synchronized(obj)` | cold | 100,000 (stopped) | ~100,000 (cascade) | 0 | dead — per-object lock ineffective |
| v3, `synchronized(obj)` | warm | 20,000 | 770 (3.9%) | 360 | barely better than unpatched |
| v3, global Duplicate lock (class monitor) | cold probe #1 | 4,000 | 159 (4.0%) | 85 | LUCKY cold start — no first-burst tear |
| v3, global Duplicate lock (interned string) | cold probe #2 | 4,000 | 4,000 (cascade) | 0 | dead — cascaded, NPEs thrown while holding the lock |
| v3, global Duplicate lock (interned string) | cold probe #3 | 4,000 | 4,000 (cascade) | 0 | dead — cascaded again (262 tear NPEs) |
| v3-combined (per-instance + global lock) | cold probe | 4,000 | 4,000 (cascade) | 0 | dead — per-instance fixes need the construction lock |
| v3-combined, interned-string lock | cold probe | 4,000 | 4,000 (cascade) | 0 | dead — same, lock object is not the cause |

Pass criteria (unmet by every v3 variant): no cold cascade, and residual 5xx at or below
the v1 lock (~1 per 20,000). The single "159 / 4,000, no cascade" run was one lucky cold
start; re-running the same jar cold cascaded to 100%. Cold-start outcome is bimodal (tear in
the first concurrent burst → cascade, or not → low steady rate), and the ObjectDuplicator
lock only lowers the tear probability — it does not remove it.

## Why no lock-free fix can work (the real deliverable)

The captured stack shows a thread throwing the metadata-tear NPE at
`ObjectDuplicator._duplicate0` **while it holds the global Duplicate lock** (the stack goes
`_duplicate` → `_duplicate0`, i.e. through the monitor). If the lock were enough, no thread
holding it could ever see a torn read. So the thread that STRUCTURALLY MUTATES the shared
metadata map is not another duplicator — it is construction code (Quick's `getOrSet`
producer running `getMetadata`/`getInheritedMetadata`, and ColdFusion's own lazy metadata
population) that writes the map during `onDIComplete`, outside ObjectDuplicator and outside
any lock a duplicator could take.

That is why only a lock around CONSTRUCTION works: v1's `CONSTRUCTION_LOCK` in
`resolveName` serializes the whole construction path, so the metadata WRITE and the metadata
DUPLICATE never overlap. Any lock placed inside ObjectDuplicator, or keyed on the object
being copied, or keyed per-component, leaves that construction-time writer free to run
concurrently — which is exactly what every failed variant (unlocked, stripe, all v3 builds)
demonstrates. The two races are really one requirement: serialize construction. Adobe's v1
does that; its per-instance class fixes and its construction lock are a package that cannot
be split. v1 stays in production.

## Performance results

`[PENDING]` — run only if correctness passes. Real-workload (/repro) throughput vs the
buggy (vanilla) arm and the v1 lock. For reference, prior rounds measured the v1 lock at
~1.86x the cost of vanilla on /repro (not the 5.5x figure, which came from the synthetic
construct endpoint). Pass bar: v3 at >=90% of vanilla /repro throughput.

| Conns | buggy (vanilla) rps | v1 lock rps | v3 rps | v3 / vanilla | v3 / v1 |
|---|---|---|---|---|---|
| [PENDING] | | | | | |

Lock evidence under load (`Get-LockEvidence.ps1 -Arm v3-u23 -Endpoint repro`): `[PENDING]`.
Expectation for this fix: near-zero threads blocked in `resolveName` (the v1 lock's ~25 of
32), with only brief contention on genuinely shared metadata objects.

## Reproduction

```
.\scripts\Build-UnlockedJar.ps1 -V3
.\scripts\Install-U23BenchmarkArms.ps1
# positive control:
.\scripts\Invoke-ContaminationGate.ps1 -Arm buggy-warm-control -Port 60845 -TotalRequests 20000 -Connections 20
# the real gate (cold-restart v3-u23 first):
.\scripts\Invoke-ContaminationGate.ps1 -Arm v3-u23-cold -Port 60847 -ConfigFile server-bench-v3-u23.json -TotalRequests 100000 -Connections 20 -Sessions 3 -RestartBetweenSessions
```
