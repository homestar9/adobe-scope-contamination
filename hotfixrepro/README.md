# Standalone reproductions

These need nothing from the rest of the repository: no ColdBox, no Quick, no database. Copy the
`hotfixrepro` folder into the web root of any ColdFusion 2023 server.

## deadlock/

A permanent deadlock introduced by the third hotfix (per-class construction locks).

| File | Purpose |
|---|---|
| `Application.cfc` | An empty application, so the test has an application scope |
| `MutualA.cfc` | Its pseudo-constructor creates `MutualB` the first time |
| `MutualB.cfc` | Its pseudo-constructor creates `MutualA` the first time |
| `index.cfm` | Starts two threads at the same instant, one at each class, and reports the result |

Open `/hotfixrepro/deadlock/index.cfm`.

| Server | Result (2026-09-24) |
|---|---|
| ColdFusion 2023 Update 23, no hotfix | PASS, both threads complete in about 0.1 s |
| Update 23 + first hotfix (global lock) | PASS, about 0.2 s |
| Update 23 + third hotfix (per-class locks) | **DEADLOCK**, both threads still running after 10 s |

**What happens.** Thread 1 starts building `MutualA` and holds `MutualA`'s construction lock.
Thread 2 starts building `MutualB` and holds `MutualB`'s lock. Each pseudo-constructor then
creates the other class, so each thread asks for the lock the other one holds. Neither can
proceed, and `ReentrantLock.lock()` ignores interrupts, so a request timeout does not free them.

Confirm it with `jcmd <ColdFusion pid> Thread.print -l`. The dump ends with
`Found one Java-level deadlock`, naming two threads parked in
`coldfusion.runtime.TemplateProxyFactory.resolveName` on each other's `ReentrantLock`.
**Restart ColdFusion afterwards**: the threads stay parked for the life of the JVM.

The `sleep( 100 )` in each pseudo-constructor only makes the timing repeatable. In real code the
window is the pseudo-constructor's own work.

## scopeleak/

The mechanism behind the contamination itself, and what the fourth hotfix changes.

| File | Purpose |
|---|---|
| `Application.cfc` | An empty application, so the test has an application scope |
| `Probe.cfc` | One shared instance (stands in for any singleton); each method returns an inline struct or array literal around the caller's token, with a short sleep inside the literal |
| `index.cfm` | Builds once single-threaded, then starts N threads at the same instant, each building many times with its own token, and reports the result |
| `Shapes.cfc`, `shapes.cfm` | Thirty-three code shapes that build a literal; the page lists which ones leave a temporary in `variables` |

Open `/hotfixrepro/scopeleak/index.cfm` (`?threads=32&reps=100&ms=2` to change the load), and
`/hotfixrepro/scopeleak/shapes.cfm` for the shape table (`?json=1` for JSON).

**What happens.** The ColdFusion compiler stores every inline literal in a temporary variable
named `___IMPLICITARRYSTRUCTVAR<n>`. For a literal in a plain statement it declares that
temporary as a local. For a literal inside a conditional expression, `cond ? { ... } : { ... }`
or `x ?: { ... }`, it does not, so inside a function the temporary is written to the component's
`variables` scope (measured 2026-10-13 on Update 21 and Update 23: nine of thirty-three shapes
leak, all nine are the conditional ones). One shared instance has one `variables` scope, so
concurrent threads overwrite each other's half-built struct and a thread gets back a struct
carrying another thread's token. WireBox's `Builder.buildCFC` builds every constructor argument
collection with that shape. The fourth hotfix keeps the temporary in the function's local scope.
The page reports both symptoms: leaked `___IMPLICIT...` keys in the shared instance's `variables`
scope (visible even single-threaded), and values that came back carrying another thread's token.
