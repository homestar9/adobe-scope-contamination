# De-locked Hotfix Jar — Build, Verification, and Deployment Record

## What this is

`hotfixes/hf202300-4232227-unlocked.jar` is a modified copy of Adobe's hotfix
`hf202300-4232227.jar`. It keeps the hotfix's correctness fix but removes the JVM-wide
construction lock that the hotfix added, which was the sole cause of the throughput
regression documented in `docs/adobe-hotfixes/1-first-hotfix-performance.md`.

Adobe's hotfix does two independent things (see `docs/adobe-hotfixes/1-first-hotfix-static-analysis.md`):

1. **The real correctness fix (kept, untouched):** per-instance scope fields in three
   classes — `TemplateProxy`, `UDFMethod`, and `Closure`. These stop the cross-scope
   contamination and carry no contention cost.
2. **A redundant global lock (removed):** `TemplateProxyFactory` gained a single static
   `Object CONSTRUCTION_LOCK`, and the public `resolveName` was wrapped in
   `synchronized (CONSTRUCTION_LOCK) { return resolveNameLocked(...); }`. This serialized
   every CFC construction across the whole JVM.

The modification rewrites only the public `resolveName` wrapper so it calls the private
`resolveNameLocked` directly, with no monitor. Every other jar entry — including the three
correctness-fix classes — is copied byte-for-byte.

## The exact change (bytecode)

Before (Adobe hotfix, verified with `javap -p -c`):

```
public static resolveName(TemplateProxy, NeoPageContext, File, String, boolean, Map, HashSet, boolean):
   getstatic  CONSTRUCTION_LOCK
   dup; astore 8; monitorenter
   aload_0 .. iload 7
   invokestatic resolveNameLocked
   aload 8; monitorexit; areturn
   [exception handler] astore 9; aload 8; monitorexit; aload 9; athrow
   Exception table: 7->25 target 26 any ; 26->31 target 26 any
```

After (de-locked):

```
public static resolveName(...same signature...):
   aload_0 .. iload 7
   invokestatic resolveNameLocked
   areturn
   Exception table: (empty)
```

`resolveNameLocked` is unchanged. The two per-component double-checked locks that already
lived inside `resolveNameLocked` remain, so the post-patch class has exactly **2
monitorenter / 4 monitorexit**, matching the shipped Update-22 baseline
(`chf20230022.jar`). The `resolveName` wrapper itself has 0 monitorenter.

## How it is built (reproducible)

The patch is a surgical ASM Tree transform of one method, done by
`scripts/archive/java/PatchHotfix.java`, driven by `scripts/archive/Build-UnlockedJar.ps1`:

```powershell
.\scripts\Build-UnlockedJar.ps1            # full removal  -> hf202300-4232227-unlocked.jar
.\scripts\Build-UnlockedJar.ps1 -Stripe    # fallback       -> hf202300-4232227-stripe.jar
```

The build script locates the CommandBox-bundled OpenJDK 17, ensures the pinned ASM jars are
present (`scripts/tool-versions.json`, fetched by `Get-BenchmarkTools.ps1`), compiles the
patcher, runs it, and then statically verifies the result before trusting it: correct
monitor counts, and a per-entry hash diff proving only `TemplateProxyFactory.class` changed.

### Pinned tooling

| Artifact | Version | SHA256 |
|---|---|---|
| ASM core | 9.7 | `adf46d5e34940bdf148ecdd26a9ee8eea94496a72034ff7141066b3eea5c4e9d` |
| ASM tree | 9.7 | `62f4b3bc436045c1acb5c3ba2d8ec556ec3369093d7f5d06c747eb04b56d52b1` |
| JDK | OpenJDK 17.0.20+8 (Adoptium) | CommandBox `serverJREs` |

Both ASM jars' SHA1 were cross-checked against Maven Central's published `.sha1` siblings.

### Artifact hashes (SHA256)

| Jar | SHA256 |
|---|---|
| Adobe original `hf202300-4232227.jar` | `7B586D55814B120FB818EAB7EF16DD83336449A6088162D627F114A6CC352C56` |
| De-locked `hf202300-4232227-unlocked.jar` | `1674130D487807C4A75CBF59EC48DB95883C51020AE1C1E4EEBFD5678DF0BC85` |
| Stripe fallback `hf202300-4232227-stripe.jar` | `726F8D51E833B5F244285ACAD8CCA7A88BE10D6BD903CDA876B025D4260D1550` |

> The stripe hash above is the reproducible value produced after `PatchHotfix.java` was changed to
> pin the modification time of the one entry it adds (`ConstructionLockSupport.class`) to a fixed
> value. Builds made before that change produced a different SHA256 on every run (the entry carried
> the build time), so any earlier recorded stripe hash — for example `D9CA0715…` — will not match a
> current build. The de-locked jar was always reproducible because it adds no entries.

## Static verification (passed)

- `TemplateProxyFactory`: 2 monitorenter / 4 monitorexit; the `resolveName` wrapper contains
  no monitorenter and no `CONSTRUCTION_LOCK` reference; it calls `resolveNameLocked` directly.
- Per-entry hash diff of the original vs de-locked jar: 54 entries in both, none added or
  removed, and exactly one entry differs — `coldfusion/runtime/TemplateProxyFactory.class`.
  The three correctness-fix classes (`TemplateProxy`, `UDFMethod`, `Closure`), all inner
  classes, and all i18n `.properties` files are byte-identical.

## Runtime smoke test (this machine, one session, both arms live)

A `bench-unlocked` arm (port 60842) was created by cloning the installed `bench-patched`
engine home and swapping in the de-locked jar (same filename). Results:

- **Loads and verifies:** ACF 2023.0.22.330928 on JVM 17.0.20 started cleanly with the
  modified class — no `VerifyError`, no classloader failure. `/benchmark/engine` confirms
  `TemplateProxyFactory` loads from the de-locked jar and `TemplateProxy` (the correctness
  fix) is active.
- **Constructs correctly under concurrency (DB-free):** `/benchmark/construct?count=200&shape=wide`
  at c=16 returned **0 HTTP 500s across thousands of requests** (the endpoint returns 500 on
  any checksum mismatch), on both the unlocked and patched arms.
- **The global lock is gone (thread dumps, c=32 wide, 12 samples each):**

  | | Patched (Adobe hotfix) | Unlocked (de-locked) |
  |---|---|---|
  | Avg threads blocked / dump | 32.1 (of 32) | 0.9 |
  | Blocked in `resolveName` | 385 / 385 (100%) | ~0 (the few are incidental `HashMap`/`VariableScope` locks in `TemplateProxyDependencyCache`, not a global monitor) |
  | Dominant monitor | one `java.lang.Object` | none |

- **Throughput recovers:** at c=16 wide in the same session, patched = 85.9 RPS,
  unlocked = 532.2 RPS — a **6.2× recovery**, in line with the baseline-vs-patched gap in
  `docs/adobe-hotfixes/1-first-hotfix-performance.md`.

Raw data: `benchmark-results/lock-evidence-unlocked.json`,
`benchmark-results/lock-evidence-patched.json`, and the `threaddumps-*` directories.

## What is NOT yet proven — the correctness gate (must pass before production)

The smoke test above proves the jar loads, constructs correctly in a DB-free micro-benchmark,
and has no global lock. It is **not** the contamination gate. The DB-free construct endpoint
does not exercise the actual Quick/qb `variables`-scope write patterns that trigger the bug.

Before deploying to production, run the full correctness gate on the unlocked arm:

1. Requires a SQL Server datasource and the `/repro` schema (real Quick entities). The bench
   arms already run `cfpm install sqlserver` on install.
2. Drive bombardier `-c 20` alternating `/repro/alpha` and `/repro/bravo` on all three arms as
   a positive-control design:
   - **baseline** must show contamination > 0 (proves the harness reproduces the bug this run),
   - **patched** must show 0 (fix present),
   - **unlocked** must show 0 (the claim under test).
   Detection is automatic via `interceptors/ContaminationDetector.cfc`; read the tally at
   `/repro/status` and `logs/contamination_log.txt`.
3. Require **0 contamination on the unlocked arm across N >= 300,000 requests**, run as
   sustained c=20 plus a c=32 burst, split alpha/bravo, across **>= 3 sessions with a fresh
   JVM restart between them** (the cold class-init window is the highest-risk case). At the
   observed ~1-2% unpatched rate, 0 events in 300k requests bounds any residual rate below
   ~1e-5 at 95% confidence.

If any contamination appears on the fully de-locked arm, switch to the **stripe** fallback
(`Build-UnlockedJar.ps1 -Stripe`), which keeps a per-component lock so different components
still construct concurrently, and re-run the identical gate. If stripe is also contaminated,
do not ship a de-locked jar; report the repro to Adobe.

## Deployment (production bridge, reversible)

1. Confirm the production ACF 2023 install is at the update level the hotfix targets (the jar
   only corrects the four classes the Adobe hotfix replaces). Do not deploy onto a different
   update baseline.
2. Stop the production ACF instance. Replace
   `WEB-INF/cfusion/lib/updates/hf202300-4232227.jar` with the de-locked jar (keep the
   filename). Restart. The classloader reads `lib/updates` at startup, so the server must be
   fully stopped first.
3. Keep the original Adobe `hf202300-4232227.jar` as the rollback artifact. Rolling back is
   "put the original jar back and restart."
4. This is a temporary bridge. Adobe's own hotfix (with a narrowed lock, or with the lock
   removed once they confirm it is redundant) should supersede it. Continue pressing Adobe
   using the throughput and thread-dump evidence in `docs/adobe-hotfixes/1-first-hotfix-performance.md` and
   `docs/adobe-hotfixes/1-first-hotfix-static-analysis.md`.

Note: running a modified Adobe proprietary jar is very likely outside the Adobe EULA/support
agreement. That is an accepted business decision for this bridge, not something this build
resolves.
