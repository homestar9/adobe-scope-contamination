import java.util.zip.ZipFile;

/**
 * Loads every class in an overlay jar through a throwaway classloader so the JVM's bytecode
 * verifier runs on it. Used by Build-UnlockedJar.ps1 before any patched jar is trusted.
 * Usage: OverlayVerify <overlay.jar> <entry> [<entry> ...]
 */
public class OverlayVerify extends ClassLoader {
    public static void main(String[] a) throws Exception {
        try (ZipFile z = new ZipFile(a[0])) {
            for (int i = 1; i < a.length; i++) {
                byte[] b = z.getInputStream(z.getEntry(a[i])).readAllBytes();
                String cls = a[i].substring(0, a[i].length() - ".class".length()).replace('/', '.');
                OverlayVerify v = new OverlayVerify();
                Class<?> c = v.defineClass(cls, b, 0, b.length);
                v.resolveClass(c);
                System.out.println("VERIFIED " + cls);
            }
        }
        System.out.println("VERIFY OK");
    }
}
