# Phase 0 findings: the exact corrupting operation on cold start

> **Naming:** this note is about the first phase of our own experimental "v3" line, not Adobe's third hotfix. See [the research log index](README.md).

Date: 2026-08-21. Arm: `unlocked-u23` (stock Update 23, no lock), started cold, driven with
32 concurrent connections on `/repro/alpha` + `/repro/bravo`, 30 thread dumps taken during
the burst. Logs were rotated first so this is a clean capture.

## The headline

The corruption does NOT happen in `TemplateProxyFactory.resolveName`. It happens inside
ColdFusion's `Duplicate()` built-in function, while Quick's `BaseEntity` duplicates entity
metadata during dependency-injection completion. This runs on essentially every entity
instance construction.

Of 294 threads caught blocked on a monitor across the 30 dumps, only **1** was in
`TemplateProxyFactory.resolveName`. The monitors actually contended were `ApplicationScope`
(192) and the JDBC connection pool (99) — normal load, not the bug. So resolveName is not
where the threads collide.

## The corrupting call stack (captured live)

A thread caught mid-corruption (`dump-019.txt`, thread `XNIO-1 task-91`, state RUNNABLE):

```
java.util.HashMap.keysToArray(HashMap.java:948)
java.util.HashMap$KeySet.toArray(HashMap.java:997)
coldfusion.util.CaseInsensitiveMap$ScopeIterator.<init>(CaseInsensitiveMap.java:426)
coldfusion.util.CaseInsensitiveMap$ScopeSet.iterator(CaseInsensitiveMap.java:394)
coldfusion.runtime.ObjectDuplicator._duplicate(ObjectDuplicator.java:154)
coldfusion.runtime.ObjectDuplicator.duplicate(ObjectDuplicator.java:80)
coldfusion.runtime.ArrayUtil.Duplicate(ArrayUtil.java:118)
coldfusion.runtime.ObjectDuplicator._duplicate(ObjectDuplicator.java:92)
...
coldfusion.runtime.CFPage.Duplicate(CFPage.java:10902)
cfBaseEntity...funcMETADATAINSPECTION._factor0(modules/quick/models/BaseEntity.cfc:2727)
cfBaseEntity...funcMETADATAINSPECTION.runFunction(BaseEntity.cfc:2722)
...
cfBaseEntity...funcONDICOMPLETE.runFunction(BaseEntity.cfc:293)
...
coldfusion.runtime.TemplateProxy.invoke(TemplateProxy.java:539)
cfInjector...funcPROCESSAFTERCOMPLETEDI(coldbox/system/ioc/Injector.cfc:1225)
```

A second thread caught in the same duplication (`dump-016.txt`, `XNIO-1 task-82`), showing
the WRITE side of the race:

```
coldfusion.util.CaseInsensitiveMap.put(CaseInsensitiveMap.java:97)
coldfusion.runtime.Struct.getAdditionalMetadata(Struct.java:386)
coldfusion.runtime.Struct.setMetaData(Struct.java:377)
coldfusion.runtime.ObjectDuplicator._duplicate(ObjectDuplicator.java:150)
coldfusion.runtime.ObjectDuplicator.duplicate(ObjectDuplicator.java:80)
coldfusion.runtime.CFPage.Duplicate(CFPage.java:10902)
cfBaseEntity...funcMETADATAINSPECTION._factor0(BaseEntity.cfc:2727)
...same onDIComplete path...
```

Frame frequencies across all 30 dumps confirm this is the hot path, not a fluke:
`metadataInspection` 210 hits, `TemplateProxyFactory.resolveName` 51, `CaseInsensitiveMap`
17, `ObjectDuplicator` 12, `ScopeIterator` 1.

## What this means (the mechanism)

1. Quick's `BaseEntity.metadataInspection` (BaseEntity.cfc:2722-2727) calls ColdFusion's
   `Duplicate()` on an entity metadata structure. This runs inside `onDIComplete`
   (BaseEntity.cfc:293) — WireBox's post-construction hook — so it fires for every transient
   entity instance that gets built.
2. `ObjectDuplicator` deep-copies that structure. During the copy it BOTH reads the source
   map (via `ScopeIterator.<init>` → `HashMap.keysToArray`, line 154) AND writes to a map
   (`Struct.setMetaData` → `CaseInsensitiveMap.put`, line 150). So the duplicator mutates
   maps while iterating maps.
3. The structure being duplicated is SHARED across the two concurrent constructions. When
   AlphaParent and BravoParent are built at the same time, both duplication passes reach the
   same underlying `CaseInsensitiveMap` (backed by a plain `java.util.HashMap`). One thread's
   `keysToArray`/iterator sees the map mid-mutation from the other thread → a torn read → the
   "this.key is null" NPE. That first NPE poisons the shared structure, and every later
   request fails (the cascade).

## Why this fits every prior result

- **Global lock (v1) works** because it serializes ALL construction in `resolveName`, and
  `onDIComplete`/`metadataInspection` runs inside construction. The lock is not fixing
  resolveName's own state — it is incidentally serializing the metadata duplication that
  happens downstream of construction. That is also why it is slow: it serializes far more
  than the racy region.
- **Per-component (stripe) lock fails** because AlphaParent and BravoParent are different
  leaf components, so they take different per-component locks — but they duplicate a shared
  metadata structure, so they still collide.
- **Cold start is fatal** because the shared structure is populated/duplicated on first use;
  a cold burst guarantees two threads hit it at once during that first population.

## Which candidate hypothesis this confirms

This confirms **candidate (a)** from the plan's correction 5: metadata shared across the
concurrent constructions, reached through the common `BaseEntity` code. It is NOT the
per-instance `variables` scope theory. The shared thing is what Quick's `metadataInspection`
passes to `Duplicate()`. The exact identity of that structure — whether it is the cached
component metadata subtree for the `BaseEntity` ancestor, or a Quick-level cached struct — is
the one open question for Phase 1, which reads BaseEntity.cfc:2722-2727 and the
`ObjectDuplicator` bytecode to name it exactly.

## Impact on the fix approaches (Phase 2)

The fix target moved OUT of `TemplateProxyFactory` and INTO the duplication path. Re-rank:

- The cleanest fix may be at the ColdFusion engine level: make `ObjectDuplicator` /
  `CaseInsensitiveMap` duplication safe (iterate over a snapshot, or don't mutate the source
  during copy). Both classes live in `cfusion.jar` (Approach A packaging). This fixes the
  race for ALL callers with no construction lock.
- Alternatively, at the Quick level (not an Adobe hotfix): make `metadataInspection`
  duplicate from a per-instance or immutable snapshot, or memoize the duplicated result so
  the shared structure is only copied once. This is an app/module change, not a jar patch,
  and may be simpler and safer. The original plan did not consider it.
- Approach B/C (narrowing or re-keying the `resolveName` lock) now looks WRONG-targeted: the
  race is not in resolveName, so locking resolveName only ever helped by side effect. A
  narrow lock in resolveName around a region that doesn't contain the duplication would not
  fix the bug. Any lock-based fix must wrap the duplication itself.

## Housekeeping

- The temporary 8000-char stack truncation in `handlers/Repro.cfc` was reverted (git shows
  the file clean).
- Old logs saved as `logs/repro_errors-2026-08-21-prephase0.txt` and
  `logs/contamination_log-2026-08-21-prephase0.txt`.
- The `unlocked-u23` arm was stopped by PID.
- Raw dumps: `benchmark-results-u23/threaddumps-unlocked-u23-repro/`. Lock-evidence summary:
  `benchmark-results-u23/lock-evidence-unlocked-u23-repro.json`.
