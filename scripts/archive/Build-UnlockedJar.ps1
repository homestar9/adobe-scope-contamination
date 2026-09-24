<#
.SYNOPSIS
    Builds a de-locked copy of Adobe's hotfix jar and statically verifies it.

.DESCRIPTION
    Adobe's hotfix hf202300-4232227 fixes the cross-scope contamination bug but wraps ALL CFC
    name resolution in one JVM-wide `synchronized (CONSTRUCTION_LOCK)` monitor, which serializes
    every `new SomeComponent()` and cuts throughput by up to ~72% under concurrency
    (docs/adobe-hotfixes/1-first-hotfix-static-analysis.md, docs/adobe-hotfixes/1-first-hotfix-performance.md).

    This script runs scripts/java/PatchHotfix.java (ASM Tree) to rewrite ONLY the public
    resolveName wrapper so it calls the private resolveNameLocked directly, with no monitor.
    Every other jar entry - including the three classes that carry the actual per-instance
    correctness fix (TemplateProxy, UDFMethod, Closure) - is copied byte-for-byte.

    It then statically verifies the result before you are allowed to trust it:
      * TemplateProxyFactory has exactly 2 monitorenter / 4 monitorexit (the surviving
        per-component double-checked locks inside resolveNameLocked), matching the Update-22
        baseline. The wrapper itself has 0 monitorenter.
      * Only coldfusion/runtime/TemplateProxyFactory.class differs from the original jar;
        the other 53 entries are hash-identical.
      * It prints the SHA256 of the modified jar for the audit trail.

    This does NOT prove correctness or measure throughput. That is the job of the benchmark
    arms: Install-BenchmarkArms.ps1 -> Invoke-Benchmark.ps1 / Get-LockEvidence.ps1, plus the
    /repro contamination gate. See the plan and docs/UNLOCKED_JAR_BUILD.md.

.PARAMETER Stripe
    Build the per-component "lock striping" fallback instead of removing the lock entirely.
    Use this only if the correctness gate shows the fully-unlocked jar reintroduces
    contamination. Produces hf202300-4232227-stripe.jar and embeds ConstructionLockSupport.

.PARAMETER V3
    Build the v3 fix. This is a different fix at a different place. Phase 0/1 showed the real
    race is in ColdFusion's Duplicate() (coldfusion.runtime.ObjectDuplicator), which reads and
    lazily writes the SOURCE object during a deep copy; two entity constructions duplicating
    the same shared BaseEntity metadata tear it. v3 reads ObjectDuplicator out of the stock
    engine's cfusion.jar, wraps its private _duplicate in `synchronized (obj)`, and writes a
    tiny OVERLAY jar (hf202300-4232227-v3.jar) that contains only that one patched class. The
    overlay deploys as hf202300-4232227.jar and the bootstrap loads it ahead of cfusion.jar,
    so only ObjectDuplicator changes and the rest of Update 23 is untouched. Mutually exclusive
    with -Stripe. See docs/HOTFIX_V3_PHASE0_FINDINGS.md.

.EXAMPLE
    .\scripts\Build-UnlockedJar.ps1

.EXAMPLE
    .\scripts\Build-UnlockedJar.ps1 -Stripe

.PARAMETER V3Combined
    Build the combined v3 fix: the "unlocked" jar's four per-instance scope fixes
    (TemplateProxyFactory/TemplateProxy/UDFMethod/Closure, construction lock already removed)
    PLUS the synchronized ObjectDuplicator. This addresses BOTH races found in testing: the
    per-instance fixes for the variables-scope contamination, the ObjectDuplicator global
    monitor for the metadata-duplication cascade. Requires the unlocked jar to exist first
    (build it with no switch). Produces hf202300-4232227-v3.jar. See docs/HOTFIX_V3_RESULTS.md.

.PARAMETER ConcMapV1
    Build the shippable fallback: Adobe's ORIGINAL v1 hotfix jar (per-instance fixes AND the
    global construction lock, untouched) plus the concurrent CaseInsensitiveMap from -ConcMap.
    The lock closes race 2 (~1/20k residual); the concurrent map makes the race-1 duplication
    tear structurally impossible even if the lock ever has a gap. Produces
    hf202300-4232227-concmap-v1.jar. Strictly safer than v1 alone.

.EXAMPLE
    .\scripts\Build-UnlockedJar.ps1 -V3

.EXAMPLE
    .\scripts\Build-UnlockedJar.ps1 -V3Combined

.PARAMETER Trace
    Build the DIAGNOSTIC jar. It changes no behavior. It renames a few engine methods to
    <name>$orig, puts a thin wrapper in their place, and has each wrapper report the object
    identities it saw to coldfusion.runtime.ScopeTrace.

    Why it exists: the earlier fix attempts each guessed which shared reference crosses between
    two concurrent CFC constructions, patched it, and the contamination rate did not move. This
    build answers the question from a running server instead of from reading bytecode.

    Base is the unlocked jar (v1's per-instance classes, no construction lock) because that is
    the build that still shows the ~4% contamination. The concurrent CaseInsensitiveMap is
    layered on so the already-solved cold-start cascade does not drown the run.

    The jar is inert unless the server is started with -Dcfscope.trace=<file>. It is a
    measuring tool, never a shipped fix. Produces hf202300-4232227-trace.jar.

.EXAMPLE
    .\scripts\Build-UnlockedJar.ps1 -ConcMapV1

.EXAMPLE
    .\scripts\Build-UnlockedJar.ps1 -Trace
#>
[CmdletBinding()]
param(
    [switch] $Stripe,
    [switch] $V3,
    [switch] $V3Combined,
    [switch] $ConcMap,
    [switch] $ConcMapCombined,
    [switch] $ConcMapV1,
    [switch] $Trace,
    [switch] $TraceLocked
)

$ErrorActionPreference = 'Stop'

if ( ( @( $Stripe, $V3, $V3Combined, $ConcMap, $ConcMapCombined, $ConcMapV1, $Trace, $TraceLocked ) | Where-Object { $_ } ).Count -gt 1 ) {
    throw "-Stripe, -V3, -V3Combined, -ConcMap, -ConcMapCombined, -ConcMapV1, -Trace, and -TraceLocked are mutually exclusive."
}
$anyV3 = $V3 -or $V3Combined
# concmap builds are overlays too (patch CaseInsensitiveMap from cfusion.jar); they share the
# overlay packaging + cfusion base-SHA pin but have their own verification (see below).
$anyConc = $ConcMap -or $ConcMapCombined -or $ConcMapV1

$repoRoot    = Split-Path -Parent $PSScriptRoot
$toolsDir    = Join-Path $repoRoot 'tools'
$buildDir    = Join-Path $repoRoot 'build\patchtool'
$javaSrcDir  = Join-Path $repoRoot 'scripts\java'

# v3 patches a class in the stock engine's cfusion.jar, not Adobe's hotfix jar. Pin the base
# jar's SHA so a re-installed or different engine can never silently change what we patch.
$cfusionJar    = Join-Path $repoRoot '.engine\bench-u23\WEB-INF\cfusion\lib\cfusion.jar'
$cfusionJarSha = '7070D953E612E550D5DD524EFECD9E4D75B76C6A83F9C17AB0180AAD89BF3025'
# Stock Update 23. Only needed on the classpath when verifying a patched class loads: some of
# the classes a patched class links against live here rather than in cfusion.jar.
$chfJar        = Join-Path $repoRoot '.engine\bench-u23\WEB-INF\cfusion\lib\updates\chf20230023.jar'
# The audited unlocked jar (base for the combined build): v1's four per-instance fixes, no lock.
$unlockedJar    = Join-Path $repoRoot 'hotfixes\hf202300-4232227-unlocked.jar'
$unlockedJarSha = '1674130D487807C4A75CBF59EC48DB95883C51020AE1C1E4EEBFD5678DF0BC85'
# Adobe's original v1 hotfix jar (base for the concmap-v1 fallback): per-instance fixes AND the
# global construction lock, untouched.
$v1Jar    = Join-Path $repoRoot 'hotfixes\hf202300-4232227.jar'
$v1JarSha = '7B586D55814B120FB818EAB7EF16DD83336449A6088162D627F114A6CC352C56'

# -TraceLocked is the negative control: the same instrumentation on Adobe's LOCKED v1 jar.
# If the crossings the diagnostic reports are the real bug, they must disappear when the lock
# that is known to stop the bug is switched on. If they do not, the detector is measuring
# something normal and its numbers mean nothing.
$anyTrace = $Trace -or $TraceLocked
if ( $anyTrace ) {
    $inputJar = if ( $TraceLocked ) { $v1Jar } else { $unlockedJar }
    $outName  = if ( $TraceLocked ) { 'hf202300-4232227-trace-locked.jar' } else { 'hf202300-4232227-trace.jar' }
} elseif ( $V3 -or $ConcMap ) {
    $inputJar = $cfusionJar
    $outName  = 'hf202300-4232227-v3.jar'
} elseif ( $V3Combined -or $ConcMapCombined ) {
    $inputJar = $unlockedJar
    $outName  = 'hf202300-4232227-v3.jar'
} elseif ( $ConcMapV1 ) {
    $inputJar = $v1Jar
    $outName  = 'hf202300-4232227-concmap-v1.jar'
} else {
    $inputJar = Join-Path $repoRoot 'hotfixes\hf202300-4232227.jar'
    $outName  = if ( $Stripe ) { 'hf202300-4232227-stripe.jar' } else { 'hf202300-4232227-unlocked.jar' }
}
$hotfixJar = $inputJar   # kept for the legacy (non-V3) verification block below
$outJar    = Join-Path $repoRoot "hotfixes\$outName"

if ( -not ( Test-Path $inputJar ) ) {
    if ( $anyTrace ) { throw "Unlocked jar not found at $inputJar. Build it first with: .\scripts\Build-UnlockedJar.ps1" }
    if ( $V3 -or $ConcMap ) { throw "Stock engine cfusion.jar not found at $inputJar. Run .\scripts\Install-U23BenchmarkArms.ps1 first." }
    if ( $V3Combined -or $ConcMapCombined ) { throw "Unlocked jar not found at $inputJar. Build it first with: .\scripts\Build-UnlockedJar.ps1" }
    if ( $ConcMapV1 ) { throw "Adobe v1 hotfix jar not found at $inputJar." }
    throw "Adobe hotfix jar not found at $inputJar"
}
if ( $anyV3 -or $anyConc -or $anyTrace ) {
    # All overlay builds patch a class out of cfusion.jar, so its SHA is always pinned.
    if ( -not ( Test-Path $cfusionJar ) ) { throw "Stock engine cfusion.jar not found at $cfusionJar. Run .\scripts\Install-U23BenchmarkArms.ps1 first." }
    $baseSha = ( Get-FileHash -Algorithm SHA256 $cfusionJar ).Hash
    if ( $baseSha -ne $cfusionJarSha ) {
        throw "cfusion.jar SHA $baseSha does not match the pinned $cfusionJarSha. The engine base changed; re-review the patch before trusting it."
    }
}
if ( $V3Combined -or $ConcMapCombined -or $Trace ) {
    $baseUnlSha = ( Get-FileHash -Algorithm SHA256 $unlockedJar ).Hash
    if ( $baseUnlSha -ne $unlockedJarSha ) {
        throw "The unlocked base jar SHA $baseUnlSha does not match the audited $unlockedJarSha. Rebuild it with .\scripts\Build-UnlockedJar.ps1 before combining."
    }
}
if ( $TraceLocked ) {
    # The negative control instruments Adobe's own locked jar, so that is the base to pin.
    $baseV1TraceSha = ( Get-FileHash -Algorithm SHA256 $v1Jar ).Hash
    if ( $baseV1TraceSha -ne $v1JarSha ) {
        throw "The v1 base jar SHA $baseV1TraceSha does not match the pinned $v1JarSha. The Adobe hotfix jar changed; re-review before trusting it."
    }
}
if ( $ConcMapV1 ) {
    $baseV1Sha = ( Get-FileHash -Algorithm SHA256 $v1Jar ).Hash
    if ( $baseV1Sha -ne $v1JarSha ) {
        throw "The v1 base jar SHA $baseV1Sha does not match the pinned $v1JarSha. The Adobe hotfix jar changed; re-review before trusting it."
    }
}

# ---------------------------------------------------------------- locate a JDK 17
$jdkRoot = Join-Path $env:USERPROFILE '.CommandBox\serverJREs'
$javac = Get-ChildItem -Path $jdkRoot -Filter 'javac.exe' -Recurse -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -match 'openjdk17_jdk' } |
         Sort-Object FullName -Descending | Select-Object -First 1
if ( -not $javac ) {
    throw "No openjdk17_jdk found under $jdkRoot. Install one with:`n  box java install openjdk17_jdk"
}
$jdkBin = Split-Path -Parent $javac.FullName
$javacExe = Join-Path $jdkBin 'javac.exe'
$javaExe  = Join-Path $jdkBin 'java.exe'
$javapExe = Join-Path $jdkBin 'javap.exe'
Write-Host "JDK: $jdkBin" -ForegroundColor Cyan

# ---------------------------------------------------------------- ensure ASM present
$asm     = Join-Path $toolsDir 'asm-9.7.jar'
$asmTree = Join-Path $toolsDir 'asm-tree-9.7.jar'
if ( -not ( Test-Path $asm ) -or -not ( Test-Path $asmTree ) ) {
    Write-Host "ASM jars missing, fetching via Get-BenchmarkTools.ps1..." -ForegroundColor Yellow
    & ( Join-Path $PSScriptRoot 'Get-BenchmarkTools.ps1' )
}
if ( -not ( Test-Path $asm ) -or -not ( Test-Path $asmTree ) ) {
    throw "ASM jars still missing in $toolsDir. Check scripts/tool-versions.json and network access."
}
$asmCp = "$asm;$asmTree"

# ---------------------------------------------------------------- compile the patcher
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$srcFiles = @( Join-Path $javaSrcDir 'PatchHotfix.java' )
if ( $Stripe ) { $srcFiles += Join-Path $javaSrcDir 'ConstructionLockSupport.java' }
# The trace build needs the logging helper (it goes INTO the jar) and the verifier (it checks
# the jar afterwards). Both compile with a bare javac; neither needs the ACF classpath.
if ( $anyTrace ) { $srcFiles += ( Join-Path $javaSrcDir 'ScopeTrace.java' ), ( Join-Path $javaSrcDir 'OverlayVerify.java' ) }

Write-Host "`n=== Compiling patcher ===" -ForegroundColor Cyan
& $javacExe -cp $asmCp -d $buildDir @srcFiles
if ( $LASTEXITCODE -ne 0 ) { throw "javac failed" }
Write-Host "compiled OK"

# ---------------------------------------------------------------- run the patch
$mode = if ( $TraceLocked ) { 'trace-locked' } elseif ( $Trace ) { 'trace' } elseif ( $V3 ) { 'v3' } elseif ( $V3Combined ) { 'v3-combined' } elseif ( $ConcMap ) { 'concmap' } elseif ( $ConcMapCombined ) { 'concmap-combined' } elseif ( $ConcMapV1 ) { 'concmap-v1' } elseif ( $Stripe ) { 'stripe' } else { 'full-removal' }
Write-Host "`n=== Patching jar ($mode) ===" -ForegroundColor Cyan
if ( $anyTrace ) {
    & $javaExe -cp "$buildDir;$asmCp" PatchHotfix $inputJar $outJar --trace --dup-from $cfusionJar --trace-support $buildDir --trace-extra $chfJar
} elseif ( $V3 ) {
    & $javaExe -cp "$buildDir;$asmCp" PatchHotfix $inputJar $outJar --v3
} elseif ( $V3Combined ) {
    & $javaExe -cp "$buildDir;$asmCp" PatchHotfix $inputJar $outJar --v3-combined --dup-from $cfusionJar
} elseif ( $ConcMap ) {
    & $javaExe -cp "$buildDir;$asmCp" PatchHotfix $inputJar $outJar --concmap
} elseif ( $ConcMapCombined ) {
    & $javaExe -cp "$buildDir;$asmCp" PatchHotfix $inputJar $outJar --concmap-combined --dup-from $cfusionJar
} elseif ( $ConcMapV1 ) {
    & $javaExe -cp "$buildDir;$asmCp" PatchHotfix $inputJar $outJar --concmap-v1 --dup-from $cfusionJar
} elseif ( $Stripe ) {
    $lockClass = Join-Path $buildDir 'coldfusion\runtime\ConstructionLockSupport.class'
    if ( -not ( Test-Path $lockClass ) ) { throw "ConstructionLockSupport.class not produced at $lockClass" }
    & $javaExe -cp "$buildDir;$asmCp" PatchHotfix $inputJar $outJar --stripe $lockClass
} else {
    & $javaExe -cp "$buildDir;$asmCp" PatchHotfix $inputJar $outJar
}
if ( $LASTEXITCODE -ne 0 ) { throw "PatchHotfix failed" }

# ---------------------------------------------------------------- trace verification
if ( $anyTrace ) {
    Write-Host "`n=== Verifying $outName (diagnostic overlay) ===" -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [System.IO.Compression.ZipFile]::OpenRead( $outJar )
    $names = @( $zip.Entries | ForEach-Object { $_.FullName } )
    $zip.Dispose()

    # The logging helper and its two inner classes (counter thread, shutdown hook) must be here,
    # or the patched engine classes would call a class that does not exist.
    foreach ( $c in @( 'coldfusion/runtime/ScopeTrace.class', 'coldfusion/util/CaseInsensitiveMap.class' ) ) {
        if ( $names -notcontains $c ) { throw "trace overlay is missing $c." }
    }
    $inner = @( $names | Where-Object { $_ -like 'coldfusion/runtime/ScopeTrace$*' } ).Count
    if ( $inner -lt 1 ) { throw "trace overlay has no ScopeTrace inner classes; the helper was not compiled fully." }

    # Every instrumented method must now exist twice: the wrapper under the original name, and
    # the untouched original under <name>$orig. If a $orig is missing the hook never runs.
    $expect = @(
        @{ Class = 'coldfusion.runtime.UDFMethod';            Methods = @( 'resolveInvocationSuperScope$orig', 'setSuperScope$orig' ) },
        @{ Class = 'coldfusion.runtime.TemplateProxy';        Methods = @( 'getBoundSuperScopeForLevel$orig', 'setupScopesForInvoke$orig' ) },
        @{ Class = 'coldfusion.runtime.TemplateProxyFactory'; Methods = @( 'setupThisAndSuper$orig', 'resolveName$orig' ) },
        @{ Class = 'coldfusion.runtime.NeoPageContext';       Methods = @( 'pushNewFunctionLocalScope$orig', 'getActiveFunctionLocalScope$orig', 'setupThreadLocalScope$orig' ) },
        @{ Class = 'coldfusion.runtime.CFPage';               Methods = @( 'StructNew$orig', 'Duplicate$orig', 'invoke$orig' ) }
    )
    foreach ( $e in $expect ) {
        $dis = & $javapExe -p -c -classpath "$outJar;$cfusionJar" $e.Class
        foreach ( $m in $e.Methods ) {
            if ( -not ( $dis | Select-String -SimpleMatch $m ) ) {
                throw "$( $e.Class ) has no $m — the instrumentation did not apply. Refusing."
            }
        }
        if ( -not ( $dis | Select-String -SimpleMatch 'coldfusion/runtime/ScopeTrace' ) ) {
            throw "$( $e.Class ) never calls ScopeTrace — the instrumentation did not apply. Refusing."
        }
        Write-Host "  $( $e.Class ): wrappers in place, originals kept as `$orig." -ForegroundColor Green
    }

    # And it all has to pass the JVM's own bytecode verifier before anyone runs a server on it.
    Write-Host "  Verifying every patched class loads under -Xverify:all..."
    $verifyEntries = @(
        'coldfusion/runtime/UDFMethod.class',
        'coldfusion/runtime/TemplateProxy.class',
        'coldfusion/runtime/TemplateProxyFactory.class',
        'coldfusion/runtime/NeoPageContext.class',
        'coldfusion/runtime/CFPage.class',
        'coldfusion/util/CaseInsensitiveMap.class',
        'coldfusion/runtime/ScopeTrace.class'
    )
    # NeoPageContext extends javax.servlet.jsp.PageContext, and ColdFusion does not ship the JSP
    # API itself — the servlet container provides it at runtime. CommandBox's Runwar jar has it,
    # so borrow it just for this check. Without it the class cannot link and the check would fail
    # for a reason that has nothing to do with the patch.
    $jspApi = Get-ChildItem -Path ( Join-Path $env:USERPROFILE '.CommandBox\lib' ) -Filter 'runwar-legacy-*.jar' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    $verifyCp = "$buildDir;$chfJar;$cfusionJar"
    if ( $jspApi ) { $verifyCp = "$verifyCp;$($jspApi.FullName)" }
    else { Write-Host "  (no Runwar jar found for the JSP API; NeoPageContext may not link)" -ForegroundColor Yellow }
    $verifyOut = & $javaExe -Xverify:all -cp $verifyCp OverlayVerify $outJar @verifyEntries 2>&1
    if ( $LASTEXITCODE -ne 0 -or -not ( $verifyOut | Select-String -SimpleMatch 'VERIFY OK' ) ) {
        throw "trace overlay failed bytecode verification:`n$verifyOut"
    }
    Write-Host "  All patched classes verify and load cleanly." -ForegroundColor Green

    $sha = ( Get-FileHash -Algorithm SHA256 $outJar ).Hash
    Write-Host "`nBuilt $outJar" -ForegroundColor Green
    Write-Host "SHA256: $sha" -ForegroundColor Green
    Write-Host "`nThis jar is a MEASURING TOOL, never a fix. It does nothing unless the server runs with" -ForegroundColor Yellow
    Write-Host "  -Dcfscope.trace=<path to a .tsv file>" -ForegroundColor Yellow
    Write-Host "Next: paste this SHA into `$traceJarSha in Install-U23BenchmarkArms.ps1, then run that script." -ForegroundColor Cyan
    return
}

# ---------------------------------------------------------------- concmap verification
if ( $anyConc ) {
    Write-Host "`n=== Verifying $outName (overlay, $mode) ===" -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead( $outJar )
    $names = @( $zip.Entries | ForEach-Object { $_.FullName } )
    $zip.Dispose()

    if ( $ConcMap ) {
        if ( $names.Count -ne 1 -or $names[0] -ne 'coldfusion/util/CaseInsensitiveMap.class' ) {
            throw "concmap overlay must contain exactly coldfusion/util/CaseInsensitiveMap.class, but has:`n  $( $names -join "`n  " )"
        }
    } else {
        if ( $names -notcontains 'coldfusion/util/CaseInsensitiveMap.class' ) {
            throw "$mode overlay is missing the patched CaseInsensitiveMap.class."
        }
        foreach ( $c in @( 'coldfusion/runtime/TemplateProxyFactory.class', 'coldfusion/runtime/TemplateProxy.class', 'coldfusion/runtime/UDFMethod.class', 'coldfusion/runtime/Closure.class' ) ) {
            if ( $names -notcontains $c ) { throw "$mode overlay is missing the per-instance fix class $c." }
        }
        # The two combined bases differ in lock shape: the unlocked base has 2 monitorenter
        # (the per-component double-checked locks only); the v1 base keeps the global
        # construction lock in the resolveName wrapper for a total of 3.
        $tpfDis   = & $javapExe -p -c -classpath $outJar coldfusion.runtime.TemplateProxyFactory
        $tpfEnter = ( $tpfDis | Select-String -SimpleMatch 'monitorenter' ).Count
        $tpfWant  = if ( $ConcMapV1 ) { 3 } else { 2 }
        $tpfShape = if ( $ConcMapV1 ) { 'locked v1' } else { 'unlocked' }
        if ( $tpfEnter -ne $tpfWant ) {
            throw "$mode expects TemplateProxyFactory to have $tpfWant monitorenter ($tpfShape shape) but found $tpfEnter. Refusing."
        }
        Write-Host "  Per-instance fix classes present; TemplateProxyFactory has the $tpfShape shape ($tpfEnter monitorenter)." -ForegroundColor Green
    }

    # The patched CaseInsensitiveMap.class must differ from the stock class.
    function Get-JarEntryHashC( $jarPath, $entryName ) {
        $z = [System.IO.Compression.ZipFile]::OpenRead( $jarPath )
        try {
            $e = $z.GetEntry( $entryName ); if ( -not $e ) { return $null }
            $s = $e.Open(); $ms = New-Object System.IO.MemoryStream; $s.CopyTo( $ms ); $s.Close()
            return [BitConverter]::ToString( ([System.Security.Cryptography.SHA256]::Create()).ComputeHash( $ms.ToArray() ) ).Replace( '-', '' )
        } finally { $z.Dispose() }
    }
    if ( ( Get-JarEntryHashC $cfusionJar 'coldfusion/util/CaseInsensitiveMap.class' ) -eq ( Get-JarEntryHashC $outJar 'coldfusion/util/CaseInsensitiveMap.class' ) ) {
        throw "concmap patch was a no-op: CaseInsensitiveMap.class is byte-identical to the stock class. Refusing."
    }

    # The two default constructors must now build CFConcurrentHashMap and no longer HashMap.
    $dis = & $javapExe -p -c -classpath $outJar coldfusion.util.CaseInsensitiveMap
    if ( -not ( $dis | Select-String -SimpleMatch 'CaseInsensitiveMap$CFConcurrentHashMap' ) ) {
        throw "concmap patched class does not reference CFConcurrentHashMap. Refusing."
    }

    # It must load and pass the bytecode verifier.
    Write-Host "  Verifying the patched class loads under -Xverify:all..."
    $cmSrc = Join-Path $buildDir 'CMVerify.java'
@'
import java.util.zip.*;
public class CMVerify extends ClassLoader {
  public static void main(String[] a) throws Exception {
    byte[] b; try (ZipFile z=new ZipFile(a[0])){ b=z.getInputStream(z.getEntry("coldfusion/util/CaseInsensitiveMap.class")).readAllBytes(); }
    CMVerify v=new CMVerify(); Class<?> c=v.defineClass("coldfusion.util.CaseInsensitiveMap",b,0,b.length); v.resolveClass(c);
    System.out.println("VERIFY OK");
  }
}
'@ | Set-Content -Path $cmSrc -Encoding Ascii
    & $javacExe -d $buildDir $cmSrc
    if ( $LASTEXITCODE -ne 0 ) { throw "could not compile the concmap verifier" }
    $verifyOut = & $javaExe -Xverify:all -cp "$buildDir;$cfusionJar" CMVerify $outJar 2>&1
    if ( $LASTEXITCODE -ne 0 -or -not ( $verifyOut | Select-String -SimpleMatch 'VERIFY OK' ) ) {
        throw "concmap patched CaseInsensitiveMap failed bytecode verification:`n$verifyOut"
    }
    Write-Host "  Class verifies and loads cleanly." -ForegroundColor Green

    $sha = ( Get-FileHash -Algorithm SHA256 $outJar ).Hash
    Write-Host "`nBuilt $outJar" -ForegroundColor Green
    Write-Host "SHA256: $sha" -ForegroundColor Green
    if ( $ConcMapV1 ) {
        Write-Host "`nThis is the shippable fallback (v1 lock + concurrent CaseInsensitiveMap). To gate it, deploy it to an arm as hf202300-4232227.jar (it is NOT tracked by `$v3JarSha)." -ForegroundColor Cyan
    } else {
        Write-Host "`nNext: paste this SHA into `$v3JarSha in Install-U23BenchmarkArms.ps1, Invoke-ReproBenchmark.ps1, Invoke-U23Benchmark.ps1, then run .\scripts\Install-U23BenchmarkArms.ps1" -ForegroundColor Cyan
    }
    return
}

# ---------------------------------------------------------------- v3 verification (overlay)
if ( $anyV3 ) {
    Write-Host "`n=== Verifying $outName (overlay, $mode) ===" -ForegroundColor Cyan

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead( $outJar )
    $names = @( $zip.Entries | ForEach-Object { $_.FullName } )
    $zip.Dispose()

    if ( $V3 ) {
        # Plain v3: exactly one entry, the patched ObjectDuplicator.class.
        if ( $names.Count -ne 1 -or $names[0] -ne 'coldfusion/runtime/ObjectDuplicator.class' ) {
            throw "v3 overlay must contain exactly coldfusion/runtime/ObjectDuplicator.class, but has:`n  $( $names -join "`n  " )"
        }
    } else {
        # v3-combined: the unlocked jar's classes PLUS the patched ObjectDuplicator.
        if ( $names -notcontains 'coldfusion/runtime/ObjectDuplicator.class' ) {
            throw "v3-combined overlay is missing the patched ObjectDuplicator.class."
        }
        foreach ( $c in @( 'coldfusion/runtime/TemplateProxyFactory.class', 'coldfusion/runtime/TemplateProxy.class', 'coldfusion/runtime/UDFMethod.class', 'coldfusion/runtime/Closure.class' ) ) {
            if ( $names -notcontains $c ) { throw "v3-combined overlay is missing the per-instance fix class $c." }
        }
        # TemplateProxyFactory must be the UNLOCKED shape (2 monitorenter, no construction lock).
        $tpfDis   = & $javapExe -p -c -classpath $outJar coldfusion.runtime.TemplateProxyFactory
        $tpfEnter = ( $tpfDis | Select-String -SimpleMatch 'monitorenter' ).Count
        if ( $tpfEnter -ne 2 ) {
            throw "v3-combined expects TemplateProxyFactory to have 2 monitorenter (unlocked, no construction lock) but found $tpfEnter. Refusing."
        }
        Write-Host "  Per-instance fix classes present; TemplateProxyFactory is unlocked (2 monitorenter)." -ForegroundColor Green
    }

    # 2. The patched class must differ from the stock class it came from (no no-op patch).
    function Get-JarEntryHash( $jarPath, $entryName ) {
        $z = [System.IO.Compression.ZipFile]::OpenRead( $jarPath )
        try {
            $e = $z.GetEntry( $entryName )
            if ( -not $e ) { return $null }
            $s = $e.Open(); $ms = New-Object System.IO.MemoryStream
            $s.CopyTo( $ms ); $s.Close()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            return [BitConverter]::ToString( $sha.ComputeHash( $ms.ToArray() ) ).Replace( '-', '' )
        } finally { $z.Dispose() }
    }
    $baseClassSha = Get-JarEntryHash $cfusionJar 'coldfusion/runtime/ObjectDuplicator.class'
    $newClassSha  = Get-JarEntryHash $outJar     'coldfusion/runtime/ObjectDuplicator.class'
    if ( $baseClassSha -eq $newClassSha ) {
        throw "v3 patch was a no-op: ObjectDuplicator.class is byte-identical to the stock class. Refusing."
    }

    # 3. Disassembly must show the synchronized delegator: 1 monitorenter / 2 monitorexit,
    #    a renamed _duplicate0, and the new _duplicate calling _duplicate0.
    $dis   = & $javapExe -p -c -classpath $outJar coldfusion.runtime.ObjectDuplicator
    $enter = ( $dis | Select-String -SimpleMatch 'monitorenter' ).Count
    $exit  = ( $dis | Select-String -SimpleMatch 'monitorexit' ).Count
    Write-Host "  monitorenter: $enter"
    Write-Host "  monitorexit:  $exit"
    if ( $enter -ne 1 -or $exit -ne 2 ) {
        throw "v3 expects 1 monitorenter / 2 monitorexit in ObjectDuplicator but found $enter / $exit. Refusing."
    }
    if ( -not ( $dis | Select-String -SimpleMatch '_duplicate0(' ) ) {
        throw "v3 patched class has no _duplicate0 method — the rename did not happen. Refusing."
    }

    # 4. The class must actually load and pass the bytecode verifier (catches a bad frame).
    Write-Host "  Verifying the patched class loads under -Xverify:all..."
    $testSrc = Join-Path $buildDir 'V3Verify.java'
@'
import java.util.zip.*;
public class V3Verify extends ClassLoader {
  public static void main(String[] a) throws Exception {
    byte[] b;
    try (ZipFile z = new ZipFile(a[0])) {
      ZipEntry e = z.getEntry("coldfusion/runtime/ObjectDuplicator.class");
      b = z.getInputStream(e).readAllBytes();
    }
    V3Verify v = new V3Verify();
    Class<?> c = v.defineClass("coldfusion.runtime.ObjectDuplicator", b, 0, b.length);
    v.resolveClass(c);
    System.out.println("VERIFY OK");
  }
}
'@ | Set-Content -Path $testSrc -Encoding Ascii
    & $javacExe -d $buildDir $testSrc
    if ( $LASTEXITCODE -ne 0 ) { throw "could not compile the v3 verifier" }
    $verifyOut = & $javaExe -Xverify:all -cp "$buildDir;$cfusionJar" V3Verify $outJar 2>&1
    if ( $LASTEXITCODE -ne 0 -or -not ( $verifyOut | Select-String -SimpleMatch 'VERIFY OK' ) ) {
        throw "v3 patched ObjectDuplicator failed bytecode verification:`n$verifyOut"
    }
    Write-Host "  Class verifies and loads cleanly." -ForegroundColor Green

    $sha = ( Get-FileHash -Algorithm SHA256 $outJar ).Hash
    Write-Host "`nBuilt $outJar" -ForegroundColor Green
    Write-Host "SHA256: $sha" -ForegroundColor Green
    Write-Host "`nNext: paste this SHA into `$v3JarSha in Install-U23BenchmarkArms.ps1, Invoke-ReproBenchmark.ps1, Invoke-U23Benchmark.ps1, then run .\scripts\Install-U23BenchmarkArms.ps1" -ForegroundColor Cyan
    return
}

# ---------------------------------------------------------------- static verification
Write-Host "`n=== Verifying $outName ===" -ForegroundColor Cyan
$dis = & $javapExe -p -c -classpath $outJar coldfusion.runtime.TemplateProxyFactory
$enter = ( $dis | Select-String -SimpleMatch 'monitorenter' ).Count
$exit  = ( $dis | Select-String -SimpleMatch 'monitorexit' ).Count
Write-Host "  monitorenter: $enter"
Write-Host "  monitorexit:  $exit"

if ( -not $Stripe ) {
    if ( $enter -ne 2 -or $exit -ne 4 ) {
        throw "Full-removal expects 2 monitorenter / 4 monitorexit but found $enter / $exit. Refusing."
    }
} else {
    # Stripe keeps Adobe's monitor skeleton (3/6) but swaps the lock source for lockFor.
    if ( $enter -ne 3 -or $exit -ne 6 ) {
        throw "Stripe expects 3 monitorenter / 6 monitorexit but found $enter / $exit. Refusing."
    }
    if ( -not ( $dis | Select-String -SimpleMatch 'ConstructionLockSupport.lockFor' ) ) {
        throw "Stripe jar does not reference ConstructionLockSupport.lockFor. Refusing."
    }
}

# Byte-for-byte diff: only TemplateProxyFactory.class may differ.
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Get-EntryHashes( $path ) {
    $z = [System.IO.Compression.ZipFile]::OpenRead( $path )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $map = @{}
    foreach ( $e in $z.Entries ) {
        $s = $e.Open(); $ms = New-Object System.IO.MemoryStream
        $s.CopyTo( $ms ); $s.Close()
        $bytes = $ms.ToArray(); $ms.Close()
        $map[ $e.FullName ] = [BitConverter]::ToString( $sha.ComputeHash( $bytes ) ).Replace( '-', '' )
    }
    $z.Dispose()
    return $map
}
$origMap = Get-EntryHashes $hotfixJar
$newMap  = Get-EntryHashes $outJar

$differ = @()
foreach ( $k in $origMap.Keys ) {
    if ( $newMap.ContainsKey( $k ) -and $origMap[$k] -ne $newMap[$k] ) { $differ += $k }
}
$addedEntries = $newMap.Keys | Where-Object { -not $origMap.ContainsKey( $_ ) }

$expectedDiff = @( 'coldfusion/runtime/TemplateProxyFactory.class' )
$unexpected = @( $differ | Where-Object { $expectedDiff -notcontains $_ } )
if ( $unexpected.Count -gt 0 ) {
    throw "Unexpected changed entries besides TemplateProxyFactory.class:`n  $( $unexpected -join "`n  " )"
}
$added = @( $addedEntries )
if ( -not $Stripe -and $added.Count -gt 0 ) {
    throw "Full-removal must not add entries, but found:`n  $( $added -join "`n  " )"
}
if ( $Stripe ) {
    if ( $added.Count -ne 1 -or $added[0] -ne 'coldfusion/runtime/ConstructionLockSupport.class' ) {
        throw "Stripe must add exactly ConstructionLockSupport.class, but added:`n  $( $added -join "`n  " )"
    }
}

foreach ( $c in @( 'coldfusion/runtime/TemplateProxy.class', 'coldfusion/runtime/UDFMethod.class', 'coldfusion/runtime/Closure.class' ) ) {
    if ( $origMap[$c] -ne $newMap[$c] ) { throw "Correctness-fix class changed unexpectedly: $c" }
}

Write-Host "  Only TemplateProxyFactory.class differs; the 3 correctness-fix classes are identical." -ForegroundColor Green

$sha = ( Get-FileHash -Algorithm SHA256 $outJar ).Hash
Write-Host "`nBuilt $outJar" -ForegroundColor Green
Write-Host "SHA256: $sha" -ForegroundColor Green
Write-Host "`nNext: .\scripts\Install-BenchmarkArms.ps1  (stands up the unlocked arm and re-verifies on the running JVM)" -ForegroundColor Cyan
