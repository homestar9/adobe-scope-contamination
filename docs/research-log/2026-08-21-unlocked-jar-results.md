# Unlocked jar correctness results (2026-08-21)

## The short version

The unlocked jar does not fix the bug. Under the real ORM workload it corrupts data
at the same rate as a completely unpatched server. It must not go to production.
The per-component "stripe" variant fails too. Only Adobe's v1 global lock holds up —
and this round found that even the v1 lock let one corruption through in 20,000
requests, so it is not perfect either.

Because the unlocked jar failed the correctness test, the planned performance
comparison was cancelled. There is nothing to benchmark.

## What was tested

The unlocked jar (`hotfixes/hf202300-4232227-unlocked.jar`, SHA256 `1674130D...BC85`)
is Adobe's v1 hotfix with the global construction lock removed and the four
per-instance scope fixes kept. Before this round it had only ever been tested on the
synthetic `/benchmark/construct` endpoint, where it looked great: about 4.4x faster
than the v1 hotfix, zero errors over 1.1M requests. That endpoint is known to give
false passes (stock Update 23 passes it and then fails completely under real load),
so this round ran the real test: the contamination gate
(`scripts/Test-Contamination.ps1`), which drives `/repro/alpha` and
`/repro/bravo` at the same time (20 connections each) against the SQL Server-backed
Quick ORM code path.

A new arm was stood up for this: ACF 2023.0.23 plus the unlocked jar, port 60846
(`server-bench-unlocked-u23.json`). The deployed jar's SHA256 was verified before
every run, because the v1 jar and the unlocked jar are both installed under the same
filename and a mixup would be invisible otherwise.

## Results

All runs on 2026-08-21, same machine, same JVM (Temurin 17.0.20), same database.
"Cold" means the JVM had never served a repro request before the concurrent load hit.
"Warm" means 20 sequential requests per endpoint ran first, so the ORM metadata was
already cached before concurrency started.

| Arm | Jar | State | Requests | HTTP 500s | Classified contaminations |
|---|---|---|---|---|---|
| buggy (2023.0.21) | none | cold | 20,000 | 20,000 (100%) | 0 (see below) |
| buggy (2023.0.21) | none | warm | 20,000 | 873 (4.4%) | 412 |
| lock-u23 (2023.0.23) | v1 hotfix | cold start | 20,000 | 1 | 1 in the log, 0 on the counter (see below) |
| u23 (2023.0.23 stock = Adobe v2) | none | cold, 3 fresh JVMs (2026-08-18 round) | 300,000 | 300,000 (100%) | 0 (cascade) |
| **unlocked-u23** | **unlocked** | **cold, 3 fresh JVMs** | **300,000** | **300,000 (100%)** | **0 (cascade)** |
| **unlocked-u23** | **unlocked** | **warm** | **20,000** | **913 (4.6%)** | **476** |
| stripe-u23 | stripe (per-component lock) | cold | 20,000 | 20,000 (100%) | 0 (cascade) |
| stripe-u23 | stripe (per-component lock) | warm | 20,000 | 76 (0.4%) | 24 |

Controls: the buggy arm (warm) proves the workload triggers the bug and the detector
counts it. The v1 lock arm proves the environment can produce a near-clean run.

## What the numbers mean

**The unlocked jar behaves exactly like an unpatched server.** Warm, it contaminates
at the same rate as buggy (913 vs 873 errors; 476 vs 412 detections). Cold, one of
the very first concurrent constructions corrupts Quick's cached entity metadata, and
after that every request on that JVM fails with
`Element NAME is undefined in THISITEM.` until restart. All three fresh-JVM sessions
did this, 100,000 out of 100,000 requests each. This is the same death mode as stock
Update 23. Conclusion: on the real ORM path, the v1 hotfix's four per-instance scope
fixes contribute almost nothing. The global lock IS the fix.

**The stripe variant fails for a clear reason.** It locks per component, so two
threads building the same component serialize, but an AlphaParent and a BravoParent
can still construct at the same time — and that cross-component pair is exactly what
races. Cold, it dies the same way as the unlocked jar. Warm, it corrupts about 10x
less often than unpatched (24 vs 412 detections), which confirms the lock granularity
is the whole story: partial serialization narrows the race window, and only full
serialization closes it.

**New finding: Adobe's v1 lock is not perfect either.** During its 20,000-request
control run, the v1 lock arm returned exactly one HTTP 500. The error was a real
variables-scope corruption (Quick's cached metadata resolved to another instance:
`Method does not exist on QueryBuilder [setalphaChildren]`), logged at 00:07:10 UTC —
inside the lock arm's run window, with nothing else under load. The 2026-08-18 clean
result for this arm was also only 20,000 requests, so it likely just got lucky. The
corruption did not cascade: one request failed and everything after it was clean.
So the v1 lock turns the bug from "constant, and fatal on cold start" into "roughly
one non-fatal error per 20,000 requests." That is deployable with monitoring, but it
is not zero.

**New finding: cold start is fatal even on the unpatched engine.** A cold 2023.0.21
JVM hit with 40 concurrent connections poisoned its metadata immediately and failed
100% of requests. The earlier "degrades gracefully at ~2-5%" description of the buggy
arm only applies when the metadata cache was populated before concurrency started.
Anything without the global lock — buggy, stock Update 23, the unlocked jar, the
stripe jar — has a high chance of bricking the JVM on every cold start under load.

## A note on the two counters

The gate reports two numbers that diverge in these runs:

- "Classified contaminations" comes from an application-scoped counter incremented by
  `interceptors/ContaminationDetector.cfc`, which inspects SQL before it executes.
- The poisoned-metadata cascade errors (`Element NAME is undefined in THISITEM.`)
  happen before any SQL is generated, and their message does not match any pattern in
  the handler's classifier, so they show up as 100% HTTP 500s with zero "classified"
  events. The 500 count is the signal in those runs.
- The v1 lock arm's single failure was classified by the request handler (it writes
  `logs/contamination_log.txt`) but that path does not increment the counter — only
  the SQL interceptor does. That is why the gate printed 0 classified while the log
  holds one `VARIABLES_SCOPE_CORRUPTION` entry.

## Where the raw data is

- `benchmark-results-u23/gate-unlocked-u23/` — the 3x100k cold run (the main result)
- `benchmark-results-u23/gate-unlocked-u23-warm/` — the warm 20k run
- `benchmark-results-u23/gate-stripe-u23-cold/`, `gate-stripe-u23-warm/`
- `benchmark-results-u23/gate-buggy/`, `gate-lock-u23/` — this round's controls
  (overwrites the 2026-08-18 control outputs; the summary numbers from that round are
  recorded in `docs/adobe-hotfixes/2-second-hotfix-correctness.md`)
- `logs/contamination_log.txt` — the v1 lock arm's single corruption is the
  `detectedAt 2026-08-22 00:07:10.324` entry (the app logs in UTC; that is
  17:07:10 local, 44 seconds before the lock gate finished)

Jar provenance for this round: unlocked jar rebuilt from source and it reproduced the
audited SHA256 `1674130D487807C4A75CBF59EC48DB95883C51020AE1C1E4EEBFD5678DF0BC85`
(2 monitorenter / 4 monitorexit, only TemplateProxyFactory changed). Stripe jar SHA256
`726F8D51E833B5F244285ACAD8CCA7A88BE10D6BD903CDA876B025D4260D1550` (3/6 plus
`ConstructionLockSupport`). The stripe jar was temporarily swapped into the
unlocked-u23 arm for its two runs and the audited unlocked jar was restored afterward.

## Practical conclusions

1. Do not deploy the unlocked jar. It does not fix anything.
2. Keep Adobe's v1 hotfix (the global lock) in production and accept the throughput
   cost. It is the only build that survives cold-start concurrency.
3. Consider production monitoring for the residual v1 failure mode: a spike of
   `QuickMissingMethod` / "Method does not exist on QueryBuilder" errors is the
   signature. Rate observed here: 1 in 20,000 requests, non-cascading.
4. Never warm-restart a lock-free build into live traffic: without the global lock,
   a cold JVM taking concurrent ORM traffic has a high chance of poisoning itself
   permanently.
5. For the Adobe thread: this is more evidence that the corruption lives in state
   shared across different components during construction, which is why their
   compiler-only v2 fix and any per-component locking cannot work.
