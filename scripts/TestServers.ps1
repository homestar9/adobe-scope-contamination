<#
.SYNOPSIS
    The one test server table and the helpers every benchmark script shares. Dot-source it:

        . ( Join-Path $PSScriptRoot 'TestServers.ps1' )

.DESCRIPTION
    Every test server is a separate ACF install under .engine\bench-<name>, started from its own
    server-bench-<name>.json, and differs from the others only by the ColdFusion update level
    and by which hotfix jar (if any) sits in WEB-INF\cfusion\lib\updates. The jar is always
    deployed under the ORIGINAL filename hf202300-4232227.jar so classloader precedence is
    identical across test servers; only the bytes differ, which is why every jar has a pinned SHA here.

    Test servers (Update 23 test runs, September and October 2026):

        u23           60843   ACF 2023.0.23, no jar            stock reference
        lock-u23      60844   ACF 2023.0.23 + Adobe v1 jar     global construction lock (rejected)
        buggy         60845   ACF 2023.0.21, no jar            known-bad check; no-lock speed reference
        localtemp-u23 60852   ACF 2023.0.23 + Adobe v4 jar     no lock; compiler temporaries kept in the
                                                               function local scope (the fix, October 2026)
        perclass-u23  60848   ACF 2023.0.23 + Adobe v3 jar     per-class construction locks (rejected; opt-in)
        lucee6        60850   Lucee 6, no jar                  no contamination bug: performance reference
        boxlang       60851   BoxLang 1 (CFML compat), no jar  no contamination bug: performance reference

    The Adobe test servers share one JDK (openjdk17). BoxLang needs Java 21, so JVM comparability is
    asserted within the Adobe family only; the other engines are a cross-engine reference,
    not a same-JVM comparison. Test servers whose engine home is not installed yet are left out of the
    default set, so a script never trips over a test server that has not been stood up.

    The SHAs are constants on purpose. An earlier version of these scripts computed the v1
    hash from whatever file sat at hotfixes\hf202300-4232227.jar, which is how a newly
    received jar could have been deployed as "v1" without anything noticing.
#>

$BenchRepoRoot = Split-Path -Parent $PSScriptRoot

# Adobe-supplied jars, by the name they carry in hotfixes\. Audited SHA256 values.
$BenchHotfixJars = [ordered]@{
    'adobe-v1' = [pscustomobject]@{ Path = Join-Path $BenchRepoRoot 'hotfixes\hf202300-4232227-adobe-v1.jar'; Sha = '7B586D55814B120FB818EAB7EF16DD83336449A6088162D627F114A6CC352C56'; Note = 'v1: per-instance fixes in 4 classes + global synchronized construction lock' }
    'adobe-v2' = [pscustomobject]@{ Path = Join-Path $BenchRepoRoot 'hotfixes\hf202300-4232227-adobe-v2.jar'; Sha = '137889D7741E1D2F1763B0698CAF37B405878C7472FDC1BF14051092FFB06FC6';   Note = 'v2: ExprAssembler only, byte-identical to stock Update 23 (never deployed)' }
    'adobe-v3' = [pscustomobject]@{ Path = Join-Path $BenchRepoRoot 'hotfixes\hf202300-4232227-adobe-v3.jar'; Sha = 'EFB0AA56912C3C7046DA47BBCC1FC28776A9F9AA1D18FBBF09CF1A3CE4780B0E'; Note = 'v3: TemplateProxyFactory only, per-class ReentrantLock held with all ancestor locks' }
    'adobe-v4' = [pscustomobject]@{ Path = Join-Path $BenchRepoRoot 'hotfixes\hf202300-4232227-adobe-v4.jar'; Sha = '9D17AD33BB1D845D0303346905A2C0E8CA3FA6D4E2E087A45590C3FEAE4C5E81'; Note = 'v4: NeoPageContext only, compiler temporaries for inline literals kept in the function local scope, no lock' }
    # Our own build (docs/root-cause/contamination-investigation-and-startup-crash-fix.md): v1 plus a CFConcurrentHashMap-backed CaseInsensitiveMap.
    'concmap-v1' = [pscustomobject]@{ Path = Join-Path $BenchRepoRoot 'hotfixes\hf202300-4232227-concmap-v1.jar'; Sha = '4943E46A045C15D9D32E0C2D108F00CC0001C5694D9D222A10B85780F32C985A'; Note = 'v1 + concurrent CaseInsensitiveMap; the cleanest build measured (0/300k cold, Aug 2026)' }
}

$TestServers = @(
    [pscustomobject]@{
        Name = 'u23';          Config = 'server-bench-u23.json';          Home = '.engine\bench-u23';          Port = 60843
        Engine = 'adobe@2023.0.23'; Jar = $null
        ExpectClean = $false;  TpfFromHotfix = $false; PerInstanceFromHotfix = $false; LockDesign = 'none'; Family = 'adobe'
        Role = 'stock Update 23 reference (fails every request until restart cold; serially warmed for throughput)'
    },
    [pscustomobject]@{
        Name = 'lock-u23';     Config = 'server-bench-lock-u23.json';     Home = '.engine\bench-lock-u23';     Port = 60844
        Engine = 'adobe@2023.0.23'; Jar = 'adobe-v1'
        ExpectClean = $true;   TpfFromHotfix = $true;  PerInstanceFromHotfix = $true;  LockDesign = 'global'; Family = 'adobe'
        Role = 'Adobe v1: correctness bar and the rejected global-lock cost'
    },
    [pscustomobject]@{
        Name = 'buggy';        Config = 'server-bench-buggy.json';        Home = '.engine\bench-buggy';        Port = 60845
        Engine = 'adobe@2023.0.21'; Jar = $null
        ExpectClean = $false;  TpfFromHotfix = $false; PerInstanceFromHotfix = $false; LockDesign = 'none'; Family = 'adobe'
        Role = 'ACF 2023.0.21 known-bad check (must reproduce) and no-lock speed reference'
    },
    [pscustomobject]@{
        Name = 'perclass-u23'; Config = 'server-bench-perclass-u23.json'; Home = '.engine\bench-perclass-u23'; Port = 60848
        Engine = 'adobe@2023.0.23'; Jar = 'adobe-v3'
        ExpectClean = $true;   TpfFromHotfix = $true;  PerInstanceFromHotfix = $false; LockDesign = 'perclass'; Family = 'adobe'; OptIn = $true
        Role = 'Adobe v3: per-class construction locks (rejected September 2026; opt-in, the comparison that matters is stock / v1 / v4)'
    },
    [pscustomobject]@{
        Name = 'localtemp-u23'; Config = 'server-bench-localtemp-u23.json'; Home = '.engine\bench-localtemp-u23'; Port = 60852
        Engine = 'adobe@2023.0.23'; Jar = 'adobe-v4'
        ExpectClean = $true;   TpfFromHotfix = $false; PerInstanceFromHotfix = $false; LockDesign = 'none'; Family = 'adobe'
        PageContextFromHotfix = $true
        Role = 'Adobe v4: no lock, compiler temporaries kept in the function local scope, under test'
    },
    # Cross-engine performance references. Neither engine has the contamination bug (see
    # docs/root-cause/how-lucee-and-boxlang-avoid-it.md), so they show what the same application costs on an
    # engine that never needed a construction lock.
    [pscustomobject]@{
        Name = 'lucee6';       Config = 'server-bench-lucee6.json';       Home = '.engine\bench-lucee6';       Port = 60850
        Engine = 'lucee@6'; Jar = $null
        ExpectClean = $true;   TpfFromHotfix = $false; PerInstanceFromHotfix = $false; LockDesign = 'n/a'; Family = 'lucee'
        Role = 'Lucee 6: no contamination bug, performance reference'
    },
    [pscustomobject]@{
        Name = 'boxlang';      Config = 'server-bench-boxlang.json';      Home = '.engine\bench-boxlang';      Port = 60851
        Engine = 'boxlang@1'; Jar = $null
        ExpectClean = $true;   TpfFromHotfix = $false; PerInstanceFromHotfix = $false; LockDesign = 'n/a'; Family = 'boxlang'
        Role = 'BoxLang 1 with bx-compat-cfml: no contamination bug, performance reference'
    },
    # Opt-in same-day check server (not in the default set): tells whether today's environment still
    # behaves like the August record. Select it explicitly with -Servers concmap-u23.
    [pscustomobject]@{
        Name = 'concmap-u23';  Config = 'server-bench-concmap-u23.json';  Home = '.engine\bench-concmap-u23';  Port = 60849
        Engine = 'adobe@2023.0.23'; Jar = 'concmap-v1'
        ExpectClean = $true;   TpfFromHotfix = $true;  PerInstanceFromHotfix = $true;  LockDesign = 'global'; Family = 'adobe'; OptIn = $true
        Role = 'our v1 + concurrent-map build: same-day calibration for the fresh-start contamination test'
    }
)

# ---------------------------------------------------------------- run profiles
# 'short' is the default everywhere: every script finishes in about five minutes or less and
# is good enough to rank test servers and catch a regression. 'long' is the long form (30 s runs,
# five connection levels, 3 x 100k cold sessions, 45 min endurance test) for a number that goes in a
# report. Any parameter given explicitly on the command line beats the profile.
$BenchProfiles = @{
    short = @{
        Contamination  = @{ TotalRequests = 20000;  Sessions = 2; Connections = 20 }
        Repro          = @{ Connections = @( 1, 8, 32 ); Runs = 2; Duration = '10s'; WarmupSeconds = 8;  SerialWarmupRequests = 100 }
        Construct      = @{ Shapes = @( 'narrow', 'fanout', 'siblings' ); Connections = @( 1, 32 ); Runs = 2; Duration = '10s'; WarmupSeconds = 5; ControlConnections = @() }
        QuickConstruct = @{ Connections = @( 1, 32 ); Runs = 2; Duration = '10s'; Count = 50; WarmupSeconds = 5 }
        Widths         = @{ Widths = @( 1, 4, 16 ); Connections = @( 32 ); Runs = 1; Duration = '10s'; WarmupSeconds = 5 }
        LockEvidence   = @{ Samples = 10; SampleIntervalSeconds = 1 }
        Torture        = @{ Reps = 3 }
        Soak           = @{ Minutes = 5; SliceMinutes = 1; SampleSeconds = 20 }
    }
    long = @{
        Contamination  = @{ TotalRequests = 100000; Sessions = 3; Connections = 20 }
        Repro          = @{ Connections = @( 1, 4, 8, 16, 32 ); Runs = 3; Duration = '30s'; WarmupSeconds = 20; SerialWarmupRequests = 200 }
        Construct      = @{ Shapes = @( 'narrow', 'wide', 'closure', 'fanout', 'siblings', 'deep', 'slowfanout', 'slowsiblings' ); Connections = @( 1, 8, 16, 32 ); Runs = 2; Duration = '20s'; WarmupSeconds = 20; ControlConnections = @( 1, 8, 32 ) }
        QuickConstruct = @{ Connections = @( 1, 8, 32 ); Runs = 3; Duration = '20s'; Count = 50; WarmupSeconds = 20 }
        Widths         = @{ Widths = @( 1, 2, 4, 8, 16 ); Connections = @( 32 ); Runs = 2; Duration = '20s'; WarmupSeconds = 20 }
        LockEvidence   = @{ Samples = 20; SampleIntervalSeconds = 1 }
        Torture        = @{ Reps = 5 }
        Soak           = @{ Minutes = 45; SliceMinutes = 5; SampleSeconds = 60 }
    }
}

# The round every script writes under. September's v3 results stay in benchmark-results-u23\adobe-v3.
# Set BENCH_ROUND in the environment to write a repeat run next to the first instead of over it,
# e.g. $env:BENCH_ROUND = 'adobe-v4-run2' (the second, confirming run of the fourth hotfix).
$BenchRound = if ( $env:BENCH_ROUND ) { $env:BENCH_ROUND } else { 'adobe-v4' }

function Get-BenchResultsRoot {
    <#
        Results are kept per round and per profile so a short run can never overwrite a long run's raw JSON:
            benchmark-results-u23\<round>\<profile>\<kind>[-<test server>[-<label>]]
    #>
    param( [Parameter(Mandatory)] [string] $Profile, [Parameter(Mandatory)] [string] $Kind )
    return Join-Path $BenchRepoRoot "benchmark-results-u23\$BenchRound\$Profile\$Kind"
}

function Use-BenchProfile {
    <#
        Applies one section of a profile to the CALLING script's variables, skipping every
        parameter the caller passed explicitly. Call it right after dot-sourcing:
            Use-BenchProfile -Profile $Profile -Section 'Repro' -Bound $PSBoundParameters
    #>
    param( [Parameter(Mandatory)] [string] $Profile, [Parameter(Mandatory)] [string] $Section, [Parameter(Mandatory)] $Bound )
    if ( -not $BenchProfiles.ContainsKey( $Profile ) ) { throw "Unknown profile '$Profile'. Known: $( $BenchProfiles.Keys -join ', ' )" }
    $values = $BenchProfiles[ $Profile ][ $Section ]
    if ( -not $values ) { throw "Profile '$Profile' has no section '$Section'." }
    foreach ( $k in $values.Keys ) {
        if ( -not $Bound.ContainsKey( $k ) ) { Set-Variable -Name $k -Value $values[ $k ] -Scope 1 }
    }
    Write-Host "profile: $Profile ($Section)" -ForegroundColor DarkGray
}

# The seven classes /benchmark/engine reports a code source for.
$BenchTpfClass         = 'coldfusion.runtime.TemplateProxyFactory'
$BenchPerInstanceClasses = @( 'coldfusion.runtime.TemplateProxy', 'coldfusion.runtime.UDFMethod', 'coldfusion.runtime.Closure' )
$BenchOtherClasses     = @( 'coldfusion.runtime.ObjectDuplicator', 'coldfusion.util.CaseInsensitiveMap' )
# Adobe v4 ships only this class; no other jar may overlay it.
$BenchPageContextClass = 'coldfusion.runtime.NeoPageContext'

function Select-TestServers {
    <# Returns the test server objects for the given names (all test servers when none given), in table order. #>
    param( [string[]] $Names )
    if ( -not $Names -or $Names.Count -eq 0 ) {
        # Default set: every test server that is not opt-in AND is installed (engine home exists).
        $set = @(); $skipped = @()
        foreach ( $a in $TestServers ) {
            if ( $a.PSObject.Properties.Name -contains 'OptIn' -and $a.OptIn ) { continue }
            if ( Test-Path ( Join-Path $BenchRepoRoot $a.Home ) ) { $set += $a } else { $skipped += $a.Name }
        }
        if ( $skipped.Count ) { Write-Host "test servers not installed, left out: $( $skipped -join ', ' )  (install with Install-TestServers.ps1 -Servers <name>)" -ForegroundColor DarkGray }
        return $set
    }
    $known = $TestServers | ForEach-Object { $_.Name }
    foreach ( $n in $Names ) {
        if ( $known -notcontains $n ) { throw "Unknown test server '$n'. Known test servers: $( $known -join ', ' )" }
    }
    return @( $TestServers | Where-Object { $Names -contains $_.Name } )
}

function Get-TestServer {
    param( [Parameter(Mandatory)] [string] $Name )
    $srv = $TestServers | Where-Object { $_.Name -eq $Name }
    if ( -not $srv ) { throw "Unknown test server '$Name'. Known test servers: $( ( $TestServers | ForEach-Object { $_.Name } ) -join ', ' )" }
    return $srv
}

function Get-TestServerJar {
    <# The jar record (Path, Sha, Note) a test server deploys, or $null for a no-jar test server. #>
    param( [Parameter(Mandatory)] $Server )
    if ( -not $Server.Jar ) { return $null }
    return $BenchHotfixJars[ $Server.Jar ]
}

function Get-TestServerHome {
    param( [Parameter(Mandatory)] $Server )
    return Join-Path $BenchRepoRoot $Server.Home
}

function Get-BenchDeployedJarPath {
    param( [Parameter(Mandatory)] $Server )
    return Join-Path ( Get-TestServerHome $Server ) 'WEB-INF\cfusion\lib\updates\hf202300-4232227.jar'
}

function Assert-BenchJarSource {
    <# The jar in hotfixes\ must exist and match its pinned SHA before it is deployed anywhere. #>
    param( [Parameter(Mandatory)] $Server )
    $jar = Get-TestServerJar $Server
    if ( -not $jar ) { return }
    if ( -not ( Test-Path $jar.Path ) ) { throw "$($Server.Name): jar not found at $($jar.Path)." }
    $actual = ( Get-FileHash $jar.Path -Algorithm SHA256 ).Hash
    if ( $actual -ne $jar.Sha ) { throw "$($Server.Name): $( Split-Path -Leaf $jar.Path ) has SHA256 $actual but the audited value is $($jar.Sha). Wrong file." }
}

function Assert-BenchDeployedJar {
    <# The jar inside the engine must be exactly the pinned jar (or absent for a no-jar test server). #>
    param( [Parameter(Mandatory)] $Server )
    $deployed = Get-BenchDeployedJarPath $Server
    $jar = Get-TestServerJar $Server
    if ( -not $jar ) {
        if ( Test-Path $deployed ) { throw "$($Server.Name): a hotfix jar is deployed at $deployed but this test server must not have one." }
        return
    }
    if ( -not ( Test-Path $deployed ) ) { throw "$($Server.Name): no hotfix jar deployed at $deployed. Run Install-TestServers.ps1." }
    $actual = ( Get-FileHash $deployed -Algorithm SHA256 ).Hash
    if ( $actual -ne $jar.Sha ) { throw "$($Server.Name): deployed jar SHA256 $actual is not the pinned $($Server.Jar) jar ($($jar.Sha))." }
}

# ---------------------------------------------------------------- process control
function Initialize-BenchShim {
    <#
        In the sandboxed shell, `box server start/stop` fails because CommandBox shells out to
        bare `tasklist` and the sandbox blocks PATH search for .exe in the child cmd. A .bat
        shim in a directory prepended to PATH *in this same process* resolves where the .exe
        does not. Harmless in a normal terminal.
    #>
    $shimDir = Join-Path $env:TEMP 'cbox-shim'
    if ( -not ( Test-Path $shimDir ) ) { New-Item -ItemType Directory -Path $shimDir | Out-Null }
    Set-Content -Path ( Join-Path $shimDir 'tasklist.bat' ) -Value '@C:\Windows\System32\tasklist.exe %*' -Encoding ascii
    if ( $env:PATH -notlike "$shimDir;*" ) { $env:PATH = "$shimDir;$env:PATH" }
}

function Get-TestServerPid {
    <# The PID listening on the test server's port, or $null. #>
    param( [Parameter(Mandatory)] $Server )
    $conn = Get-NetTCPConnection -LocalPort $Server.Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ( $conn ) { return [int] $conn.OwningProcess }
    return $null
}

function Wait-BenchPortFree {
    param( [Parameter(Mandatory)] [int] $Port, [int] $TimeoutSeconds = 60 )
    for ( $waited = 0; $waited -lt $TimeoutSeconds; $waited += 2 ) {
        if ( -not ( Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue ) ) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Stop-TestServer {
    <#
        Stops a test server by killing the JVM that owns its port. `box server stop` is not trusted
        here: its exit code is meaningless in the sandbox and a half-stopped server keeps the
        port. Killing the PID is also what makes a session genuinely cold.
    #>
    param( [Parameter(Mandatory)] $Server, [int] $TimeoutSeconds = 60 )
    $serverPid = Get-TestServerPid $Server
    if ( $serverPid ) {
        Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
    }
    # A start that was interrupted (for example by a memory guard killing the shell) can leave a JVM
    # for this server home that never got as far as listening. Its command line names the home.
    $serverHome = Get-TestServerHome $Server
    foreach ( $orphan in @( Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains( "$serverHome\" ) -and $_.ProcessId -ne $serverPid } ) ) {
        Stop-Process -Id $orphan.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ( -not ( Wait-BenchPortFree -Port $Server.Port -TimeoutSeconds $TimeoutSeconds ) ) {
        throw "$($Server.Name): port $($Server.Port) is still listening after stop."
    }
    # CommandBox keeps a pid file; a stale one makes the next start try `tasklist` and fail.
    foreach ( $stale in @( '.pid.txt', 'serverInfo.json' ) ) {
        $p = Join-Path ( Get-TestServerHome $Server ) $stale
        if ( Test-Path $p ) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
    }
}

function Start-TestServer {
    <# Starts a test server with CommandBox and waits until /benchmark/engine answers. #>
    param( [Parameter(Mandatory)] $Server, [int] $TimeoutSeconds = 180 )
    Initialize-BenchShim
    Push-Location $BenchRepoRoot
    try {
        box server start serverConfigFile=$($Server.Config)
        if ( $LASTEXITCODE -ne 0 ) { throw "$($Server.Name): box server start failed for $($Server.Config)." }
    }
    finally { Pop-Location }
    $identity = Get-TestServerIdentity -Server $Server -TimeoutSeconds $TimeoutSeconds
    if ( -not $identity ) { throw "$($Server.Name): not answering /benchmark/engine on port $($Server.Port) after ${TimeoutSeconds}s." }
    return $identity
}

function Restart-TestServerFresh {
    <# Kill and start: a fresh JVM with an empty component cache. #>
    param( [Parameter(Mandatory)] $Server )
    Stop-TestServer -Server $Server
    return ( Start-TestServer -Server $Server )
}

function Clear-BenchFelixCache {
    <#
        Repeated start/stop cycles can leave felix-cache\bundle0\bundle.id drifted, after which
        OSGi packages (felixclassloader, adminapi) silently fail to install and the test server is
        FASTER than it should be. Clearing it forces a clean bundle install on next start.
    #>
    param( [Parameter(Mandatory)] $Server )
    $felix = Join-Path ( Get-TestServerHome $Server ) 'WEB-INF\cfusion\felix-cache'
    if ( Test-Path $felix ) { Remove-Item -Recurse -Force $felix -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- identity
function Get-TestServerIdentity {
    <# /benchmark/engine as an object, retried until the test server answers. $null on timeout. #>
    param( [Parameter(Mandatory)] $Server, [int] $TimeoutSeconds = 30 )
    $url = "http://127.0.0.1:$($Server.Port)/benchmark/engine"
    $deadline = ( Get-Date ).AddSeconds( $TimeoutSeconds )
    do {
        try { return Invoke-RestMethod -Uri $url -TimeoutSec 15 }
        catch { Start-Sleep -Seconds 2 }
    } while ( ( Get-Date ) -lt $deadline )
    return $null
}

function Assert-TestServerIdentity {
    <#
        What /benchmark/engine must say for this test server to be the test server the table claims:
          - TemplateProxyFactory loaded from the hotfix jar, or not, per TpfFromHotfix;
          - TemplateProxy/UDFMethod/Closure from the hotfix jar, or not, per PerInstanceFromHotfix
            (v1 ships them, v3 does not, and that difference is itself a finding);
          - ObjectDuplicator/CaseInsensitiveMap never from a hotfix jar in this test run;
          - NeoPageContext from the hotfix jar only on a PageContextFromHotfix server (v4);
          - the runtime lock fingerprint (constructionLocks) matches LockDesign;
          - the deployed jar bytes match the pinned SHA.
    #>
    param( [Parameter(Mandatory)] $Server, [Parameter(Mandatory)] $Identity )
    $name = $Server.Name
    if ( $Server.Family -ne 'adobe' ) {
        # Lucee / BoxLang: no Adobe classes, no hotfix jar. Reachability is the identity.
        if ( -not $Identity.productVersion ) { throw "${name}: /benchmark/engine returned no productVersion." }
        return
    }
    $src  = $Identity.classSources
    $tpf  = $src.$BenchTpfClass
    if ( $Server.TpfFromHotfix -and $tpf -notmatch 'hf202300-4232227' ) { throw "${name}: TemplateProxyFactory is not loaded from the hotfix jar ($tpf)." }
    if ( -not $Server.TpfFromHotfix -and $tpf -match 'hf202300-4232227' ) { throw "${name}: TemplateProxyFactory is loaded from a hotfix jar ($tpf) but this test server must be stock." }
    foreach ( $c in $BenchPerInstanceClasses ) {
        $s = $src.$c
        if ( $Server.PerInstanceFromHotfix -and $s -notmatch 'hf202300-4232227' ) { throw "${name}: $c is not loaded from the hotfix jar ($s); the v1 per-instance fixes are missing." }
        if ( -not $Server.PerInstanceFromHotfix -and $s -match 'hf202300-4232227' ) { throw "${name}: $c is loaded from a hotfix jar ($s) but this test server's jar must not carry it." }
    }
    foreach ( $c in $BenchOtherClasses ) {
        $s = $src.$c
        # Only the concmap build overlays CaseInsensitiveMap; nothing overlays ObjectDuplicator.
        $allowed = ( $Server.Jar -eq 'concmap-v1' -and $c -eq 'coldfusion.util.CaseInsensitiveMap' )
        if ( $allowed -and $s -notmatch 'hf202300-4232227' ) { throw "${name}: $c is not loaded from the concmap jar ($s)." }
        if ( -not $allowed -and $s -match 'hf202300-4232227' ) { throw "${name}: $c is loaded from a hotfix jar ($s); this test server's jar must not overlay it." }
    }
    $pageCtxFromHotfix = ( $Server.PSObject.Properties.Name -contains 'PageContextFromHotfix' ) -and $Server.PageContextFromHotfix
    $pc = $src.$BenchPageContextClass
    if ( $pageCtxFromHotfix -and $pc -notmatch 'hf202300-4232227' ) { throw "${name}: $BenchPageContextClass is not loaded from the hotfix jar ($pc); the v4 fix is missing." }
    if ( -not $pageCtxFromHotfix -and $pc -match 'hf202300-4232227' ) { throw "${name}: $BenchPageContextClass is loaded from a hotfix jar ($pc) but this test server's jar must not carry it." }
    if ( $Identity.PSObject.Properties.Name -contains 'constructionLocks' ) {
        $design = $Identity.constructionLocks.design
        if ( $design -ne $Server.LockDesign ) { throw "${name}: runtime lock fingerprint is '$design' but the table says '$($Server.LockDesign)'." }
    }
    Assert-BenchDeployedJar -Server $Server
}

function Assert-TestServersSameJvm {
    <#
        Same JVM on every Adobe test server, or their timings are not comparable. The cross-engine test servers
        (Lucee, BoxLang) run whatever JDK they need and are reported, not asserted.
    #>
    param( [Parameter(Mandatory)] [hashtable] $Identities )
    $adobeNames = @( $TestServers | Where-Object { $_.Family -eq 'adobe' } | ForEach-Object { $_.Name } )
    $jvms = $Identities.GetEnumerator() | Where-Object { $adobeNames -contains $_.Key } | ForEach-Object { $_.Value.jvmVersion } | Sort-Object -Unique
    if ( @( $jvms ).Count -gt 1 ) { throw "Adobe test servers are on different JVMs: $( $jvms -join ', ' ). Timings would not be comparable." }
}

function Get-TestServerIdentities {
    <# Fetch, assert and return identities for a set of test servers as a hashtable by name. #>
    param( [Parameter(Mandatory)] $Servers, [string] $SaveTo = '' )
    $identities = @{}
    foreach ( $srv in $Servers ) {
        $id = Get-TestServerIdentity -Server $srv -TimeoutSeconds 15
        if ( -not $id ) { throw "Could not reach the $($srv.Name) test server on port $($srv.Port). Run .\scripts\Install-TestServers.ps1 first." }
        Assert-TestServerIdentity -Server $srv -Identity $id
        $identities[ $srv.Name ] = $id
        $lockInfo = if ( $id.PSObject.Properties.Name -contains 'constructionLocks' ) { " lock=$($id.constructionLocks.design)" } else { '' }
        if ( $id.PSObject.Properties.Name -contains 'implicitTemps' ) { $lockInfo += " temps=$($id.implicitTemps.design)" }
        $engine   = if ( $id.PSObject.Properties.Name -contains 'productName' ) { $id.productName } else { 'CF' }
        Write-Host "  $($srv.Name): $engine $($id.productVersion), JVM $($id.jvmVersion)$lockInfo"
        if ( $SaveTo ) {
            if ( -not ( Test-Path $SaveTo ) ) { New-Item -ItemType Directory -Path $SaveTo | Out-Null }
            $id | ConvertTo-Json -Depth 6 | Set-Content -Path ( Join-Path $SaveTo "engine-$($srv.Name).json" ) -Encoding utf8
        }
    }
    Assert-TestServersSameJvm -Identities $identities
    return $identities
}

# ---------------------------------------------------------------- tools
function Get-BenchBombardierPath {
    param( [string] $Override = '' )
    if ( $Override ) { if ( Test-Path $Override ) { return $Override }; throw "bombardier not found at $Override" }
    foreach ( $c in @( ( Join-Path $BenchRepoRoot 'tools\bombardier.exe' ), ( Join-Path $BenchRepoRoot 'tools\bombardier' ) ) ) {
        if ( Test-Path $c ) { return $c }
    }
    $onPath = Get-Command bombardier -ErrorAction SilentlyContinue
    if ( $onPath ) { return $onPath.Source }
    throw "bombardier not found. Run .\scripts\Get-BenchmarkTools.ps1 or pass -BombardierPath."
}

function Get-BenchJdkTool {
    <# Path to jcmd.exe / jfr.exe / javap.exe from the JDK the test servers pin (openjdk17_jdk). #>
    param( [Parameter(Mandatory)] [string] $Tool, [string] $Override = '' )
    if ( $Override ) { if ( Test-Path $Override ) { return $Override }; throw "$Tool not found at $Override" }
    $jdkRoot = Join-Path $env:USERPROFILE '.CommandBox\serverJREs'
    if ( Test-Path $jdkRoot ) {
        $found = Get-ChildItem -Path $jdkRoot -Directory -Filter 'openjdk17_jdk*' |
                 Sort-Object Name -Descending |
                 ForEach-Object { Get-ChildItem -Path $_.FullName -Filter "$Tool.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 } |
                 Select-Object -First 1
        if ( $found ) { return $found.FullName }
    }
    $onPath = Get-Command $Tool -ErrorAction SilentlyContinue
    if ( $onPath ) { return $onPath.Source }
    throw "$Tool not found. Install the JDK the test servers use with:  box java install openjdk17_jdk"
}

function Get-BenchMedian {
    param( [double[]] $Values )
    $s = @( $Values | Sort-Object ); $n = $s.Count
    if ( $n -eq 0 ) { return 0 }
    if ( $n % 2 ) { return $s[ [int]( ( $n - 1 ) / 2 ) ] }
    return ( $s[ $n / 2 - 1 ] + $s[ $n / 2 ] ) / 2
}

function Read-BombardierJson {
    <# Parses a bombardier -o json output file; $null if it is not JSON. #>
    param( [Parameter(Mandatory)] [string] $Path )
    if ( -not ( Test-Path $Path ) ) { return $null }
    try { return ( Get-Content $Path -Raw ) | ConvertFrom-Json } catch { return $null }
}

function Get-BombardierCounts {
    <# Totals a bombardier result: completed requests, 5xx, and transport errors (timeouts etc.). #>
    param( [Parameter(Mandatory)] $Json )
    $r = $Json.result
    $completed = [int] $r.req1xx + [int] $r.req2xx + [int] $r.req3xx + [int] $r.req4xx + [int] $r.req5xx
    $errors = 0
    if ( $r.PSObject.Properties.Name -contains 'errors' -and $r.errors ) {
        foreach ( $e in $r.errors ) { $errors += [int] $e.count }
    }
    return [pscustomobject]@{ Completed = $completed; Http5xx = [int] $r.req5xx; Errors = $errors; Rps = [double] $r.rps.mean }
}

function Move-BenchLogsAside {
    <#
        All test servers share one webroot and therefore one logs\ directory. Moving the two live logs
        out before a run keeps each run's evidence separate; truncating would lose it.
    #>
    param( [Parameter(Mandatory)] [string] $Label )
    $logs = Join-Path $BenchRepoRoot 'logs'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $logs "archive\$Label-$stamp"
    $moved = $false
    foreach ( $f in @( 'contamination_log.txt', 'repro_errors.txt' ) ) {
        $p = Join-Path $logs $f
        if ( ( Test-Path $p ) -and ( Get-Item $p ).Length -gt 0 ) {
            if ( -not ( Test-Path $dest ) ) { New-Item -ItemType Directory -Path $dest | Out-Null }
            Move-Item -Path $p -Destination ( Join-Path $dest $f ) -Force
            $moved = $true
        }
    }
    if ( $moved ) { return $dest }
    return $null
}

function Stop-DropboxForBenchmark {
    <#
        Dropbox sync on this tree lands on the request path and makes latency figures
        unreliable. Returns the executable path so it can be started again afterwards.
    #>
    $procs = Get-Process -Name 'Dropbox' -ErrorAction SilentlyContinue
    if ( -not $procs ) { return $null }
    $exe = ( $procs | Select-Object -First 1 ).Path
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "Dropbox stopped for the duration of the run." -ForegroundColor Yellow
    return $exe
}

function Start-DropboxAfterBenchmark {
    param( [string] $ExePath )
    if ( -not $ExePath ) {
        # A run that was killed mid-way loses the recorded path; fall back to the usual installs.
        $ExePath = @( "${env:ProgramFiles(x86)}\Dropbox\Client\Dropbox.exe", "$env:ProgramFiles\Dropbox\Client\Dropbox.exe", "$env:LOCALAPPDATA\Dropbox\Client\Dropbox.exe" ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if ( Get-Process -Name 'Dropbox' -ErrorAction SilentlyContinue ) { return }
    if ( $ExePath -and ( Test-Path $ExePath ) ) {
        Start-Process -FilePath $ExePath | Out-Null
        Write-Host "Dropbox restarted." -ForegroundColor Yellow
    }
}
