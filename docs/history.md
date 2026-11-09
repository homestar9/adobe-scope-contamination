# How the cause was found

A condensed account of the investigation, May to October 2026. It covers what was tried, what
each attempt showed, and which theories turned out wrong. The cause itself is in
[root-cause.md](root-cause.md) and the numbers in [results.md](results.md). Every dated note,
hotfix analysis and test script from the investigation is kept, as it was, at git tag
[`research-notes-2026-10`](https://github.com/homestar9/adobe-scope-contamination/tree/research-notes-2026-10/docs).

## Timeline

| When | What happened | What it showed |
|---|---|---|
| May 2026 | Wrong-table `UPDATE`s in production under load; this reproduction built and reported to Adobe | The bug reproduces with stock ColdBox, Quick and SQL Server; the same code is clean on Lucee |
| July | Adobe's first hotfix (v1): one global construction lock | Contamination almost stops, throughput roughly halves |
| August | Adobe's second hotfix (v2) | Byte-identical to a class already in Update 23: no change |
| August | Our own builds: v1 without its lock, v1 with a per-class lock, locks around `ObjectDuplicator`, a concurrent map | Without the global lock the contamination returns at the unpatched rate; the concurrent map fixes only the separate startup crash |
| August | Instrumented engine builds that record which request owns each scope and object | The crossing is a live WireBox argument struct shared between two running requests; nine suspected mechanisms ruled out |
| August | A probe at the entrance of the engine's `invoke()` | The struct is already foreign when WireBox's `Builder.buildCFC` passes it in: the cause is above the engine's invoke path |
| September | Adobe's third hotfix (v3): one lock per class | About 1 in 180,000 still contaminated, 0.76 to 0.82 of stock's speed, and a new permanent deadlock |
| October | Adobe's fourth hotfix (v4): one method in `NeoPageContext` | Names and removes the shared slot. 0 in 2,900,000, no lock, no cost |

## The production incident

The bug was first seen on ColdFusion 2023 Update 18 on Windows Server and IIS, running ColdBox 8
with Quick 12 against SQL Server: a few failed queries a day, only under concurrent load. The same
application ran cleanly on Lucee.

It showed up in two ways. First, Quick's column-formatter closure on a query builder qualified
columns with another entity's table name. After that was worked around in the application, a
second form remained: an `UPDATE` ran against the wrong table. The `WHERE` clause was correct for
the intended entity; only the table name belonged to an unrelated entity used by a different
concurrent request. The wrong table had no such column, so SQL Server rejected the statement:

```text
coldfusion.tagext.sql.QueryTag$DatabaseQueryException: Error Executing Database Query.
  at cfBaseGrammar2ecfc$funcRUNQUERY.runFunction(BaseGrammar.cfc:128)
  at cfQueryBuilder2ecfc$funcRUNQUERY.runFunction(QueryBuilder.cfc:4332)
  at cfQueryBuilder2ecfc$funcUPDATE.runFunction(QueryBuilder.cfc:3404)
  at cfQuickQB2ecfc$funcUPDATE.runFunction(QuickQB.cfc:314)
  at cfQuickBuilder2ecfc$funcUPDATEALL.runFunction(QuickBuilder.cfc:441)
  at cfHasOneOrMany2ecfc$funcAPPLYSETTER.runFunction(HasOneOrMany.cfc:273)
  at cfBaseEntity2ecfc$funcTRYRELATIONSHIPSETTER.runFunction(BaseEntity.cfc:2550)
  at cfBaseEntity2ecfc$funcONMISSINGMETHOD.runFunction(BaseEntity.cfc:2392)
```

That is a `hasMany` relationship setter dissociating children: `applySetter()` → `updateAll()` →
`UPDATE [child] SET [fk] = NULL`. Both forms fit the cause found in October: Quick's relationship
was handed another request's entity, so everything built from it carried that entity's table.

## The reproduction

`/repro/alpha` and `/repro/bravo` run that same relationship path on two independent parent/child
pairs whose foreign-key columns have different names (`alpha_parent_id`, `bravo_parent_id`). A
contaminated `UPDATE` therefore names a column the target table does not have, and SQL Server
raises `Invalid column name ...` instead of silently updating the wrong rows.
`interceptors/ContaminationDetector.cfc` catches the mismatch at qb's `preQBExecute`, before the
database sees it.

Under concurrent load this contaminates several percent of requests on Updates 19 to 23. More
concurrency does not mean more hits: the endpoints write and contend on the same rows, and past
ColdFusion's limit on simultaneous requests the extra requests only queue. Twenty connections per
endpoint was the best rate. A single, non-concurrent request never triggers it.

## August: measuring instead of guessing

v1 stopped the contamination but halved throughput, so the first question was which part of it
did the work. We rebuilt v1 without its global lock, keeping its per-instance changes. Without
the lock, contamination returned at the unpatched rate (913 of 20,000 requests warm, against 873
on an unpatched Update 21). A per-class lock cut it about tenfold but did not stop it, and
narrower locks around `ObjectDuplicator` failed too. The global lock was doing all the work, and
even v1 let one request in 20,000 through.

Reading bytecode had produced several plausible theories, so the next step was to measure a
running server. Instrumented engine builds recorded, for every scope and component created during
a construction, which in-flight request made it, then flagged any later use by a different
in-flight request. Three rules kept this honest:

- Every match was checked by object identity, not by hash code (19,879 false matches rejected in
  one run).
- Entries were dropped when their request finished, so only requests that were still running
  could match.
- Every measure was tallied separately for requests that failed and requests that succeeded. A
  measure much larger on failures is a candidate cause; one that matches is background.

The control was Adobe's v1 with its lock on (0 failures) against the same classes with the lock
removed (594 failures in 8,000 requests). One measure tracked the failures and nothing else:

| Measure | Per succeeded request | Per failed request | Ratio |
|---|---|---|---|
| **A method called on a component another, still-running request built (another entity)** | **0.0** | **7.0** | **2,497x** |
| The same, same entity | 0.9 | 1.1 | 1.16x |
| Reads of the shared super-scope field | 37.3 | 28.5 | 0.76x |
| Component constructions | 72.0 | 47.2 | 0.66x |

Follow-up rounds narrowed it to a live entity arriving as a function argument
(`HasOneOrMany.init[related]`, `QuickBuilder.setEntity[newEntity]`), carried by the WireBox
argument struct itself, with both requests still running (4,007 times while the creating request
was running, 0 after it finished). Everything else suspected was measured and cleared:

| Candidate | Verdict | Evidence |
|---|---|---|
| The shared `UDFMethod.superScope` field | not it | more common on the zero-failure locked build |
| The page context's current-variables-scope pointer | not it | 0 mismatches in 56.4 million invocations |
| Component resolution (`resolveName`) | not it | 0 foreign in 591,806 returns |
| Function local / arguments scope identity | not it | 0 foreign in 162 million reads |
| Scope objects being recycled | not it | 0 |
| Any persistent container (metadata, caches, application or server scope, WireBox) | not it | 0 reachable from any root |
| A shared page context at the symptom | not it | 0 same, 7,347 different |
| The metadata duplication source | not it | 0 foreign in 11,915 copies |
| `FusionContext` | not it | thread-local (decompiled) |

The last probe of the round sat at the entrance of the `invoke()` built-in function and at the
deepest engine frame of the same call, on the same thread. 4,071 argument structs were already
another request's when they entered `invoke()`; 0 turned foreign inside the engine's dispatch.
Every one was on an `init` call from `coldbox/system/ioc/Builder.cfc:273`, in `buildCFC`; 6 of 9
sampled were empty `{}`. The struct was created clean and nothing persistent held it, so the only
shape left was a transient write to a shared slot during a method call on the WireBox Builder
singleton. The August notes ended there: the slot could not be named without Adobe's source or a
far more invasive probe.

## September: the third hotfix

v3 replaced the global lock with one lock per class, held together with every ancestor's lock. It
cut contamination to about 1 in 180,000 but did not stop it. In an ORM application every entity
shares the `BaseEntity` ancestor, so the busiest lock still acted like a global one and cost 18%
to 24% of throughput. And two classes that create each other during construction could now wait on
each other forever ([deadlock demo](../hotfixrepro/)).

## October: the fourth hotfix names the slot

v4 changed one method: the compiler's temporary for a struct or array literal written inside a
conditional expression now lives in the function's local scope instead of the component's
`variables` scope. WireBox's `buildCFC` line 273 builds its argument struct exactly that way
(`constructorArgs.len() ? buildArgumentCollection( ... ) : {}`), on a singleton, for every
request. That was the shared slot the August probes had pinned without being able to name, and
the six empty `{}` were its `: {}` branch. The standalone
[`hotfixrepro/scopeleak`](../hotfixrepro/) page now shows the leak on every earlier build and not
on v4, with no framework at all.

## Theories that turned out wrong

- **A race in `ObjectDuplicator` or in Quick's metadata cache.** That is the separate startup
  crash, a corrupted `CaseInsensitiveMap` on a freshly started server
  ([acf-startup-npe-repro](https://github.com/homestar9/acf-startup-npe-repro)). It was mixed up
  with the contamination for weeks, because both appear under the same load.
- **Only transients are involved, nothing shared.** The query builders and entities are
  transients, but the object that leaks is built by a singleton.
- **v1's per-instance changes are the real fix and its lock is redundant.** Removing the lock
  brought the contamination straight back.
- **The global lock is the fix.** It only shortened the window; v1 still leaked about 1 in 20,000
  to 1 in 100,000.
- **The shared `UDFMethod.superScope` field.** It crosses between requests more often on the
  build with zero failures.
- **The engine's invoke path swaps the argument struct.** 0 swaps in dispatch; the struct was
  already foreign on the way in.
- **A fix needs Adobe's source or the lock.** The fix needed neither a lock nor a change to the
  construction model, only one compiler temporary moved to the right scope.

## Lessons

- **Test with the real workload.** A database-free construction test passed engines that failed
  every real request. Only the ORM path, with real `UPDATE`s, decided correctness.
- **Warm up before every burst.** A freshly started server under immediate concurrent load hits
  the separate startup crash and then fails every request, which hides the contamination. Every
  session restarted its server, waited for it to answer and sent serial requests first.
- **Speed numbers from one sweep are not enough.** Database-free construction throughput moved by
  30% to 40% between sweeps on the same server with no hotfix. Alternate the servers on every
  measurement and repeat with the order reversed.
- **Application-side guards could not catch it.** Checks in Quick that a builder's table matches
  its entity caught 0 of about 600 wrong-table statements per run: the crossed objects are
  consistent with each other, because the whole entity belongs to the other request. (A serial
  warm-up of Quick's metadata at startup did keep the separate startup crash away, in the two
  fresh starts tested.)
- **Measure, then theorize.** Each theory built from reading bytecode looked convincing. Per-request
  counts on a running server, split by failed and succeeded requests, settled each one in an
  afternoon.
