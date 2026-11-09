# Root cause: the compiler temporary for a literal inside a conditional expression

What Adobe's fourth hotfix (`hf202300-4232227`, v4) changes, read straight out of the bytecode, and
why that change is the cause of the scope contamination. Written 2026-10-13, the day the jar
arrived and before any test ran, so the predictions at the end were on record before the first
measurement. The measurements are in [results.md](results.md).

## The jar

| | |
|---|---|
| SHA256 | `9d17ad33bb1d845d0303346905a2c0e8ca3fa6d4e2e087a45590c3feae4c5e81` |
| Size | 24,210 bytes, 14 entries |
| Class file version | 52 (Java 8 target), same as stock Update 23 |
| Contents | `coldfusion/runtime/NeoPageContext.class` (38,376 bytes) and its nine inner classes. Nothing else. |

All four of Adobe's builds for this case carry the same name, `hf202300-4232227`. The first (a
global construction lock) and the third (per-class locks) replace `TemplateProxyFactory`; this one
does not. With v4 deployed, `TemplateProxyFactory`, `TemplateProxy`, `UDFMethod` and `Closure` are
the stock Update 23 classes. There is no lock of any kind in the change.

## How this was read

`NeoPageContext` from the v4 jar was compared with the same class from stock Update 23
(`chf20230023.jar`) and from stock Update 25 (`chf20230025.jar`). Disassembled with `javap -p -c`
(JDK 17), decompiled with CFR 0.152. The comparison is a normalized bytecode diff:
constant-pool indices, bytecode offsets, branch targets and whitespace stripped. The v4 class was
compiled by a newer compiler than Adobe's build, which changes `ldc` to `ldc_w` for some constants
and emits `invokeinterface` instead of `invokevirtual` for `getClass()` on interface-typed
receivers; those lines are compiler noise and were confirmed to be the only other differences.

## The change

**One method changed. Compiler temporaries for inline struct and array literals are now stored
in the running function's local scope instead of the component's `variables` scope.**

The nine inner classes are identical apart from the compiler noise above. The main class differs
in exactly one method, `SymTab_setValidatedSimpleName(String, Object, boolean)`, the path an
assignment to an unscoped simple name takes while a function is running. CFR output, stock first:

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
when the local scope has already **declared** it (`var x`), or it is a `cfthread` local, or it is
an argument. Otherwise an unscoped assignment inside a function lands in `variables`. That is
ColdFusion's documented behaviour for a variable the programmer forgot to `var`.

`___IMPLICITARRYSTRUCTVAR<n>` is the name the ColdFusion compiler gives the temporary it creates
for an inline literal, `{ ... }` or `[ ... ]`. For a literal in a plain statement the compiler
declares that temporary as a local and nothing leaks. For a literal inside a **conditional
expression**, `cond ? { ... } : { ... }` or `x ?: { ... }`, it does not. Measured with
[`hotfixrepro/scopeleak/shapes.cfm`](../hotfixrepro/scopeleak/) on Update 21 and Update 23: of 33
code shapes, exactly the nine with a literal inside a `?:` or elvis expression leak. Every other
shape, including literals in closures, loops, `invoke()` arguments and `structAppend`, does not.
So on every build before v4 that temporary took the "forgot to var" path and was written into the
component's `variables` scope. The compiler itself has been committing the classic un-`var`ed
variable bug on behalf of every function that builds a literal inside a ternary.

## Why that is the contamination

In a transient the stray key is harmless: the `variables` scope belongs to one instance. In a
**singleton** the `variables` scope is shared by every request. Building a literal is not atomic:
the compiled code creates the struct, stores it in the temporary, evaluates each value, reads the
temporary back to set each key, and reads it back once more to use the result. Two requests
running the same function on the same singleton at the same time share that one slot. Request A
stores its new struct in the slot, request B overwrites the slot with its own struct, and A reads
the slot back, continues filling, and finally returns B's struct. The longer the value
expressions take, the wider the window.

This is exactly what the August 2026 measurements found and could not name
([history](history.md#august-measuring-instead-of-guessing)). The last probe of that round showed
the crossing object is the `constructorArgCollection` struct in WireBox's `Builder.buildCFC`,
built in a method of the WireBox Builder **singleton** and passed to `invoke( oModel, "init", ... )`.
The struct was already another request's the instant it entered the engine, it had been created
clean, nothing persistent held it, and the only shape that fit was a write that landed in the
wrong place during concurrent execution of a method on a shared singleton. The line is
(`coldbox/system/ioc/Builder.cfc`, ColdBox 8.1.0):

```cfml
var constructorArgCollection = constructorArgs.len() ? buildArgumentCollection( ... ) : {};
```

A literal inside a ternary: the leaking shape. The slot is `___IMPLICITARRYSTRUCTVAR<n>` in the
Builder's `variables` scope, and the six empty `{}` structs the August probe captured are that
`: {}` branch. Quick's relationship setup then receives another request's `related` entity through
that struct, and the `UPDATE` compiles with the other entity's table.

It also explains the earlier results:

- Adobe's locks reduced the rate without removing it. A construction lock serializes the
  `createObject` inside `buildCFC`, which shortens the window in which two `buildCFC` calls
  overlap, but the literal is built before and after the locked region.
- Unrelated classes (`/repro/wire`) never crossed: every one of its six probes passes
  `initArguments`, so `constructorArgs.len()` is never zero and the `: {}` branch is never the
  struct that is used. The Quick entities are built with no constructor arguments and take the
  leaking branch on every build.
- Lucee and BoxLang do not have the bug: neither compiles literals through a temporary that can
  land in a shared scope.

## Who else is affected

Any CFML code that builds a struct or array literal inside a conditional expression, in a
function of a component that more than one request uses at a time (anything cached in the
application scope or held as a singleton by a framework). WireBox's `Builder.buildCFC` is one such
place, on every object WireBox builds without constructor arguments. Your own singletons can be
another: run [`hotfixrepro/scopeleak/shapes.cfm`](../hotfixrepro/scopeleak/) to see the shapes, and
look for `? {`, `? [`, `: {`, `: [`, `?: {` and `?: [` in singleton methods.

Rewriting such a line as an `if`/`else` that assigns to a `var`-declared variable avoids the shape
in your own code. That was not tested as a workaround for WireBox in this repository.

## What v4 does not change

- **The separate startup crash.** A freshly started server under immediate concurrent load can
  corrupt a shared `CaseInsensitiveMap` and then fail every request until restart. Nothing in this
  jar touches those classes. It has its own reproduction and fix:
  [homestar9/acf-startup-npe-repro](https://github.com/homestar9/acf-startup-npe-repro).
- **Any construction lock.** There is none, so the deadlock of the third hotfix and the throughput
  cost of the first and third cannot occur.
- **The pseudo-constructor path.** With no function running, `getActiveFunctionLocalScope()` is
  null and a literal in a pseudo-constructor still goes to `variables`, which is correct there:
  that scope belongs to the instance being built.

## Engine version

`NeoPageContext` is byte-identical in Update 23 and Update 25 (normalized diff: zero lines), so the
patch applies the same to both. That was checked by comparing bytecode, not by running v4 on
Update 25. Later updates were not compared; on a later update, ask Adobe for a matching build or
compare the class the same way.

## Things worth a look

- `putInternal` on the local scope bypasses the declared-key bookkeeping that `put` keeps. Whether
  a temporary stored this way is visible to `local` enumeration or to `localmode` checks is a
  runtime question; `/benchmark/engine` reports where the temporaries land.
- `cfthread` bodies: inside a thread the active function local scope is the thread's own, so the
  temporary stays per thread. The lock stress tests ran literals inside threads throughout.
- Code that (accidentally) relied on a literal's temporary surviving in `variables` between calls
  would change behaviour. That would be code reading a key named `___IMPLICITARRYSTRUCTVAR`, which
  nothing sensible does.

## Predictions, written before the first run

The tests named here are described in [results.md](results.md); the lock stress tests, lock
evidence and construction shapes were retired after the fourth hotfix and are kept at git tag
[`research-notes-2026-10`](https://github.com/homestar9/adobe-scope-contamination/tree/research-notes-2026-10).

| Measurement | Predicted for v4 | Outcome |
|---|---|---|
| Temp-variable probes (`/torture/p8`, `/repro/tempvar`, `hotfixrepro/scopeleak`) | stock, v1 and v3: `___IMPLICITARRYSTRUCTVAR` keys in the singleton's `variables`, and threads get back each other's values; v4: neither | as predicted |
| Warmed contamination test, `/repro/alpha` + `/repro/bravo`, 20 and 64 connections | 0 contaminated requests in at least 1,000,000 | 0 in 2,900,000 |
| `alpha + wire` | clean, as before | clean |
| Lock evidence under `/repro` load | 0 threads waiting in `resolveName` per dump, like stock (v3: 31.6, v1: 40.2) | 0 |
| Lock stress tests P1 to P7 | identical to stock | identical to stock |
| Deadlock demo `hotfixrepro/deadlock` | PASS | PASS |
| Real-workload throughput at 8 to 64 in flight | within 5% of stock Update 23 counting only its successful requests (v3 was 0.76 to 0.82, v1 0.44 to 0.53) | 0.97 to 1.15 |
| Endurance test | no error growth; throughput curve the same as the no-lock control | as predicted |
