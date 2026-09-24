package coldfusion.runtime;

import java.io.File;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Per-component construction lock, used ONLY by the "stripe" fallback of PatchHotfix.
 *
 * Adobe's hotfix serialized all CFC construction on one JVM-wide monitor. If removing that
 * monitor entirely ever reintroduces contamination, the stripe fallback keeps a monitor but
 * makes it per-component: different components construct concurrently, while two threads
 * building the SAME component still serialize. This mirrors the Update-22 per-component
 * double-checked locking granularity.
 *
 * lockFor returns a stable Object per (component name + file path). computeIfAbsent gives
 * atomic get-or-create with no hand-written branch bytecode. The map is never cleared: the
 * number of distinct component paths in an application is bounded and small relative to heap.
 *
 * This class depends only on JDK types, so it compiles with a bare javac (no ACF classpath).
 */
public final class ConstructionLockSupport {

    private static final ConcurrentHashMap<String, Object> LOCKS = new ConcurrentHashMap<String, Object>();

    public static Object lockFor(String fullName, File file) {
        String key = String.valueOf(fullName) + "|" + (file == null ? "" : file.getPath());
        return LOCKS.computeIfAbsent(key, k -> new Object());
    }

    private ConstructionLockSupport() {}
}
