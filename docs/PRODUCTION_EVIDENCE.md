# Production Evidence

Forensic data from the production system where this bug was first observed.

## Environment

| | |
|---|---|
| ColdFusion Engine | Adobe ColdFusion 2023, Update 18 (Build 330879) |
| OS | Windows Server 2022 |
| Web Server | IIS |
| JVM | Default ACF 2023 JVM |
| Framework | ColdBox 8.x with Quick ORM 12.x (qb 10.x) |
| Database | Microsoft SQL Server |
| Monitoring | FusionReactor |
| Load | ~50–100 concurrent users |
| Frequency | Several times per day, only under concurrent load |

## Symptom

A CFC component's `variables`-scoped property intermittently contains a value that
belongs to a *different* component instance being used by a concurrent request.
Specifically, `variables.tableName` on a Quick query builder (a transient, created
fresh per use via WireBox `getInstance()`) intermittently contains a table name from
an unrelated entity's query builder.

## Incident 1 — Closure captured-scope contamination

Quick assigns a `columnFormatter` closure to each query builder during init:

```cfml
// QuickBuilder.onDIComplete()
variables.qb.setColumnFormatter( function( column ) {
    return qualifyColumn( column );
} );
```

Each `QuickBuilder` has its own `qualifyColumn()` that prefixes columns with the correct
table name. Under concurrent requests, the closure's captured `this` resolved to the
**wrong** `QuickBuilder` instance, so columns were qualified with another entity's table
(e.g. a query against `remote_app_remote_carrier` had columns prefixed `user_type.`).

## Incident 2 — Table-name property contamination

After mitigating Incident 1, a second, distinct manifestation appeared — this time the
`variables.tableName` property on the query builder itself.

**Generated SQL (wrong):**

```sql
UPDATE [user_type] SET [remoteAppId] = NULL
WHERE ([remoteAppId] = 168200 AND [remoteAppId] IS NOT NULL)
```

**Expected SQL:**

```sql
UPDATE [remote_app_remote_carrier] SET [remoteAppId] = NULL
WHERE ([remoteAppId] = 168200 AND [remoteAppId] IS NOT NULL)
```

### Key observations

- `user_type` has **no** `remoteAppId` column — this is what caused the database error.
  `remoteAppId` belongs to `remote_app_remote_carrier`.
- The **WHERE clause is correct** for `remote_app_remote_carrier`. The builder was
  initialized correctly; only `variables.tableName` was overwritten between
  initialization and execution.
- `user_type` comes from a completely unrelated entity (`UserType.cfc`) accessed by a
  **different concurrent request**.
- The builder is a **transient** — a fresh instance per use via `getInstance()`. It is
  not a singleton and is not shared across requests.
- The error is **intermittent** and only occurs under concurrent load.

### Stack trace

```
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

This is the path reproduced by `/repro/alpha` and `/repro/bravo` in this repository:
a `hasMany` relationship setter (dissociate) → `applySetter()` → `updateAll()` →
`UPDATE [child] SET [fk] = NULL`.

## Same code on Lucee

The same application code runs without these issues on Lucee Server, where Quick is also
widely used — pointing to an ACF-specific runtime issue rather than application logic.
