# Technical Explanation

## What the engine appears to be doing

Under concurrent request load, ACF 2023 intermittently allows a **transient CFC's
`variables`-scoped state to be contaminated by a different concurrent instance** of a
(usually same-typed) component. Two manifestations have been observed; this repository
reproduces the underlying class of both.

Both involve **transients** — fresh instances created per request/use via WireBox
`getInstance()`, with no application-scoped or singleton sharing.

## Where the table name actually lives (and why the production workaround works)

This is the key correction to an earlier hypothesis that blamed Quick's metadata cache
(`quickMeta`). Tracing stock Quick 12 / qb 10 shows the metadata cache is **not** the
contaminated structure:

- The **entity** stores its table once at init in `variables._table`
  (`BaseEntity.metadataInspection()` reads it from CFC metadata via the `quickMeta`
  cache). `BaseEntity.tableName()` returns this value. It is per-instance and observed to
  be **clean**.
- `QuickBuilder.tableName()` delegates to `getEntity().tableName()` — it does not store
  the table itself.
- The underlying **qb `QueryBuilder`** has its own `variables.tableName` / `FROM` clause,
  set once when the query is created (`QuickBuilder.newQuery()` calls
  `.from( getEntity().tableName() )`). **This** is the value observed to be contaminated
  across concurrent requests.

The production vendor workaround is decisive proof of where the contamination is:

```cfml
// just before executing the UPDATE
variables.qb.from( getEntity().tableName() );
```

Re-reading the table from the **entity** (the clean source) repairs the **builder** (the
contaminated source). If the metadata cache itself were polluted,
`getEntity().tableName()` would also be wrong and this workaround could not work.

## Manifestation 1 — closure captured `this`

`QuickBuilder.onDIComplete()` sets a `columnFormatter` closure on the qb that captures
`this` (the `QuickBuilder`). When invoked later, under concurrency the captured `this`
can resolve to a different `QuickBuilder` instance, so `qualifyColumn()` qualifies columns
with the wrong table. (Production mitigated this by replacing the closure with a direct
object reference in `QuickQB.applyColumnFormatter()`.)

## Manifestation 2 — `variables`-scoped property

Even without the closure, the qb instance's `variables.tableName` / a `BaseEntity`'s
`variables.*` properties intermittently hold another concurrent instance's value. The
production failure (`UPDATE [user_type] ...` instead of `UPDATE [remote_app_remote_carrier] ...`)
is this manifestation.

This repository reproduces this class directly: see
[LOCAL_REPRODUCTION_RESULTS.md](LOCAL_REPRODUCTION_RESULTS.md), where concurrent transient
construction intermittently leaves a `BaseEntity`'s `variables._str` helper resolving to an
unrelated value (`Element _STR is undefined in a Java object of type class [Ljava.lang.String;`).
That is a `variables`-scoped property holding another instance's value — the same fault as
the production table-name contamination, surfaced on a different property.

The same crossing has also been observed on the entity's cached metadata, `variables._meta`.
`hasRelationship()` iterates `variables._meta.functionNames`; when `_meta` holds another
concurrent instance's value, the entity cannot see its own relationship, so `onMissingMethod`
forwards the setter to qb and ACF throws `Quick couldn't figure out what to do with
[setAlphaChildren]... Method does not exist on QueryBuilder [setAlphaChildren]`. Same root
cause again, a third victim property — which one loses the race is timing-dependent.

## Engine-level evidence — NPE inside ACF's `ObjectDuplicator`

Under the same concurrent load, the harness's full-error capture (`logs/repro_errors.txt`)
recorded an `UNCLASSIFIED` `java.lang.NullPointerException` thrown **inside ACF's own runtime**
while a transient was being constructed:

```
java.lang.NullPointerException
  at coldfusion.util.CaseInsensitiveMap$ScopeIterator$ScopeEntry.getKey(CaseInsensitiveMap.java:482)
  at coldfusion.runtime.ObjectDuplicator._duplicate(ObjectDuplicator.java:156)
  at coldfusion.runtime.ObjectDuplicator.duplicate(ObjectDuplicator.java:80)
  ...
  at cf...BaseEntity.cfc:2727  (metadataInspection -> Duplicate())
  at cf...BaseEntity.cfc:293   (onDIComplete)
```

`BaseEntity.metadataInspection()` calls CF's `Duplicate()` on the entity metadata during
`onDIComplete`. The NPE is raised by `CaseInsensitiveMap.ScopeEntry.getKey()` returning `null`
**mid-duplication** — i.e. a map entry's key vanished while ACF was iterating/copying it. A key
cannot legitimately become `null` during a single-threaded copy; this is direct evidence that
**another thread mutated the same backing map while the engine was duplicating it**. That is
the root-cause mechanism behind all three application-level signatures above: shared component
state is not being isolated per instance/thread during concurrent transient construction. It is
an engine fault surfacing in stock CF runtime classes (`ObjectDuplicator`, `CaseInsensitiveMap`),
not in Quick or application code.

## Why it is intermittent

It requires a specific interleaving of concurrent CFC construction / scope assignment.
It does not occur with single requests; it appears only under concurrent load. This is the
classic signature of a thread-safety / memory-visibility issue in the engine runtime —
e.g. missing memory fencing allowing stale or cross-thread reads of component instance
data, or compiled bytecode sharing references that should be thread-local.

## Scope of impact

Any code where, under concurrency:

- multiple CFCs are constructed concurrently (very common with per-request transients), and
- they have mutable `variables`-scoped properties, and/or
- closures capture `this` and are invoked after other concurrent requests run.
