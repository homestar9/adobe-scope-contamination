# Results: every hotfix, and stock Update 23 against the fourth

The measurements behind the [README](../README.md). The cause is in [root-cause.md](root-cause.md),
and how the investigation got there is in [history.md](history.md). Everything was measured on one
Windows machine (24 logical cores, 32 GB, SQL Server local) with ColdBox 8.1.0, Quick 12.0.12 and
qb 13.3.1, unmodified.

"Contaminated" means a request that failed because an object built for another request was used
in it: in practice an `UPDATE` or query compiled against the other entity's table (HTTP 500,
`Invalid column name ...`). Every contamination session hit a server that had been restarted,
answered, and taken serial warm-up requests first. The startup crash under immediate load is a
separate bug ([acf-startup-npe-repro](https://github.com/homestar9/acf-startup-npe-repro)) and is
not counted here.

## Every build at a glance

| Build | What it changes | Contaminated requests, warmed | Cost on the real workload | Other effects |
|---|---|---|---|---|
| Stock Update 23 | | about 1 in 15 (6.7% to 8%) | | |
| **v1** (July 2026) | one global lock around every component construction, plus per-instance changes in four classes | 0 in 550,000 (September); 1 in 20,000 (August); 1 in 100,000 in each October run | 0.44 to 0.53 of stock | `cflock` and `cfthread` join timeouts when a constructor waits on other work (P3, P5) |
| v2 (August 2026) | `ExprAssembler` only, byte-identical to the class already in stock Update 23 | same as stock | none | none: it changes nothing on Update 23 |
| **v3** (September 2026) | one lock per component class, held together with every ancestor's lock | 5 in 900,000 (about 1 in 180,000); 6 in 200,000 in October | 0.76 to 0.82 of stock | a new permanent deadlock when two classes create each other during construction (P2, [demo](../hotfixrepro/)) |
| **v4** (October 2026) | `NeoPageContext` only: literal temporaries kept in the function's local scope, no lock | **0 in 2,900,000** | **none (0.97 to 1.15 of stock's successful requests)** | none found |
| Lucee 6.2 | | 0 in 70,000 | | no lock needed |
| BoxLang 1.17 | | 0 in 160,000 | | no lock needed |

v4's 2,900,000 are real-workload requests (`/repro/alpha` + `/repro/bravo`) over four separate
runs on fresh servers, two overnight (1,300,000 each) and two short comparisons (150,000 each).
Counting the database-free mechanism test as well, v4 served 3,580,000 requests with none
contaminated. Zero in 2,900,000 rules out any rate above about 1 in 950,000 (95% confidence).

The four Adobe jars are all named `hf202300-4232227`. Tell them apart by SHA256:

| Build | SHA256 |
|---|---|
| v1 | `7b586d55814b120fb818eab7ef16dd83336449a6088162d627f114a6cc352c56` |
| v2 | `137889d7741e1d2f1763b0698caf37b405878c7472fdc1bf14051092ffb06fc6` |
| v3 | `efb0aa56912c3c7046da47bbcc1fc28776a9f9aa1d18fbbf09cf1a3ce4780b0e` |
| **v4** | **`9d17ad33bb1d845d0303346905a2c0e8ca3fa6d4e2e087a45590c3feae4c5e81`** |

## Why the locks cost so much

v1 takes one process-wide monitor in `TemplateProxyFactory.resolveName` and holds it for the whole
construction, including the component body and every parent in its `extends` chain, so one slow
pseudo-constructor blocks every construction in the JVM. On a database-free construction test
(Update 22) it flattened at about 127 requests per second at 8, 16 and 32 connections, 72% below
the unpatched server at 32. Thread dumps under load showed on average 25.5 of 32 worker threads
blocked on that one monitor, every one of them in `resolveName`. On the real workload, where the
database takes part of each request, v1 served 0.44 to 0.53 of stock.

v3 replaced the global lock with one per class. In an ORM application that barely helps: every
Quick entity extends `BaseEntity`, so every entity construction takes the same ancestor lock, and
the query builder is built on every query. Under load the busiest lock still behaves like a
global one: 31.6 threads waiting in `resolveName` per dump, against 40.2 for v1 and 0 for stock
and v4.

## The final comparison: stock Update 23 against v4

2026-10-14. Two ColdFusion 2023 Update 23 installs that differ only by one jar: `u23` (stock) and
`localtemp-u23` (stock plus v4). Same JDK 17, same settings, same SQL Server database. Before the
run both servers proved their identity: v4 loads `NeoPageContext` from the hotfix jar and keeps the
compiler's literal temporaries function-local, while stock keeps them in the shared `variables`
scope.

The main run started right after a full reboot, with nothing else running on the machine and
Dropbox stopped. It took 37 minutes. A 16-minute repeat of the speed tests followed it with the
measurement order reversed. The same comparison had been run on a busier machine that afternoon.
The raw summaries are in [evidence/](evidence/).

### Is the contamination fixed?

Contaminated requests (HTTP 5xx) of requests sent, 20 connections per endpoint.

| Test | Stock Update 23 | Update 23 + v4 |
|---|---|---|
| Real workload: two Quick entities sharing `BaseEntity` (`/repro/alpha` + `/repro/bravo`) | 1,346 of 20,000 (6.7%) | **0 of 150,000** (two fresh server starts) |
| Mechanism alone, no database (`/repro/tempvar`) | 6,936 of 20,000 (34.7%) | **0 of 100,000** |
| Standalone demo (`hotfixrepro/scopeleak`): builds that came back with another thread's value, struct / array / `invoke()` | 1,834 / 1,753 / 1,620 of 3,200 each: FAIL | **0 / 0 / 0: PASS** |
| P8 inside the application (`/torture/p8`) | 2,014 of 4,800 crossed, 3 leaked keys | **0 of 4,800, 0 leaked keys** |

The afternoon run matched this: stock failed 8.0% of real requests and 34.6% of mechanism
requests, and v4 again failed 0 of 250,000.

### Does v4 cost speed?

Real workload, median of 3 runs of 30 s per point, the two servers alternated on every
measurement. Stock loses requests to the bug, and its error pages are quick to produce, so its raw
rate flatters it; the fair comparison counts only its successful requests. In the main run v4 was
measured first in every pair; the repeat restarted both servers and measured stock first, so that
neither the order nor one particular server process could decide the result.

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

v4 kept up with stock at every point. Measured against stock's raw rate, which includes its error
pages, the main run showed v4 6% to 8% behind; with the order reversed on fresh servers that gap
shrank to 0% to 5%, so most of it came from the order and the particular server processes, not
the hotfix. Counting only work actually done, v4 ranged from 3% slower to 11% faster, and it pulls
ahead under heavier load because none of its requests are lost to the bug. The hotfix contains no
lock, and nowhere in it could a cost build up under load. The two overnight runs agree: 0.97 to
1.15 of stock's successful requests at 8 to 64 connections.

## Lock stress tests

The tests below were built for the lock-based hotfixes (v1 and v3) and run on all four servers in
October. Only P8 and the deadlock demo remain in this repository; the rest are at tag
[`research-notes-2026-10`](https://github.com/homestar9/adobe-scope-contamination/tree/research-notes-2026-10)
(`handlers/Torture.cfc`). They matter if you are still running v1 or v3.

| Probe | What it does | stock | v1 | v3 | **v4** |
|---|---|---|---|---|---|
| P1, 7 pairs | two constructions released together, 200 ms each; serial means one waited for the other | all parallel | serial except `slowinit` | serial except `unrelated`, `slowinit`, `alias` | **all parallel** |
| P2 in one request | mutual lazy init in two `cfthread`s | completes | completes | **deadlock**, 4 threads parked | **completes** |
| P3, holder is a component | named `cflock` taken inside a pseudo-constructor while another thread constructs | ok | ok | `cflock` timeout on the same class | **ok** |
| P3, holder is plain code | the same, lock taken in request code | ok | `cflock` timeout | `cflock` timeout on the same class | **ok** |
| P4 | exceptions and `abort` from pseudo-constructors, then a clean construction | ok | ok | ok | **ok** |
| P5 | `cfthread` spawned inside a constructor and joined | ok | join timeout | join timeout on the same and sibling class | **ok** |
| P6 | `duplicate()` against concurrent construction | ok | ok | ok | **ok** |
| P7 | 64 distinct classes once each | ok | ok | ok, lock map grows by 64 | **ok** |
| **P8** | shared compiler temporary on a singleton, 32 threads x 50 builds of three literal forms | **755 crossings, 3 leaked keys** | **704, 3** | **1,830, 3** | **0, 0** |
| Deadlock demo `hotfixrepro/deadlock` | | PASS | PASS | DEADLOCK | **PASS, 105 ms** |

## Reproducing the final comparison

See [Re-run the comparison](../README.md#re-run-the-comparison) in the README. About 40 minutes;
results and `summary.md` (both tables, computed from the raw files) are written to
`benchmark-results-u23/<round>/`.
