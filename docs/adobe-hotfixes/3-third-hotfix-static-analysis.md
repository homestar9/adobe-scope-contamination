# Static analysis of Adobe's third hotfix jar (`hf202300-4232227-adobe-v3.jar`)

What Adobe changed, read straight out of the bytecode, before running any benchmark. Written
2026-09-22, the day the jar arrived, so that the predictions at the end are on record before
the first measurement.

## Provenance

| | |
|---|---|
| File | `hotfixes/hf202300-4232227-adobe-v3.jar` (received as `hf202300-4232227.jar`) |
| SHA256 | `efb0aa56912c3c7046da47bbcc1fc28776a9f9aa1d18fbbf09cf1a3ce4780b0e` |
| Size | 23,787 bytes, 14 entries |
| Manifest | 69 bytes, `Created-By: 1.8.0_401 (Oracle Corporation)`. Unlike v1 and v2, no stale scheduler-bundle manifest. |
| Class file version | 52 (Java 8), same as stock Update 23 |
| Adobe's description | "for Update 23". Nothing else. |

Contents: `coldfusion/runtime/TemplateProxyFactory.class` (37,550 bytes) and its nine inner
classes (`$1`, `$2`, `$3`, `ComponentCacheKey`, `InvalidComponentException`,
`InvalidComponentNameException`, `ResolveTemplateNamePrivilege`, `ResolveTemplatePathPrivilege`,
`TemplateClassLoaderPrivilege`). Nothing else.

## How this was produced

| Version | Where the class comes from |
|---|---|
| v3 | `hotfixes/hf202300-4232227-adobe-v3.jar` |
| Stock Update 23 | `.engine/bench-u23/WEB-INF/cfusion/lib/updates/chf20230023.jar` |
| v1, for comparison | `hotfixes/hf202300-4232227-adobe-v1.jar` |

Disassembled with `javap -p -c` from JDK 21 and decompiled with CFR 0.152
(`tools/cfr.jar`, `--extraclasspath` pointing at the U23 `cfusion.jar`). The comparison against
stock is a **normalized bytecode diff**: `javap -p -c` output with constant-pool indices and
bytecode offsets stripped (`sed -E 's/#[0-9]+//g; s/^ +[0-9]+: //'`) and branch targets ignored,
so that the different constant pool layout of a recompiled class does not produce noise. The
v3 class was compiled without local-variable debug info, so a source-level diff of the CFR
output shows every parameter renamed; the bytecode diff does not have that problem.

## Headline finding

**Adobe replaced v1's single JVM-wide monitor with one `ReentrantLock` per CFC file, but a
construction holds its own lock and every ancestor's lock until it fully completes, and none of
v1's per-instance scope fixes are shipped.**

### The diff against stock Update 23

The nine inner classes are bytecode-identical to stock (zero diff lines each). The main class
differs in exactly three places:

1. Three new static fields:

   ```java
   private static final ConcurrentHashMap<String, ReentrantLock> CLASS_CONSTRUCTION_LOCKS;
   private static final ReentrantLock FALLBACK_CONSTRUCTION_LOCK;
   private static final ThreadLocal<LinkedHashSet<ReentrantLock>> HELD_CONSTRUCTION_LOCKS;
   ```

2. One new method:

   ```java
   private static ReentrantLock getConstructionLock(File file, String name) {
       String key = file != null ? file.getPath() : (name != null ? name.toUpperCase() : null);
       if (key == null) return FALLBACK_CONSTRUCTION_LOCK;
       ReentrantLock lock = CLASS_CONSTRUCTION_LOCKS.get(key);
       if (lock == null) {
           ReentrantLock fresh = new ReentrantLock();
           lock = CLASS_CONSTRUCTION_LOCKS.putIfAbsent(key, fresh);
           if (lock == null) lock = fresh;
       }
       return lock;                                   // entries are never removed
   }
   ```

3. The public 8-argument `resolveName(...)`, which in stock is the whole implementation, is
   now a wrapper, and the old body moved unchanged into a new private `resolveNameLocked(...)`
   (the same split v1 made):

   ```java
   public static TemplateProxy resolveName(TemplateProxy proxy, NeoPageContext ctx, File file,
           String name, boolean origCFC, Map initialThis, HashSet derived, boolean initializeCFC) {
       LinkedHashSet<ReentrantLock> held = HELD_CONSTRUCTION_LOCKS.get();
       boolean outermost = (held == null);
       if (outermost) { held = new LinkedHashSet<>(); HELD_CONSTRUCTION_LOCKS.set(held); }
       ReentrantLock lock = getConstructionLock(file, name);
       if (held.add(lock)) lock.lock();                 // uninterruptible, no timeout
       try {
           return resolveNameLocked(proxy, ctx, file, name, origCFC, initialThis, derived, initializeCFC);
       } finally {
           if (outermost) {
               HELD_CONSTRUCTION_LOCKS.remove();
               for (ReentrantLock l : held) l.unlock();  // released only by the outermost call
           }
       }
   }
   ```

Everything else in the class, including the per-component metadata double-checked lock that
stock already had, is byte-for-byte stock Update 23.

### What v3 does not ship

v1 changed four classes. The per-instance fixes were the part of v1 that was actually a
correctness change rather than a lock:

| Class | v1 added | Present in stock U23? | Present in v3? |
|---|---|---|---|
| `TemplateProxy` | `boundSuperScopeLevel0`, `boundSuperScopesByLevel` (`ConcurrentHashMap`), `initializeInvokePageForInstance` | no | **no** |
| `UDFMethod` | `resolveInvocationSuperScope(Object)` | no | **no** |
| `Closure` | `capturedOwner`, `capturedVarScope`, `bindOwner`, `installCapturedVariableScope` | no | **no** |

Verified with `javap -p` on the U23 `cfusion.jar` and `chf20230023.jar`: none of those members
exist. v3 relies on locking alone. Whatever v1's per-instance fixes protected during `init()`
(which the caller invokes after `resolveName` returns, outside any construction lock) is
unprotected in v3.

## What the lock actually covers

`resolveNameLocked` is the full stock body, so the critical section under a class's lock is the
same as under v1's global lock:

- `getCFCInstance(...)`: template lookup, and compilation on a cache miss
- metadata population (the old per-component monitor, now nested inside the class lock)
- `resolveInterfaceHelper(...)` / `resolveComponentHelper(...)`, which includes **running the
  pseudo-constructor** (`templateProxy.filterChain.invoke(...)`)

### Nesting: every ancestor's lock is held too

`resolveComponentHelper` resolves the `extends` parent by calling `resolveName` again. Under v3
that nested call adds the **parent's** lock to the thread's held set, and the `finally` only
runs the unlocks when the outermost call returns. So constructing a class holds:

- its own lock,
- its parent's lock, its grandparent's lock, and so on up the chain,
- the lock of every class that its pseudo-constructor constructs (`new`, `createObject`,
  WireBox `getInstance`), and their ancestors,

all for the entire duration of the construction, including the pseudo-constructor's own work.

Consequences for real applications:

- Every Quick entity extends `quick.models.BaseEntity` (which has no `extends` of its own).
  Every entity construction therefore takes the `BaseEntity` lock. For a Quick application this
  is a global lock partitioned by hierarchy root, with a critical section as long as v1's.
- Every ColdBox handler extends `coldbox.system.EventHandler`, every interceptor extends
  `coldbox.system.Interceptor`, every model that extends anything shares its root's lock. In this
  reproduction app handlers are cached singletons, so the handler root does not matter here; it
  does in applications that construct handlers or interceptors per request.
- A component with no `extends` and the stock empty `WEB-INF/cftags/component.cfc` (0 bytes in
  every test server here) does **not** nest: `resolveComponentHelper` caches the base metadata and skips
  the nested `resolveName`. A site that customizes `component.cfc` (non-empty) makes every
  construction nest into that one base lock: a global lock again.

### The lock key

`file.getPath()` when a `File` is supplied, which in `resolveNameLocked` it always is (the
body calls `file.getPath()` unconditionally). The name-keyed and fallback branches are
effectively dead. Whether two spellings of the same component (`models.x` vs
`MODELS.X`, mapping aliases) resolve to the same `File` path, and therefore the same lock, is a
runtime question the lock stress tests answer; if they do not, two locks guard one class and the
protection is incomplete for that pair.

### `ReentrantLock`, not `synchronized`

Two consequences:

1. Evidence looks different. Contention on v1 appeared as `BLOCKED (on object monitor)` on one
   `java.lang.Object`. Contention on v3 appears as `WAITING (parking)` with
   `parking to wait for <0x...> (a java.util.concurrent.locks.ReentrantLock$NonfairSync)`, and
   with `Thread.print -l` the owner is listed under "Locked ownable synchronizers". The number
   of **distinct** contended addresses is the number that decides whether this is really a
   per-class design at runtime. JFR records it as `jdk.ThreadPark`, not `jdk.JavaMonitorEnter`.
2. `lock()` is uninterruptible and has no timeout. A request timeout cannot free a thread
   parked on it.

### Deadlock

With a single reentrant monitor (v1) there is no lock ordering problem. With many locks that
are acquired incrementally as construction proceeds and held until the outermost call returns,
there is:

- Request A constructs `X`. `X`'s pseudo-constructor lazily constructs `Y`
  (`if (!structKeyExists(application, "y")) application.y = new Y()`).
- Request B constructs `Y`. `Y`'s pseudo-constructor lazily constructs `X` the same way.
- A holds `X` and waits for `Y`. B holds `Y` and waits for `X`. Neither ever returns, and
  `jcmd Thread.print` reports a Java-level deadlock.

That pattern works on stock (no locks) and on v1 (one monitor). On v3 it is a permanent hang of
two worker threads per occurrence, until the worker pool is exhausted. Mutual lazy
initialization in pseudo-constructors is not exotic in older ColdFusion code. A related, milder
case: a pseudo-constructor that takes a named `cflock` while another request holds that
`cflock` and is constructing the same class will wait until the `cflock` times out.

### `duplicate()` still bypasses the lock

`resolveNameForDuplicate` calls `resolveComponentHelper` directly, exactly as in v1 and stock.
The `duplicate()` of a component is not serialized against construction of that component's
class, except where the extends chain resolution nests into a shared ancestor lock.

### Unbounded lock map

`CLASS_CONSTRUCTION_LOCKS` is keyed by file path and never evicts. Bounded by the number of
distinct CFC paths ever constructed in the JVM; a minor leak for applications that generate or
mount components dynamically. Worth reporting, not worth failing on.

## Why the per-component precedent matters

In August 2026 this repository built and gated a per-component monitor variant of v1
("stripe", see `docs/research-log/2026-08-21-unlocked-jar-results.md`). It kept v1's per-instance fixes
and locked per component instead of globally. Result: the fresh-start failure (race 1) fired on
100% of requests in every fresh-JVM session, exactly as on stock, and the warm leak rate was
24 per 20,000 against v1's 1 per 20,000. v3 is the same idea with two differences: the locks
are held for longer (ancestors too), and the per-instance fixes are gone. The first difference
may help race 1, since a `duplicate()` of an entity and a construction of the same entity now
both take the `BaseEntity` lock during extends resolution; the second cannot help anything.

## Predictions, written before the first run

| Measurement | Predicted for v3 |
|---|---|
| fresh-start contamination test (3 fresh JVMs x 100k) | uncertain; the stripe precedent says failure of every request until restart, the longer hold on `BaseEntity` says maybe not. This is the test that matters. |
| warmed-up contamination test | if it survives cold: at or slightly worse than v1's residual rate, since `init()` is unprotected and the per-instance fixes are absent |
| `/repro` real workload RPS at 16-32 connections | about equal to v1 (all four entity classes share the `BaseEntity` lock) |
| construct `narrow` / `wide` / `closure` (one class hammered) | collapses like v1 |
| construct `fanout` (16 unrelated classes) | close to stock: the one clear win of the design |
| construct `siblings` / `deep` / `quickconstruct` | collapses like v1 |
| `slowsiblings` (3 ms sleep in the leaf constructor) | whole-JVM cap of roughly 330 constructions per second regardless of connection count |
| `fanout` width test at c=32 | throughput rises with n; v1 flat |
| thread dumps under `/repro` load | most waiters parked on a single lock address whose owner is inside `BaseEntity` |
| P1 timing matrix | same class serial; unrelated parallel; siblings serial; `SlowInit` parallel; alias spellings serial |
| P2 mutual lazy-init | permanent deadlock, reported by `jcmd` |
| P3 `cflock` interlock | 3 s lock timeouts for the same-class variant only |
| P4 exception in a nested constructor | no lock leak (the outermost `finally` releases everything) |
| P5 `cfthread` inside a constructor joining on the same class | join timeout (child parks on the parent's lock); v1 has the same regression |
| endurance test | stable; lock map levels off at the number of distinct CFCs |

The results are in [ADOBE_V3_HOTFIX_RESULTS.md](3-third-hotfix-results.md).
