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
