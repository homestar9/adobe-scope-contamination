# v2 hotfix and Update 23 — static analysis

Date: 2026-08-18

Adobe sent a new patch for the CFC scope contamination bug (ticket 4232227) with the
note "apply the patch on top of Update 23." We saved their new file as
`hotfixes/hf202300-4232227-v2.jar` (it had the same name as the first one). This
document records what the new patch is and how it compares to Adobe's original hotfix
and to the "unlocked" jar we built.

Short version: **the v2 patch is Adobe's real answer to our regression complaint.**
They threw out the process-wide lock that caused the slowdown and fixed the bug a
different way, in the compiler. That fix is already inside Update 23 — the v2 jar
carries the exact same class bytes Update 23 already ships.

## How to reproduce this analysis

- Decompiler: `tools/cfr.jar` (CFR). Disassembler: `javap` from a JDK (used JDK 21).
- Update 23 base used for comparison: an installed ACF `2023.0.23.330940`
  (`.../adobe-2023.0.23.330940/WEB-INF/cfusion/`), whose cumulative jar is
  `lib/updates/chf20230023.jar` (entries dated 2026-08-07). Confirmed identical across
  two independent installs on this machine.
- "GA base" means the original `2023.0` release class inside `lib/cfusion.jar`
  (entries dated 2023-10-03), before any cumulative update.

## What each jar contains

| Jar | Size | Classes it patches |
|---|---|---|
| `hf202300-4232227.jar` (original / "v1") | 102,116 B | `coldfusion/runtime/`: `TemplateProxy`, `TemplateProxyFactory`, `UDFMethod`, `Closure` |
| `hf202300-4232227-unlocked.jar` (our build) | 101,964 B | same as v1, but `TemplateProxyFactory` has the lock removed |
| `hf202300-4232227-v2.jar` (new) | 29,786 B | `coldfusion/compiler/`: `ExprAssembler` (+ 2 inner exception classes, 4 properties) |

The original patch and the v2 patch share **zero class files**. The original fixes the
bug in the runtime classes and adds a lock. The v2 patch changes only the compiler and
adds no lock.

Jar-level SHA256:

```
hf202300-4232227.jar          7b586d55814b120fb818eab7ef16dd83336449a6088162d627f114a6cc352c56
hf202300-4232227-unlocked.jar 1674130d487807c4a75cbf59ec48db95883c51020ae1c1e4eebfd5678df0bc85
hf202300-4232227-v2.jar       137889d7741e1d2f1763b0698caf37b405878c7472fdc1bf14051092ffb06fc6
```

## Headline: v2 equals stock Update 23

The `ExprAssembler.class` inside the v2 patch is **byte-for-byte identical** to the
`ExprAssembler.class` Adobe already ships inside Update 23's cumulative jar. Same
SHA256 for the main class and both inner classes, checked against two separate Update
23 installs.

```
ExprAssembler.class
  v2 hotfix  = Update 23 (chf20230023.jar)  54d10deccbe5d3f4f6805dfa8cd0d1aad96d9190f806afb10b62cb3c6fc10aa7
  GA base (2023.0 release)                   a310a69c3a3a469c7d15878e9e40852d6604ad7a94b24a52f000628246f1bee7
```

What this means in practice: **on a fully patched Update 23, dropping in the v2 hotfix
jar changes nothing.** The class is already there and already identical, so classloader
order does not matter. Adobe's "apply on top of Update 23" note fits this: the v2 jar
only carries the compiler piece, and the matching runtime changes already live inside
Update 23.

## The lock is gone in Update 23

The original v1 hotfix added one process-wide monitor (`CONSTRUCTION_LOCK`) around all
CFC name resolution. That is the change that serialized construction and dropped
throughput from ~500 req/s to ~100 req/s in the three-arm run. We measured it directly
by counting `monitorenter` instructions in `TemplateProxyFactory`:

```
TemplateProxyFactory monitorenter count
  v1 hotfix                  3   (the two original per-component locks + the new global lock)
  Update 23 (chf20230023)    2   (only the original per-component locks — NO global lock)
  GA base (2023.0)           2
```

Update 23 has two `monitorenter`, same as the pre-fix base. The global lock is not
there. Adobe abandoned the lock approach.

Update 23's runtime classes are still changed from the GA base — `TemplateProxyFactory`
and `UDFMethod` both differ by hash from `cfusion.jar` — so the fix is real, it is just
done without a global lock. In the cumulative jar, the fix spans `ExprAssembler`
(compiler) plus `TemplateProxyFactory` and `UDFMethod` (runtime).

## What the compiler change does

Comparing the GA `ExprAssembler` (51,469 B) to the Update 23 one (51,537 B) with CFR,
the change is small and centers on a new field:

- New `protected boolean disableLineFeed;`.
- In `assignVar` (the method that generates bytecode for assigning a value into a
  simple variable, e.g. into the `variables` scope), the assembler now sets
  `disableLineFeed = true` around assembling the right-hand-side expression, then sets
  it back to `false`.
- Where the assembler used to always emit line-number tracking bytecode, it now guards
  that emission with `!this.disableLineFeed`.

So the compiler now generates slightly different bytecode for scope-variable
assignments. This is a code-generation change, not a lock — it does not serialize
anything at runtime.

Note: this is the exact mechanism CFR shows for the compiler piece. The full
correctness fix also includes the runtime `TemplateProxyFactory` and `UDFMethod`
changes in Update 23, which we did not decompile line-by-line.

## How the three approaches compare

| | Correctness fix | Global lock | Throughput | Correctness tested? |
|---|---|---|---|---|
| Original v1 hotfix | 4 runtime classes | Yes | Bad (~4–5x regression) | Yes (fixed the bug, per prior runs) |
| Our unlocked jar | v1 classes, lock stripped | No | Good (recovered) | No — never gated |
| v2 = Update 23 | Compiler + runtime, new route | No | Should match baseline | Not yet — this is what to test |

Our unlocked jar is now obsolete. It was a test build to prove the lock was the
problem. Adobe agreed and shipped a different fix that also drops the lock.

## One caveat about picking a "buggy" control for testing

While gathering base classes, we found that the Update 22 cumulative jar in one install
(`chf20230022.jar`, entries dated 2026-07-07) already contains the same fixed
`ExprAssembler`, `TemplateProxyFactory`, and `UDFMethod` as Update 23 — byte-identical.
So Adobe re-released the fix into cumulative updates.

The takeaway for benchmarking: "Update 22" is ambiguous now. An older Update 22 jar has
the bug; a re-released one does not. When you set up a known-buggy control arm, do not
trust the update number — **verify it actually reproduces the contamination through the
`/repro/alpha` and `/repro/bravo` endpoints before using it as the control.**

## What static analysis cannot tell us

Bytecode proves the lock is gone and that v2 equals stock Update 23. It does not prove
Update 23 actually stops the contamination under real concurrent load. The repo's
correctness gate has never been run. That is the open question, and the reason for the
Update 23 benchmark round described in the plan.
