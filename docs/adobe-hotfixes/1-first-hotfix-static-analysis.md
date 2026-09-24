# Static analysis of hotfix `hf202300-4232227.jar`

What Adobe changed, read straight out of the bytecode, before running any benchmark.

## How this was produced

| Version | Where the class actually comes from |
|---|---|
| Patched | `hotfixes/hf202300-4232227.jar` |
| Unpatched — `TemplateProxyFactory`, `UDFMethod` | `.engine/adobe2023/WEB-INF/cfusion/lib/updates/chf20230022.jar` (Update 22) |
| Unpatched — `TemplateProxy`, `Closure` | `.engine/adobe2023/WEB-INF/cfusion/lib/cfusion.jar` (Update 22 does not replace these) |

Disassembled with `javap -p -c` from `openjdk17_jdk` (installed via `box java install openjdk17_jdk`,
lands in `~/.CommandBox/serverJREs/`). All eight class files are Java 8 bytecode (major version 52)
in both versions, so nothing here is a stray ACF 2025 build despite what the jar's manifest claims.

> The jar's `META-INF/MANIFEST.MF` is stale and misleading — it declares
> `Bundle-SymbolicName: scheduler`, `Bundle-Version: 2025.0.05.331529`. It was repacked from a
> scheduler bundle and does not describe the payload. Do not identify this hotfix by its manifest.

## Headline finding

**Adobe added a single process-wide lock around all CFC name resolution.**

`TemplateProxyFactory` gains a new field and a new method:

```java
private static final Object CONSTRUCTION_LOCK;   // = new Object() in <clinit>
```

The public 8-argument `resolveName(...)` — previously the whole implementation — is now just a
wrapper. Its entire old body was moved into a new private `resolveNameLocked(...)`. Decompiled
with CFR, the whole of the new `resolveName` is:

```java
public static TemplateProxy resolveName( TemplateProxy proxyInstance, NeoPageContext pageContext,
        File canonicalResolvedFile, String fullName, boolean origCFC, Map initalThisVars,
        HashSet derivedClasses, boolean initializeCFC ) throws Throwable {
    Object object = CONSTRUCTION_LOCK;
    synchronized ( object ) {
        return TemplateProxyFactory.resolveNameLocked( proxyInstance, pageContext,
            canonicalResolvedFile, fullName, origCFC, initalThisVars, derivedClasses, initializeCFC );
    }
}
```

The bytecode confirms there is no fast path — `getstatic CONSTRUCTION_LOCK` / `monitorenter` are at
offsets 0 and 6, before any other work:

```text
 0: getstatic     #38   // Field CONSTRUCTION_LOCK:Ljava/lang/Object;
 3: dup
 4: astore        8
 6: monitorenter
 7: aload_0
 ...
19: invokestatic  #39   // Method resolveNameLocked:(...)Lcoldfusion/runtime/TemplateProxy;
22: aload         8
24: monitorexit
25: areturn
```

`monitorenter` count in `TemplateProxyFactory` goes from 2 to 3. The other three patched classes
contain no `monitorenter` and no `synchronized` methods in either version — the lock is entirely in
`TemplateProxyFactory`.

## Why this is a bigger change than it looks

The unpatched `resolveName` was not lock-free, but its locking was much narrower. It does
double-checked locking on the component's own metadata object (CFR output, trimmed):

```java
if ( !metadata.isMetaDataInitialized() ) {          // fast path — no lock at all
    AttributeCollection attributeCollection = metadata;
    synchronized ( attributeCollection ) {          // per-component metadata object
        if ( !metadata.isMetaDataInitialized() ) {
            metadata.put( Key.NAME, fullName );
            metadata.put( Key.PATH, pagePath );
            ...
            thisScope = TemplateProxyFactory.resolveComponentHelper( ... );
            metadata.metadataInitialized();
        }
    }
}
if ( thisScope == null ) {
    // Steady state lands here: the real resolution work runs with no lock held at all.
    thisScope = TemplateProxyFactory.resolveComponentHelper( ... );
}
```

Three properties of the old code are all lost:

1. **It skipped the lock entirely in steady state.** Once a CFC's metadata was initialized, the
   `isMetaDataInitialized()` check short-circuited and no monitor was ever acquired.
2. **The monitor was per component.** Two threads constructing *different* CFCs never contended.
   Even during first-time init, contention was scoped to one component.
3. **The actual resolution work ran outside the lock.** On the steady-state path the call to
   `resolveComponentHelper` happens after the `if` block, holding nothing.

The new lock is the opposite on both counts: **one monitor for the whole JVM, acquired
unconditionally on every call.**

### What runs while the lock is held

`resolveNameLocked` is the full original body, so the critical section covers:

- `getCFCInstance(...)` — template lookup, and compilation on a cache miss
- metadata population and the old per-component lock, now nested inside the global one
- `resolveInterfaceHelper(...)` and `resolveComponentHelper(...)`

Both of those helpers call back into `resolveName`, so resolving an `extends` chain re-enters the
same monitor. Java monitors are reentrant, so this does not deadlock — but it does mean an entire
inheritance chain resolves under a single continuous hold of the global lock.

### It is on the construction path

The 8-argument `resolveName` is reached from every public entry point that produces a component:
`resolveName` (all five overloads), `resolveFile`, `resolvePath`, `resolveSuperName`,
`resolveNameWithImport`, `createTemplateProxyForMetaData`, `resolveComponentHelper`, and
`resolveInterfaceHelper`.

The overload that `new Foo()` reaches — `resolveName(String, TemplateProxy, NeoPageContext)` — does
its `File.exists()` probing *before* delegating, but performs no component-cache lookup that could
let a warm CFC skip the locked call.

## The rest of the fix

The other three classes carry the actual correctness change, and it is a reasonable one — instances
stop sharing scope state:

| Class | What was added |
|---|---|
| `TemplateProxy` | `boundSuperScopeLevel0`, `boundSuperScopeLevel0Path` (both `volatile`), and `boundSuperScopesByLevel` — a `ConcurrentHashMap<String, Scope>`. Plus `getBoundSuperScopeForLevel` / `setBoundSuperScopeForLevel` and `initializeInvokePageForInstance`. Super scopes are now bound per instance. |
| `UDFMethod` | `resolveInvocationSuperScope(Object)` — derives the super scope from the invocation target instead of shared state. |
| `Closure` | `capturedOwner`, `capturedVarScope`, `bindOwner(Object)`, `installCapturedVariableScope(...)`. Closures now capture their owner's variable scope explicitly rather than inheriting whatever is current. |
| `TemplateProxyFactory` | `registerImplicitAccessorsInVarScope` changed from taking a `CfJspPage` to a `TemplateProxy`, so implicit accessors register against the right instance. |

Worth noting for the conversation with Adobe: for the per-instance scope map they chose
`ConcurrentHashMap` — a scalable, lock-free-on-read structure. Then in the same fix they wrapped
name resolution in a global monitor. The inconsistency suggests the lock may be a conservative
stopgap rather than a considered design, which is a good sign it could be narrowed on request.

## Prediction for the benchmark

**These predictions were subsequently measured and all of them held. See
[HOTFIX_BENCHMARK_RESULTS.md](1-first-hotfix-performance.md) — throughput on a Quick-weight
component flattens at roughly a quarter of unpatched, and 100% of blocked threads under load
sit on `resolveName`.**

If the analysis above is right, the load test should show:

| Measurement | Expected result |
|---|---|
| `c=1` throughput and latency | Near-identical between arms. An uncontended monitor costs tens of nanoseconds. |
| Throughput as concurrency rises | Baseline keeps scaling; **patched flattens** once threads start queueing on `CONSTRUCTION_LOCK`. |
| `construct_ns` (per-CFC cost) | Flat vs concurrency on baseline; **rising roughly linearly with concurrency** on patched. |
| Tail latency (p95/p99) | Grows much faster on patched, since queue depth at the monitor grows with offered load. |
| Thread dumps under load | Patched arm shows worker threads `BLOCKED (on object monitor)` with `TemplateProxyFactory.resolveName` on the stack. Baseline shows effectively none. |
| Effect of CFC size | Bigger components hold the lock longer, so `shape=wide` should separate the arms harder than `shape=narrow`. |

Because the lock is a `synchronized` block and not a `ReentrantLock`, contention shows up as
`BLOCKED` in thread dumps and as `jdk.JavaMonitorEnter` events in JFR — not as parked threads.

That is the shape of serialization, and it is the hypothesis the benchmark is set up to confirm or
refute.
