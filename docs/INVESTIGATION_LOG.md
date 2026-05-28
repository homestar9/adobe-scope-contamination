# Investigation Log

Chronological summary of how this issue was discovered and narrowed down.

1. **Production errors observed.** Intermittent `DatabaseQueryException`s under concurrent
   load — several times per day. SQL targeted the wrong table
   (`UPDATE [user_type] ...` instead of `UPDATE [remote_app_remote_carrier] ...`).

2. **First manifestation isolated (closure `this`).** Traced to Quick's `columnFormatter`
   closure (set in `QuickBuilder.onDIComplete()`) whose captured `this` resolved to the
   wrong `QuickBuilder` under concurrency, mis-qualifying columns.
   - **Workaround:** replaced the closure with a direct object reference in
     `QuickQB.applyColumnFormatter()`.

3. **Second manifestation isolated (`variables.tableName`).** After the closure fix, a
   distinct failure remained: the qb builder's `variables.tableName` itself was wrong, even
   though the WHERE clause (built at the same time) was correct — proving the builder was
   initialized correctly and only the table name was overwritten later, by a concurrent
   request using an unrelated entity.

4. **Confirmed the contaminated layer.** The **entity's** `variables._table` is clean; the
   **qb builder's** `variables.tableName`/`FROM` is the contaminated value. Verified by the
   working production workaround `variables.qb.from( getEntity().tableName() )`, which repairs
   the builder from the (clean) entity. This ruled out the earlier "metadata cache pollution"
   theory. See [BUG_EXPLANATION.md](BUG_EXPLANATION.md).

5. **Confirmed transients, not shared state.** All components involved are WireBox
   transients created per use; no singleton/application-scoped sharing.

6. **Confirmed engine-specificity.** The same code runs cleanly on Lucee.

7. **Built this minimal reproduction.** Stock ColdBox + stock (unpatched) Quick + SQL
   Server, two independent `hasMany` pairs with differently-named FK columns, exercising the
   exact production path (relationship dissociate → `updateAll()` → `UPDATE [child] SET [fk]=NULL`).

8. **Reproduced locally.** Under concurrent transient construction, an entity's
   `variables._str` intermittently resolves to an unrelated value (~4–7% of constructions) —
   the same `variables`-scope contamination class as production, on a different property.
   See [LOCAL_REPRODUCTION_RESULTS.md](LOCAL_REPRODUCTION_RESULTS.md).

## Current status

- Production is protected by defensive vendor patches (closure → direct reference;
  re-assert `from()` before `update()`/`delete()`).
- A proper engine-level resolution is preferred. This repository is provided to help Adobe
  reproduce and diagnose the root cause.
