# v5 probe: the struct is already foreign when it enters the engine (2026-08-24)

> **Naming:** this note is about our own experimental "v5" probe build, not an Adobe hotfix. See [the research log index](README.md).

This is the decisive probe the plan called for. It answers a question three prior sessions
circled but never measured: **does the ColdFusion engine's method-invoke path corrupt the
constructor-argument struct, or does the struct arrive already corrupted?**

The answer is clean and it closes the engine-invoke fix: **the struct is already another
request's struct the instant it enters the engine.** The engine's invoke dispatch does not
cause the crossing. It happens one layer up, in WireBox's construction code.

## How it was measured

The whole dispatch chain a WireBox `invoke( target, "init", struct )` takes was traced first, by
reading the decompiled engine (both the stock classes and Adobe's v1-hotfix classes):

- Frame A: `CFPage.invoke(Object,String,Object)` — the `invoke()` built-in function.
- Frame B: `CfJspPage._invoke(Object,String,Map,boolean,boolean)`.
- Frame C: `TemplateProxy.invoke(String,Map,PageContext)`.
- Frame D: `TemplateProxy.invoke(UDFMethod,String,Object[],Map,CfJspPage,FusionContext)`.
- Frame E: `UDFMethod.invoke(Object,String,Object,Map)` — the deepest frame; the struct is seen
  here (this is the pre-existing `udfMapInvoke` hook that counts `STRUCT_OBJECT_CROSSED`).

All five frames run on one thread and pass the struct by reference, unchanged, with no shared
field read. So the same struct can be checked at both ends on the same thread, and the two
answers must agree unless a shared field swapped the reference somewhere between them.

Two additions to the diagnostic jar made the check:

1. A **pre-hook** at frame A (`CFPage.invoke`) that fires before the call runs, records the
   struct's owner in a thread-local stamp, and — when the struct is already a different in-flight
   request's — writes the exact Java+CFML call stack. Pre-hook support was added to the patcher
   (`"PRE:"` prefix on a hook name); it emits the hook before the original, still straight-line,
   still passes `-Xverify:all`.
2. At frame E, a comparison against that stamp (by object identity, same thread) that classifies
   each struct as `STRUCT_THREADED_CLEAN` (foreign at both ends), `STRUCT_SWAPPED_IN_DISPATCH`
   (clean at the BIF, foreign at frame E — the only case that would be a patchable engine field),
   or `STRUCT_THREADED_OWN` (own at both ends).

Run: warm gate, 8,000 concurrent requests on `/repro/alpha` + `/repro/bravo`, trace jar SHA
`2A5D6296…`, on the v3-u23 arm (port 60847). The run reproduced race 2: 659 HTTP 500s, 394
classified contaminations.

## The result

| counter | value | meaning |
|---|---|---|
| `bifInvoke.ENTERED_FOREIGN` | **4071** | struct already another live request's at the invoke() BIF |
| `mapInvoke.STRUCT_OBJECT_CROSSED` | **4071** | same count at the deepest engine frame |
| `engine.STRUCT_THREADED_CLEAN` | 3712 | confirmed foreign at BOTH ends, same struct |
| **`engine.STRUCT_SWAPPED_IN_DISPATCH`** | **0** | never clean-in, foreign-out |
| `engine.STRUCT_THREADED_OWN` | 1,087,138 | the normal case |
| `bifInvoke.total` | 1,200,676 | BIF pre-hook fired this many times |

Every foreign struct was on an `init` call, with the creating request still running, on a
different page context. **Zero structs entered the engine clean and turned foreign inside
dispatch.** There is no engine-invoke field to isolate per thread. The `--v5` engine-invoke-field
fix is dead — reached by measurement, not assumption.

## Where the struct enters (the fact no prior run captured)

The pre-hook wrote the call stack for each foreign struct. Every one is identical, and it names
the source exactly:

```
BIF_FOREIGN method=init struct=35cac0f0 structClass=coldfusion.runtime.Struct keys=(empty)
            req=AlphaParent builtFor=AlphaParent/StructNew builtInReq=55
  coldfusion.runtime.CFPage.invoke(CFPage.java)
  cfBuilder...funcBUILDCFC.runFunction(coldbox/system/ioc/Builder.cfc:273)   <-- here
  ...
  cfInjector...funcBUILDINSTANCE.runFunction(coldbox/system/ioc/Injector.cfc:620)
  cfNoScope...funcGETFROMSCOPE.runFunction(coldbox/system/ioc/scopes/NoScope.cfc:43)
```

The struct is `constructorArgCollection` inside WireBox's `Builder.buildCFC`, at the
`invoke( oModel, constructorName, constructorArgCollection )` call. It is reached on the transient
construction path (`NoScope` = WireBox's transient scope). Of 9 sampled crossings there were 9
**distinct** struct identities (not one shared pooled struct); 6 were empty `{}`, 3 carried a
`META` key; each was created by a different request's `CFPage.StructNew()` and shared with a
concurrent request.

The at-BIF container walk reached the struct only through the reader's own active page context
(its own function-local), never through the WireBox Injector or the target object. So nothing
persistent holds it — it is a live per-request transient shared between two concurrent `buildCFC`
executions on the WireBox Builder singleton.

## The paradox, and what it means for the root cause

`constructorArgCollection` is a `var` local. `CFPage.StructNew()` always returns a fresh struct
(0 foreign in 12.1M calls). The function-local scope object never crosses
(`getActiveFunctionLocalScope` 0 foreign in 162M; `crossLocalScope` 0 in this run). And yet the
local's VALUE is a struct that a different request created.

The reader's `buildCFC` did not create this struct (its owner is the other request), and its own
local scope is correct — so the only way its local variable slot holds the other request's struct
is a **write that landed in the wrong place during concurrent execution**. Two concurrent requests
run `builder.buildCFC()` on the same WireBox Builder singleton (which the prior container-walk
found shares one page context). This is the same ACF concurrent-construction value crossing that
Adobe's global construction lock serializes away — now pinned to a concrete spot: a local /
argument value binding during concurrent execution of a method on a shared singleton.

The struct crossing (4071) sits upstream of the failure-tracking entity crossing
(`crossVarOtherEntity`, 0.0 per OK request vs 6.5 per failed request, 1723x): the shared struct
carries the wrong `related` / `parent` entity into a relationship, and later method calls on that
foreign entity compile the wrong-table SQL.

## Bottom line

- **Engine invoke dispatch: exonerated.** No lock-free engine-invoke-field fix exists. `--v5`
  is dead, by measurement.
- **Root, precisely named:** a shared local / argument value during concurrent execution of a
  method on the WireBox Builder singleton (`constructorArgCollection` in `buildCFC`). This is an
  ACF local-variable/scope-binding behavior under concurrency, the same class the global lock
  fixes — not the invoke path, and not any of the nine mechanisms ruled out before.
- **Remaining fix options:** (a) a deeper engine patch on the local-variable / scope-binding path
  — the hottest path in the engine, very invasive, and likely an ACF-internal change with no
  bytecode-overlay fix; (b) a WireBox/framework change so concurrent construction does not share
  the singleton Builder's execution state; or (c) the shipping fallback —
  `hotfixes/hf202300-4232227-concmap-v1.jar` (race 1, lock-free) + the app-level out-of-band
  family guard (race 2 made fail-closed at the database) + this strengthened Adobe report.

## Reproducing

```powershell
.\scripts\Build-UnlockedJar.ps1 -Trace          # trace jar with the frame-A pre-hook
.\scripts\Install-U23BenchmarkArms.ps1 -SkipInstall -Trace
# warm the v3-u23 arm, then:
.\scripts\Invoke-ContaminationGate.ps1 -Arm trace -Port 60847 -TotalRequests 8000 -Connections 20
# read logs\scopetrace.tsv.counters (engine.STRUCT_* and bifInvoke.*), and the BIF_FOREIGN
# stacks in logs\scopetrace.tsv after the last #start.
```
