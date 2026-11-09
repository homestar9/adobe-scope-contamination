# Final comparison: stock Update 23 against Update 23 + v4

Round `final-v4-vs-stock-reboot`, generated 2026-10-14 17:21. Stock = `u23`, v4 = `localtemp-u23`. Log: `final-20261014-164427.log`.

## 1. Is the contamination fixed?

Contaminated requests (HTTP 5xx) of requests sent, 20 connections per endpoint, every session on a restarted server warmed with 500 serial requests.

| Test | Stock | v4 |
|---|---|---|
| Real workload (`/repro/alpha` + `/repro/bravo`) | 1,346 of 20,000 (6.7%), CONTAMINATION, 223 requests/s | **0 of 150,000**, CLEAN, 214, 220 requests/s |
| Mechanism alone (`/repro/tempvar`, no database) | 6,936 of 20,000 (34.7%), CONTAMINATION, 1228 requests/s | **0 of 100,000**, CLEAN, 1160 requests/s |
| Standalone demo (`hotfixrepro/scopeleak`), struct / array / invoke() | FAIL, 1834 / 1753 / 1620 of 3,200 crossed | PASS, 0 / 0 / 0 of 3,200 crossed |
| P8 inside the application (`/torture/p8`) | 2014 of 4800 crossed, 3 leaked keys | 0 of 4800 crossed, 0 leaked keys |

## 2. Does v4 cost speed?

Real workload, median of 3 runs of 30s, servers alternated per measurement. Stock loses some requests to the bug and its error pages are fast, so it is also shown counting only successful requests; the pass bar is v4 at least 0.95 of that. A cell whose runs spread by more than 10% is marked *noisy*.

| Connections per endpoint | Stock, all requests | Stock failing | Stock, successful only | v4 | v4 / stock successful | v4 / stock all | p99 stock | p99 v4 | Runs stock | Runs v4 |
|---|---|---|---|---|---|---|---|---|---|---|
| 8 | 236.2 | 6.3% | 220.6 | **216.8** (0.0% failing) | **0.98** | 0.92 | 101 ms | 110 ms | 236 / 237 / 228 | 223 / 217 / 213 |
| 16 | 233.6 | 3.9% | 224.2 | **217.5** (0.0% failing) | **0.97** | 0.93 | 208 ms | 235 ms | 234 / 234 / 230 | 218 / 222 / 215 |
| 32 | 204.4 | 9.9% | 183.5 | **191.4** (0.0% failing) | **1.04** | 0.94 | 475 ms | 501 ms | 204 / 205 / 193 | 193 / 191 / 191 |

Quick entity + builder construction (the ORM path, no database), median of 3 runs of 20s:

| Connections | Stock | v4 | v4 / stock | Runs stock | Runs v4 |
|---|---|---|---|---|---|
| 8 | 41.7 | 39.9 | **0.96** | 42 / 42 / 41 | 40 / 40 / 40 |
| 32 | 80.1 | 78.9 | **0.99 *noisy*** | 83 / 76 / 80 | 79 / 71 / 84 |

Steps that failed: 0 (see the log).

