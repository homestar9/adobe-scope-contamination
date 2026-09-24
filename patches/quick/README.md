# Defensive Quick patches for the ACF scope-contamination bug

These four patches change the Quick ORM module (v12.0.12) to reduce the impact of the
Adobe ColdFusion engine concurrency defect documented in `docs/`. They are the source
of truth for this work: `modules/**` is gitignored, so the patched files in
`modules/quick/` are not tracked — these patch files are.

Each patch is one planned upstream PR to `coldbox-modules/quick`. Paths inside the
patches are relative to the Quick module root (`models/...`, `ModuleConfig.cfc`),
which matches both `modules/quick/` here and the upstream repository layout.

## The patches, in order

1. **0001-columnformatter-direct-dispatch.patch**
   Replaces the column-formatter closure (created during construction, captured the
   QuickBuilder) with direct method dispatch: `QuickQB.applyColumnFormatter` calls
   `variables.quickBuilder.qualifyColumn()` at call time. Under the engine defect,
   the captured closure link could resolve to a different builder and qualify
   columns with the wrong table. Custom formatters set via `setColumnFormatter`
   keep their old precedence. No settings; zero cost (removes a closure allocation
   per builder). Production-validated.

2. **0002-entity-table-guard.patch**
   Adds settings `verifyEntityTableOnWrite` / `verifyEntityTableOnRead`
   (`"off" | "detect" | "repair"`, both default `"off"`). Two layers: QuickQB
   compares its table name against `entity.tableName()` just before insert / update /
   upsert / delete / insertUsing (write flag) or get (read flag), and QuickBuilder
   re-asserts the entity's table on the qb object before forwarding statements
   (the production "re-assert from()" pattern), plus a detect-mode check that flags
   `updateAll` attributes the target entity does not know about. On mismatch it
   announces a new `quickEntityTableMismatch` interception point; `repair` also
   resets the table. Cost when off: two short-circuited string checks per statement.

   **Honest scope (measured 2026-08-23, see docs/research-log/2026-08-23-quick-defensive-patches.md):**
   these guards catch crossings that are VISIBLE from inside the builder (a mangled
   table with a clean entity — the production incident's shape). They are blind to
   the repro's dominant vectors, where the crossing is self-consistent (builder and
   entity cross together, or a whole relationship graph crosses, or the crossed read
   happens inside qb's compile). In the repro gate they repaired 0 of ~600 wrong-table
   statements per 20k warm requests; the unknown-attribute check detected 85
   crossed-graph cases. Frame upstream as detection + partial mitigation, never as a
   fix.

3. **0003-metadata-snapshot-hardening.patch**
   Restructures `BaseEntity.metadataInspection`:
   - The cache producer closure body moves unchanged into a new private method
     `buildMetadataSnapshot()`, which now returns a **detached** copy made behind a
     single module-wide named lock (`quick.metadata.snapshot`). Per-construction
     duplication then never touches engine-shared metadata. The lock is only
     reachable on a cache miss, so the warm path never sees it.
   - The whole build-and-duplicate moves into `duplicateMetadataSnapshot()`: on ANY
     failure (a torn build included) it evicts the cache entry and retries once; on
     a second failure it throws a clear `QuickEntityMetadataException` instead of
     the engine's NullPointerException.

   **Honest scope:** the build-time duplicate still reads engine-shared metadata and
   can tear during a cold concurrent-first-build storm — the racing writer is the
   engine's construction path, which no CFML lock reaches (observed live: the tear
   NPE fired inside this method's locked duplicate). This patch cannot prevent the
   cold cascade by itself; pair it with 0004. The clean-exception path is designed
   behavior, not yet observed against a real tear.

4. **0004-metadata-warmup.patch**
   Adds the opt-in setting `metadataWarmupMappings` (array of entity mapping names,
   default `[]`). After the application loads, Quick constructs each listed entity
   once, one at a time, with `shallow=true` — filling the metadata caches before
   concurrent traffic can race the first-time builds. A warm-up failure logs a
   warning and never blocks startup.

   **This is the cold-start fix.** With the four repro entities listed, two fresh
   JVMs took immediate 40-way load with zero cascade and zero tears, where stock and
   patched-without-warm-up both went to 100% failure until restart
   (docs/research-log/2026-08-23-quick-defensive-patches.md, runs 1, 3, 7).

## Construction cost

Measured with `/benchmark/quickconstruct` (entity + builder per iteration, no
database, interleaved stock-vs-patched runs). The first version of the patch set
cost 9–12% on pure construction. Two fixes brought it down: the guard settings now
arrive as constant constructor arguments resolved once in `ModuleConfig.onLoad`
(instead of four per-instance `box:setting:` injections), and the column formatter
compatibility closure is built on demand in `getColumnFormatter()` (instead of on
every builder). After that, single-threaded construction is inside stock's
run-to-run spread; under 8-way concurrency a ~5–8% gap remained for the combined
set — per-patch numbers are in docs/research-log/2026-08-23-quick-defensive-patches.md.

## Re-applying to a fresh Quick 12.0.12

From the Quick module root (files must have LF line endings):

```
git -c core.autocrlf=false apply -p1 0001-*.patch 0002-*.patch 0003-*.patch 0004-*.patch
```

`-c core.autocrlf=false` matters on Windows: without it, git apply can rewrite the
whole file to CRLF. To get back to stock, reverse-apply in reverse order:
`git -c core.autocrlf=false apply -R -p1 0004-*.patch 0003-*.patch 0002-*.patch 0001-*.patch`
(or reinstall quick 12.0.12 from ForgeBox).

## What these patches do NOT do

They are mitigations for an Adobe engine defect, not a fix. Measured on the repro
gate (docs/research-log/2026-08-23-quick-defensive-patches.md): the ~4–5% warm contamination rate under
heavy concurrent construction is unchanged, and wrong-table SQL from
self-consistently crossed builders still reaches the database — no userland guard
can see it. Only Adobe can fix the engine. What the patch set demonstrably removes
is the cold-start cascade (a fresh JVM under a traffic burst failing 100% until
restart) when the warm-up list is configured, plus the production-observed
columnFormatter vector. Lucee and BoxLang do not have the defect; on those engines
these changes are behavior-neutral.
