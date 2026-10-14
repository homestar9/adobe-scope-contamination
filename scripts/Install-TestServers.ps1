<#
.SYNOPSIS
    Installs, jars, starts and verifies the Update 23 benchmark test servers.

.DESCRIPTION
    Test servers come from scripts\TestServers.ps1 (the one table every script shares):

        u23           60843   ACF 2023.0.23, no jar            stock reference
        lock-u23      60844   ACF 2023.0.23 + Adobe v1 jar     global construction lock (rejected)
        buggy         60845   ACF 2023.0.21, no jar            known-bad check; no-lock speed reference
        perclass-u23  60848   ACF 2023.0.23 + Adobe v3 jar     per-class construction locks (rejected)
        localtemp-u23 60852   ACF 2023.0.23 + Adobe v4 jar     no lock, compiler temporaries kept local (under test)

    Flow: start each test server once so CommandBox installs the engine, stop them all (a jar copied
    into a running server is not picked up), place each test server's pinned jar under the ORIGINAL
    filename hf202300-4232227.jar, start them again, then prove each test server is what the table
    says it is:

      - /benchmark/engine classSources: TemplateProxyFactory from the hotfix jar or not;
        TemplateProxy/UDFMethod/Closure from the hotfix jar (v1) or not (v3, stock);
      - /benchmark/engine classSources: NeoPageContext from the hotfix jar (v4) or not;
      - /benchmark/engine constructionLocks: the runtime lock fingerprint (global / perclass / none);
      - /benchmark/engine implicitTemps: where inline-literal temporaries land (shared-variables / function-local);
      - the deployed jar's SHA256 equals the pinned constant for that test server;
      - every test server on the same JVM.

    Every jar SHA is a pinned constant. Nothing is ever hashed "from the source file" to decide
    what it is.

.PARAMETER Servers
    Which test servers to handle. Default: every test server in TestServers.ps1 that is already
    installed under .engine and is not opt-in (concmap-u23 is opt-in). A test server that has
    never been installed must be named here the first time, e.g. -Servers lucee6,boxlang.
    Other test servers are left untouched.

.PARAMETER SkipInstall
    Skip the initial start/stop cycle. Use when the engines are already installed; the
    script still stops running test servers, places jars, starts and verifies.

.PARAMETER ClearFelixCache
    Delete each test server's felix-cache before starting. Repeated start/stop cycles can leave it
    drifted, after which OSGi packages silently fail to install and the test server runs FASTER
    than it should. Recommended before a measurement test run.

.PARAMETER StopOnly
    Stop the selected test servers and exit: frees each port, kills any JVM left over from an
    interrupted start of that server home, and removes stale pid files. Cleanup between rounds.

.EXAMPLE
    .\scripts\Install-TestServers.ps1
.EXAMPLE
    .\scripts\Install-TestServers.ps1 -SkipInstall -ClearFelixCache
.EXAMPLE
    .\scripts\Install-TestServers.ps1 -Servers localtemp-u23
.EXAMPLE
    .\scripts\Install-TestServers.ps1 -StopOnly
#>
[CmdletBinding()]
param(
    [string[]] $Servers = @(),
    [switch]   $SkipInstall,
    [switch]   $ClearFelixCache,
    [switch]   $StopOnly,
    [string]   $OutputDir = ''
)

$ErrorActionPreference = 'Stop'
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )

$serverSet = Select-TestServers -Names $Servers
if ( -not $OutputDir ) { $OutputDir = Join-Path $BenchRepoRoot "benchmark-results-u23\$BenchRound\identity" }

# ---------------------------------------------------------------- stop only (cleanup between rounds)
if ( $StopOnly ) {
    foreach ( $srv in $serverSet ) {
        Stop-TestServer -Server $srv
        Write-Host "  $($srv.Name) stopped (port $($srv.Port) free, orphaned JVMs and pid files removed)."
    }
    return
}

# ---------------------------------------------------------------- source jars
foreach ( $srv in $serverSet ) { Assert-BenchJarSource -Server $srv }
Write-Host "Source jars match their pinned SHA256 values." -ForegroundColor Green

Initialize-BenchShim
Push-Location $BenchRepoRoot
try {
    # ---------------------------------------------------------------- install engines
    if ( -not $SkipInstall ) {
        foreach ( $srv in $serverSet ) {
            Write-Host "`n=== Installing $($srv.Name) engine ($($srv.Config)) ===" -ForegroundColor Cyan
            box server start serverConfigFile=$($srv.Config)
            if ( $LASTEXITCODE -ne 0 ) { throw "Failed to start $($srv.Config)" }
        }
    }

    # ---------------------------------------------------------------- stop
    Write-Host "`n=== Stopping test servers so jars can be placed ===" -ForegroundColor Cyan
    foreach ( $srv in $serverSet ) {
        Stop-TestServer -Server $srv
        Write-Host "  $($srv.Name) stopped."
    }

    # ---------------------------------------------------------------- place jars
    foreach ( $srv in $serverSet ) {
        if ( $srv.Family -ne 'adobe' ) { Write-Host "  $($srv.Name): $($srv.Engine), no jar to place"; continue }
        $updatesDir = Join-Path ( Get-TestServerHome $srv ) 'WEB-INF\cfusion\lib\updates'
        if ( -not ( Test-Path $updatesDir ) ) {
            throw "Updates directory missing for $($srv.Name): $updatesDir. Re-run without -SkipInstall."
        }
        $target = Get-BenchDeployedJarPath $srv
        $jar    = Get-TestServerJar $srv

        if ( $jar ) {
            Copy-Item -Path $jar.Path -Destination $target -Force
            Write-Host "Placed $( Split-Path -Leaf $jar.Path ) in $($srv.Name) as hf202300-4232227.jar" -ForegroundColor Green
        }
        elseif ( Test-Path $target ) {
            Remove-Item $target -Force
            Write-Host "Removed a stray hotfix jar from $($srv.Name)" -ForegroundColor Yellow
        }

        if ( $ClearFelixCache ) {
            Clear-BenchFelixCache -Server $srv
            Write-Host "  $($srv.Name): felix-cache cleared"
        }

        $jars = Get-ChildItem -Path $updatesDir -Filter '*.jar' | Select-Object -ExpandProperty Name
        Write-Host "  $($srv.Name) updates: $( $jars -join ', ' )"
    }

    # ---------------------------------------------------------------- start and verify
    Write-Host "`n=== Starting test servers ===" -ForegroundColor Cyan
    foreach ( $srv in $serverSet ) {
        $null = Start-TestServer -Server $srv
        Write-Host "  $($srv.Name) up on $($srv.Port)."
    }

    Write-Host "`n=== Engine identity ===" -ForegroundColor Cyan
    $identities = Get-TestServerIdentities -Servers $serverSet -SaveTo $OutputDir

    foreach ( $srv in $serverSet ) {
        $id = $identities[ $srv.Name ]
        Write-Host "`n[$($srv.Name)] port $($srv.Port)  ($($srv.Role))"
        Write-Host "  Engine     : $( if ( $id.PSObject.Properties.Name -contains 'productName' ) { $id.productName } else { 'ColdFusion' } ) $($id.productVersion) $($id.productLevel)"
        Write-Host "  JVM        : $($id.jvmVersion) ($($id.jvmVendor))"
        if ( $srv.Family -ne 'adobe' ) { continue }
        Write-Host "  Lock design: $($id.constructionLocks.design)"
        if ( $id.PSObject.Properties.Name -contains 'implicitTemps' ) { Write-Host "  Literal temporaries: $($id.implicitTemps.design) (variables: $( @( $id.implicitTemps.inVariables ).Count ), local: $( @( $id.implicitTemps.inLocal ).Count ))" }
        foreach ( $c in @( $BenchTpfClass ) + $BenchPerInstanceClasses + $BenchOtherClasses + @( $BenchPageContextClass ) ) {
            Write-Host ( "  {0,-42} {1}" -f ( $c -replace '^coldfusion\.(runtime|util)\.', '' ), ( Split-Path -Leaf $id.classSources.$c ) )
        }
    }

    Write-Host "`nVERIFIED: every selected test server loads the classes the table says, carries the pinned jar bytes, and reports the expected lock design." -ForegroundColor Green
    Write-Host "Identity JSON saved under $OutputDir" -ForegroundColor Green
    Write-Host "`nNEXT (do NOT skip): confirm the buggy test server still reproduces contamination, so it is a valid known-bad check:" -ForegroundColor Yellow
    Write-Host "  .\scripts\Test-Contamination.ps1 -Server buggy -TotalRequests 20000 -Connections 20"
    Write-Host "then the contamination test on the new hotfix server (fresh JVMs, each warmed with 500 serial requests first):" -ForegroundColor Yellow
    Write-Host "  .\scripts\Test-Contamination.ps1 -Server localtemp-u23 -ColdStart -TotalRequests 100000 -Connections 20 -Sessions 3"
}
finally {
    Pop-Location
}
