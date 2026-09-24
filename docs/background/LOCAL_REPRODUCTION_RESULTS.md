# Local Reproduction Results

These are results observed while building this repository, on the author's machine.
They are provided so Adobe knows what to expect and what "success" looks like.

## Environment used

- Adobe ColdFusion **2023.0.19** (CommandBox-managed engine, build 330899)
- Windows 11
- Microsoft SQL Server (datasource `adobe-temp`)
- Stock, **unpatched** Quick 12 / qb 10 from ForgeBox (no vendor patches applied)

## Single-threaded sanity (no contamination — expected)

`GET /repro/alpha` and `GET /repro/bravo` each return `ok:true` with `childCount:3` and
execute the correct SQL (`UPDATE [alpha_child] SET [alpha_parent_id] = NULL ...` /
`UPDATE [bravo_child] SET [bravo_parent_id] = NULL ...`). `GET /repro/status` reports
`contaminations: 0`.

## Concurrent HTTP requests — the production symptom reproduced

The canonical test: drive ordinary concurrent HTTP requests (no `cfthread`) against both
endpoints at once. Example using `curl` + `xargs` (Git Bash on Windows):

```
seq 1 600 | awk '{ if ($1%2==0) print "http://127.0.0.1:60830/repro/alpha";
                    else        print "http://127.0.0.1:60830/repro/bravo" }' \
  | xargs -P 80 -n 1 curl -s -o /dev/null
```

**Result: reproduced the exact production manifestation — `TABLE_NAME_CONTAMINATION`.** In one
600-request burst (80-way parallel), 10 requests returned HTTP 500 and 6 were logged as
table-name contamination (~1%). Every event is the production signature: a request operating
on one entity emitting an `UPDATE` whose **table** was overwritten by a concurrent request's
builder, while still SETting the original entity's FK column:

```
[TABLE_NAME_CONTAMINATION] context=alpha_child  thread=XNIO-1 task-7
   Invalid column name 'alpha_parent_id'.     (UPDATE was retargeted to bravo_child)
[TABLE_NAME_CONTAMINATION] context=bravo_child  thread=XNIO-1 task-78
   Invalid column name 'bravo_parent_id'.     (UPDATE was retargeted to alpha_child)
```

Each occurs on a distinct request thread (`XNIO-1 task-N`), each its own HTTP request building
fresh WireBox transients — i.e. the `variables.tableName` on a transient query builder was
contaminated by a concurrent request. This is identical in shape to the production failure
(`UPDATE [user_type] SET [remoteAppId] ...`, where `user_type` lacks `remoteAppId`).

The same result reproduces with **bombardier** at a calibrated load — two terminals, one per
endpoint:

```
bombardier -c 20 -n 3000 -t 30s "http://127.0.0.1:60830/repro/alpha"
bombardier -c 20 -n 3000 -t 30s "http://127.0.0.1:60830/repro/bravo"
```

A single 3000-request alpha run returned **2956 `2xx` / 44 `5xx` (~1.5%)**, and
`contamination_log.txt` captured 30+ interceptor `CONTAMINATION #N` lines with the cross-wired
SQL (e.g. `UPDATE [alpha_child] SET [bravo_parent_id] = ? ...`), the matching
`TABLE_NAME_CONTAMINATION` SQL errors, and `VARIABLES_SCOPE_CORRUPTION` events — all three
signatures in one run.

Rate is hardware- and load-dependent, but note: with these **write-contended** endpoints,
*more* concurrency does not mean more events. Past roughly ACF's max-simultaneous-request
limit (~25), extra connections only saturate the request queue, the DB connection pool, and
the OS socket table — requests time out and the effective hit rate drops to zero (and sustained
abuse can crash the servlet deployment). `-c 20` per endpoint is the sweet spot; step to
`-c 30–40` only while `2xx` still dominates the histogram.

## Concurrent `cfthread` stress (variables-scope corruption reproduced)

Using the built-in in-process stress mode:

```
GET /repro/stress?entity=alpha&iterations=150
```

**Result: reliably reproduced an intermittent `variables`-scope corruption**, at roughly
**4–7%** of concurrent transient constructions across repeated runs:

| Run | iterations | thread errors |
|-----|-----------|---------------|
| 1   | 50        | 6             |
| 2   | 100       | 6             |
| 3   | 100       | 5             |
| 4   | 100       | 7             |
| 5   | 150       | 11            |
| 6   | 150       | 7             |

Every failure had the **same signature**:

```
Element _STR is undefined in a Java object of type class [Ljava.lang.String;.
```

### What this means

`_str` is `BaseEntity.variables._str` — Quick's injected string-helper component. During
**concurrent transient construction** (`getInstance()` per thread), an entity's
`variables._str` intermittently resolves to an **unrelated value** (a `java.lang.String[]`
belonging elsewhere) instead of the str helper. Quick then calls `variables._str.startsWith(...)`
in `tryRelationshipSetter()` and ACF throws.

This is precisely the production fault class: a transient CFC's `variables`-scoped property
holding another concurrent instance's value. In production it surfaced on the query
builder's `tableName`; here it surfaces on the entity's `_str` helper. Same root cause,
different victim property.

The events are persisted to `logs/contamination_log.txt`, tagged
`VARIABLES_SCOPE_CORRUPTION`, e.g.:

```
VARIABLES_SCOPE_CORRUPTION {"type":"VARIABLES_SCOPE_CORRUPTION","context":"stress(alpha)",
"message":"Element _STR is undefined in a Java object of type class [Ljava.lang.String;.",
"thread":"...","detectedAt":"..."}
```

### A second face of the same corruption — relationship lookup fails

The same stress mode also intermittently produces a different message for the same root cause:

```
Quick couldn't figure out what to do with [setAlphaChildren]. The error returned was:
Method does not exist on QueryBuilder [setAlphaChildren] ...
```

Here `variables._str` survived but the entity's cached metadata did not. `hasRelationship()`
iterates `variables._meta.functionNames` (`BaseEntity.cfc`); when that transient's `_meta`
holds another concurrent instance's value, the entity cannot see its own `alphaChildren`
relationship, so `onMissingMethod` falls through and forwards the setter to qb — which has no
`setAlphaChildren` and throws. Same defect (a `variables`-scoped property holding another
instance's value), different victim property (`_meta` instead of `_str`). Which property loses
the race is timing-dependent.

These are also tagged `VARIABLES_SCOPE_CORRUPTION` in `logs/contamination_log.txt`.

> **Reading the counters:** `/repro/status` and the stress JSON `contaminations` field counts
> only `TABLE_NAME_CONTAMINATION` (caught at qb's `preQBExecute`). Both `VARIABLES_SCOPE_CORRUPTION`
> faces above fail *before* any SQL is generated, so they show up in `threadErrors` and in the
> log file, not in `contaminations` — a run can show `threadErrors: 9, contaminations: 0` and
> still be a positive reproduction.

## Notes / caveats

- **Both** manifestations reproduce locally on stock Quick + ACF 2023:
  `TABLE_NAME_CONTAMINATION` under concurrent HTTP requests (the production symptom) and
  `VARIABLES_SCOPE_CORRUPTION` under `cfthread` stress. They are the same underlying defect —
  a transient CFC's `variables`-scoped state holding another concurrent instance's value;
  which property gets contaminated first is timing-dependent.
- Reproduction rate is hardware- and load-dependent. More cores and higher concurrency
  raise the rate. A machine that serializes work heavily may show a lower rate or none.
- Restarting the server clears state; the issue reappears under load.

## How to confirm patches are absent (stock behavior)

`modules/quick/models/QuickBuilder.cfc` → `updateAll()` calls `variables.qb.update(...)`
directly and contains **no** `variables.qb.from( getEntity().tableName() )` reassertion.
That reassertion is the production workaround and is intentionally **not** present here, so
the raw engine behavior is observable.
