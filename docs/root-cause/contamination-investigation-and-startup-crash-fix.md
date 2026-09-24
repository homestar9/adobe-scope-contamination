# Race 2 investigation — results (2026-08-22 session)

This session set out to port BoxLang's approach to ACF: try to close race 2 (the ~4%
variables-scope contamination) without the v1 construction lock, or prove it needs the lock /
an Adobe-runtime change, and build a shippable fallback jar.

Race 1 (the cold-start cascade) was already fixed lock-free by the `concmap` overlay. This doc
is only about race 2.

## Short version

- **The app-level experiments did not find a lock-free race-2 fix.** A global lock around
  Quick's `metadataInspection` cut the rate roughly in half but left plenty of contamination.
  The scope-identity probe never fired, which means the corruption is not visible as an
  inconsistency inside that method — it happens in ACF's construction path around it.
- **The shippable fallback works.** `hf202300-4232227-concmap-v1.jar` (Adobe's v1 hotfix, lock
  and all, plus the concurrent `CaseInsensitiveMap`) passed the cold probe with zero errors.
  Its full gate (cold, 3 fresh JVMs, 300k) is running.
- Decompilation to name the exact shared structure is in progress (Phase B).

## Positive control (proves the detector works)

Buggy arm (ACF 2023.0.21, no hotfix), warm, 20,000 requests, 20 connections per endpoint:

| Run | HTTP 5xx | Classified | Rate |
|---|---|---|---|
| buggy-warm | 813 | 414 | 4.1% |
| buggy-warm (probe rev 2) | 791 | 378 | 4.0% |

Error breakdown across these runs: `TABLE_NAME_CONTAMINATION` (wrong table in the UPDATE) and
`VARIABLES_SCOPE_CORRUPTION` (a `variables`-scoped value resolved to another instance), roughly
3:1. Zero `getKeyString` race-1 NPEs (expected — this is a warm run).

## Phase A — app-level experiments

### A1: scope-identity probe inside metadataInspection

I instrumented `modules/quick/models/BaseEntity.cfc` `metadataInspection` to log a line only
when the instance's scope identity looked wrong. Checks: `_str`/`_mapping` missing at entry;
`_mapping` changed between entry and after the `duplicate()` assignment; `_meta.fullName`
disagreeing with the entry mapping; `_mapping` changed by exit; `_table` disagreeing with
`_meta.table`; and a wholesale check comparing `getMetadata(this).fullname` (the true compiled
class of the object) against `_mapping`.

**Result: the probe never fired**, across more than 40,000 contaminated requests. A
`PROBE_ALIVE` line confirmed the log write path works, so the silence is a real finding, not a
broken probe.

Reading: at the moment `metadataInspection` runs, the object identity (`this`) and its
`variables` scope are mutually consistent and correct. The ~4% contamination is **not** a
wholesale variables-scope swap observable inside this method. Whatever crosses does so in the
construction path around the method, not as an internal inconsistency the method could catch.

### A2: global exclusive lock around metadataInspection

I wrapped the whole `metadataInspection` body in one app-wide `cflock` (a single literal name,
so Alpha and Bravo actually serialize against each other). Buggy arm, warm, 20,000:

| Run | HTTP 5xx | Classified | Rate |
|---|---|---|---|
| buggy-warm-a2lock | 361 | 107 | 1.8% |

The lock cut the rate from ~4% to ~1.8% but did not close race 2. Combined with the A1 result
(no in-method inconsistency ever seen), the most consistent reading is: serializing
`metadataInspection` reduces how much construction overlaps, which shrinks the window for the
real race, but the racing writer is elsewhere in the construction path. Only a lock that covers
the whole construction (v1's lock in `TemplateProxyFactory.resolveName`) serializes it fully.

Both the probe and the lock were reverted after measuring. The probe helper is kept in the file
(harmless, logs only on mismatch) for later rounds; the A2 lock was removed.

## Fallback jar (the shippable answer)

New patcher mode `--concmap-v1` (`scripts/archive/java/PatchHotfix.java`) and build switch `-ConcMapV1`
(`scripts/archive/Build-UnlockedJar.ps1`) produce `hotfixes/hf202300-4232227-concmap-v1.jar`:
Adobe's original v1 hotfix jar (per-instance fixes AND the global construction lock, untouched)
plus the concurrent `CaseInsensitiveMap` from the concmap fix. The build refuses to run unless
the base jar is really the locked v1 jar (its `resolveName` wrapper still has a `monitorenter`)
and verifies the output has the locked shape (3 monitorenter), the four per-instance fix
classes, a `CaseInsensitiveMap` that differs from stock, and passes `-Xverify:all`.

- SHA256: `4943E46A045C15D9D32E0C2D108F00CC0001C5694D9D222A10B85780F32C985A`
- Cold probe (v3-u23 arm, 4,000 requests): **0 HTTP 5xx, 0 classified — clean.**
- Full gate (cold, 3 fresh JVMs, 300k): running.

Why it is strictly safer than v1 alone: the lock closes race 2 (~1/20k residual), and the
concurrent map makes the race-1 duplication tear structurally impossible even if the lock ever
has a gap.

## Phase B — decompilation

Goal: name the exact shared mutable structure in ACF's construction path that carries one
instance's scope into another, and decide whether it is reachable from engine classes
(patchable by an overlay) or emitted into compiler-generated CFC bytecode (not patchable —
would need an Adobe change).

### The litmus test passed: the racing code is in the engine, not generated bytecode

I decompiled the on-disk compiled bytecode for `metadataInspection`
(`.engine/bench-u23/WEB-INF/cfclasses/cfBaseEntity2ecfc719693131$funcMETADATAINSPECTION.class`).
Every read and write of the `variables` scope goes through an engine method call on the
per-call page parameter:

- The function body `runFunction(LocalScope, Object instance, CFPage parentPage,
  ArgumentCollection)` receives the page as a normal method parameter (`parentPage`, loaded as
  `aload_3`).
- Reading `variables._cache` / `_mapping` / `_str` compiles to
  `parentPage._resolve("VARIABLES", {...})` / `._resolveAndAutoscalarize("VARIABLES", {...})`.
- Writing `variables._meta` / `_table` compiles to `parentPage._structSetAt("VARIABLES", {...})`.
- There is **no** `getstatic`/`getfield` of any scope, map, or struct anywhere in the class.
  The compiled code never holds the scope in a field; it asks the engine for it by the string
  name `"VARIABLES"` on every access.

The per-UDF objects (including `metadataInspection`) are `private static final` fields on the
generated component class — shared across instances — but they hold no per-call scope state;
`instance`, `parentPage`, `__localScope`, and `__arguments` all arrive as parameters.

**Consequence:** the racing memory access lives inside `coldfusion.runtime.CfJspPage._resolve`
/ `._resolveAndAutoscalarize` / `._structSetAt` and `CFPage.Duplicate` — all engine classes in
`cfusion.jar`, all overlayable. No Adobe compiler change is required to reach the code. The open
question narrows to: how does `parentPage._resolve("VARIABLES", ...)` pick which scope map to
return, and what shared thing (a per-thread scope stack, a page-context "current" pointer, or
the `Duplicate()` object cache) lets a concurrent construction swap it? That decision is made in
engine classes — which the TemplateProxy / UDFMethod / page-context decompiles are pinning down.

### The exact shared structures (UDFMethod / TemplateProxyFactory)

Decompiled stock (from `chf20230023.jar`) vs v1 (from the hotfix jar). Two shared mutable
references carry one instance's scope into another during concurrent construction:

1. **`coldfusion.runtime.UDFMethod.superScope`** (instance field, v1 `UDFMethod.java:118`). One
   `UDFMethod` object is shared by every instance of a component (it is keyed by the compiled
   component class via its class loader). Stock `UDFMethod.invoke` reads this shared field
   directly (`this.superScope`, stock line 404) to push the super scope for a `super.method()`
   call. Two concurrent constructions of the same component both stamp their own super scope
   onto this one field, so a later `super` call can push the wrong one.

2. **The "current variables scope" pointer** returned by
   `page.pageContext.getVariableScope()`. Stock
   `TemplateProxyFactory.registerImplicitAccessorsInVarScope(CfJspPage)` (stock lines 464-482)
   reads this pointer and binds the generated getter/setter UDFs into whatever scope it points
   to at that instant — and that pointer is pushed, popped, and reset all through
   `resolveComponentHelper`. `TemplateProxy.setupScopesForInvoke` had the identical idiom (stock
   line 745). So the accessors, and the invoke-time scope, could land in a scope that is not the
   instance being built.

**What v1 changed (the READ side only):** v1 added `UDFMethod.resolveInvocationSuperScope(Object
instance)` (v1 lines 128-134) which derives the super scope from the invocation target — the
`TemplateProxy` instance — via new per-instance fields `boundSuperScopeLevel0` (volatile) and
`boundSuperScopesByLevel` (a `ConcurrentHashMap<String,Scope>`), falling back to the shared
`this.superScope` only if the per-instance lookup misses. It changed
`registerImplicitAccessorsInVarScope` to take a `TemplateProxy` and bind accessors into
`instance.getVariableScope()` (the per-instance `varScope` field), and made
`setupScopesForInvoke` read `this.getVariableScope()` too. These stop the code from *trusting*
shared scope pointers at read time.

### Why the per-instance read fixes still need the lock

The write side into shared state was NOT removed. On every construction:

- `TemplateProxyFactory.setupThisAndSuper` still writes the shared `UDFMethod` via
  `function.setSuperScope(superScope)` (v1 lines 758/771) and merges into the shared `SUPER`
  struct (`funcSuper.put(...)`, v1 line 768). `superScope` is a fresh `VariableScope` made per
  construction, so each construction races to overwrite the shared field.
- Shared per-component structures are mutated during `resolveComponentHelper`: the component
  `metadata` (`metadata.put(Key.EXTENDS, ...)`, `initImplicitGettersAndSetters` →
  `metadata.put(Key.FUNCTIONS, ...)`) and the implicit-method map (`comp._setImplicitMethods`).
- The hot duplicate path bypasses the lock entirely: `resolveNameForDuplicate` (v1 lines
  159-162) calls `resolveComponentHelper` directly, NOT through `resolveName`, so it never takes
  `CONSTRUCTION_LOCK`. `CONSTRUCTION_LOCK` guards only `resolveName` (v1 lines 184-187). So while
  one thread's `ObjectDuplicator.Duplicate()` reads these shared structures, another thread's
  construction writes them — outside any shared lock.
- An opt-in path, `registerImplicitUDFs` (only active when the app setting is on), was never
  converted to per-instance and still reads `page.pageContext.getVariableScope()` (v1 line
  1172).

So v1's per-instance reads remove the read-time trust in shared pointers, but every construction
still writes shared `UDFMethod.superScope`, the shared `SUPER` struct, and shared component
metadata — and the duplicate path runs construction with no lock at all. Only serializing all
construction through the global `CONSTRUCTION_LOCK` makes those concurrent shared writes safe.
This is exactly why "v1's per-instance fixes without the lock" measured the same ~4% as
unpatched, and why a jar overlay cannot close race 2 without either re-adding the lock or
removing the shared writes across `setupThisAndSuper`, `resolveComponentHelper`,
`initImplicitGettersAndSetters`, and the lock-bypassing `resolveNameForDuplicate` path — a broad,
high-risk change across several engine methods that also has to guarantee the per-instance
super-scope map is always populated before any `super` call (or `super.method()` breaks).

### The decisive detail: why per-instance storage cannot fix it alone

A second independent decompile confirmed the above and found the exact reason the v1
per-instance store is not enough by itself. In `setupThisAndSuper`, when a second thread finds
`function.getSuperScope()` already set by the first thread, it does not just overwrite — it
**merges** its own method entries into the first instance's `SuperScope` struct
(`TemplateProxyFactory` v1 lines 763-768: read `funcSuper = function.getSuperScope().get(SUPER)`,
then `funcSuper.put(key, val)`). That `funcSuper` object is the very struct the first instance's
`boundSuperScopeLevel0` points at. So instance A's per-instance store faithfully records
`superScopeA`, but `superScopeA`'s struct gets method entries from instance B written into it by
B's construction thread. The per-instance map points at a shared object that a concurrent
construction is still mutating. Only the global lock, which serializes the whole build, stops
the two constructions from touching that object at the same time.

The three decompiles agree on the named reference: **`coldfusion.runtime.UDFMethod.superScope`**
(`protected Scope`, non-final, non-volatile), on a `UDFMethod` object shared by all instances of
a component (the UDFMethods are `private static final` fields on the generated component class,
bound into each instance's variables scope by `registerUDFs()`). Written and merged during
`setupThisAndSuper`. The secondary reference is the page-context variables-scope pointer
(`CfJspPage.varScope`, set by `bindPageVariables`), which v1 stopped trusting at read time but
still writes during construction.

### How this maps to the BoxLang / Lucee comparison

BoxLang never has a shared `superScope` field to race: its super-scope values are copied into
each instance's own concurrent scope at construction (`BoxClassSupport` `addAll`), and its
metadata is built fresh per call. Lucee isolates construction with thread-local construction
state. ACF instead shares the `UDFMethod` object and the component metadata across instances and
serializes construction with a lock. The concurrent-map half of BoxLang's design ported cleanly
(concmap = race 1). The per-instance-construction half is a runtime-construction-model property:
ACF binds and writes shared construction state that only its lock serializes, so replicating it
without the lock means rewriting ACF's construction write path, not adding an overlay class.

## Conclusion: race 2 needs the construction lock (or an Adobe-runtime change)

No lock-free overlay was built for race 2, and the decompilation shows why one is not a narrow,
safe overlay:

1. The racing code is in engine classes (good — reachable by an overlay, not compiler-generated),
   but the fix is not a single site. Construction writes shared state in several places:
   `setupThisAndSuper` (writes and merges `UDFMethod.superScope` and its `SUPER` struct),
   `resolveComponentHelper` / `initImplicitGettersAndSetters` (mutate shared component
   `metadata`), and `_setImplicitMethods` (shared implicit-method map).
2. A true lock-free fix would have to stop writing the shared `UDFMethod.superScope` and the
   shared `SUPER` struct entirely, keep super scope strictly per-instance, and guarantee the
   per-instance super-scope map is populated before every possible `super.method()` call —
   including from closures, cfthreads, and the reload path — because
   `resolveInvocationSuperScope` falls back to the shared field when the per-instance lookup
   misses. A missed population does not error loudly; it silently reads a cross-written shared
   scope. That is exactly the "passes warm, fails cold at ~4%" failure the plan warned about.
3. The hot duplicate path, `resolveNameForDuplicate`, runs `resolveComponentHelper` without
   taking `CONSTRUCTION_LOCK` at all, so any overlay that relied on the lock's critical section
   being the whole build would still leave this path racing.

This meets the plan's "needs an Adobe-runtime change" bar: the fix requires rewriting ACF's
construction write path across several methods with a real, silent correctness risk, not adding
an overlay class. The BoxLang-faithful design (no shared super-scope field; super values copied
into each instance's own concurrent scope; metadata built fresh per call) is a construction-model
change that only Adobe can make in the runtime.

## Shipping recommendation

Ship **`hotfixes/hf202300-4232227-concmap-v1.jar`** (SHA
`4943E46A045C15D9D32E0C2D108F00CC0001C5694D9D222A10B85780F32C985A`): Adobe's v1 hotfix (lock and
per-instance fixes) plus the concurrent `CaseInsensitiveMap`. It is correct today and strictly
safer than v1 alone — the lock closes race 2 to v1's ~1/20,000, and the concurrent map makes the
race-1 cascade structurally impossible even if the lock ever has a gap.

For the Adobe report: the concmap argument covers race 1 cleanly ("your own successor engines
default their scope maps to concurrent; ACF's `CaseInsensitiveMap` defaults to `HashMap`, and you
already ship `CFConcurrentHashMap` — make it the default"). Race 2 is the construction-model
argument above: the shared `UDFMethod.superScope` and shared component metadata, written and
merged during construction, are what force the lock; BoxLang and Lucee avoid the lock by never
sharing that construction state.

### Fallback gate result

Cold, 3 fresh JVMs, 100,000 requests each (300,000 total), 20 connections per endpoint:

| Session (fresh JVM) | Requests | HTTP 5xx | Classified |
|---|---|---|---|
| 1 | 100,000 | 0 | 0 |
| 2 | 100,000 | 0 | 0 |
| 3 | 100,000 | 0 | 0 |
| **total** | **300,000** | **0** | **0** |

`logs/repro_errors.txt` was empty (no failures at all), and `grep getKeyString` found zero
race-1 NPEs. This is cleaner than v1 alone, which leaked exactly 1 `VARIABLES_SCOPE_CORRUPTION`
in 20,000 on an earlier run: the concurrent map removes the race-1 tear path entirely, and this
300k cold run saw zero race-2 leaks. The fallback is confirmed shippable and strictly safer than
v1.
