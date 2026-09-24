<#
.SYNOPSIS
    Runs the whole Adobe v3 test test run, one load phase at a time, and writes a log.

.DESCRIPTION
    Order (the same as docs/adobe-hotfixes/3-third-hotfix-results.md):
      0. every test server restarted fresh and serially warmed (a JVM left failed every request until restart by a fresh-start contamination test
         dies before it reaches Quick and would poison the next measurement);
      1. correctness: known-bad check on buggy, fresh-start contamination test on the new hotfix server and on v1,
         warmed-up contamination test on the new hotfix server;
      2. lock evidence under the real workload on the new hotfix server and v1;
      3. throughput: real workload, then the synthetic shapes, quickconstruct, width test,
         on every installed test server including the Lucee 6 and BoxLang references;
      4. lock stress tests on the three Update 23 test servers, deadlock probe last;
      5. endurance test on the new hotfix server.

    -Profile short (default) finishes in roughly 80 minutes with all six test servers
    (the Lucee 6 contamination check alone takes about 10). -Profile long is the report-grade
    test run (several hours). -Phases picks a subset. Each step's exit status is logged, and a
    failing step does not stop the test run.

.EXAMPLE
    .\scripts\Invoke-AdobeV3TestRun.ps1
.EXAMPLE
    .\scripts\Invoke-AdobeV3TestRun.ps1 -Profile long -StopDropbox
.EXAMPLE
    .\scripts\Invoke-AdobeV3TestRun.ps1 -Phases contamination,lockwaits
#>
[CmdletBinding()]
param(
    [ValidateSet( 'short', 'long' )]
    [string]   $Profile   = 'short',
    [ValidateSet( 'reset', 'contamination', 'lockwaits', 'realworkload', 'construction', 'stress', 'endurance' )]
    [string[]] $Phases    = @( 'reset', 'contamination', 'lockwaits', 'realworkload', 'construction', 'stress', 'endurance' ),
    [string]   $NewHotfixServer = 'perclass-u23',
    [string]   $V1Server = 'lock-u23',
    [switch]   $StopDropbox,
    [string]   $LogPath   = ''
)

$ErrorActionPreference = 'Continue'
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
if ( -not $LogPath ) { $LogPath = Join-Path $BenchRepoRoot "benchmark-results-u23\adobe-v3\$Profile\round-$( Get-Date -Format 'yyyyMMdd-HHmmss' ).log" }
$logDir = Split-Path -Parent $LogPath
if ( -not ( Test-Path $logDir ) ) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$scripts = $PSScriptRoot
$dropboxArgs = @{}
if ( $StopDropbox ) { $dropboxArgs.StopDropbox = $true }

function Step {
    param( [string] $Name, [scriptblock] $Body )
    "`n##### $( Get-Date -Format 'HH:mm:ss' ) START $Name" | Tee-Object -FilePath $LogPath -Append
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { & $Body 2>&1 | Tee-Object -FilePath $LogPath -Append }
    catch { "STEP FAILED: $Name :: $_" | Tee-Object -FilePath $LogPath -Append }
    "##### $( Get-Date -Format 'HH:mm:ss' ) END $Name ($( [math]::Round( $sw.Elapsed.TotalMinutes, 1 ) ) min)" | Tee-Object -FilePath $LogPath -Append
}

function Reset-Servers {
    foreach ( $srv in ( Select-TestServers ) ) {
        $null = Restart-TestServerFresh -Server $srv
        $fail = 0
        for ( $i = 1; $i -le 100; $i++ ) {
            $ep = if ( $i % 2 ) { 'alpha' } else { 'bravo' }
            try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$($srv.Port)/repro/$ep" -TimeoutSec 60 } catch { $fail++ }
        }
        "  $($srv.Name): fresh JVM, serial warm-up failures $fail / 100"
    }
}

"Round: profile=$Profile phases=$( $Phases -join ',' ) newHotfixServer=$NewHotfixServer v1Server=$V1Server" | Tee-Object -FilePath $LogPath -Append

# Memory: every running test server holds its whole fixed heap. Stop any test server that is up but not part
# of this test run (opt-in calibration test servers, engines left running from an earlier session).
$inRound = @( ( Select-TestServers ).Name )
foreach ( $srv in $TestServers ) {
    if ( $inRound -notcontains $srv.Name -and ( Get-TestServerPid -Server $srv ) ) {
        Stop-TestServer -Server $srv
        "  stopped $($srv.Name): not part of this round" | Tee-Object -FilePath $LogPath -Append
    }
}
$os = Get-CimInstance Win32_OperatingSystem
( "  memory: {0:N1} GB free of {1:N1} GB before the round" -f ( $os.FreePhysicalMemory / 1MB ), ( $os.TotalVisibleMemorySize / 1MB ) ) | Tee-Object -FilePath $LogPath -Append

if ( $Phases -contains 'reset' )    { Step 'reset test servers (fresh + serial warm)' { Reset-Servers } }

if ( $Phases -contains 'contamination' ) {
    Step 'contamination test: known-bad check (buggy, warm)' { & "$scripts\Test-Contamination.ps1" -Server buggy -Profile $Profile -Sessions 1 -Label control }
    Step "contamination test: $NewHotfixServer cold"                { & "$scripts\Test-Contamination.ps1" -Server $NewHotfixServer -Profile $Profile -ColdStart -Label cold }
    Step "contamination test: $V1Server cold"                { & "$scripts\Test-Contamination.ps1" -Server $V1Server -Profile $Profile -ColdStart -Label cold }
    Step "contamination test: $NewHotfixServer warm"                { & "$scripts\Test-Contamination.ps1" -Server $NewHotfixServer -Profile $Profile -ColdStart -Sessions 1 -WarmRequests 500 -Label warm }
    # The cross-engine references have no bug; one short session each proves the workload
    # runs clean there (and that their DB wiring works) before their throughput is trusted.
    foreach ( $eng in @( 'lucee6', 'boxlang' ) ) {
        if ( ( Select-TestServers ).Name -contains $eng ) {
            Step "contamination test: $eng (no-bug reference)" { & "$scripts\Test-Contamination.ps1" -Server $eng -Profile $Profile -Sessions 1 -Label check }
        }
    }
    # The cold contamination tests leave JVMs failed every request until restart; everything after needs healthy ones.
    Step 'reset test servers after the contamination tests' { Reset-Servers }
}

if ( $Phases -contains 'lockwaits' ) {
    Step "evidence: $NewHotfixServer repro"  { & "$scripts\Get-LockEvidence.ps1" -Server $NewHotfixServer -Profile $Profile -Endpoint repro }
    Step "evidence: $V1Server repro"  { & "$scripts\Get-LockEvidence.ps1" -Server $V1Server -Profile $Profile -Endpoint repro }
    Step "evidence: $NewHotfixServer siblings" { & "$scripts\Get-LockEvidence.ps1" -Server $NewHotfixServer -Profile $Profile -Endpoint siblings }
}

if ( $Phases -contains 'realworkload' ) {
    Step 'throughput: real workload' { & "$scripts\Invoke-RealWorkloadBenchmark.ps1" -Profile $Profile @dropboxArgs }
}

if ( $Phases -contains 'construction' ) {
    Step 'throughput: construct shapes' { & "$scripts\Invoke-ConstructionBenchmark.ps1" -Profile $Profile @dropboxArgs }
    Step 'throughput: quickconstruct'   { & "$scripts\Invoke-ConstructionBenchmark.ps1" -Profile $Profile -Endpoint quickconstruct @dropboxArgs }
    Step 'throughput: fanout width'     { & "$scripts\Invoke-ConstructionBenchmark.ps1" -Profile $Profile -Widths ( $BenchProfiles[ $Profile ].Widths.Widths ) @dropboxArgs }
}

if ( $Phases -contains 'stress' ) {
    foreach ( $srv in @( 'u23', $V1Server, $NewHotfixServer ) ) {
        Step "torture: $srv" { & "$scripts\Invoke-LockStressTests.ps1" -Server $srv -Profile $Profile }
    }
    foreach ( $srv in @( 'u23', $V1Server, $NewHotfixServer ) ) {
        Step "torture p2 (deadlock): $srv" { & "$scripts\Invoke-LockStressTests.ps1" -Server $srv -Profile $Profile -Probes p2 -KillAfterP2 }
    }
    Step 'reset test servers after torture' { Reset-Servers }
}

if ( $Phases -contains 'endurance' ) {
    Step "soak: $NewHotfixServer" { & "$scripts\Invoke-LockSoak.ps1" -Server $NewHotfixServer -Profile $Profile @dropboxArgs }
}

"`n##### TEST RUN DONE $( Get-Date -Format 'HH:mm:ss' )  log: $LogPath" | Tee-Object -FilePath $LogPath -Append
