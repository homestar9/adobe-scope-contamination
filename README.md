# Adobe Metadata Or Variables Scope Corruption

## Environment

ColdFusion Engine: Adobe ColdFusion 2023, Update 18 (Build 330879)
OS: Windows Server 2022
Web Server: IIS
JVM: Default ACF 2023 JVM
Framework: ColdBox 8.x with Quick ORM 12.x
Monitoring: FusionReactor

## The Problem

We are observing intermittent errors in production where a CFC component's variables-scoped property contains a value that belongs to a completely different component instance being used by a concurrent request. Specifically, the variables.tableName property on a query builder component (a transient, created fresh per use) intermittently contains a table name from a different entity's query builder.

## Evidence — Incident 1: Column Formatter Closure Contamination

Our ORM framework (Quick) assigns a columnFormatter closure to each query builder instance during initialization:

// QuickBuilder.onDIComplete()
variables.qb.setColumnFormatter( function( column ) {
    return qualifyColumn( column );
} );

Each QuickBuilder instance has its own qualifyColumn() method that prefixes columns with the correct table name. Under concurrent requests, we observed that the closure's captured this reference was resolving to the wrong QuickBuilder instance, causing columns to be qualified with incorrect table names. For example, a query targeting the remote_app_remote_carrier table would have its columns prefixed with user_type. instead.

We mitigated this by overriding the method to avoid the closure entirely and instead use a direct object reference:

public any function applyColumnFormatter( required any column ) {
    if ( !isSimpleValue( arguments.column ) ) {
        return arguments.column;
    }
    if ( !isNull( getQuickBuilder() ) ) {
        return getQuickBuilder().qualifyColumn( arguments.column );
    }
    return variables.columnFormatter( arguments.column );
}

## Evidence — Incident 2: Table Name Property Contamination

After applying the above mitigation, we observed a second, distinct manifestation of the same underlying issue. This time, it is not a closure's captured scope that's wrong — it is the variables.tableName property on the query builder component itself.

The generated SQL was:

```
UPDATE [user_type] SET [remoteAppId] = NULL
WHERE ([remoteAppId] = 168200 AND [remoteAppId] IS NOT NULL)
```

What the SQL should have been:

```
UPDATE [remote_app_remote_carrier] SET [remoteAppId] = NULL
WHERE ([remoteAppId] = 168200 AND [remoteAppId] IS NOT NULL)
```

### Key observations:

The user_type table does not have a remoteAppId column. This is what caused the database error. The column remoteAppId belongs to the remote_app_remote_carrier table.

The WHERE clause is correct for remote_app_remote_carrier. This means the query builder was initialized correctly — the constraints were applied against the right table and column. Only the variables.tableName property was overwritten sometime between initialization and query execution.

The user_type table name comes from a completely unrelated entity (UserType.cfc) that was being accessed by a different concurrent request.

The query builder is a transient — a new instance is created for each use via WireBox's getInstance(). It is not a singleton and should not be shared across requests.

The error is intermittent — it occurs only under concurrent load, typically a few times per day in production. It is not reproducible with a single request.

### Stack Trace

coldfusion.tagext.sql.QueryTag$DatabaseQueryException: Error Executing Database Query.
  at cfBaseGrammar2ecfc$funcRUNQUERY.runFunction(BaseGrammar.cfc:128)
  at cfQueryBuilder2ecfc$funcRUNQUERY.runFunction(QueryBuilder.cfc:4332)
  at cfQueryBuilder2ecfc$funcUPDATE.runFunction(QueryBuilder.cfc:3404)
  at cfQuickQB2ecfc$funcUPDATE.runFunction(QuickQB.cfc:314)
  at cfQuickBuilder2ecfc$funcUPDATEALL.runFunction(QuickBuilder.cfc:441)
  at cfHasOneOrMany2ecfc$funcAPPLYSETTER.runFunction(HasOneOrMany.cfc:273)
  at cfBaseEntity2ecfc$funcTRYRELATIONSHIPSETTER.runFunction(BaseEntity.cfc:2550)
  at cfBaseEntity2ecfc$funcONMISSINGMETHOD.runFunction(BaseEntity.cfc:2392)

## Why I Believe This Is an Engine Bug

All components involved are transients, created fresh per request/use via a dependency injection framework (WireBox). There is no application-scoped or singleton sharing of these instances.

The contamination crosses component instance boundaries. A variables.tableName property on one CFC instance contains a value that was set on a completely different CFC instance in a concurrent request.

Two distinct contamination vectors have been observed on the same engine version:

Closure captured scope (this) resolving to the wrong component instance
Component variables-scoped property containing a value from a different instance

Both issues are intermittent and only manifest under concurrent request load — the classic signature of a thread-safety / memory model issue in the engine's runtime.

The same application code runs without these issues on Lucee Server, where the ORM framework (Quick) is also widely used. This points to an ACF-specific runtime issue rather than an application logic bug.

The behavior is consistent with improper JVM memory fencing — the CFML engine may be allowing stale or cross-thread reads of component instance data, or the compiled Java bytecode for CFC instances may be sharing references that should be thread-local.

## Our Workarounds

We have applied defensive vendor patches to the ORM framework to re-assert correct state immediately before query execution:

Closure contamination: Replaced closure-based column formatting with a direct object reference
Table name contamination: Added variables.qb.from( getEntity().tableName() ) calls immediately before update() and delete() execution to re-assert the correct table name from the entity's metadata (which is set during entity init from CFC annotations and appears immune to contamination)

Even though these workarounds appear to be working, we would prefer a proper engine-level resolution.

## Request

Can you please investigate whether ACF 2023 has a known thread-safety issue with CFC variables scope or closure captured scope under concurrent requests?

Is there an existing hotfix or update that addresses this class of issue?

If this is a new finding, can we open a formal bug report to track a fix? ACF 2023 is currently a supported product and we are a paying customer relying on it in production.

Can you provide any guidance on JVM flags, garbage collector settings, or other configuration that might reduce the frequency of this issue while awaiting a proper fix?

I'm happy to provide additional details, FusionReactor captures, thread dumps, or heap dumps if that would help your investigation.
