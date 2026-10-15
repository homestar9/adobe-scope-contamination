# Final comparison: stock ColdFusion 2023 against the fourth hotfix

Date: 2026-10-14. A short, two-server comparison that answers the two questions that matter
for shipping Adobe's fourth hotfix (v4): is the scope contamination fixed, and does the hotfix
cost speed? The full analysis and two overnight runs with every hotfix are in
[4-fourth-hotfix-static-analysis.md](4-fourth-hotfix-static-analysis.md) and
[4-fourth-hotfix-results.md](4-fourth-hotfix-results.md).

## Answer

**Yes, it is fixed, and there is no noticeable speed cost.** On a freshly rebooted, quiet
machine, stock Update 23 failed 6.7% of real requests and a third of the mechanism test's
requests to the bug. v4 failed none of 250,000. Counting the work each server actually
completed, v4 ran at 0.97 to 1.11 times stock's speed at every load level. Its 99th-percentile
latency was never more than 27 ms above stock's. The same comparison run on a busier machine that afternoon gave the same
answer.

## Setup

Two ColdFusion 2023 Update 23 installs on one Windows machine that differ only by one jar:
`u23` (stock) and `localtemp-u23` (stock plus `hf202300-4232227-adobe-v4.jar`, SHA256
`9d17ad33…`). Same JDK 17, same settings, same SQL Server database, ColdBox 8.1.0 and Quick
12.0.12. Before the run both servers proved their identity: v4 loads `NeoPageContext` from the
hotfix jar and keeps the compiler's literal temporaries function-local, while stock keeps them
in the shared `variables` scope. Every burst hit a server that had been restarted, answered,
and taken serial warm-up requests first. The startup crash under immediate load is a separate
Adobe case and was not measured.

The main run (`final-v4-vs-stock-reboot`) started right after a full reboot. No other
development servers were running, Dropbox was stopped for the run, and nothing else was in use
on the machine. It took 37 minutes. A 16-minute repeat of the speed tests followed it, with the
order reversed.

## 1. Is the contamination fixed?

Contaminated requests (HTTP 5xx) of requests sent, 20 connections per endpoint.

| Test | Stock Update 23 | Update 23 + v4 |
|---|---|---|
| Real workload: two Quick entities sharing `BaseEntity` (`/repro/alpha` + `/repro/bravo`) | 1,346 of 20,000 (6.7%) | **0 of 150,000** (two fresh server starts) |
| Mechanism alone, no database (`/repro/tempvar`) | 6,936 of 20,000 (34.7%) | **0 of 100,000** |
| Standalone demo (`hotfixrepro/scopeleak`): builds that came back with another thread's value, struct / array / `invoke()` | 1,834 / 1,753 / 1,620 of 3,200 each: FAIL | **0 / 0 / 0: PASS** |
| P8 inside the application (`/torture/p8`) | 2,014 of 4,800 crossed, 3 leaked keys | **0 of 4,800, 0 leaked keys** |

The afternoon run on the busier machine matched this: stock failed 8.0% of real requests and
34.6% of mechanism requests, and v4 again failed 0 of 250,000. Across both of today's runs and
the two earlier overnight runs, v4 has served 2,900,000 real-workload requests with zero
contaminated. That rules out any rate above about 1 in 950,000 (95% confidence).

## 2. Does v4 cost speed?

Real workload, median of 3 runs of 30 s per point, the two servers alternated on every
measurement. Stock loses requests to the bug, and its error pages are quick to produce, so its
raw rate flatters it; the fair comparison counts only its successful requests.

In the main run, v4 was measured first in every pair. The repeat restarted both servers and
measured stock first, so that the order of measurement or one particular server process could
not decide the result.

| Run | Connections per endpoint | Stock, all requests | Stock failing | Stock, successful only | v4 (0% failing) | v4 / stock, successful | v4 / stock, all | p99 stock | p99 v4 |
|---|---|---|---|---|---|---|---|---|---|
| Main, v4 first | 8 | 236.2 | 6.3% | 220.6 | **216.8** | **0.98** | 0.92 | 101 ms | 110 ms |
| | 16 | 233.6 | 3.9% | 224.2 | **217.5** | **0.97** | 0.93 | 208 ms | 235 ms |
| | 32 | 204.4 | 9.9% | 183.5 | **191.4** | **1.04** | 0.94 | 475 ms | 501 ms |
| Repeat, stock first, fresh servers | 8 | 229.6 | 6.7% | 214.2 | **217.2** | **1.01** | 0.95 | 112 ms | 122 ms |
| | 16 | 230.9 | 4.2% | 221.2 | **227.7** | **1.03** | 0.99 | 220 ms | 231 ms |
| | 32 | 192.5 | 10.0% | 173.3 | **192.0** | **1.11** | 1.00 | 501 ms | 499 ms |

Construction of a Quick entity and its query builder (the ORM path, no database), median of 3
runs of 20 s:

| Run | Connections | Stock | v4 | v4 / stock |
|---|---|---|---|---|
| Main, v4 first | 8 | 41.7 | 39.9 | **0.96** |
| | 32 | 80.1 | 78.9 | **0.99** (runs spread 16%) |
| Repeat, stock first | 8 | 40.0 | 40.7 | **1.02** |
| | 32 | 76.4 | 76.6 | **1.00** |

v4 kept up with stock at every point. Measured against stock's raw rate, which includes its
error pages, the main run showed v4 6% to 8% behind. With the order reversed on fresh servers
that gap shrank to 0% to 5%, so most of it came from the order and from the particular server
processes, not from the hotfix. The afternoon run on the busier machine gave 0.98 to 1.00
against stock's raw rate. Counting only work actually done, v4 ranged from 3% slower to 11%
faster, and it pulls ahead under heavier load because none of its requests are lost to the bug.
The hotfix contains no lock, and nowhere in it could a cost build up under load.

## Reproducing it

```powershell
.\scripts\Install-TestServers.ps1 -SkipInstall -ClearFelixCache -Servers u23,localtemp-u23
.\scripts\Invoke-FinalComparison.ps1 -Round final-v4-vs-stock-reboot
```

About 40 minutes. Results, the step log and `summary.md` (both tables, computed from the raw
files) are written to `benchmark-results-u23/<round>/`. This page's main-run figures come from
`final-v4-vs-stock-reboot/summary.md`. The reversed repeat is in
`final-v4-vs-stock-reboot/speed-reversed/`, and the afternoon run is in `final-v4-vs-stock/`.
