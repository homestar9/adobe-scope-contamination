# Scope contamination: does Adobe's v3 hotfix fix it, what does it cost, and how do Lucee and BoxLang compare

Run 2026-09-22 22:30 to 2026-09-23 05:35 on the usual test machine (24 cores, 32 GB, SQL
Server local, Dropbox stopped). Runner: `scripts/Invoke-ScopeContaminationRound.ps1`.
Raw results: `benchmark-results-u23/adobe-v3/scope-round/`.

This round is about the scope contamination bug only. The null-pointer failure on a freshly
started server is a separate engine bug. It is present in stock, v1 and v3, and Adobe's
hotfixes do not address it. It was kept out of every test here: each contamination session
restarted its test server and sent 500 single requests before any concurrent load.

## Answers

1. **Does v3 fix the scope contamination?** It reduces it from about 1 request in 15 to about
   1 in 180,000, but it does not eliminate it. 5 of 900,000 requests were contaminated on v3,
   in 4 of 9 fresh server starts, at both normal and heavy load, with the same signature as the
   unfixed engine.
2. **Does it cost performance?** Yes. On the real application v3 serves about 80% of what the
   unfixed engine serves (76% to 82% by load level), against 44% to 53% for v1. Section 3 has
   the database-free numbers, where the lock's own cost shows.
3. **Is it a final solution?** No. It still leaks, it keeps a real throughput cost that grows
   with load, and the lock stress tests of the previous round found a new permanent deadlock
   that stock and v1 do not have (`docs/adobe-hotfixes/3-third-hotfix-results.md`, section 6).
4. **Lucee and BoxLang.** Neither engine contaminated in 230,000 requests between them,
   including heavy load, and neither needs a lock for it. On this application BoxLang
   overtakes ACF v3 under heavy load (151 vs 135 requests per second at 128 in flight) but
   is slower at light load. Lucee is far slower on this application, because of one Quick
   code path. Both have a specific, identified bottleneck (section 4).

## 1. Contamination

Workload: `/repro/alpha` and `/repro/bravo` at the same time, 20 or 64 connections each. Every
request builds fresh Quick entities through WireBox and runs the production UPDATE. A
contaminated request is one whose entity ends up holding another request's object, which shows
up as an UPDATE against the wrong table or a relationship setter landing on a query builder.

| Test server | Load (connections per endpoint) | Requests | Contaminated | Rate |
|---|---|---|---|---|
| Update 21, no fix | 20 | 40,000 | 2,683 | 6.7% |
| Update 21, no fix | 64 | 20,000 | 2,487 | 12.4% |
| Stock Update 23 | 20 | 40,000 | 2,606 | 6.5% |
| **v3 (per-class locks)** | 20 | 600,000 (6 fresh starts) | **3** | 1 in 200,000 |
| **v3 (per-class locks)** | 64 | 300,000 (3 fresh starts) | **2** | 1 in 150,000 |
| v1 (global lock) | 20 | 450,000 (5 fresh starts) | 0 | |
| v1 (global lock) | 64 | 100,000 | 0 | |
| Lucee 6.2.8 | 20 and 64 | 70,000 | 0 | |
| BoxLang 1.17.5 | 20 and 64 | 160,000 | 0 | |

Every v3 leak has the production signature: `Quick couldn't figure out what to do with
[setalphaChildren] ... Method does not exist on QueryBuilder`. The entity's `variables` scope
held another instance's query builder.

What the numbers support:

- **v3 leaks.** 5 in 900,000 puts its rate between 1 in 77,000 and 1 in 554,000 (95% range).
  With the first day's 2 in 320,000 it is 7 in 1.22 million.
- **v3 vs v1 is not settled.** v1 had none in 550,000. If both leaked at v3's rate, a clean
  550,000 on v1 would still happen 9% of the time. So v1 looks at least as good as v3, but this
  sample does not prove it is better. v1 also leaked once in 20,000 in August, so neither is
  zero.
- **Lucee and BoxLang show no contamination.** Zero in 70,000 and 160,000 only rules out rates
  above about 1 in 19,000 and 1 in 43,000 by itself. The stronger evidence is structural:
  neither engine shares construction state between requests (see
  [how Lucee and BoxLang avoid it](../root-cause/how-lucee-and-boxlang-avoid-it.md)), and neither needed a lock to get here.

### Is v3's protection an accident of this workload?

v3 locks per class and per parent class. Alpha and bravo share Quick's `BaseEntity` and the
query builder chain, so on this workload their constructions serialize anyway. To test whether
contamination can cross between constructions that share no lock, this round added
`/repro/wire`: six unrelated WireBox-built components per request, each with a per-request
value in its constructor arguments and injected dependencies, checked at the end.

| Test server | Workload | Requests | Contaminated |
|---|---|---|---|
| Update 21, no fix | wire + wire | 40,000 | 0 |
| Update 21, no fix | alpha + wire | 40,000 | 225, all on the Quick side |
| Update 21, no fix | alpha + alpha | 40,000 | 574 |
| v3 | alpha + wire | 40,000 | 0 |

Unrelated construction does not contaminate even with no lock at all, and it adds nothing to
Quick's own rate. The contamination needs concurrent construction of classes that share Quick's
base classes, and v3's locks do cover that. So v3's protection is not an accident of this
workload. The residual leaks are the lock not covering every path, not unrelated classes
slipping through.

## 2. Real-application throughput

`/repro/alpha` + `/repro/bravo`, 3 runs of 30 s per point, test servers taking turns, each
restarted and warmed with 300 single requests first. Requests per second, median of three.
"In flight" is the total across both endpoints.

| In flight | Stock U23 (no fix) | v3 | v1 | BoxLang | Lucee 6 |
|---|---|---|---|---|---|
| 2 | 29 | 30 | 29 | 14 | 21 |
| 16 | 218 (6% failing) | 179 | 116 | 71 | 31 |
| 64 | 183 (10% failing) | 147 | 83 | 105 | 27 |
| 128 | 178 (12% failing) | 135 | 79 | **151** | 26 |

| In flight | v3 / stock | v1 / stock | v3 / v1 | p99 v3 | p99 v1 | p99 BoxLang | p99 Lucee |
|---|---|---|---|---|---|---|---|
| 16 | 0.82 | 0.53 | 1.54 | 108 ms | 165 ms | 292 ms | 640 ms |
| 64 | 0.80 | 0.46 | 1.76 | 521 ms | 899 ms | 1,676 ms | 2,822 ms |
| 128 | 0.76 | 0.44 | 1.72 | 1,119 ms | 2,131 ms | 3,143 ms | 5,550 ms |

Counting only the unfixed engine's successful requests, v3 is at 0.86 to 0.89 of it.

Reading:
- **v3's cost is real and grows with load:** 18% at 16 in flight, 24% at 128. Every Quick
  query constructs a query builder, and v3 serializes those constructions on one lock.
- **v1 costs about half.** v3 is 1.5 to 1.8 times faster than v1.
- **BoxLang scales with load where every ACF build flattens.** It is slower than ACF at light
  load but gains throughput as load rises, and at 128 in flight it beats v3. Its worst-case
  latency is higher than ACF's at every level.
- **Lucee is flat at about 26 to 31 requests per second** from 16 in flight up.

## 3. Database-free construction throughput

No database, 3 runs of 20 s per point. This is where a construction lock's own cost shows. Ratios
against stock Update 23 at 32 and 64 connections. The no-lock Update 21 server sat at 0.98 to
1.12 of stock throughout, which is the noise level.

| Shape | What it builds | v3 / stock | v1 / stock | Lucee / stock | BoxLang / stock |
|---|---|---|---|---|---|
| One class | the same component over and over | 0.54, 0.61 | 0.54, 0.61 | 0.52, 0.53 | 0.16, 0.18 |
| 16 unrelated classes | no shared parent | 1.01, 1.02 | 0.42, 0.44 | 0.51, 0.62 | 0.19, 0.27 |
| 16 classes sharing a parent | the ORM case | **0.25, 0.29** | 0.28, 0.36 | 0.50, 0.67 | 0.20, 0.23 |
| Quick entity + query builder | 50 per request | 0.64, 0.46 | 0.35, 0.26 | 0.08, 0.13 | 0.49, 0.52 |

Reading:
- v3 only removes the lock cost for unrelated classes. For one busy class it costs the same as
  v1, and for classes that share a parent, which covers every ORM entity, it is slower than
  v1 at both loads.
- On Quick entity construction without a database, v3 loses 36% to 54% against stock as load
  rises, while v1 loses 65% to 74%. BoxLang holds half of stock's rate here, about level with
  v3 under load. Lucee is at 8% to 13%, with requests hitting the 5-second client timeout: the
  Quick metadata copy of section 4.
- Plain construction on Lucee is about half of ACF's no-lock rate. BoxLang is slowest on plain
  construction, a fifth of ACF's rate, which fits the per-call configuration copy of section 4.

## 4. Why Lucee and BoxLang are slow on this application

Both were diagnosed with thread dumps under load.

- **Lucee.** Every Quick entity build runs `duplicate()` on its cached metadata
  (`modules/quick/models/BaseEntity.cfc:2727`). On Lucee that deep copy falls back to Java
  serialization for an object inside the metadata, and the deserializer's class lookup takes a
  JVM class-loader lock. In the dumps, most busy request threads were blocked on that lock
  (`JavaConverter$ObjectInputStreamImpl.resolveClass`). This is a Quick-on-Lucee cost on one
  line, not a Lucee limit in general. On plain construction without Quick, Lucee ran at half to
  two thirds of ACF's no-lock rate under load, and at or above it on a single connection
  (section 3). A change in Quick, such as not deep-copying the cached metadata per entity, or
  a Lucee fix would remove this bottleneck.
- **BoxLang.** 30 of 46 busy request threads were inside `structSort()`, which looks up the
  timezone on every call, and that lookup copies the whole runtime configuration
  (`LocalizationUtil.parseZoneId` then `Configuration.asStruct`). Setting the timezone
  explicitly did not avoid it. This is a BoxLang 1.17.5 engine inefficiency worth reporting to
  Ortus. It explains BoxLang's poor light-load numbers. BoxLang also re-checked every template
  on disk until this round's settings turned the trusted cache on.

Setup notes that affect fairness: all engines ran the same app, database, 1 GB heap and machine,
one at a time. The ACF servers run with template inspection off. BoxLang ran with
`-Dboxlang.trustedCache=true -Dboxlang.clearClassFilesOnStartup=true` and the shared
`.cfconfig-bench-db.json`. Lucee ran with its CFConfig defaults plus the shared settings file.
Neither Lucee nor BoxLang was tuned beyond that.

## 5. Conclusion

- **The third hotfix is not a final fix.** It leaves a rare but real contamination, costs about a
  fifth of throughput on the real application, and adds a permanent deadlock. It is faster than
  the first hotfix, but neither removes the cause.
- **A construction lock is not required to solve this.** Lucee and BoxLang ran the same
  application with no contamination and no construction lock.
