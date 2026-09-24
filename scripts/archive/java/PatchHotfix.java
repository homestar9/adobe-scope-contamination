/*
 * PatchHotfix — surgically remove (or narrow) the JVM-wide construction lock that Adobe's
 * hotfix hf202300-4232227 added to coldfusion.runtime.TemplateProxyFactory.resolveName.
 *
 * WHY THIS EXISTS
 *   The hotfix does two independent things:
 *     1. The real correctness fix: per-instance scope fields in TemplateProxy, UDFMethod,
 *        and Closure. Cheap, no contention. We keep these untouched.
 *     2. A redundant belt-and-braces guard: it wraps the whole resolveName path in
 *        `synchronized (CONSTRUCTION_LOCK)`, a single static Object monitor. This serializes
 *        every CFC construction across the JVM and is the sole cause of the throughput
 *        regression (see docs/adobe-hotfixes/1-first-hotfix-static-analysis.md and docs/adobe-hotfixes/1-first-hotfix-performance.md).
 *
 *   This tool rewrites ONLY the public static 8-arg resolveName wrapper so it calls the
 *   private resolveNameLocked directly, with no monitor. Everything else in the jar is copied
 *   byte-for-byte. The other three fixed classes are never opened by ASM.
 *
 * MODES
 *   full removal (default): drop the global lock entirely. resolveName delegates straight to
 *                           resolveNameLocked. Post-patch TemplateProxyFactory has exactly
 *                           2 monitorenter (the surviving per-component double-checked locks
 *                           inside resolveNameLocked), and the wrapper has 0 monitorenter.
 *   --stripe <class>:       fallback. Keep Adobe's exact monitor skeleton but swap the single
 *                           global lock object for a per-component lock from
 *                           coldfusion.runtime.ConstructionLockSupport.lockFor(String,File).
 *                           Different components construct concurrently; same-component init
 *                           stays serialized. Requires the compiled ConstructionLockSupport.class.
 *
 * USAGE
 *   PatchHotfix <in.jar> <out.jar>
 *   PatchHotfix <in.jar> <out.jar> --stripe <path/to/ConstructionLockSupport.class>
 *
 * Compiled and run against ASM Tree 9.7 (see scripts/tool-versions.json). Java 8+ bytecode.
 */
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.FrameNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.IntInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TryCatchBlockNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.zip.CRC32;
import java.util.zip.Deflater;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

public final class PatchHotfix {

    static final String OWNER        = "coldfusion/runtime/TemplateProxyFactory";
    static final String TARGET_ENTRY = "coldfusion/runtime/TemplateProxyFactory.class";

    // The public static 8-arg resolveName wrapper (and its private twin resolveNameLocked)
    // share this exact descriptor. Matching on the full descriptor + PUBLIC + STATIC uniquely
    // identifies the wrapper, distinct from the 7-arg private resolveName overload.
    static final String DESC8 =
          "(Lcoldfusion/runtime/TemplateProxy;Lcoldfusion/runtime/NeoPageContext;"
        + "Ljava/io/File;Ljava/lang/String;ZLjava/util/Map;Ljava/util/HashSet;Z)"
        + "Lcoldfusion/runtime/TemplateProxy;";

    static final String LOCK_SUPPORT_OWNER = "coldfusion/runtime/ConstructionLockSupport";
    static final String LOCK_SUPPORT_ENTRY = "coldfusion/runtime/ConstructionLockSupport.class";

    // Fixed modification time for the one entry this tool ADDS (the stripe-mode
    // ConstructionLockSupport.class). Copied entries keep the input jar's own fixed timestamps,
    // so they are already deterministic; only a freshly created ZipEntry defaults to the current
    // build time, which made two stripe builds differ by this single field and produce different
    // SHA256 values. Pinning it makes the stripe jar byte-reproducible. 2000-01-01T00:00:00 as
    // epoch milliseconds. (ZipEntry.setTime converts through the default time zone, so this is
    // reproducible per machine/zone, which is what the build's hash check needs.)
    static final long FIXED_ENTRY_TIME = 946684800000L;
    static final String LOCKFOR_DESC       = "(Ljava/lang/String;Ljava/io/File;)Ljava/lang/Object;";

    // ---- v3 (ObjectDuplicator race fix) constants ---------------------------------------
    // v3 targets a different class entirely: coldfusion.runtime.ObjectDuplicator, whose
    // Duplicate() reads and lazily writes the SOURCE object during a deep copy. Two threads
    // duplicating the same shared metadata object (Quick's cached _meta, shared through the
    // common BaseEntity ancestor) tear it. The fix serializes duplicates of the SAME object
    // only: rename the private static _duplicate to _duplicate0 and add a thin _duplicate
    // that wraps the call in `synchronized (obj)`. Unrelated objects still duplicate in
    // parallel, so throughput stays close to vanilla. See docs/HOTFIX_V3_PHASE0_FINDINGS.md.
    static final String OBJDUP_OWNER = "coldfusion/runtime/ObjectDuplicator";
    static final String OBJDUP_ENTRY = "coldfusion/runtime/ObjectDuplicator.class";
    static final String DUP_DESC     = "(Ljava/lang/Object;Ljava/util/IdentityHashMap;)Ljava/lang/Object;";
    // A unique interned-String monitor for the duplicate lock. A String literal is interned
    // JVM-wide, so it is one object shared across every classloader that loads this method.
    static final String DUP_LOCK_STRING = "coldfusion.runtime.ObjectDuplicator.V3_DUPLICATE_LOCK";

    // ---- concmap (concurrent metadata map) constants ------------------------------------
    // This is how the open-source engines (BoxLang, Lucee) avoid the bug: their struct/scope
    // maps are concurrent, so iterating one while another thread mutates it does not tear.
    // ACF's CaseInsensitiveMap ALREADY ships a null-safe ConcurrentHashMap variant
    // (CFConcurrentHashMap) and uses it when constructed with concurrent=true — but the two
    // DEFAULT constructors use a plain HashMap, whose keysToArray tears under concurrent
    // modification (the getKey NPE that cascades cold). This patch points the two default
    // constructors at CFConcurrentHashMap. The backing field is typed Map, so no field
    // descriptor changes (serialVersionUID safe); CFConcurrentHashMap routes nulls through
    // NULL_PILL, so it is null-safe. See docs/root-cause/how-lucee-and-boxlang-avoid-it.md.
    static final String CIMAP_OWNER = "coldfusion/util/CaseInsensitiveMap";
    static final String CIMAP_ENTRY = "coldfusion/util/CaseInsensitiveMap.class";
    static final String HASHMAP     = "java/util/HashMap";
    static final String CFCHM       = "coldfusion/util/CaseInsensitiveMap$CFConcurrentHashMap";

    // ---- trace (the DIAGNOSTIC build) ----------------------------------------------------
    // This mode changes no behavior. It renames a few engine methods to <name>$orig and puts a
    // thin wrapper in their place: call the original, then hand (this, args, result) to a hook
    // on coldfusion.runtime.ScopeTrace, then return the original's result.
    //
    // Why bother: the earlier fix attempts each GUESSED which shared reference crosses between
    // two concurrent CFC constructions, patched it, and the contamination rate did not move.
    // This build names the crossing reference from a running server instead.
    //
    // The wrappers are deliberately dumb — no branches, no exception handlers — so they need no
    // stack map frames and cannot break verification. Every hook on ScopeTrace catches Throwable
    // itself, and the whole thing stays inert unless -Dcfscope.trace=<file> is set.
    static final String TRACE_OWNER = "coldfusion/runtime/ScopeTrace";
    static final String TRACE_ENTRY = "coldfusion/runtime/ScopeTrace.class";
    static final String HOOK_DESC   = "(Ljava/lang/Object;[Ljava/lang/Object;Ljava/lang/Object;)V";

    /** { jar entry, expected class name, then triples of (method, descriptor, hook) }. */
    static final String[][] TRACE_TARGETS = {
        {
            "coldfusion/runtime/UDFMethod.class", "coldfusion/runtime/UDFMethod",
            // The read that matters most: v1 prefers a per-instance super scope and falls back
            // to the shared UDFMethod.superScope field. Every fallback gets logged.
            "resolveInvocationSuperScope", "(Ljava/lang/Object;)Lcoldfusion/runtime/Scope;", "udfResolveSuper",
            // The shared write. One UDFMethod object is static on the generated component class.
            "setSuperScope", "(Lcoldfusion/runtime/Scope;)V", "udfSetSuper",
            // Every CFML function return passes through here. If a function hands back a
            // component that belongs to another in-flight request, this is where that object
            // enters the request — and the stack names the exact function that did it.
            "invoke", "(Lcoldfusion/filter/FusionContext;)V", "udfInvokeReturn",
            // The named-args entry point: `invoke( obj, "init", someStruct )` lands here with
            // the caller's raw STRUCT, before it is converted to an ArgumentCollection. If the
            // struct is already carrying another request's component at this boundary, the
            // pollution is upstream in struct state; if the struct is clean here while the
            // resulting ArgumentCollection is dirty, the engine's conversion is the polluter.
            "invoke",
            "(Ljava/lang/Object;Ljava/lang/String;Ljava/lang/Object;Ljava/util/Map;)Ljava/lang/Object;",
            "udfMapInvoke",
        },
        {
            "coldfusion/runtime/TemplateProxy.class", "coldfusion/runtime/TemplateProxy",
            // A miss here is what sends resolveInvocationSuperScope to the shared field.
            "getBoundSuperScopeForLevel", "(Ljava/lang/String;)Lcoldfusion/runtime/Scope;", "proxyBoundSuperLookup",
            // Where the variables scope for a call gets chosen. If it is not the instance's own
            // scope, the instance is about to read someone else's variables.
            "setupScopesForInvoke",
            "(Ljavax/servlet/jsp/PageContext;Lcoldfusion/filter/FusionContext;)Lcoldfusion/runtime/CfJspPage;",
            "proxySetupInvoke",
        },
        {
            "coldfusion/runtime/TemplateProxyFactory.class", "coldfusion/runtime/TemplateProxyFactory",
            // One construction step — the thing the shared writes happen inside.
            "setupThisAndSuper",
            "(Lcoldfusion/runtime/TemplateProxy;Ljava/util/HashMap;Lcoldfusion/runtime/VariableScope;ZZ)V",
            "factorySetupThisAndSuper",
            // The 8-argument overload every public entry point funnels through (see
            // docs/adobe-hotfixes/1-first-hotfix-static-analysis.md). If a request gets back a component that a
            // DIFFERENT request built, the object crossed here, at creation. If this stays clean
            // while the relationship code still sees a foreign object, the crossing is in
            // argument passing instead. Either answer settles it.
            "resolveName", DESC8, "factoryResolveName",
        },
    };

    /**
     * Trace targets that live in the stock Update 23 jar rather than in Adobe's hotfix jar, so
     * they have to be copied into the overlay before they can be instrumented.
     *
     * NeoPageContext holds the stack of function-local scopes. Adobe made the push, pop, and
     * "which one is active" methods `synchronized`, which says the object really can be reached
     * by more than one thread at a time. A lock keeps the stack itself from breaking, but it
     * does nothing about order: if two threads share one page context, thread A can push, thread
     * B can push, and then thread A asks for the active scope and gets B's. That would hand one
     * request another request's local variables and arguments, which is exactly the symptom.
     */
    static final String[][] TRACE_EXTRA_TARGETS = {
        {
            "coldfusion/runtime/NeoPageContext.class", "coldfusion/runtime/NeoPageContext",
            "pushNewFunctionLocalScope", "()Lcoldfusion/runtime/LocalScope;", "ctxPushLocalScope",
            "getActiveFunctionLocalScope", "()Lcoldfusion/runtime/LocalScope;", "ctxActiveLocalScope",
            // The one-way iscfthread latch on a shared UDFMethod routes EVERY later call of
            // that function here, and this returns the page context's single threadLocalScope
            // instead of a fresh frame. If that shared frame ever serves two live requests,
            // whole argument sets cross together — which is exactly the observed corruption.
            "setupThreadLocalScope", "()Lcoldfusion/runtime/LocalScope;", "ctxThreadLocalScope",
        },
        {
            // Every `{}` struct literal in compiled CFML comes from here. Registering each new
            // struct against the request that created it lets a later cross-request sighting
            // name its creator — the missing fact in the struct-object crossing.
            "coldfusion/runtime/CFPage.class", "coldfusion/runtime/CFPage",
            "StructNew", "()Ljava/util/Map;", "pageStructNew",
            // The decisive probe. Quick's metadataInspection copies the cached metadata snapshot,
            // which "still references the engine's shared component metadata", through this.
            // Walking the source graph DURING the copy catches a cross-request live-entity
            // reference while it still exists — which a walk after the fact cannot.
            "Duplicate", "(Ljava/lang/Object;)Ljava/lang/Object;", "pageDuplicate",
            // Frame A: the invoke() built-in function. WireBox constructs every entity and
            // relationship with invoke( target, "init", struct ), so this is the first engine
            // frame that struct reaches on the calling thread. A PRE-hook, so the struct's owner
            // is read before the nested construction runs (and before a failure can retire it).
            // This is the boundary that finally answers whether the struct is already another
            // request's when it enters the engine, or only becomes so inside dispatch.
            "invoke", "(Ljava/lang/Object;Ljava/lang/String;Ljava/lang/Object;)Ljava/lang/Object;", "PRE:cfpageBifInvoke",
        },
    };

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: PatchHotfix <in.jar> <out.jar> [--stripe <ConstructionLockSupport.class>]");
            System.err.println("       PatchHotfix <cfusion.jar> <out-overlay.jar> --v3");
            System.exit(2);
            return;
        }
        String inJar  = args[0];
        String outJar = args[1];
        boolean stripe = false;
        boolean v3     = false;
        boolean v3Combined = false;
        boolean concMap = false;
        boolean concMapCombined = false;
        boolean concMapV1 = false;
        boolean trace = false;
        String dupFromJar = null;
        String traceSupportDir = null;
        String traceExtraJar = null;
        byte[] lockSupportClass = null;

        for (int i = 2; i < args.length; i++) {
            if (args[i].equals("--stripe")) {
                stripe = true;
                if (i + 1 >= args.length) {
                    throw new IllegalArgumentException("--stripe requires the path to ConstructionLockSupport.class");
                }
                lockSupportClass = Files.readAllBytes(Paths.get(args[i + 1]));
                i++;
            } else if (args[i].equals("--v3")) {
                v3 = true;
            } else if (args[i].equals("--v3-combined")) {
                v3Combined = true;
            } else if (args[i].equals("--concmap")) {
                concMap = true;
            } else if (args[i].equals("--concmap-combined")) {
                concMapCombined = true;
            } else if (args[i].equals("--concmap-v1")) {
                concMapV1 = true;
            } else if (args[i].equals("--trace")) {
                trace = true;
            } else if (args[i].equals("--trace-extra")) {
                if (i + 1 >= args.length) {
                    throw new IllegalArgumentException("--trace-extra requires the stock Update jar that holds NeoPageContext");
                }
                traceExtraJar = args[i + 1];
                i++;
            } else if (args[i].equals("--trace-support")) {
                if (i + 1 >= args.length) {
                    throw new IllegalArgumentException("--trace-support requires the directory holding the compiled ScopeTrace classes");
                }
                traceSupportDir = args[i + 1];
                i++;
            } else if (args[i].equals("--dup-from")) {
                if (i + 1 >= args.length) {
                    throw new IllegalArgumentException("--dup-from requires the path to the jar holding stock ObjectDuplicator (cfusion.jar)");
                }
                dupFromJar = args[i + 1];
                i++;
            } else {
                throw new IllegalArgumentException("unknown argument: " + args[i]);
            }
        }

        if (trace) {
            if (stripe || v3 || v3Combined || concMap || concMapCombined || concMapV1) {
                throw new IllegalArgumentException("--trace is mutually exclusive with the other modes");
            }
            if (dupFromJar == null) {
                throw new IllegalArgumentException("--trace requires --dup-from <cfusion.jar> (for the concurrent CaseInsensitiveMap)");
            }
            if (traceSupportDir == null) {
                throw new IllegalArgumentException("--trace requires --trace-support <dir with compiled ScopeTrace classes>");
            }
            if (traceExtraJar == null) {
                throw new IllegalArgumentException("--trace requires --trace-extra <chf update jar> (the source of NeoPageContext)");
            }
            writeTraceOverlay(inJar, outJar, dupFromJar, traceSupportDir, traceExtraJar);
            return;
        }

        if (concMap) {
            if (stripe || v3 || v3Combined || concMapCombined || concMapV1) {
                throw new IllegalArgumentException("--concmap is mutually exclusive with the other modes");
            }
            writeConcMapOverlay(inJar, outJar);
            return;
        }

        if (concMapCombined) {
            if (stripe || v3 || v3Combined || concMap || concMapV1) {
                throw new IllegalArgumentException("--concmap-combined is mutually exclusive with the other modes");
            }
            if (dupFromJar == null) {
                throw new IllegalArgumentException("--concmap-combined requires --dup-from <cfusion.jar>");
            }
            writeConcMapCombinedOverlay(inJar, outJar, dupFromJar);
            return;
        }

        if (concMapV1) {
            if (stripe || v3 || v3Combined || concMap || concMapCombined) {
                throw new IllegalArgumentException("--concmap-v1 is mutually exclusive with the other modes");
            }
            if (dupFromJar == null) {
                throw new IllegalArgumentException("--concmap-v1 requires --dup-from <cfusion.jar>");
            }
            writeConcMapV1Overlay(inJar, outJar, dupFromJar);
            return;
        }

        if (v3) {
            if (stripe || v3Combined) {
                throw new IllegalArgumentException("--v3 is mutually exclusive with --stripe / --v3-combined");
            }
            writeV3Overlay(inJar, outJar);
            return;
        }

        if (v3Combined) {
            if (stripe) {
                throw new IllegalArgumentException("--v3-combined and --stripe are mutually exclusive");
            }
            if (dupFromJar == null) {
                throw new IllegalArgumentException("--v3-combined requires --dup-from <cfusion.jar>");
            }
            writeV3CombinedOverlay(inJar, outJar, dupFromJar);
            return;
        }

        boolean patchedTarget = false;
        try (ZipFile in = new ZipFile(inJar);
             ZipOutputStream out = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(outJar)))) {
            out.setLevel(Deflater.DEFAULT_COMPRESSION);
            Enumeration<? extends ZipEntry> entries = in.entries();
            while (entries.hasMoreElements()) {
                ZipEntry src = entries.nextElement();
                byte[] data = readAll(in.getInputStream(src));
                if (src.getName().equals(TARGET_ENTRY)) {
                    data = stripe ? stripePatch(data) : fullRemovePatch(data);
                    patchedTarget = true;
                }
                writeEntry(out, src, data);
            }
            if (stripe) {
                if (lockSupportClass == null) {
                    throw new IllegalStateException("stripe mode requires ConstructionLockSupport.class bytes");
                }
                ZipEntry ne = new ZipEntry(LOCK_SUPPORT_ENTRY); // DEFLATED by default
                ne.setTime(FIXED_ENTRY_TIME);                   // pin the time so the jar hashes stably
                out.putNextEntry(ne);
                out.write(lockSupportClass);
                out.closeEntry();
            }
        }

        if (!patchedTarget) {
            throw new IllegalStateException("did not find " + TARGET_ENTRY + " in " + inJar);
        }
        System.out.println("Wrote " + outJar + (stripe ? "  (stripe mode)" : "  (full-removal mode)"));
    }

    // ---- the transforms -----------------------------------------------------------------

    /** Replace the wrapper body with a plain delegation to resolveNameLocked; no monitor. */
    static byte[] fullRemovePatch(byte[] original) {
        ClassNode cn = new ClassNode();
        new ClassReader(original).accept(cn, 0);
        MethodNode m = findWrapper(cn);
        assertWrapperShape(m);

        m.instructions.clear();
        if (m.tryCatchBlocks != null)                 m.tryCatchBlocks.clear();
        if (m.localVariables != null)                 m.localVariables.clear();
        m.visibleLocalVariableAnnotations   = null;
        m.invisibleLocalVariableAnnotations = null;

        InsnList il = new InsnList();
        il.add(new VarInsnNode(Opcodes.ALOAD, 0)); // TemplateProxy
        il.add(new VarInsnNode(Opcodes.ALOAD, 1)); // NeoPageContext
        il.add(new VarInsnNode(Opcodes.ALOAD, 2)); // File
        il.add(new VarInsnNode(Opcodes.ALOAD, 3)); // String
        il.add(new VarInsnNode(Opcodes.ILOAD, 4)); // boolean
        il.add(new VarInsnNode(Opcodes.ALOAD, 5)); // Map
        il.add(new VarInsnNode(Opcodes.ALOAD, 6)); // HashSet
        il.add(new VarInsnNode(Opcodes.ILOAD, 7)); // boolean
        il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, OWNER, "resolveNameLocked", DESC8, false));
        il.add(new InsnNode(Opcodes.ARETURN));
        m.instructions.add(il);
        m.maxStack  = 8; // 8 category-1 args pushed
        m.maxLocals = 8; // slots 0..7, all category-1

        ClassWriter cw = new ClassWriter(0); // no COMPUTE_FRAMES -> no ACF classpath needed
        cn.accept(cw);
        return cw.toByteArray();
    }

    /** Keep Adobe's monitor skeleton; swap the global lock object for a per-component one. */
    static byte[] stripePatch(byte[] original) {
        ClassNode cn = new ClassNode();
        new ClassReader(original).accept(cn, 0);
        MethodNode m = findWrapper(cn);
        assertWrapperShape(m);

        FieldInsnNode getLock = null;
        for (AbstractInsnNode insn = m.instructions.getFirst(); insn != null; insn = insn.getNext()) {
            if (insn.getOpcode() == Opcodes.GETSTATIC) {
                FieldInsnNode f = (FieldInsnNode) insn;
                if (f.owner.equals(OWNER) && f.name.equals("CONSTRUCTION_LOCK")) {
                    getLock = f;
                    break;
                }
            }
        }
        if (getLock == null) {
            throw new IllegalStateException("could not find getstatic CONSTRUCTION_LOCK in the resolveName wrapper");
        }

        // Replace the single getstatic (pushes 1 Object) with: push fullName, push file,
        // invokestatic lockFor -> (pops 2, pushes 1 Object). Net stack effect identical, so
        // the following `dup; astore; monitorenter ... monitorexit` skeleton and its handler
        // frame remain valid untouched.
        InsnList prefix = new InsnList();
        prefix.add(new VarInsnNode(Opcodes.ALOAD, 3)); // fullName : String (param 3)
        prefix.add(new VarInsnNode(Opcodes.ALOAD, 2)); // file : File (param 2)
        prefix.add(new MethodInsnNode(Opcodes.INVOKESTATIC, LOCK_SUPPORT_OWNER, "lockFor", LOCKFOR_DESC, false));
        m.instructions.insertBefore(getLock, prefix);
        m.instructions.remove(getLock);
        // prefix peaks at stack depth 2, which is <= the wrapper's existing maxStack (>=8),
        // and adds no locals, so maxStack/maxLocals are left unchanged.

        ClassWriter cw = new ClassWriter(0);
        cn.accept(cw);
        return cw.toByteArray();
    }

    // ---- v3: ObjectDuplicator race fix --------------------------------------------------

    /**
     * Build the v3 overlay jar. Unlike the legacy modes (which copy the whole input jar and
     * change one entry), v3 reads ONLY coldfusion/runtime/ObjectDuplicator.class out of the
     * given cfusion.jar, patches it, and writes a tiny overlay jar containing just that one
     * patched class. The overlay deploys as hf202300-4232227.jar next to chf20230023.jar; the
     * bootstrap loads hf jars ahead of both the chf update jar and cfusion.jar, so this one
     * patched class wins while every other class still loads from the stock engine.
     */
    static void writeV3Overlay(String cfusionJar, String outJar) throws Exception {
        byte[] original = null;
        try (ZipFile in = new ZipFile(cfusionJar)) {
            ZipEntry e = in.getEntry(OBJDUP_ENTRY);
            if (e == null) {
                throw new IllegalStateException("did not find " + OBJDUP_ENTRY + " in " + cfusionJar);
            }
            original = readAll(in.getInputStream(e));
        }

        byte[] patched = v3Patch(original);

        try (ZipOutputStream out = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(outJar)))) {
            out.setLevel(Deflater.DEFAULT_COMPRESSION);
            ZipEntry ne = new ZipEntry(OBJDUP_ENTRY); // DEFLATED by default
            ne.setTime(FIXED_ENTRY_TIME);             // pin time so the overlay hashes stably
            out.putNextEntry(ne);
            out.write(patched);
            out.closeEntry();
        }
        System.out.println("Wrote " + outJar + "  (v3 mode: synchronized ObjectDuplicator overlay)");
    }

    // ---- concmap: concurrent metadata map (the open-source-engine fix) ------------------

    /**
     * Build the concmap overlay: read coldfusion/util/CaseInsensitiveMap out of cfusion.jar,
     * point its two default constructors at the null-safe CFConcurrentHashMap, and write a
     * one-class overlay. The overlay deploys as hf202300-4232227.jar and wins the classloader,
     * so every default CaseInsensitiveMap becomes concurrent (tear-proof iteration) while the
     * rest of the engine is untouched.
     */
    static void writeConcMapOverlay(String cfusionJar, String outJar) throws Exception {
        byte[] original = null;
        try (ZipFile in = new ZipFile(cfusionJar)) {
            ZipEntry e = in.getEntry(CIMAP_ENTRY);
            if (e == null) {
                throw new IllegalStateException("did not find " + CIMAP_ENTRY + " in " + cfusionJar);
            }
            original = readAll(in.getInputStream(e));
        }

        byte[] patched = concMapPatch(original);

        try (ZipOutputStream out = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(outJar)))) {
            out.setLevel(Deflater.DEFAULT_COMPRESSION);
            ZipEntry ne = new ZipEntry(CIMAP_ENTRY);
            ne.setTime(FIXED_ENTRY_TIME);
            out.putNextEntry(ne);
            out.write(patched);
            out.closeEntry();
        }
        System.out.println("Wrote " + outJar + "  (concmap: CaseInsensitiveMap default backing -> CFConcurrentHashMap)");
    }

    /**
     * In CaseInsensitiveMap's two DEFAULT constructors (no-arg and int-capacity), swap the
     * backing-map creation from java/util/HashMap to the null-safe CFConcurrentHashMap inner
     * class (which the class already uses on its concurrent=true path). Every NEW HashMap and
     * its INVOKESPECIAL HashMap.<init> inside those two constructors is retargeted. Refuse if
     * the shape is not exactly what we expect.
     */
    static byte[] concMapPatch(byte[] original) {
        ClassNode cn = new ClassNode();
        new ClassReader(original).accept(cn, 0);

        if (!CIMAP_OWNER.equals(cn.name)) {
            throw new IllegalStateException("expected class " + CIMAP_OWNER + " but got " + cn.name);
        }

        int swaps = 0;
        for (MethodNode m : cn.methods) {
            if (!m.name.equals("<init>")) continue;
            // Only the two DEFAULT constructors: ()V and (I)V. The (boolean...) ones already
            // choose CFConcurrentHashMap when concurrent=true; leave them alone.
            if (!m.desc.equals("()V") && !m.desc.equals("(I)V")) continue;

            for (AbstractInsnNode insn = m.instructions.getFirst(); insn != null; insn = insn.getNext()) {
                if (insn.getOpcode() == Opcodes.NEW) {
                    org.objectweb.asm.tree.TypeInsnNode t = (org.objectweb.asm.tree.TypeInsnNode) insn;
                    if (t.desc.equals(HASHMAP)) {
                        t.desc = CFCHM;
                        swaps++;
                    }
                } else if (insn.getOpcode() == Opcodes.INVOKESPECIAL) {
                    MethodInsnNode mi = (MethodInsnNode) insn;
                    if (mi.owner.equals(HASHMAP) && mi.name.equals("<init>")) {
                        mi.owner = CFCHM; // descriptor ()V / (I)V is identical on CFConcurrentHashMap
                        swaps++;
                    }
                }
            }
        }

        // Each of the two constructors has exactly one NEW + one INVOKESPECIAL to swap = 4 total.
        if (swaps != 4) {
            throw new IllegalStateException(
                "expected exactly 4 HashMap references to swap in the two default constructors, found "
                + swaps + " — CaseInsensitiveMap shape changed; refusing to patch");
        }
        // Sanity: the concurrent inner class the patched code now references must exist as an
        // inner class of this class (it ships in cfusion.jar and loads unchanged).
        boolean hasInner = false;
        if (cn.innerClasses != null) {
            for (org.objectweb.asm.tree.InnerClassNode ic : cn.innerClasses) {
                if (CFCHM.equals(ic.name)) { hasInner = true; break; }
            }
        }
        if (!hasInner) {
            throw new IllegalStateException("CFConcurrentHashMap inner class not declared on CaseInsensitiveMap — refusing.");
        }

        ClassWriter cw = new ClassWriter(0);
        cn.accept(cw);
        return cw.toByteArray();
    }

    /**
     * Build the concmap-combined overlay: copy every entry of the "unlocked" jar byte-for-byte
     * (Adobe's four per-instance scope fixes, construction lock removed), then add the patched
     * CaseInsensitiveMap (concurrent default backing) from cfusion.jar. This targets BOTH races
     * lock-free: the concurrent map for the metadata-duplication tear (race 1), the per-instance
     * fixes for the variables-scope contamination (race 2).
     */
    static void writeConcMapCombinedOverlay(String unlockedJar, String outJar, String cfusionJar) throws Exception {
        byte[] cimOriginal = null;
        try (ZipFile cimIn = new ZipFile(cfusionJar)) {
            ZipEntry e = cimIn.getEntry(CIMAP_ENTRY);
            if (e == null) {
                throw new IllegalStateException("did not find " + CIMAP_ENTRY + " in " + cfusionJar);
            }
            cimOriginal = readAll(cimIn.getInputStream(e));
        }
        byte[] cimPatched = concMapPatch(cimOriginal);

        try (ZipFile in = new ZipFile(unlockedJar);
             ZipOutputStream out = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(outJar)))) {
            out.setLevel(Deflater.DEFAULT_COMPRESSION);
            Enumeration<? extends ZipEntry> entries = in.entries();
            while (entries.hasMoreElements()) {
                ZipEntry src = entries.nextElement();
                if (src.getName().equals(CIMAP_ENTRY)) {
                    throw new IllegalStateException("the unlocked base jar already contains " + CIMAP_ENTRY
                        + " — refusing, the base is not the expected v1-derived unlocked jar");
                }
                writeEntry(out, src, readAll(in.getInputStream(src)));
            }
            ZipEntry ne = new ZipEntry(CIMAP_ENTRY);
            ne.setTime(FIXED_ENTRY_TIME);
            out.putNextEntry(ne);
            out.write(cimPatched);
            out.closeEntry();
        }
        System.out.println("Wrote " + outJar + "  (concmap-combined: unlocked per-instance fixes + concurrent CaseInsensitiveMap)");
    }

    /**
     * Build the concmap-v1 overlay (the shippable fallback): copy every entry of the ORIGINAL
     * v1 hotfix jar byte-for-byte — per-instance fixes AND the global construction lock — then
     * add the patched CaseInsensitiveMap (concurrent default backing) from cfusion.jar.
     * The lock closes race 2 (the ~4% variables-scope contamination, ~1/20k residual); the
     * concurrent map makes race 1 (the duplication tear cascade) structurally impossible even
     * if the lock ever has a gap. Strictly safer than v1 alone.
     *
     * Refuses to run unless the base jar really is the LOCKED v1 jar: the public static 8-arg
     * resolveName wrapper must still contain its monitorenter (the unlocked/stripe derivatives
     * removed or replaced it).
     */
    static void writeConcMapV1Overlay(String v1Jar, String outJar, String cfusionJar) throws Exception {
        byte[] cimOriginal = null;
        try (ZipFile cimIn = new ZipFile(cfusionJar)) {
            ZipEntry e = cimIn.getEntry(CIMAP_ENTRY);
            if (e == null) {
                throw new IllegalStateException("did not find " + CIMAP_ENTRY + " in " + cfusionJar);
            }
            cimOriginal = readAll(cimIn.getInputStream(e));
        }
        byte[] cimPatched = concMapPatch(cimOriginal);

        boolean sawLockedWrapper = false;
        try (ZipFile in = new ZipFile(v1Jar);
             ZipOutputStream out = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(outJar)))) {
            out.setLevel(Deflater.DEFAULT_COMPRESSION);
            Enumeration<? extends ZipEntry> entries = in.entries();
            while (entries.hasMoreElements()) {
                ZipEntry src = entries.nextElement();
                byte[] data = readAll(in.getInputStream(src));
                if (src.getName().equals(CIMAP_ENTRY)) {
                    throw new IllegalStateException("the v1 base jar already contains " + CIMAP_ENTRY
                        + " — refusing, the base is not the expected stock v1 hotfix jar");
                }
                if (src.getName().equals(TARGET_ENTRY)) {
                    ClassNode cn = new ClassNode();
                    new ClassReader(data).accept(cn, 0);
                    for (MethodNode m : cn.methods) {
                        if (!m.name.equals("resolveName") || !m.desc.equals(DESC8)) continue;
                        if ((m.access & Opcodes.ACC_PUBLIC) == 0 || (m.access & Opcodes.ACC_STATIC) == 0) continue;
                        for (AbstractInsnNode insn = m.instructions.getFirst(); insn != null; insn = insn.getNext()) {
                            if (insn.getOpcode() == Opcodes.MONITORENTER) { sawLockedWrapper = true; break; }
                        }
                    }
                    if (!sawLockedWrapper) {
                        throw new IllegalStateException("the base jar's resolveName wrapper has no monitorenter"
                            + " — this is an unlocked/stripe derivative, not the locked v1 jar; refusing");
                    }
                }
                writeEntry(out, src, data);
            }
            if (!sawLockedWrapper) {
                throw new IllegalStateException("did not find " + TARGET_ENTRY + " in " + v1Jar
                    + " — the base is not the v1 hotfix jar; refusing");
            }
            ZipEntry ne = new ZipEntry(CIMAP_ENTRY);
            ne.setTime(FIXED_ENTRY_TIME);
            out.putNextEntry(ne);
            out.write(cimPatched);
            out.closeEntry();
        }
        System.out.println("Wrote " + outJar + "  (concmap-v1: v1 lock + per-instance fixes + concurrent CaseInsensitiveMap)");
    }

    /**
     * Build the combined v3 overlay: copy every entry of the "unlocked" jar byte-for-byte
     * (Adobe's four per-instance scope fixes — TemplateProxyFactory, TemplateProxy, UDFMethod,
     * Closure — with the construction lock already removed), then add the patched
     * ObjectDuplicator from the stock cfusion.jar. The result carries BOTH fixes and NO
     * construction lock: the per-instance fixes for the scope-contamination race, the
     * ObjectDuplicator global monitor for the metadata-duplication race.
     */
    static void writeV3CombinedOverlay(String unlockedJar, String outJar, String cfusionJar) throws Exception {
        // Patch ObjectDuplicator from the stock engine jar.
        byte[] dupOriginal = null;
        try (ZipFile dupIn = new ZipFile(cfusionJar)) {
            ZipEntry e = dupIn.getEntry(OBJDUP_ENTRY);
            if (e == null) {
                throw new IllegalStateException("did not find " + OBJDUP_ENTRY + " in " + cfusionJar);
            }
            dupOriginal = readAll(dupIn.getInputStream(e));
        }
        byte[] dupPatched = v3Patch(dupOriginal);

        boolean sawObjDup = false;
        try (ZipFile in = new ZipFile(unlockedJar);
             ZipOutputStream out = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(outJar)))) {
            out.setLevel(Deflater.DEFAULT_COMPRESSION);
            Enumeration<? extends ZipEntry> entries = in.entries();
            while (entries.hasMoreElements()) {
                ZipEntry src = entries.nextElement();
                if (src.getName().equals(OBJDUP_ENTRY)) {
                    // The unlocked jar must not already carry ObjectDuplicator; if it does, the
                    // base jar is not what we think it is.
                    sawObjDup = true;
                    throw new IllegalStateException("the unlocked base jar already contains " + OBJDUP_ENTRY
                        + " — refusing, the base is not the expected v1-derived unlocked jar");
                }
                writeEntry(out, src, readAll(in.getInputStream(src)));
            }
            // Add the patched ObjectDuplicator as a new entry with a pinned timestamp.
            ZipEntry ne = new ZipEntry(OBJDUP_ENTRY);
            ne.setTime(FIXED_ENTRY_TIME);
            out.putNextEntry(ne);
            out.write(dupPatched);
            out.closeEntry();
        }
        if (sawObjDup) {
            throw new IllegalStateException("unreachable"); // the throw above already fired
        }
        System.out.println("Wrote " + outJar + "  (v3-combined: unlocked per-instance fixes + synchronized ObjectDuplicator)");
    }

    /**
     * Rename the private static _duplicate(Object, IdentityHashMap) to _duplicate0, then add a
     * new _duplicate with the same descriptor whose whole body is
     * `synchronized (ObjectDuplicator.class) { return _duplicate0(obj, refCache); }`.
     *
     * A per-object monitor (synchronized(obj)) was tried first and FAILED the cold gate: the
     * thread that structurally mutates the shared metadata map is not always duplicating the
     * same object reference, so locking on the object being copied never excluded it (see
     * docs/HOTFIX_V3_PHASE0_FINDINGS.md and the results doc). Phase 0 caught BOTH racing
     * threads inside ObjectDuplicator (one iterating the source, one writing it), so a single
     * class-level monitor serializes every deep copy against every other and closes the race.
     * The monitor is reentrant, so the whole recursive copy of one tree runs under one hold.
     */
    static byte[] v3Patch(byte[] original) {
        ClassNode cn = new ClassNode();
        new ClassReader(original).accept(cn, 0);

        if (!OBJDUP_OWNER.equals(cn.name)) {
            throw new IllegalStateException("expected class " + OBJDUP_OWNER + " but got " + cn.name);
        }

        // Locate the exact method to wrap, and refuse anything but the known pre-patch shape.
        MethodNode target = null;
        int hits = 0;
        for (MethodNode m : cn.methods) {
            if (m.name.equals("_duplicate0")) {
                throw new IllegalStateException("_duplicate0 already exists — jar is already v3-patched");
            }
            if (m.name.equals("_duplicate") && m.desc.equals(DUP_DESC)) {
                target = m;
                hits++;
            }
        }
        if (hits != 1) {
            throw new IllegalStateException(
                "expected exactly 1 _duplicate" + DUP_DESC + ", found " + hits
                + " — ObjectDuplicator shape changed; refusing to patch");
        }
        if ((target.access & Opcodes.ACC_STATIC) == 0) {
            throw new IllegalStateException("_duplicate is not static — unexpected shape");
        }

        // Rename the original body. Both methods live in ObjectDuplicator, so _duplicate0 can
        // stay private static; the same-class INVOKESTATIC below reaches it fine.
        target.name = "_duplicate0";

        // Preserve the checked-exception list so the delegator matches the original signature.
        java.util.List<String> exceptions =
            (target.exceptions != null) ? new ArrayList<>(target.exceptions) : new ArrayList<>();

        MethodNode del = new MethodNode(
            Opcodes.ASM9, Opcodes.ACC_PRIVATE | Opcodes.ACC_STATIC, "_duplicate", DUP_DESC, null,
            exceptions.toArray(new String[0]));

        LabelNode tryStart = new LabelNode();
        LabelNode tryEnd   = new LabelNode();
        LabelNode handler  = new LabelNode();
        LabelNode afterExit = new LabelNode();

        InsnList il = new InsnList();
        // lock = an interned String literal; monitorenter. A class-object monitor
        // (synchronized(ObjectDuplicator.class)) is NOT reliable here: when the overlay also
        // carries the core runtime classes, ObjectDuplicator can resolve through more than one
        // classloader, giving more than one Class object and more than one monitor. A String
        // LITERAL is interned once in the JVM-wide string pool, so every loader's copy of this
        // method locks the SAME object. This makes the lock truly global across classloaders.
        il.add(new LdcInsnNode(DUP_LOCK_STRING));
        il.add(new InsnNode(Opcodes.DUP));
        il.add(new VarInsnNode(Opcodes.ASTORE, 2));  // slot 2 = the monitor object (a String)
        il.add(new InsnNode(Opcodes.MONITORENTER));
        // try { return _duplicate0(obj, refCache); }
        il.add(tryStart);
        il.add(new VarInsnNode(Opcodes.ALOAD, 0));
        il.add(new VarInsnNode(Opcodes.ALOAD, 1));
        il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, OBJDUP_OWNER, "_duplicate0", DUP_DESC, false));
        il.add(new VarInsnNode(Opcodes.ALOAD, 2));
        il.add(new InsnNode(Opcodes.MONITOREXIT));
        il.add(tryEnd);
        il.add(new InsnNode(Opcodes.ARETURN));
        // catch (any) { monitorexit; throw; }
        il.add(handler);
        il.add(new FrameNode(Opcodes.F_FULL, 3,
            new Object[]{ "java/lang/Object", "java/util/IdentityHashMap", "java/lang/String" },
            1, new Object[]{ "java/lang/Throwable" }));
        il.add(new VarInsnNode(Opcodes.ASTORE, 3));  // slot 3 = the throwable
        il.add(new VarInsnNode(Opcodes.ALOAD, 2));
        il.add(new InsnNode(Opcodes.MONITOREXIT));
        il.add(afterExit);
        il.add(new VarInsnNode(Opcodes.ALOAD, 3));
        il.add(new InsnNode(Opcodes.ATHROW));
        del.instructions = il;

        del.tryCatchBlocks = new ArrayList<>();
        // body -> handler, and the handler's own monitorexit -> handler (mirrors javac).
        del.tryCatchBlocks.add(new TryCatchBlockNode(tryStart, tryEnd, handler, null));
        del.tryCatchBlocks.add(new TryCatchBlockNode(handler, afterExit, handler, null));
        del.maxStack  = 2;
        del.maxLocals = 4;

        cn.methods.add(del);

        ClassWriter cw = new ClassWriter(0); // manual frame provided; no COMPUTE_FRAMES needed
        cn.accept(cw);
        return cw.toByteArray();
    }

    // ---- trace: the diagnostic overlay ---------------------------------------------------

    /**
     * Build the trace overlay. Base is the "unlocked" jar (Adobe's v1 per-instance classes with
     * the global construction lock removed) because that is the build that still shows the ~4%
     * contamination — it is the thing we need to explain. The concurrent CaseInsensitiveMap from
     * --concmap is layered on so the cold-start cascade (a separate, already-solved race) does
     * not drown the run. The compiled ScopeTrace classes are added last.
     *
     * NOT SHIPPABLE. This jar exists to answer one question: which shared reference crosses?
     */
    static void writeTraceOverlay(String unlockedJar, String outJar, String cfusionJar, String supportDir,
            String extraJar) throws Exception {
        byte[] cimOriginal;
        try (ZipFile cimIn = new ZipFile(cfusionJar)) {
            ZipEntry e = cimIn.getEntry(CIMAP_ENTRY);
            if (e == null) {
                throw new IllegalStateException("did not find " + CIMAP_ENTRY + " in " + cfusionJar);
            }
            cimOriginal = readAll(cimIn.getInputStream(e));
        }
        byte[] cimPatched = concMapPatch(cimOriginal);

        // The ScopeTrace class plus its anonymous inner classes (the counter thread and the
        // shutdown hook). Collect them before touching the jar so a missing compile fails early.
        java.io.File supportRoot = new java.io.File(supportDir, "coldfusion/runtime");
        java.io.File[] supportFiles = supportRoot.listFiles();
        java.util.Map<String, byte[]> support = new java.util.LinkedHashMap<>();
        if (supportFiles != null) {
            for (java.io.File f : supportFiles) {
                String n = f.getName();
                if (n.equals("ScopeTrace.class") || n.startsWith("ScopeTrace$")) {
                    support.put("coldfusion/runtime/" + n, Files.readAllBytes(f.toPath()));
                }
            }
        }
        if (!support.containsKey(TRACE_ENTRY)) {
            throw new IllegalStateException("did not find compiled " + TRACE_ENTRY + " under " + supportDir
                + " — compile scripts/java/ScopeTrace.java first");
        }

        java.util.Set<String> instrumented = new java.util.HashSet<>();
        try (ZipFile in = new ZipFile(unlockedJar);
             ZipOutputStream out = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(outJar)))) {
            out.setLevel(Deflater.DEFAULT_COMPRESSION);
            Enumeration<? extends ZipEntry> entries = in.entries();
            while (entries.hasMoreElements()) {
                ZipEntry src = entries.nextElement();
                byte[] data = readAll(in.getInputStream(src));
                if (src.getName().equals(CIMAP_ENTRY) || support.containsKey(src.getName())) {
                    throw new IllegalStateException("the base jar already contains " + src.getName()
                        + " — it is not the expected unlocked jar; refusing");
                }
                for (String[] spec : TRACE_TARGETS) {
                    if (!src.getName().equals(spec[0])) continue;
                    data = instrumentClass(data, spec[1], spec);
                    instrumented.add(spec[0]);
                }
                writeEntry(out, src, data);
            }
            for (String[] spec : TRACE_TARGETS) {
                if (!instrumented.contains(spec[0])) {
                    throw new IllegalStateException("did not find " + spec[0] + " in " + unlockedJar
                        + " — the base jar is not the expected unlocked jar; refusing");
                }
            }
            ZipEntry cim = new ZipEntry(CIMAP_ENTRY);
            cim.setTime(FIXED_ENTRY_TIME);
            out.putNextEntry(cim);
            out.write(cimPatched);
            out.closeEntry();

            // Classes that are not in the hotfix jar have to be copied out of the stock Update
            // jar and instrumented on the way in.
            try (ZipFile extra = new ZipFile(extraJar)) {
                for (String[] spec : TRACE_EXTRA_TARGETS) {
                    ZipEntry src = extra.getEntry(spec[0]);
                    if (src == null) {
                        throw new IllegalStateException("did not find " + spec[0] + " in " + extraJar);
                    }
                    ZipEntry ne = new ZipEntry(spec[0]);
                    ne.setTime(FIXED_ENTRY_TIME);
                    out.putNextEntry(ne);
                    out.write(instrumentClass(readAll(extra.getInputStream(src)), spec[1], spec));
                    out.closeEntry();
                }
            }

            for (java.util.Map.Entry<String, byte[]> e : support.entrySet()) {
                ZipEntry ne = new ZipEntry(e.getKey());
                ne.setTime(FIXED_ENTRY_TIME);
                out.putNextEntry(ne);
                out.write(e.getValue());
                out.closeEntry();
            }
        }
        System.out.println("Wrote " + outJar + "  (trace: unlocked + concurrent CaseInsensitiveMap + ScopeTrace hooks)");
    }

    /**
     * Rename each named method to <name>$orig and put a wrapper in its place:
     *
     *     Result name(a, b) {
     *         Result r = name$orig(a, b);
     *         ScopeTrace.hook(this, new Object[]{ a, b }, r);
     *         return r;
     *     }
     *
     * The original keeps its own body and its own stack map frames, so renaming it is safe. The
     * wrapper is straight-line code with no branches and no exception handler, so it needs no
     * frames of its own — which is why ClassWriter(0) is enough and nothing here can produce an
     * unverifiable class.
     *
     * The renamed original is forced to PRIVATE and called with INVOKESPECIAL (or INVOKESTATIC),
     * so a subclass can never intercept the inner call. Callers elsewhere in the engine refer to
     * the method by its ORIGINAL name, so they land on the wrapper, which is the point.
     */
    static byte[] instrumentClass(byte[] original, String expectedOwner, String[] spec) {
        ClassNode cn = new ClassNode();
        new ClassReader(original).accept(cn, 0);
        if (!expectedOwner.equals(cn.name)) {
            throw new IllegalStateException("expected class " + expectedOwner + " but got " + cn.name);
        }

        // spec is { entry, owner, then (method, desc, hook) triples }.
        for (int i = 2; i + 2 < spec.length; i += 3) {
            String name = spec[i];
            String desc = spec[i + 1];
            String hook = spec[i + 2];
            // A hook tagged "PRE:name" runs BEFORE the original (a pre-hook). Frames that must
            // observe an argument on the way IN — before a nested call can finish and its objects
            // be cleaned up — use this, so the trace sees the struct while its owner is still live.
            boolean preHook = hook.startsWith("PRE:");
            if (preHook) hook = hook.substring(4);
            String orig = name + "$orig";

            MethodNode target = null;
            int hits = 0;
            for (MethodNode m : cn.methods) {
                // Overloads share a name (two invoke() entries are instrumented), so the
                // "already patched" check has to match on the descriptor too.
                if (m.name.equals(orig) && m.desc.equals(desc)) {
                    throw new IllegalStateException(orig + desc + " already exists in " + cn.name
                        + " — this jar is already instrumented; refusing");
                }
                if (m.name.equals(name) && m.desc.equals(desc)) {
                    target = m;
                    hits++;
                }
            }
            if (hits != 1) {
                throw new IllegalStateException("expected exactly 1 " + cn.name + "." + name + desc
                    + ", found " + hits + " — engine shape changed; refusing to patch");
            }

            int access = target.access;
            boolean isStatic = (access & Opcodes.ACC_STATIC) != 0;
            String[] thrown = (target.exceptions != null)
                ? target.exceptions.toArray(new String[0]) : new String[0];

            target.name = name + "$orig";
            target.access = (access & ~(Opcodes.ACC_PUBLIC | Opcodes.ACC_PROTECTED)) | Opcodes.ACC_PRIVATE;

            Type[] argTypes = Type.getArgumentTypes(desc);
            Type retType = Type.getReturnType(desc);
            int firstArgSlot = isStatic ? 0 : 1;

            MethodNode w = new MethodNode(Opcodes.ASM9, access, name, desc, target.signature, thrown);
            InsnList il = new InsnList();

            if (preHook) {
                // hook( self, boxed-args, null ) BEFORE the original runs, then call the original
                // and hand back exactly what it returns. Still straight-line: no branch, no frame.
                if (isStatic) il.add(new InsnNode(Opcodes.ACONST_NULL));
                else il.add(new VarInsnNode(Opcodes.ALOAD, 0));
                il.add(intConst(argTypes.length));
                il.add(new TypeInsnNode(Opcodes.ANEWARRAY, "java/lang/Object"));
                int ps = firstArgSlot;
                for (int a = 0; a < argTypes.length; a++) {
                    Type t = argTypes[a];
                    il.add(new InsnNode(Opcodes.DUP));
                    il.add(intConst(a));
                    il.add(new VarInsnNode(t.getOpcode(Opcodes.ILOAD), ps));
                    box(il, t);
                    il.add(new InsnNode(Opcodes.AASTORE));
                    ps += t.getSize();
                }
                il.add(new InsnNode(Opcodes.ACONST_NULL));   // result not known yet
                il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, TRACE_OWNER, hook, HOOK_DESC, false));

                if (!isStatic) il.add(new VarInsnNode(Opcodes.ALOAD, 0));
                ps = firstArgSlot;
                for (Type t : argTypes) {
                    il.add(new VarInsnNode(t.getOpcode(Opcodes.ILOAD), ps));
                    ps += t.getSize();
                }
                il.add(new MethodInsnNode(
                    isStatic ? Opcodes.INVOKESTATIC : Opcodes.INVOKESPECIAL, cn.name, orig, desc, false));
                if (retType.getSort() == Type.VOID) il.add(new InsnNode(Opcodes.RETURN));
                else il.add(new InsnNode(retType.getOpcode(Opcodes.IRETURN)));

                w.instructions = il;
                w.maxLocals = ps;
                int cs = isStatic ? 0 : 1;
                for (Type t : argTypes) cs += t.getSize();
                w.maxStack = Math.max(cs, 6) + 2;
                cn.methods.add(w);
                continue;
            }

            // 1. call the original and keep its result
            if (!isStatic) il.add(new VarInsnNode(Opcodes.ALOAD, 0));
            int slot = firstArgSlot;
            for (Type t : argTypes) {
                il.add(new VarInsnNode(t.getOpcode(Opcodes.ILOAD), slot));
                slot += t.getSize();
            }
            il.add(new MethodInsnNode(
                isStatic ? Opcodes.INVOKESTATIC : Opcodes.INVOKESPECIAL, cn.name, orig, desc, false));
            int resultSlot = slot;
            int maxLocals = slot;
            if (retType.getSort() != Type.VOID) {
                il.add(new VarInsnNode(retType.getOpcode(Opcodes.ISTORE), resultSlot));
                maxLocals = resultSlot + retType.getSize();
            }

            // 2. self
            if (isStatic) il.add(new InsnNode(Opcodes.ACONST_NULL));
            else il.add(new VarInsnNode(Opcodes.ALOAD, 0));

            // 3. the arguments, boxed, as an Object[]
            il.add(intConst(argTypes.length));
            il.add(new TypeInsnNode(Opcodes.ANEWARRAY, "java/lang/Object"));
            slot = firstArgSlot;
            for (int a = 0; a < argTypes.length; a++) {
                Type t = argTypes[a];
                il.add(new InsnNode(Opcodes.DUP));
                il.add(intConst(a));
                il.add(new VarInsnNode(t.getOpcode(Opcodes.ILOAD), slot));
                box(il, t);
                il.add(new InsnNode(Opcodes.AASTORE));
                slot += t.getSize();
            }

            // 4. the result, boxed (null for a void method)
            if (retType.getSort() == Type.VOID) {
                il.add(new InsnNode(Opcodes.ACONST_NULL));
            } else {
                il.add(new VarInsnNode(retType.getOpcode(Opcodes.ILOAD), resultSlot));
                box(il, retType);
            }
            il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, TRACE_OWNER, hook, HOOK_DESC, false));

            // 5. hand back exactly what the original returned
            if (retType.getSort() == Type.VOID) {
                il.add(new InsnNode(Opcodes.RETURN));
            } else {
                il.add(new VarInsnNode(retType.getOpcode(Opcodes.ILOAD), resultSlot));
                il.add(new InsnNode(retType.getOpcode(Opcodes.IRETURN)));
            }

            w.instructions = il;
            w.maxLocals = maxLocals;
            int callStack = (isStatic ? 0 : 1);
            for (Type t : argTypes) callStack += t.getSize();
            w.maxStack = Math.max(callStack, 6) + 2;   // 6 = self + array + dup + index + wide value
            cn.methods.add(w);
        }

        ClassWriter cw = new ClassWriter(0); // straight-line wrappers only; no frames to compute
        cn.accept(cw);
        return cw.toByteArray();
    }

    /** Smallest instruction that pushes a small non-negative int constant. */
    static AbstractInsnNode intConst(int v) {
        if (v >= -1 && v <= 5) return new InsnNode(Opcodes.ICONST_0 + v);
        if (v >= Byte.MIN_VALUE && v <= Byte.MAX_VALUE) return new IntInsnNode(Opcodes.BIPUSH, v);
        if (v >= Short.MIN_VALUE && v <= Short.MAX_VALUE) return new IntInsnNode(Opcodes.SIPUSH, v);
        return new LdcInsnNode(Integer.valueOf(v));
    }

    /** Box a primitive on the stack so it can go into an Object[]. Reference types are left alone. */
    static void box(InsnList il, Type t) {
        switch (t.getSort()) {
            case Type.BOOLEAN: il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Boolean",   "valueOf", "(Z)Ljava/lang/Boolean;",   false)); break;
            case Type.BYTE:    il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Byte",      "valueOf", "(B)Ljava/lang/Byte;",      false)); break;
            case Type.CHAR:    il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Character", "valueOf", "(C)Ljava/lang/Character;", false)); break;
            case Type.SHORT:   il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Short",     "valueOf", "(S)Ljava/lang/Short;",     false)); break;
            case Type.INT:     il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Integer",   "valueOf", "(I)Ljava/lang/Integer;",   false)); break;
            case Type.FLOAT:   il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Float",     "valueOf", "(F)Ljava/lang/Float;",     false)); break;
            case Type.LONG:    il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Long",      "valueOf", "(J)Ljava/lang/Long;",      false)); break;
            case Type.DOUBLE:  il.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Double",    "valueOf", "(D)Ljava/lang/Double;",    false)); break;
            default: break; // already a reference
        }
    }

    // ---- helpers ------------------------------------------------------------------------

    static MethodNode findWrapper(ClassNode cn) {
        MethodNode found = null;
        int hits = 0;
        for (MethodNode m : cn.methods) {
            if (m.name.equals("resolveName")
                && m.desc.equals(DESC8)
                && (m.access & Opcodes.ACC_STATIC) != 0
                && (m.access & Opcodes.ACC_PUBLIC) != 0) {
                found = m;
                hits++;
            }
        }
        if (hits != 1) {
            throw new IllegalStateException(
                "expected exactly 1 public static 8-arg resolveName wrapper, found " + hits
                + " — the hotfix shape changed; refusing to patch");
        }
        return found;
    }

    /** Guard: the input really is the locked wrapper, not an already-patched or foreign jar. */
    static void assertWrapperShape(MethodNode m) {
        boolean hasMonitorEnter = false;
        boolean callsLocked = false;
        for (AbstractInsnNode insn = m.instructions.getFirst(); insn != null; insn = insn.getNext()) {
            if (insn.getOpcode() == Opcodes.MONITORENTER) {
                hasMonitorEnter = true;
            }
            if (insn.getOpcode() == Opcodes.INVOKESTATIC) {
                MethodInsnNode mi = (MethodInsnNode) insn;
                if (mi.owner.equals(OWNER) && mi.name.equals("resolveNameLocked") && mi.desc.equals(DESC8)) {
                    callsLocked = true;
                }
            }
        }
        if (!hasMonitorEnter) {
            throw new IllegalStateException("resolveName wrapper has no monitorenter — already patched or a different hotfix?");
        }
        if (!callsLocked) {
            throw new IllegalStateException("resolveName wrapper does not call resolveNameLocked — unexpected shape");
        }
    }

    static void writeEntry(ZipOutputStream out, ZipEntry src, byte[] data) throws IOException {
        ZipEntry dst = new ZipEntry(src.getName());
        if (src.getTime() != -1L) {
            dst.setTime(src.getTime());
        }
        if (src.getMethod() == ZipEntry.STORED) {
            dst.setMethod(ZipEntry.STORED);
            dst.setSize(data.length);
            dst.setCompressedSize(data.length);
            CRC32 crc = new CRC32();
            crc.update(data);
            dst.setCrc(crc.getValue());
        } else {
            dst.setMethod(ZipEntry.DEFLATED);
        }
        out.putNextEntry(dst);
        out.write(data);
        out.closeEntry();
    }

    static byte[] readAll(InputStream is) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = is.read(buf)) != -1) {
            bos.write(buf, 0, n);
        }
        is.close();
        return bos.toByteArray();
    }

    private PatchHotfix() {}
}
