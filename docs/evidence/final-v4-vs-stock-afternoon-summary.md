# Final comparison: stock Update 23 against Update 23 + v4

Round `final-v4-vs-stock`, generated 2026-10-14 13:21. Stock = `u23`, v4 = `localtemp-u23`. Log: `final-20261014-123622.log`.

## 1. Is the contamination fixed?

Contaminated requests (HTTP 5xx) of requests sent, 20 connections per endpoint, every session on a restarted server warmed with 500 serial requests.

| Test | Stock | v4 |
|---|---|---|
| Real workload (`/repro/alpha` + `/repro/bravo`) | 1,607 of 20,000 (8.0%), CONTAMINATION, 136 requests/s | **0 of 150,000**, CLEAN, 159, 173 requests/s |
| Mechanism alone (`/repro/tempvar`, no database) | 6,917 of 20,000 (34.6%), CONTAMINATION, 1130 requests/s | **0 of 100,000**, CLEAN, 1052 requests/s |
| Standalone demo (`hotfixrepro/scopeleak`), struct / array / invoke() | FAIL, 1655 / 1467 / 1348 of 3,200 crossed | PASS, 0 / 0 / 0 of 3,200 crossed |
| P8 inside the application (`/torture/p8`) | 543 of 4800 crossed, 3 leaked keys | 0 of 4800 crossed, 0 leaked keys |

## 2. Does v4 cost speed?

Real workload, median of 3 runs of 30s, servers alternated per measurement. Stock loses some requests to the bug and its error pages are fast, so it is also shown counting only successful requests; the pass bar is v4 at least 0.95 of that. A cell whose runs spread by more than 10% is marked *noisy*.

| Connections per endpoint | Stock, all requests | Stock failing | Stock, successful only | v4 | v4 / stock successful | v4 / stock all | p99 stock | p99 v4 | Runs stock | Runs v4 |
|---|---|---|---|---|---|---|---|---|---|---|
| 8 | 206.6 | 6.2% | 193.9 | **206.2** (0.0% failing) | **1.06** *noisy* | 1.00 | 127 ms | 115 ms | 207 / 225 / 194 | 206 / 207 / 201 |
| 16 | 212.5 | 5.2% | 200.6 | **209.1** (0.0% failing) | **1.04** *noisy* | 0.98 | 250 ms | 253 ms | 212 / 213 / 201 | 218 / 209 / 188 |
| 32 | 185.0 | 12.3% | 162.0 | **181.4** (0.0% failing) | **1.12** | 0.98 | 569 ms | 544 ms | 187 / 185 / 181 | 181 / 180 / 185 |

Quick entity + builder construction (the ORM path, no database), median of 3 runs of 20s:

| Connections | Stock | v4 | v4 / stock | Runs stock | Runs v4 |
|---|---|---|---|---|---|
| 8 | 38.5 | 38.6 | **1.00** | 39 / 39 / 39 | 38 / 39 / 39 |
| 32 | 67.6 | 72.4 | **1.07 *noisy*** | 65 / 75 / 68 | 73 / 72 / 72 |

Steps that failed: 0 (see the log).

