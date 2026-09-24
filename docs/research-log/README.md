# Research log (August 2026)

Dated working notes from the investigation into the cause. They record experiments that were
tried and closed, so they are written in the moment and some conclusions were later revised.
Where that happened, the later note says so. Commands in these notes use the script names of the
time (`Invoke-ContaminationGate.ps1` is now `Test-Contamination.ps1`); the current ones are in the
[testing guide](../guides/TESTING_GUIDE.md). For the current picture, read
[docs/README.md](../README.md) first.

**Naming.** In these notes "v3", "v4" and "v5" are names for **our own experimental builds and
probes**, made before Adobe's third hotfix existed. They are not Adobe hotfixes. Everywhere else
in this repository, v1, v2 and v3 mean Adobe's first, second and third hotfix.

| Date | Note | What it found |
|---|---|---|
| 2026-08 | [unlocked-jar-build](2026-08-unlocked-jar-build.md) | How we rebuilt Adobe's first hotfix without its global lock, to measure the lock's cost |
| 2026-08 | [unlocked-jar-benchmark](2026-08-unlocked-jar-benchmark.md) | That build's throughput against Adobe's first hotfix |
| 2026-08-21 | [unlocked-jar-results](2026-08-21-unlocked-jar-results.md) | Without the lock the contamination returns: the lock was doing the work |
| 2026-08-21 | [startup-crash-root-cause](2026-08-21-startup-crash-root-cause.md) | The exact operation behind the startup crash |
| 2026-08-21 | [duplicator-lock-experiments](2026-08-21-duplicator-lock-experiments.md) | Narrower locks around `ObjectDuplicator` do not fix it |
| 2026-08-23 | [quick-defensive-patches](2026-08-23-quick-defensive-patches.md) | What application-side Quick patches can and cannot catch |
| 2026-08-23 | [what-crosses-between-requests](2026-08-23-what-crosses-between-requests.md) | Instrumented measurement of what actually crosses between requests, and nine causes ruled out |
| 2026-08-24 | [invoke-path-probe](2026-08-24-invoke-path-probe.md) | The crossing object is already foreign when it enters the engine's invoke path |

The tools that built these experimental jars are in `scripts/archive/`.
