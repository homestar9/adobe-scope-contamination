# Final comparison: stock ColdFusion 2023 against the fourth hotfix

Date: 2026-10-14. A short, two-server comparison that answers the two questions that matter
for shipping Adobe's fourth hotfix (v4): is the scope contamination fixed, and does the hotfix
cost speed? The full analysis and two overnight runs with every hotfix are in
[4-fourth-hotfix-static-analysis.md](4-fourth-hotfix-static-analysis.md) and
[4-fourth-hotfix-results.md](4-fourth-hotfix-results.md).

## Answer

**Yes, it is fixed, and there is no speed cost.** On the same machine, in the same hour, stock
Update 23 failed 8% of real requests and a third of the mechanism test's requests to the bug. v4
failed none of 250,000. v4 served as many requests per second as stock, with about the same
tail latency, at every load level measured.

## Setup

Two ColdFusion 2023 Update 23 installs on one Windows machine that differ only by one jar:
`u23` (stock) and `localtemp-u23` (stock plus `hf202300-4232227-adobe-v4.jar`, SHA256
`9d17ad33…`). Same JDK 17, same settings, same SQL Server database, ColdBox 8.1.0 and Quick
12.0.12. Before the run both servers proved their identity: v4 loads `NeoPageContext` from the
hotfix jar and keeps the compiler's literal temporaries function-local, while stock keeps them
in the shared `variables` scope. Every burst hit a server that had been restarted, answered,
and taken serial warm-up requests first. The startup crash under immediate load is a separate
Adobe case and was not measured. The machine was as quiet as a working day allowed: other
development servers were still running, Dropbox was off.

## 1. Is the contamination fixed?

Contaminated requests (HTTP 5xx) of requests sent, 20 connections per endpoint.

| Test | Stock Update 23 | Update 23 + v4 |
|---|---|---|
| Real workload: two Quick entities sharing `BaseEntity` (`/repro/alpha` + `/repro/bravo`) | 1,607 of 20,000 (8.0%) | **0 of 150,000** (two fresh server starts) |
| Mechanism alone, no database (`/repro/tempvar`) | 6,917 of 20,000 (34.6%) | **0 of 100,000** |
| Standalone demo (`hotfixrepro/scopeleak`): builds that came back with another thread's value, struct / array / `invoke()` | 1,655 / 1,467 / 1,348 of 3,200 each: FAIL | **0 / 0 / 0: PASS** |
| P8 inside the application (`/torture/p8`) | 543 of 4,800 crossed, 3 leaked keys | **0 of 4,800, 0 leaked keys** |

Stock's failures are the production symptom: 1,311 queries built against the other entity's
table (`TABLE_NAME_CONTAMINATION`) and 296 entities handed another request's state
(`VARIABLES_SCOPE_CORRUPTION`). Today's 0 in 250,000 adds to the
two earlier runs' 0 in 3,080,000; together, zero in 2,750,000 real-workload requests rules out
any rate above about 1 in 900,000 (95%).

## 2. Does v4 cost speed?

Real workload, median of 3 runs of 30 s per point, the two servers alternated on every
measurement. Stock loses requests to the bug, and its error pages are quick to produce, so its
raw rate flatters it; the fair comparison counts only its successful requests.

| Connections per endpoint | Stock, all requests | Stock failing | Stock, successful only | v4 (0% failing) | v4 / stock, successful | v4 / stock, all | p99 stock | p99 v4 |
|---|---|---|---|---|---|---|---|---|
| 8 | 206.6 | 6.2% | 193.9 | **206.2** | **1.06** | 1.00 | 127 ms | 115 ms |
| 16 | 212.5 | 5.2% | 200.6 | **209.1** | **1.04** | 0.98 | 250 ms | 253 ms |
| 32 | 185.0 | 12.3% | 162.0 | **181.4** | **1.12** | 0.98 | 569 ms | 544 ms |

Construction of a Quick entity and its query builder (the ORM path, no database), median of 3
runs of 20 s:

| Connections | Stock | v4 | v4 / stock |
|---|---|---|---|
| 8 | 38.5 | 38.6 | **1.00** |
| 32 | 67.6 | 72.4 | **1.07** |

Even against stock's raw rate, error pages included, v4 is within 2% at every level, which is
inside the run-to-run spread of either server (up to 16% between repeat runs of one point on
this machine). Counting only work actually done, v4 is 4% to 12% faster, because none of its
requests are lost to the bug. There is no lock in the hotfix, so there is nothing to pay for.

## Reproducing it

```powershell
.\scripts\Install-TestServers.ps1 -SkipInstall -ClearFelixCache -Servers u23,localtemp-u23
.\scripts\Invoke-FinalComparison.ps1
```

About 45 minutes. Results, the step log and `summary.md` (both tables, computed from the raw
files) are written to `benchmark-results-u23/final-v4-vs-stock/`; this page's figures come from
that summary.
