# Quick defensive-patch gate results (2026-08-23)

This documents the first full test pass of the four Quick-level defensive patches in
`patches/quick/` against the real contamination gate. All runs: stock ACF 2023.0.21
(`server-bench-buggy.json`, port 60845, no Adobe hotfix), Quick 12.0.12 + qb 13.1.0,
20 connections per endpoint on `/repro/alpha` + `/repro/bravo` concurrently.

"Reached SQL" below means a wrong-table statement actually executed against SQL Server
(the destructive outcome). "Caught pre-execute" means the app's ContaminationDetector
saw the mismatched SQL at qb's `preQBExecute` before the driver ran it.

## Run summary

| # | Quick | Mode | JVM state | Requests | 5xx | Outcome |
|---|-------|------|-----------|----------|-----|---------|
| 1 | stock | — | cold + immediate load | 20,000 | 20,000 (100%) | Cascade. 38 `getKeyString` tears, then every request failed. JVM stayed broken (single requests still 500) until restart. |
| 2 | stock | — | warm (20 serial requests first) | 20,000 | 991 (5.0%) | The known warm race-2 rate. 0 `getKeyString`. |
| 3 | patched (A+B+C, first C version) | repair | cold + immediate load | 19,773 | 19,773 (100%) | Cascade with a NEW signature: raw NPE looping inside `buildMetadataSnapshot` on every request. Exposed a flaw in C's first version (producer failures escaped the evict-and-retry). Fixed the same day. JVM stayed broken. |
| 4 | patched (A+B v1+C fixed) | repair | warm | 20,000 | 959 (4.8%) | 656 wrong-table statements reached SQL. Guard caught 0. |
| 5 | patched (A+B v2 cross-object+C) | repair | warm | 20,000 | 861 (4.3%) | 614 reached SQL. Guard caught 0. |
| 6 | patched (+ unknown-attribute diagnostic) | repair | warm | 20,000 | 863 (4.3%) | 595 reached SQL. Diagnostic caught **85** crossed-graph statements (detect-only). |
| 7 | patched (all) + **warm-up** | repair | cold + immediate load, **2 fresh JVMs** | 40,000 | 1,915 (4.8%) | **No cascade in either session. No brick. Cold now behaves like warm.** 0 `getKeyString`. |
| 8 | patched (all) | **off** | warm | 20,000 | 905 (4.5%) | Same rate as stock — defaults preserve behavior. |
| 9 | patched (all), no warm-up | off | cold + immediate load | 4,000 | 212 (5.3%) | No cascade — a "lucky" cold start (0 tears occurred; cold cascade is bimodal). One run; not evidence either way. |

Throughput (bombardier mean RPS, alpha+bravo combined, warm 20k runs):
stock 252.3 · patched guards-on 241.1 · patched guards-off 240.2. Guards on vs off are
identical; patched vs stock shows −4.8% on single runs in this Dropbox-synced
environment, which is within plausible run-to-run noise but was not proven to be noise.
The synthetic construction benchmark should be run before making a performance claim in
a PR.

## Construction microbenchmark (2026-08-23, later session)

`/benchmark/quickconstruct?count=200` constructs a Quick entity plus its query builder
per iteration with no database work, isolating exactly the code the patches change.
Protocol: stock and patched runs interleaved (restart between states), 30s warmup, 45s
measurements, results written outside the Dropbox folder. Mean RPS over 2 runs each:

| State | c=1 | c=8 |
|---|---|---|
| stock | 1.76 | 10.85 |
| patched (first version) | 1.60 (−9.1%) | 9.57 (−11.8%) |

That regression was real and reproducible (stock's c=8 runs landed on 10.85 twice).
Two causes were identified and fixed:

1. The guard settings were injected into every QuickQB and QuickBuilder through the
   `box:setting:` WireBox DSL — four DSL resolutions per entity+builder pair. Fix:
   `ModuleConfig.onLoad` resolves the settings once and passes them as constant
   constructor arguments to the QuickQB mapping; QuickBuilder copies the modes lazily
   from its paired qb builder.
2. `useQuickColumnFormatter()` still allocated a compatibility closure per builder.
   Fix: an overridden `getColumnFormatter()` builds that closure only on demand, so
   plain construction allocates nothing.

Optimized numbers (same interleaved protocol):

| State | c=1 | c=8 |
|---|---|---|
| stock | 1.77 | 11.03 |
| patched, optimized | 1.72 (−2.8%) | 10.24 (−7.2%) |

At c=1 the optimized build sits inside stock's own run-to-run spread (stock ranged
1.71–1.82 across sessions), so single-threaded construction cost is not measurable.
At c=8 a few-percent gap remained in that session.

A third interleaved session measured each PR branch's files separately (c=8 only,
2 reps: stock 12.57, formatter-only 12.09, snapshot+warmup 11.45, guard-only 11.82).
That session's machine noise was too high to attribute cost per branch — stock's own
two reps differed by 21% — so treat the per-branch numbers as "all within a few
percent of stock" rather than a ranking. It did serve as the compile-and-run check
for each branch's exact file set: all four configurations booted and passed the
construction checksum.

Bottom line for the PR: no measurable single-threaded construction cost; under
heavy concurrent construction, at most a few percent on a construction-only
microbenchmark in a noisy environment, and no measurable difference on the
DB-bound repro workload. Upstream's own tests/performance suite and six-engine PR
CI can confirm independently.

## Engine smoke tests (fully patched module, defaults off)

- BoxLang 1: 20/20 sequential `/repro/alpha` + `/repro/bravo` requests OK;
  `/benchmark/quickconstruct` checksum correct.
- Lucee 6: same — 20/20 OK, checksum correct.

The patched module is behavior-neutral on both engines, as designed.

## Upstream port (fork: homestar9/quick)

Upstream `main` sits exactly at v12.0.12 — the version vendored here — with zero
drift in the four files we change, so the port needed no adaptation. Three
branches are pushed to the fork, each standing alone on `main`, each with TestBox
specs in the upstream house style (specs are written to convention but were not
executed locally; upstream's `pr.yml` CI runs the full suite on Lucee 5/6,
ACF 2021/2023/2025, and BoxLang for every PR):

1. `acf/columnformatter-direct-dispatch` — patch 0001 + ColumnFormatterSpec.
2. `acf/cold-start-protection` — patches 0003 + 0004 (two commits) +
   MetadataSnapshotSpec + MetadataWarmupSpec.
3. `acf/entity-table-guard` — patch 0002 + EntityTableGuardSpec.

Each branch's exact file set was booted and construction-checked on the local ACF
arm before pushing. Branches 1 and 3 both add lines at the end of
`QuickQB.newQuery()`, so whichever PR merges second will need a trivial conflict
resolution there.

## What the runs proved

### 1. The warm-up (patch 0004) is the cold-start fix

The cold cascade needs concurrent FIRST-TIME metadata builds. Serially constructing the
four entities at `afterAspectsLoad` removes that window. Two fresh JVMs took immediate
40-way load with zero cascade and zero tears (run 7), where stock (run 1) and patched-
without-warm-up (run 3) both went to 100% failure until restart. Cold runs are bimodal,
so 2/2 clean is initial evidence, not proof — but the mechanism is deterministic: after
the serial warm-up there is no first-population race left to lose.

### 2. Race 2's wrong-table SQL cannot be reliably intercepted in userland

This is the session's most important negative result, with a new mechanism finding:

- **The state guards are blind because the crossing is self-consistent.** When the
  engine crosses scopes, the builder's table name AND its entity reference cross
  together. A guard comparing them (B v1, inside QuickQB) sees a matching pair and
  passes — 0 catches across runs 4–6 while ~600 wrong-table statements per run reached
  SQL. A deliberately mangled table (probe test) was caught and repaired instantly, so
  the machinery works; the real corruption just never looks mangled from inside.
- **The crossing can capture a whole relationship graph.** The unknown-attribute
  diagnostic (run 6) caught 85 statements shaped like
  `UPDATE [alpha_child] SET [bravo_parent_id]` where the builder's OWN entity was
  AlphaChild: the bravoChildren relationship had been built holding the wrong related
  entity. Everything the builder can check agrees with itself; only the attribute names
  betray the mix. This is direct evidence of a third race-2 victim (the relationship's
  captured related-entity reference), new since the engine-level analysis.
- **The remaining ~85% of wrong-table statements were not even graph-crossed** — their
  attributes matched their entity at `updateAll` time, yet the compiled SQL had the
  wrong table. That points at a crossed READ inside qb's compile itself, after the
  guard ran microseconds earlier. A pre-compile push (`from( entityTable )`, B v2 —
  the production workaround pattern) cannot survive that.

Practical consequence: B's `repair` mode fixes visible crossings (which the production
incident's vector apparently was) and its `detect` mode is a valuable diagnostic, but
neither stops the repro's wrong-table SQL. Only Adobe's construction lock does.

### 3. One real app-level chokepoint exists: `preQBExecute`

qb's `BaseGrammar.runQuery` executes `data.sql` AFTER announcing `preQBExecute` with
the same struct — an interceptor can rewrite `data.sql` and qb honors it. The app's
ContaminationDetector proves wrong-table UPDATEs are *textually* identifiable there
(~420 catches per warm run, before the driver). An app that can infer the owning table
from the SET columns (as this repro's schema can) could repair or abort there. That is
app-schema-specific, so it belongs in documentation, not in a generic Quick patch.

### 4. C (snapshot hardening) — evidence status

- Its first version made the cold failure WORSE-looking (raw NPEs looping in the
  producer, run 3) because the evict-and-retry didn't wrap the producer. Fixed: the
  whole build+duplicate is now inside the retry.
- The detached snapshot means steady-state constructions never hand engine-shared maps
  to `ObjectDuplicator`. No warm run with C showed a tear — but neither did the stock
  warm run (run 2: 0 `getKeyString`), so there is no positive control for a warm-tear
  claim; warm tears are simply rare at this load.
- The clean-`QuickEntityMetadataException` path has not yet been observed against a
  real tear (run 9's cold start happened not to tear). Claim it as designed behavior,
  not as measured behavior.
- Its build-time duplicate still reads engine-shared metadata and CAN tear during a
  cold storm (run 3 stack: NPE inside `buildMetadataSnapshot`'s locked duplicate) —
  the racing writer is the engine's construction path, which no CFML lock reaches.
  This is why C needs D for cold starts.

### 5. A (columnFormatter direct dispatch)

Did not reduce this repro's wrong-table rate — the repro's UPDATE uses unqualified
query-param columns, so the formatter never touches the table name here. Its value is
unchanged from production: it removed the qualifyColumn-wrong-table vector there, and
it deletes a per-builder closure allocation. Keep, framed as cleanup + one closed
vector, not as a fix for this repro.

## Recommended upstream framing (revised)

- **PR 1 (A)**: engine-neutral refactor, one closed production vector, zero cost. Easy.
- **PR 2 (D + C)**: the cold-start protection, pitched together: warm-up removes the
  concurrent-first-build window; snapshot hardening keeps steady-state duplication off
  engine-shared structures and converts residual metadata corruption into one clear,
  named exception. Opt-in warm-up list; zero warm-path cost.
- **PR 3 (B)**: `detect`/`repair` guard, pitched as detection + partial mitigation with
  the blindness finding stated plainly. `detect` mode's interception point (plus the
  unknown-attribute check) gives ACF users visibility they currently have no way to get.
- **qb**: documentation note only (unchanged), now with a stronger fact: `preQBExecute`
  mutation of `data.sql` is honored, so schema-aware apps can build a last-line guard.

## Environment toggles used by the harness

`.env` drives the patched module through `config/Coldbox.cfc` `moduleSettings.quick`:

- `QUICK_VERIFY_ENTITY_TABLE` = `off` | `detect` | `repair` (resting state: `off`)
- `QUICK_WARMUP` = comma list of entity mappings (resting state: empty, so the buggy
  arm still reproduces the cold cascade as a control)

The `quickEntityTableMismatch` events are recorded by
`interceptors/ContaminationDetector.cfc` as `TABLE_MISMATCH_CAUGHT` lines in
`logs/contamination_log.txt`.

Raw gate outputs: `benchmark-results-u23/gate-buggy-*/`.
