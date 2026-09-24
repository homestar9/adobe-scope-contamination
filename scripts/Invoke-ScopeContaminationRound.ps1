<#
.SYNOPSIS
    The scope-contamination round: does Adobe's v3 hotfix stop the contamination, what does it
    cost, and how do Lucee 6 and BoxLang compare under heavy load.

.DESCRIPTION
    The null-pointer failure on a freshly started server is deliberately kept out of this round.
    Every contamination session restarts its test server and sends 500 serial requests first, so
    no burst ever meets a cold JVM.

    Phases (in order; -Phases picks a subset):
      contamination  large warmed contamination tests per test server, at 20 and 64 connections
                     per endpoint, plus the Quick-against-unrelated-construction check on v3
      realworkload   /repro throughput at 1, 8, 32 and 64 connections per endpoint, all six servers
      construction   database-free construction shapes and Quick entity + builder at 1, 32 and 64

    Results: benchmark-results-u23\adobe-v3\scope-round\. Roughly 6 hours with every phase.

.EXAMPLE
    .\scripts\Invoke-ScopeContaminationRound.ps1
.EXAMPLE
    .\scripts\Invoke-ScopeContaminationRound.ps1 -Phases realworkload,construction
#>
[CmdletBinding()]
param(
    [ValidateSet( 'contamination', 'realworkload', 'construction' )]
    [string[]] $Phases = @( 'contamination', 'realworkload', 'construction' ),
    [string]   $OutputRoot = ''
)

$ErrorActionPreference = 'Continue'
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
if ( -not $OutputRoot ) { $OutputRoot = Join-Path $BenchRepoRoot 'benchmark-results-u23\adobe-v3\scope-round' }
if ( -not ( Test-Path $OutputRoot ) ) { New-Item -ItemType Directory -Path $OutputRoot | Out-Null }
$LogPath = Join-Path $OutputRoot "round-$( Get-Date -Format 'yyyyMMdd-HHmmss' ).log"
$scripts = $PSScriptRoot
$all = @( 'u23', 'lock-u23', 'buggy', 'perclass-u23', 'lucee6', 'boxlang' )

function Step {
    param( [string] $Name, [scriptblock] $Body )
    "`n##### $( Get-Date -Format 'HH:mm:ss' ) START $Name" | Tee-Object -FilePath $LogPath -Append
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { & $Body 2>&1 | Out-String -Width 250 | Tee-Object -FilePath $LogPath -Append | Out-Null }
    catch { "STEP FAILED: $Name :: $_" | Tee-Object -FilePath $LogPath -Append }
    $os = Get-CimInstance Win32_OperatingSystem
    ( "##### {0} END {1} ({2} min, {3:N1} GB free)" -f ( Get-Date -Format 'HH:mm:ss' ), $Name, [math]::Round( $sw.Elapsed.TotalMinutes, 1 ), ( $os.FreePhysicalMemory / 1MB ) ) | Tee-Object -FilePath $LogPath -Append
}

function Contam {
    param( [string] $Server, [string[]] $Endpoints, [int] $Connections, [int] $PerSession, [int] $Sessions, [string] $Label )
    $out = Join-Path $OutputRoot "contam-$Server-$Label"
    & "$scripts\Test-Contamination.ps1" -Server $Server -Endpoints $Endpoints -Connections $Connections `
        -TotalRequests $PerSession -Sessions $Sessions -ColdStart -WarmRequests 500 -Label $Label -OutputDir $out |
        Select-String -Pattern 'session \d+:|x  |CLEAN|CONTAMINATION|INCOMPLETE' | ForEach-Object { $_.Line }
}

"Scope-contamination round: phases=$( $Phases -join ',' )" | Tee-Object -FilePath $LogPath -Append

# Only one test server under load at a time; all six stay up so every phase can use them.
foreach ( $name in $all ) {
    $srv = Get-TestServer -Name $name
    if ( -not ( Get-TestServerPid -Server $srv ) ) { $null = Start-TestServer -Server $srv; "  started $name" | Tee-Object -FilePath $LogPath -Append }
}
foreach ( $srv in $TestServers ) {
    if ( $all -notcontains $srv.Name -and ( Get-TestServerPid -Server $srv ) ) { Stop-TestServer -Server $srv; "  stopped $($srv.Name)" | Tee-Object -FilePath $LogPath -Append }
}

if ( $Phases -contains 'contamination' ) {
    # Reference rates first: how often the unfixed engines contaminate on this workload today.
    Step 'contamination: buggy (Update 21, no fix) 20 conns'   { Contam -Server buggy        -Endpoints alpha,bravo -Connections 20 -PerSession 20000  -Sessions 2 -Label ab-c20 }
    Step 'contamination: u23 (stock Update 23) 20 conns'       { Contam -Server u23          -Endpoints alpha,bravo -Connections 20 -PerSession 20000  -Sessions 2 -Label ab-c20 }
    # The question: v3 at large N, standard and heavy concurrency.
    Step 'contamination: perclass-u23 (v3) 20 conns'           { Contam -Server perclass-u23 -Endpoints alpha,bravo -Connections 20 -PerSession 100000 -Sessions 6 -Label ab-c20 }
    Step 'contamination: perclass-u23 (v3) 64 conns'           { Contam -Server perclass-u23 -Endpoints alpha,bravo -Connections 64 -PerSession 100000 -Sessions 3 -Label ab-c64 }
    # The accepted fix, same workload, for comparison.
    Step 'contamination: lock-u23 (v1) 20 conns'               { Contam -Server lock-u23     -Endpoints alpha,bravo -Connections 20 -PerSession 100000 -Sessions 3 -Label ab-c20 }
    Step 'contamination: lock-u23 (v1) 64 conns'               { Contam -Server lock-u23     -Endpoints alpha,bravo -Connections 64 -PerSession 100000 -Sessions 1 -Label ab-c64 }
    Step 'contamination: buggy 64 conns'                       { Contam -Server buggy        -Endpoints alpha,bravo -Connections 64 -PerSession 20000  -Sessions 1 -Label ab-c64 }
    # v3 with Quick running against unrelated construction that takes none of Quick's locks.
    Step 'contamination: perclass-u23 (v3) alpha+wire 20 conns' { Contam -Server perclass-u23 -Endpoints alpha,wire -Connections 20 -PerSession 40000 -Sessions 1 -Label aw-c20 }
    # The two other CFML engines: same workload, standard and heavy.
    Step 'contamination: lucee6 20 conns'                      { Contam -Server lucee6       -Endpoints alpha,bravo -Connections 20 -PerSession 40000  -Sessions 1 -Label ab-c20 }
    Step 'contamination: lucee6 64 conns'                      { Contam -Server lucee6       -Endpoints alpha,bravo -Connections 64 -PerSession 30000  -Sessions 1 -Label ab-c64 }
    Step 'contamination: boxlang 20 conns'                     { Contam -Server boxlang      -Endpoints alpha,bravo -Connections 20 -PerSession 50000  -Sessions 2 -Label ab-c20 }
    Step 'contamination: boxlang 64 conns'                     { Contam -Server boxlang      -Endpoints alpha,bravo -Connections 64 -PerSession 60000  -Sessions 1 -Label ab-c64 }
}

if ( $Phases -contains 'realworkload' ) {
    Step 'reset before throughput' {
        foreach ( $name in $all ) { $null = Restart-TestServerFresh -Server ( Get-TestServer -Name $name ); "  restarted $name" }
    }
    Step 'throughput: real workload' {
        & "$scripts\Invoke-RealWorkloadBenchmark.ps1" -Servers $all -Connections 1,8,32,64 -Runs 3 -Duration 30s `
            -WarmupSeconds 20 -SerialWarmupRequests 300 -OutputDir ( Join-Path $OutputRoot 'repro-throughput' )
    }
}

if ( $Phases -contains 'construction' ) {
    Step 'throughput: construct shapes' {
        & "$scripts\Invoke-ConstructionBenchmark.ps1" -Servers $all -Shapes narrow,fanout,siblings -Connections 1,32,64 `
            -Runs 3 -Duration 20s -WarmupSeconds 10 -ControlConnections @() -OutputDir ( Join-Path $OutputRoot 'construct' )
    }
    Step 'throughput: quickconstruct' {
        & "$scripts\Invoke-ConstructionBenchmark.ps1" -Servers $all -Endpoint quickconstruct -Count 50 -Connections 1,32,64 `
            -Runs 3 -Duration 20s -WarmupSeconds 10 -OutputDir ( Join-Path $OutputRoot 'quickconstruct' )
    }
}

"`n##### ROUND DONE $( Get-Date -Format 'HH:mm:ss' )  log: $LogPath" | Tee-Object -FilePath $LogPath -Append
