# Static analysis of Adobe's fourth hotfix jar (`hf202300-4232227-adobe-v4.jar`)

What Adobe changed, read straight out of the bytecode, before running any test. Written
2026-10-13, the day the jar arrived, so that the predictions at the end are on record before the
first measurement.

## Provenance

| | |
|---|---|
| File | `hotfixes/hf202300-4232227-adobe-v4.jar` (Adobe's "PatchVersion4" OneDrive folder) |
| SHA256 | `9d17ad33bb1d845d0303346905a2c0e8ca3fa6d4e2e087a45590c3feae4c5e81` |
| Size | 24,210 bytes, 14 entries |
| Manifest | 59 bytes, `Created-By: 21.0.12.1 (Homebrew)` |
| Class file version | 52 (Java 8 target), same as stock Update 23, compiled with a JDK 21 compiler |
| Adobe's description | "updated patch without any locks, it was verified on repro machine also with 9000 concurrent requests" |

Contents: `coldfusion/runtime/NeoPageContext.class` (38,376 bytes) and its nine inner classes
(`$InvalidArrayDimensionException`, `$InvalidArrayIndexException`, `$InvalidArraySymbolException`,
`$InvalidArrayTypeException`, `$InvalidArrayVariableException`, `$InvalidVariableNameException`,
`$SymTab_ScopeInArray`, `$TagSet`, `$UndefinedLiteralException`). Nothing else.

**No `TemplateProxyFactory`.** The jar replaces neither the first hotfix's global construction
lock nor the third hotfix's per-class locks; with this jar deployed, `TemplateProxyFactory`,
`TemplateProxy`, `UDFMethod` and `Closure` are the stock Update 23 classes. There is no lock of
any kind in the change.

## How this was produced

| Version | Where the class comes from |
|---|---|
| v4 | `hotfixes/hf202300-4232227-adobe-v4.jar` |
| Stock Update 23 | `.engine/bench-u23/WEB-INF/cfusion/lib/updates/chf20230023.jar` |
| Stock Update 25, for the engine-version question | `chf20230025.jar` from a ColdFusion 2023 Update 25 install on the same machine |

Disassembled with `javap -p -c` from JDK 17 and decompiled with CFR 0.152 (`tools/cfr.jar`,
`--extraclasspath` pointing at the Update 23 `cfusion.jar`). The comparison is a **normalized
bytecode diff**: constant-pool indices, bytecode offsets, branch targets and run-length
whitespace stripped. The v4 class was compiled by a newer compiler than Adobe's build, which
changes `ldc` to `ldc_w` for some constants and emits `invokeinterface` instead of
`invokevirtual` for `getClass()` on interface-typed receivers; those lines are compiler noise and
were confirmed to be the only other differences.

## Headline finding

**One method changed. Compiler temporaries for inline struct and array literals are now stored
in the running function's local scope instead of the component's `variables` scope.**

### The diff against stock Update 23

The nine inner classes are identical apart from the compiler noise above. The main class
differs in exactly one method, `SymTab_setValidatedSimpleName(String, Object, boolean)`, which is
the path an assignment to an unscoped simple name takes while a function is running. CFR output,
stock first:

```java
private void SymTab_setValidatedSimpleName(String name, Object value, boolean checkLocal) {
    Key key = Key.getInstance(name);
    if (!checkLocal || !this.SymTab_setValidSimpleFunctionLocalVariable(name, value)) {
        this.SymTab_varScope.putInternal(key, value);          // the component's variables scope
    }
}
```

v4:

```java
private void SymTab_setValidatedSimpleName(String name, Object value, boolean checkLocal) {
    Key key = Key.getInstance(name);
    if (!checkLocal || !this.SymTab_setValidSimpleFunctionLocalVariable(name, value)) {
        LocalScope localScope;
        if (name.startsWith("___IMPLICITARRYSTRUCTVAR")
                && (localScope = this.getActiveFunctionLocalScope()) != null) {
            localScope.putInternal(key, value);                 // NEW: the function's local scope
            return;
        }
        this.SymTab_varScope.putInternal(key, value);          // unchanged
    }
}
```

`SymTab_setValidSimpleFunctionLocalVariable` (unchanged) only claims a name for the local scope
when the local scope has already **declared** it (`var x`), or it is a `cfthread` local, or it
is an argument. Otherwise an unscoped assignment inside a function lands in `variables`. That is
ColdFusion's documented behaviour for a variable the programmer forgot to `var`.

`___IMPLICITARRYSTRUCTVAR<n>` is the name the ColdFusion compiler gives the temporary it creates
for an inline literal, `{ ... }` or `[ ... ]`. For a literal in a plain statement the compiler
declares that temporary as a local and nothing leaks. For a literal inside a **conditional
expression**, `cond ? { ... } : { ... }` or `x ?: { ... }`, it does not (measured with
`hotfixrepro/scopeleak/shapes.cfm` on 2026-10-13: of 33 code shapes, exactly the nine with a
literal inside a `?:` or `?:` expression leak, every other shape, including literals in
closures, loops, `invoke()` arguments and `structAppend`, does not). So on every build before v4
that temporary took the "forgot to var" path and was written into the component's `variables`
scope: the compiler itself has been committing the classic un-`var`ed variable bug on behalf of
every function that builds a literal inside a ternary.

### Why that is the contamination

In a transient the stray key is harmless: the `variables` scope belongs to one instance. In a
**singleton** the `variables` scope is shared by every request. Building a literal is not
atomic: the compiled code creates the struct, stores it in the temporary, evaluates each value,
reads the temporary back to set each key, and reads it back once more to use the result. Two
requests running the same function on the same singleton at the same time share that one slot.
Request A stores its new struct in the slot, request B overwrites the slot with its own struct,
and A reads the slot back and continues filling, and finally returns, B's struct. The longer the
value expressions take, the wider the window.

This is exactly what the August measurement found and could not name. The last probe of that
round (`docs/research-log/2026-08-24-invoke-path-probe.md`) showed the crossing object is the
`constructorArgCollection` struct in WireBox's `Builder.buildCFC`, built in a method of the
WireBox Builder **singleton** and passed to `invoke( oModel, "init", ... )`; the struct "is
already another request's the instant it enters the engine", it was "created clean" by
`StructNew`, nothing persistent held it, and the only shape that fit was "a write that landed in
the wrong place during concurrent execution of a method on a shared singleton". The line is
(`coldbox/system/ioc/Builder.cfc`, ColdBox 8.1.0):

```cfml
var constructorArgCollection = constructorArgs.len() ? buildArgumentCollection( ... ) : {};
```

A literal inside a ternary: the leaking shape. The slot is `___IMPLICITARRYSTRUCTVAR<n>` in the
Builder's `variables` scope, and the "6 empty `{}` structs" the August probe captured are that
`: {}` branch. Quick's relationship setup then receives another request's `related` entity through
that struct, and the `UPDATE` compiles with the wrong table.

It also explains the earlier results:

- Adobe's locks reduced the rate without removing it. The construction lock serializes the
  `createObject` inside `buildCFC`, which shortens the window in which two `buildCFC` calls
  overlap, but the literal is built before and after the locked region.
- Unrelated classes (`/repro/wire`) never crossed: every one of its six probes passes
  `initArguments`, so `constructorArgs.len()` is never zero and the `: {}` branch is never the
  struct that is used; the Quick entities are built with no constructor arguments and take the
  leaking branch on every build.
- Lucee and BoxLang do not have the bug: neither compiles literals through a temporary that can
  land in a shared scope.

### What v4 does not change

- The separate startup crash (a `CaseInsensitiveMap` tear in `ObjectDuplicator` when a freshly
  started server gets concurrent load; `docs/root-cause/contamination-investigation-and-startup-crash-fix.md`).
  Nothing in this jar touches those classes. That crash is being filed with Adobe as its own
  issue and is kept out of this round: every contamination session here warms the server first.
- Any construction lock. There is none, so the deadlock of the third hotfix and the throughput
  cost of the first and third cannot occur.
- The pseudo-constructor path. With no function running, `getActiveFunctionLocalScope()` is
  null and a literal in a pseudo-constructor still goes to `variables`, which is correct there:
  that scope belongs to the instance being built.

### Engine version

`NeoPageContext` is byte-identical in Update 23 and Update 25 (normalized diff: zero lines), so
this patch applies the same to both and the Update 23 test servers used for the first three
hotfixes are the right base. Adobe did not name an update level; none is needed.

### Things worth a look

- `putInternal` on the local scope bypasses the declared-key bookkeeping that `put` keeps.
  Whether a temporary stored this way is visible to `local` enumeration or to `localmode`
  checks is a runtime question; `/benchmark/engine` reports where the temporaries land.
- `cfthread` bodies: inside a thread the active function local scope is the thread's own, so
  the temporary stays per thread. The lock stress tests run literals inside threads throughout.
- Code that (accidentally) relied on a literal's temporary surviving in `variables` between calls
  would change behaviour. That would be code reading a key named `___IMPLICITARRYSTRUCTVAR`,
  which nothing sensible does.

## Predictions, written before the first run

| Measurement | Predicted for v4 |
|---|---|
| Temp-variable probe (`/torture/p8`, `/repro/tempvar`, `hotfixrepro/scopeleak`), literals inside conditional expressions | stock, v1 and v3: `___IMPLICITARRYSTRUCTVAR` keys in the singleton's `variables`, and threads get back each other's values; v4: neither |
| Warmed contamination test, `/repro/alpha` + `/repro/bravo`, 20 and 64 connections | 0 contaminated requests in at least 1,000,000 (v3: 5 in 900,000; v1: 0 in 550,000 but 1 in 20,000 in August) |
| `alpha + wire` | clean, as before |
| Lock evidence under `/repro` load | 0 threads waiting in `resolveName` per dump, like stock (v3: 31.6, v1: 40.2) |
| Lock stress tests P1 to P7 | identical to stock: every P1 pair parallel, P2 completes, no `cflock` interlock, P5 joins |
| Deadlock demo `hotfixrepro/deadlock` | PASS |
| Real-workload throughput at 8 to 64 in flight | within noise of stock Update 23 counting only its successful requests (pass bar: within 5%); v3 was 0.76 to 0.82, v1 0.44 to 0.53 |
| Construction shapes, quickconstruct, width test | at stock on every shape |
| Endurance test | no error growth; throughput curve the same as the `buggy` no-lock control |

The results are in [4-fourth-hotfix-results.md](4-fourth-hotfix-results.md).
