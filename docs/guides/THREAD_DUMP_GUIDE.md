# Thread dumps — what to look at

Accompanies the `thread-dumps-hf202300-4232227.zip` archive.

## What is in the archive

| Path | Contents |
|---|---|
| `threaddumps-patched/dump-001.txt` … `dump-015.txt` | ACF 2023.0.22 **with** `hf202300-4232227.jar` |
| `threaddumps-baseline/dump-001.txt` … `dump-015.txt` | ACF 2023.0.22 **without** the hotfix, otherwise identical |
| `lock-evidence-patched.json`, `lock-evidence-baseline.json` | Machine-readable tallies of the below |
| `summary.csv` | Throughput and latency for every measured cell |

Both servers: same JDK 17.0.20+8, same fixed 2 GB heap, FusionReactor disabled,
`neo-runtime.xml` diffed identical apart from install paths. The only difference is the jar.

Captured with `jcmd <pid> Thread.print`, 15 samples one second apart, while the server was
under 32 concurrent requests. Each request constructs 200 transient CFCs and touches no
database. The component has a two-level `extends` chain and about fifteen methods, roughly the
weight of a Quick ORM entity.

## The short version

The monitor of interest is `<0x00000000828f4ce0>`, a `java.lang.Object`. That is
`TemplateProxyFactory.CONSTRUCTION_LOCK`, which the hotfix declares as
`private static final Object` and initialises with `new Object()` in the static initialiser.

In `threaddumps-patched/dump-001.txt`:

- **29 threads** are `BLOCKED (on object monitor)` waiting to lock `0x828f4ce0`
- **1 thread** holds it
- Every blocked thread's top frame is
  `coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:202)`

Across all 15 patched dumps: 383 blocked-thread observations, **100% of them** on that monitor
at that line, averaging 25.5 of 32 request threads blocked at any instant.

Across all 15 baseline dumps: **one** blocked thread total, and **zero** in `resolveName`.

## Point 1 — find the waiters

Search any patched dump for `waiting to lock <0x00000000828f4ce0>`. Typical entry:

```text
"XNIO-1 task-2" #113 prio=5 os_prio=0 ... waiting for monitor entry
   java.lang.Thread.State: BLOCKED (on object monitor)
	at coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:202)
	- waiting to lock <0x00000000828f4ce0> (a java.lang.Object)
	at coldfusion.cfc.ComponentProxyFactory.getProxy(ComponentProxyFactory.java:85)
	...
	at coldfusion.runtime.CFPage._createObject(CFPage.java:17066)
```

The same block repeats for 28 more threads. The equivalent search in any baseline dump returns
nothing.

## Point 2 — the lock spans the whole `extends` chain

Search the same file for `- locked <0x00000000828f4ce0>`. Exactly one thread holds it, and it
appears **three times in that single thread's stack**:

```text
	at coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:204)
	- locked <0x00000000828f4ce0> (a java.lang.Object)
	at coldfusion.runtime.TemplateProxyFactory.resolveComponentHelper(TemplateProxyFactory.java:427)
	at coldfusion.runtime.TemplateProxyFactory.resolveNameLocked(TemplateProxyFactory.java:301)
	at coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:204)
	- locked <0x00000000828f4ce0> (a java.lang.Object)
	at coldfusion.runtime.TemplateProxyFactory.resolveComponentHelper(TemplateProxyFactory.java:427)
	...
```

`resolveNameLocked` calls `resolveComponentHelper`, which calls back into `resolveName`, which
takes the same monitor again. Java monitors are reentrant so this does not deadlock, but it
means resolving a three-level inheritance chain holds the global lock continuously from the
first parent to the last. A deeper hierarchy holds it longer.

## Point 3 — application CFML executes while the lock is held

This is the part worth the closest look. Reading further down that same holder stack:

```text
	at coldfusion.runtime.LocalScope.putInternal(LocalScope.java:375)
	at coldfusion.runtime.LocalScope.put(LocalScope.java:346)
	at coldfusion.runtime.CfJspPage._arrayset(CfJspPage.java:1998)
	at coldfusion.runtime.NeoPageContext.SymTab_setSplitNameInMap(NeoPageContext.java:1812)
	at coldfusion.runtime.CfJspPage._structSetAt(CfJspPage.java:3945)
	at cfWideProbeRoot2ecfc3956415.runPage(...\models\WideProbeRoot.cfc:11)   <-- user CFML
	at coldfusion.runtime.CfJspPage.invoke(CfJspPage.java:251)
	at coldfusion.runtime.TemplateProxyFactory.resolveComponentHelper(TemplateProxyFactory.java:624)
	at coldfusion.runtime.TemplateProxyFactory.resolveNameLocked(TemplateProxyFactory.java:301)
	at coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:204)
	- locked <0x00000000828f4ce0> (a java.lang.Object)
```

`resolveComponentHelper` line 624 calls `CfJspPage.invoke`, which runs the component's
pseudo-constructor — the CFML in the component body. In this dump the JVM-wide construction
lock is held while executing line 11 of an application CFC.

The consequence is that the time the lock is held is not bounded by engine work. It is bounded
by whatever the slowest component body in the application does. A CFC whose body runs a query,
reads a file, or calls a web service would hold this monitor for that entire duration, and no
other thread anywhere in the JVM could construct any CFC until it finished.

## Reproducing

Public reproduction case, including the harness that produced these dumps:

- `scripts/Install-TestServers.ps1` — builds both servers, verifies they load
  `TemplateProxyFactory` from different jars
- `scripts/Get-LockEvidence.ps1 -Arm patched` — drives load and captures these dumps
- `docs/adobe-hotfixes/1-first-hotfix-static-analysis.md` — the bytecode and decompiled diff
- `docs/adobe-hotfixes/1-first-hotfix-performance.md` — throughput results and method
