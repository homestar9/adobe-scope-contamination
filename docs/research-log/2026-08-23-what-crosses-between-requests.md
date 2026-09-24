# v4 Phase 0: what actually crosses (2026-08-23)

> **Naming:** this note is about our own experimental "v4" line (a planned engine patch), not an Adobe hotfix. See [the research log index](README.md).

This is the diagnostic round the v4 plan called for, done by measuring a running server
instead of by reading bytecode. It answers the question three earlier attempts guessed at.

**Headline: the shared `UDFMethod.superScope` field is not the cause of race 2.** It crosses
between requests just as often on a build that has zero failures. What does track the failures
exactly is something nobody had measured: a request calling a method on a component object that
a different, still-running request built.

## How this was measured

`scripts/archive/Build-UnlockedJar.ps1 -Trace` builds a jar that changes no behavior. It renames five
engine methods to `<name>$orig`, puts a thin wrapper in their place, and has each wrapper hand
`(this, args, result)` to `coldfusion.runtime.ScopeTrace`. The wrappers are straight-line code
with no branches and no exception handlers, so they need no stack map frames; every hook catches
`Throwable` itself. All five patched classes pass `-Xverify:all`. Nothing runs unless the server
starts with `-Dcfscope.trace=<file>`.

Instrumented: `UDFMethod.resolveInvocationSuperScope`, `UDFMethod.setSuperScope`,
`UDFMethod.invoke(FusionContext)`, `TemplateProxy.getBoundSuperScopeForLevel`,
`TemplateProxy.setupScopesForInvoke`, `TemplateProxyFactory.setupThisAndSuper`,
`TemplateProxyFactory.resolveName` (the 8-argument overload), and
`NeoPageContext.pushNewFunctionLocalScope` / `getActiveFunctionLocalScope`.

**The owner table.** When a scope is created during a construction, its identity is recorded
against the request that made it, together with a reference to the scope object itself and to
the component it was built for. A later read of that same object by a different in-flight
request is a crossing. Two things keep this honest:

- Every lookup compares the stored reference with `==` before believing the answer, because
  `identityHashCode` is not unique. In the unlocked run this rejected **19,879** false matches.
- Entries are removed when the request that made them finishes, so the table only ever holds
  requests that are still running. It ended both runs at 0 entries, so nothing leaked.

**The comparison that matters.** Raw crossing counts mean nothing on their own — a ColdBox
singleton's scope is read by every request by design. So every measure is tallied per request
and averaged separately over requests that FAILED and requests that SUCCEEDED. A measure that
is much larger on failures is a candidate cause; one that matches is background noise.

`handlers/Repro.cfc` calls `ScopeTrace.mark()` at the start of a request, on success, and on
failure, so engine events and request outcomes line up exactly instead of being matched by
clock time.

## The controls

Same rig, same detector, same workload (8,000 requests, 20 connections per endpoint on
`/repro/alpha` + `/repro/bravo`, warm). The only difference is the base jar.

| | LOCKED (Adobe v1, lock on) | UNLOCKED (v1 classes, lock removed) |
|---|---|---|
| requests | 8,000 | 8,000 |
| HTTP 5xx | **0** | 594 |
| classified contaminations | **0** | 322 |
| variables-scope crossings | **0** | **11,757** |
| super-scope crossings | **740,875** | 606,105 |
| local/arguments-scope crossings | 0 | 0 |
| `resolveName` returned a foreign component | 0 of 603,735 | 0 of 591,806 |
| scope object reused by another request | 0 | 0 |

Raw counter files: `benchmark-results-u23/gate-trace-LOCKED-control/scopetrace.counters` and
`benchmark-results-u23/gate-trace-UNLOCKED-paired/scopetrace.counters`.

## Result 1: the variables-scope crossing is the bug

Per-request averages on the unlocked build (7,446 successes, 594 failures):

| measure | per OK request | per FAILED request | ratio |
|---|---|---|---|
| **crossVarOtherEntity** | **0.0** | **7.0** | **2,497x** |
| crossVarSameEntity | 0.9 | 1.1 | 1.16x |
| crossSuperOtherEntity | 37.3 | 28.5 | 0.76x |
| crossSuperSameEntity | 40.1 | 21.4 | 0.53x |
| boundMiss | 60.0 | 57.6 | 0.96x |
| superWrite | 502.1 | 287.6 | 0.57x |
| construct | 72.0 | 47.2 | 0.66x |
| readSharedObject | 4,486.9 | 2,652.2 | 0.59x |

Only one measure goes up on failing requests, and it goes up by a factor of about 2,500.
Everything else goes *down*, which is what you would expect: a failing request dies early and
does less work.

"crossVarOtherEntity" means: this request called a method on a component whose variables scope
was created by a different request that is still running, and that other request was working on
the other test entity. Four separate runs measured this ratio at 585x, 722x, 2,497x, and
5,960x. The exact number moves with how much the two arms overlap; the finding does not.

And it is zero — not small, zero — on the locked build, where the failure count is also zero.
The detector reads nothing on the build that is known to be correct, and reads the failures on
the build that is known to be broken.

### It is always the same object, never a shared scope

Every one of the 11,757 crossings was the **same component object** being used by two requests
(`CROSSING.varScope.sameComponentObject` = 11,757, `differentComponentObjects` = 0). So this is
not two components accidentally sharing one variables scope. A whole entity object escapes from
one request into another.

### Where it first shows up

The first crossing in each failing request was captured with a call stack. All 77 stacks land
in the same place, inside Quick's relationship setup:

- 66 at `modules/quick/models/Relationships/BaseRelationship.cfc:87`, which is
  `variables.relationshipBuilder = arguments.related.newQuery();`
- 11 at `modules/quick/models/Relationships/HasOneOrMany.cfc:247`

So the foreign object arrives as `arguments.related` — the related entity handed into the
relationship. A representative line:

```
INVOKE_SCOPE_CROSSED  proxy=79ef8527  cfc=models.BravoChild
                      own=32e81b4f  installed=32e81b4f
                      builtFor=BravoParent/TemplateProxy  builtInReq=125  req=AlphaParent
```

A request working on AlphaParent is calling a method on a BravoChild that request 125 built
while serving BravoParent.

## Result 2: the shared super-scope field is NOT the cause

This is the hypothesis the whole v4 plan was built on, and it does not survive contact with
a control.

- On the LOCKED build, which produced **zero** failures, cross-request super-scope reads
  happened **740,875** times — 47.4 per request. More than on the failing build.
- On the UNLOCKED build they happened 606,105 times, 37.3 per request.
- Within the unlocked build, failing requests saw *fewer* of them than succeeding ones
  (0.53x and 0.76x).

A cause cannot be more common on the build with no failures. The shared
`UDFMethod.superScope` field really is written and read across requests constantly — that part
of the earlier analysis was right — but it does not cause the contamination.

The reason it does not matter is visible in the same data: a super scope is used to *find*
method objects, and those are `static final` on the generated component class, so they are the
same for every instance. Reading another instance's super scope still finds the same methods.

### Related detail: Adobe's per-instance read almost never runs

Worth recording because it explains why v1's per-instance fix could not have been the answer on
its own. `UDFMethod.resolveInvocationSuperScope` only consults the per-instance store when the
invocation target is a `TemplateProxy`. Measured over 146,373,042 calls on the unlocked build:

| outcome | count | share |
|---|---|---|
| target was null, so the shared field was used | 87,775,187 | 60% |
| per-instance store held the same object as the shared field | 21,224,435 | 14% |
| per-instance store held a different object | 37,373,420 | 26% |
| **any read that returned the shared field's object** | **100,274,686** | **68.5%** |

The target comes from `FusionContext.instance`, and it is null on 60% of calls. So Adobe's
per-instance read is bypassed most of the time. That is a real defect in the v1 fix — it is just
not the defect that causes race 2.

## Result 3: three more candidates ruled out

Each of these was a plausible mechanism. Each measured zero.

| candidate | how it was tested | result |
|---|---|---|
| The page-context "current variables scope" pointer disagreeing with the instance's own scope | compare both at every `setupScopesForInvoke` | 0 mismatches in 56,406,162 invocations |
| Components handed over at creation | check every component `resolveName` returns | 0 foreign in 591,806 calls |
| The function local / arguments scope crossing | check every `getActiveFunctionLocalScope` | 0 foreign in 162,062,659 reads |
| Scope objects being recycled (which would make the owner table lie) | flag any scope registered twice by different requests | 0 |

The local-scope result is worth dwelling on. `NeoPageContext.pushNewFunctionLocalScope`,
`popFunctionLocalScope`, and `getActiveFunctionLocalScope` are all `synchronized`, which says
Adobe expects more than one thread to reach a page context. It looked like the obvious way for
one request to read another's arguments. It never happened once in 162 million reads.

## Where that leaves the fix

The box is now tight. The object is built correctly, for the right request. ColdFusion's
component resolution does not hand it to anyone else. Its arguments and local variables never
cross. And yet a second request ends up calling methods on it, and only when the construction
lock is off.

That points at a container that CFML code can see and that construction writes to — the shared
per-component metadata that `resolveComponentHelper` and `initImplicitGettersAndSetters` mutate
during every build. It is the same shared structure whose torn reads cause race 1, and Quick
reads it through `getMetadata()` and `duplicate()`. That is a hypothesis, not a result: it is
the next thing to test, not something this round established.

**The concrete next test:** instrument `ObjectDuplicator` and the component metadata map, and
check whether a live component reference belonging to one request ever passes through the shared
metadata into another. If it does, the fix target is BoxLang design point 2 — build metadata
fresh per call instead of sharing one mutable object — which the plan ranked second and
nobody has tried.

---

## Follow-up round, 2026-08-23 (later): the object crosses as a live WireBox argument struct

The census left one thing open: the object is built correctly, yet a second request calls
methods on it. This round traced the value flow through WireBox and found how it crosses. It did
not change the census conclusion — it sharpened it and ruled out the guess above.

Instrumented three more boundaries, all behavior-neutral, all passing `-Xverify:all`:

- `UDFMethod.invoke(FusionContext)` — checks the return value, the invocation target, and every
  argument for a foreign component.
- `UDFMethod.invoke(Object,String,Object,Map)` — the named-args entry point, so a raw CFML
  struct is checked before ACF converts it to an `ArgumentCollection`.
- `CFPage.StructNew()` — registers every `{}` struct literal to the request that created it.

### 1. The object arrives as a function ARGUMENT, not a return value

Per 8,000-request run: a foreign component was returned by a function 1,851 times, but was
passed *as an argument* far more, and the argument crossings line up exactly with the failure
site. The heaviest are all Quick relationship setup:

| foreign argument | count |
|---|---|
| `QuickBuilder.setEntity[newEntity]` | 209 |
| `HasOneOrMany.init[related]` / `BaseRelationship.init[related]` | 109 each |
| `HasOneOrMany.init[parent]` / `BaseRelationship.init[parent]` | 108 each |

The invocation *target* also crosses — a foreign entity used as `this` — 11,013 times, led by
`BaseEntity.qualifyColumn`, `tryScopes`, `tableName`. That is the same entity object seen from
the method side.

### 2. The argument STRUCT itself is the shared object

`BaseEntity.hasMany()` builds `initArguments = { related: <entity>, parent: this, ... }` as a
plain `{}` literal and passes it down through WireBox to the relationship's `init`. That whole
struct object crosses between requests — 4,007 times, led by `BaseEntity.cfc#init` and
`QuickBuilder.cfc#init`. `StructNew` itself always returns a fresh object (0 foreign in 12.1
million calls), so the struct is created clean and shared afterward.

### 3. The decisive part: both requests are still running

Each crossing was classified by whether the request that CREATED the shared object was still
running when the other request read it:

| | creator still running | creator already finished |
|---|---|---|
| entity variables scope | **11,009** | 4 |
| the argument struct | **4,007** | 0 |

So this is two genuinely concurrent requests sharing one live, mutable object graph — the
entity, the struct that carries it, and the entity seen as a method target are all facets of the
same leak. It is not a stale reference held in a singleton past its request. That rules out the
"metadata held in a cache" guess in the section above: a cached-metadata leak would show the
creator already finished, and it essentially never does.

### What this means for the fix

The leak is in the construction / dependency-injection path, it shares a live object between two
overlapping builds, and it is exactly what Adobe's global construction lock serializes away
(zero crossings with the lock on). Every individual engine reference the plan and the census
suspected has now been measured and cleared: super-scope (more common on the clean build),
page-context variables pointer (0), component resolution (0), and the function local/arguments
scope (0 in 162M). The object nonetheless crosses, which means the shared container is one this
round did not name — reached through the WireBox singleton construction path that both requests
run at once.

That is the honest edge of the measurement. Two readings remain open and they need different
fixes:

1. **An ACF engine structure** still shares construction state between the two builds, below the
   frames instrumented so far. If so it is the same class of bug the census describes, and the
   fix is per-instance construction isolation (which only Adobe can do in the runtime) or the
   lock.
2. **WireBox shares a live object through a singleton** during concurrent DI. This one is
   testable without the engine: it would mean the same corruption should appear on any engine
   whose construction is not serialized. BoxLang measured clean on this exact workload, which
   argues against a pure WireBox bug — but it has not been tested with WireBox construction
   deliberately overlapped, so it is not ruled out.

**Next probe (one round):** at each struct/entity crossing, walk from the shared object to the
container that both requests reach — check the invocation target's own `variables` scope, the
WireBox Injector/Builder singleton fields, and the mapping object — and name it. That converts
"reached through the WireBox path" into a specific field, which is what a fix or a precise Adobe
report needs. Until then, the shipping recommendation is unchanged: keep `concmap-v1`.

Raw counters: `benchmark-results-u23/gate-trace-liveclass/scopetrace.counters`. Every counter in
this section is reproducible with `Build-UnlockedJar.ps1 -Trace` at the SHA recorded in
`Install-U23BenchmarkArms.ps1`.

---

## Container walk, 2026-08-24: the shared object is in no persistent container

This round ran the "name the field" probe: at a crossing, walk the object graph from every
long-lived root to the exact foreign object (by identity) and print the path. If a transient is
reachable from a process-wide root, that root is the leak. The walk is bounded (depth 8, 120,000
nodes) and runs only on the first dozen crossings. It is behavior-neutral and passes
`-Xverify:all` like the rest.

Roots walked, in order of suspicion: the shared per-class component metadata
(`getMetadata()`), `TemplateProxyFactory.componentCache` (static), `TemplateProxyFactory.baseMetaData`
(static), the application scope, the server scope, and the WireBox Injector singleton.

**Result: the foreign object was reachable from none of them.** Across the run, all 12 entity-scope
crossings and all 12 struct crossings came back `notFoundFromAnyRoot`. Not the shared metadata,
not the component cache, not the app scope, not WireBox.

That is a strong negative and it reshapes the conclusion. The object provably crosses between two
concurrent requests (previous section), yet a walk microseconds later finds it held by nothing
persistent. The only way both are true is that the reference is **transient**: one thread writes
it into a shared slot during construction and another thread reads it before it is overwritten or
cleared. A post-hoc walk cannot catch a reference that is already gone.

### Shared page context: real but not the vector at the symptom

WireBox's Injector and Builder are singletons, so they have one `NeoPageContext` that every
request co-uses. That made a shared page context the natural suspect: two concurrent requests
pushing function frames onto one shared scope stack. Two tests:

- Page contexts *are* shared across concurrent requests — confirmed, though rarely caught (the
  detector only compares against the single last pusher, so it undercounts).
- But at the moment of a crossing, the foreign object's creator was on a **different** page
  context than the reader every time: 7,347 `differentPageContext`, 0 `sameLivePageContext`.

The second result has a timing caveat: the crossing is detected at the *entity's* own method call
(the entity has its own page context), not during the earlier WireBox construction where any
sharing would occur. So this weakens the shared-page-context theory but does not fully kill it —
the sharing, if it matters, happens upstream of where the symptom shows.

### Correction to the previous section

The follow-up section above dismissed the census's "shared component metadata" hypothesis on the
grounds that the creator is still running. That reasoning was wrong: a **live** shared-metadata
cross also shows the creator still running, because both concurrent constructions are live and
both touch the shared metadata during their overlapping windows. The "creator still running"
result rules out a *stale* cached reference, not a live shared one. So the shared per-class
metadata is back on the table as the transient container — consistent with this round's walk
finding nothing (the reference would be written and cleared inside the duplicate/construction
window, invisible to a later walk), and it is the same structure whose torn reads cause race 1.

## Bottom line after Phase 0

What is now proven, with a control and raw numbers:

1. The bug is a live entity object shared between two concurrent requests — same object, both
   requests still running, zero occurrences when Adobe's lock is on.
2. It is **not** the shared `UDFMethod.superScope` field (more common on the clean build), the
   page-context variables pointer (0 read mismatch), component resolution (0 foreign), the
   function local/arguments scope (0 in 162M), or scope recycling (0).
3. It is held by **no persistent container** — not the shared metadata, component cache, app or
   server scope, or WireBox (0 reachable from any root). The share is transient: written and
   cleared inside the construction window.

The original v4 plan — stop the shared `UDFMethod.superScope` write and drop the read fallback —
is dead on this evidence. Do not build it.

The fix target is what the census concluded, now supported rather than assumed: the transient
lives in ACF's construction path, most plausibly the shared per-class component metadata that
`resolveComponentHelper` and Quick's `duplicate(getMetadata(this))` both touch. The
BoxLang-faithful fix is design point 2 — build metadata fresh (or immutable) per call so no two
concurrent constructions share one mutable metadata object. That is an Adobe-runtime change (or
the lock). Nobody has built it; it is the next thing to try.

**The one probe that would nail it** (a future round, not done here): instrument
`ObjectDuplicator._duplicate` / `CFPage.Duplicate` and check, *during* a duplicate, whether the
source graph reaches a foreign live entity. That catches the reference while it still exists,
which a post-hoc walk cannot. A yes confirms the metadata path and the fix target; a no sends the
search to the remaining construction writes.

Shipping recommendation is unchanged: `hotfixes/hf202300-4232227-concmap-v1.jar`.

Raw counters for this round: `benchmark-results-u23/gate-trace-causal/scopetrace.counters`
(walk results and the page-context test are both in it).

---

## Duplicate-path probe, 2026-08-24: the metadata is NOT the carrier

This is the decisive probe the previous section named. It hooks `CFPage.Duplicate(Object)` — the
copy Quick's `metadataInspection` runs on the cached metadata snapshot — and, *while the copy is
happening*, walks the source graph for a live entity that belongs to a different concurrent
request. That catches a transient reference while it still exists, which a post-hoc walk cannot.

Quick's vendored code here calls `duplicate( _cache.getOrSet( key, buildMetadataSnapshot ) )`, and
its own comment says the snapshot "still references the engine's shared component metadata." So if
the shared metadata carries a cross-request entity reference at duplicate time, this walk sees it.

**Result: it does not.** In one run: 15,959 `Duplicate` calls, 11,915 with a struct source, and
**zero** where the source graph reached a foreign live entity — while the entity and struct
crossings kept happening in the same run (5,505 and 2,228). The metadata being duplicated does not
carry the foreign entity. Race 1 (the metadata tear) and race 2 (the entity crossing) really are
separate: the metadata is shared and tears, but it is not how the entity object crosses.

That retracts the correction two sections up. The shared metadata is not the container either.

### FusionContext ruled out by decompile

The per-call `instance` / `args` / `returnValue` fields on `FusionContext` looked like a way for
one request's arguments to reach another. But `FusionContext.current` is a
`ThreadLocal<FusionContext>` (decompiled, `FusionContext.java:130`), so each thread has its own.
The foreign values seen on it earlier (`udfTarget.FOREIGN` = 11,013) are the symptom: request B
invoking a method on request A's entity, which B already holds as `related`.

## Final Phase 0 conclusion

Every specific mechanism has now been measured and cleared:

| candidate | verdict | evidence |
|---|---|---|
| shared `UDFMethod.superScope` | not it | more common on the zero-failure locked build |
| page-context variables pointer | not it | 0 read mismatch in 56.4M invocations |
| component resolution (`resolveName`) | not it | 0 foreign in 591,806 returns |
| function local / arguments scope identity | not it | 0 foreign in 162M reads |
| scope-object recycling | not it | 0 |
| any persistent container (metadata, cache, app/server scope, WireBox) | not it | 0 reachable from any root |
| shared page context at the symptom | not it (timing-caveated) | 0 same, 7,347 different |
| the metadata duplication source | not it | 0 foreign in 11,915 copies |
| FusionContext | not it | thread-local (decompiled) |

What remains proven and unexplained: a live entity object, and the WireBox `initArguments` struct
that carries it, are shared between two concurrent requests — same object, both still running,
zero when Adobe's lock is on. Every allocation on the path is fresh and clean (StructNew returns
0 foreign; getInstance returns 0 foreign), yet the object crosses. The only shape consistent with
"every allocation is clean, no scope identity crosses, no container holds it, and it only happens
concurrently" is a **transient write race**: one thread writes a reference into a shared slot
during the reflective-invoke / argument-binding path and another reads it before it is restored,
in a window the global construction lock closes.

Catching that write is a different and much more invasive instrument — it means hooking the
hottest path in the engine (`LocalScope.bindInternal` / `ArgumentCollection` construction, billions
of calls) — and it may still land on an ACF-internal field with no CFML-level fix. On this
evidence the honest verdict is the one the plan set as the NO-GO outcome, now reached by
exhaustive elimination instead of assumption: **race 2 needs Adobe's source or the construction
lock.** The lock-free super-scope overlay the v4 plan proposed is dead, and no other single engine
reference explains the crossing.

Recommendation unchanged: ship `hotfixes/hf202300-4232227-concmap-v1.jar` (concurrent map for
race 1 + Adobe's lock for race 2). For the Adobe report, this Phase 0 is the deliverable: a
precise, measured statement that the contamination is a transient cross-request share in the
construction/argument-binding path, with nine specific mechanisms ruled out by experiment.

Raw counters: `benchmark-results-u23/gate-trace-dup/scopetrace.counters`.

**What should NOT be built:** the planned v4 design (a private working plan, not published), which was to
stop the shared `UDFMethod.superScope` write and remove the read fallback. On this evidence it
would change something real and fix nothing, and removing the fallback risks breaking
`super.method()` on the 60% of calls where the per-instance store is bypassed. Do not build it.

## Reproducing this

```powershell
# the diagnostic jar, and the same instrumentation on Adobe's locked jar as a control
.\scripts\Build-UnlockedJar.ps1 -Trace
.\scripts\Build-UnlockedJar.ps1 -TraceLocked

# deploy one of them to the candidate arm (its config already passes -Dcfscope.trace=...)
.\scripts\Install-U23BenchmarkArms.ps1 -SkipInstall -Trace

# warm with ~20 sequential requests per endpoint, then
.\scripts\Invoke-ContaminationGate.ps1 -Arm trace -Port 60847 -TotalRequests 8000 -Connections 20

# read logs\scopetrace.tsv.counters — the per-outcome table is at the top
```

The trace jar is a measuring tool. It is never a fix and must never be shipped.
