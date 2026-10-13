<#
.SYNOPSIS
    Runs the whole Adobe hotfix test run, one load phase at a time, and writes a log.

.DESCRIPTION
    Order (the same as the results documents in docs/adobe-hotfixes):
      0. every test server restarted fresh and serially warmed;
      1. correctness: known-bad check on buggy; contamination tests on the new hotfix server,
         on v1 and on v3, every session on a freshly started, warmed server (no burst ever
         hits a server that is not online and warmed: the startup crash is a separate issue);
         the shared-temporary endpoint on buggy and on the new hotfix server;
      2. lock evidence under the real workload on the new hotfix server and v1;
      3. throughput: real workload, then the synthetic shapes, quickconstruct, width test,
         on every installed test server including the Lucee 6 and BoxLang references;
      4. lock stress tests on the Update 23 test servers, deadlock probe last;
      5. endurance test on the new hotfix server, then on buggy as the no-lock control.

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
.EXAMPLE
    # the Adobe servers only (no Lucee 6 / BoxLang)
    .\scripts\Invoke-AdobeV3TestRun.ps1 -Servers u23,buggy,lock-u23,perclass-u23,localtemp-u23
#>
[CmdletBinding()]
param(
    [ValidateSet( 'short', 'long' )]
    [string]   $Profile   = 'short',
    [ValidateSet( 'reset', 'contamination', 'lockwaits', 'realworkload', 'construction', 'stress', 'endurance' )]
    [string[]] $Phases    = @( 'reset', 'contamination', 'lockwaits', 'realworkload', 'construction', 'stress', 'endurance' ),
    [string]   $NewHotfixServer = 'localtemp-u23',
    [string]   $V1Server = 'lock-u23',
    [string]   $V3Server = 'perclass-u23',
    [string[]] $Servers  = @(),
    [switch]   $StopDropbox,
    [string]   $LogPath   = ''
)

$ErrorActionPreference = 'Continue'
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
if ( -not $LogPath ) { $LogPath = Join-Path ( Split-Path -Parent ( Get-BenchResultsRoot -Profile $Profile -Kind 'round' ) ) "round-$( Get-Date -Format 'yyyyMMdd-HHmmss' ).log" }
$logDir = Split-Path -Parent $LogPath
if ( -not ( Test-Path $logDir ) ) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$scripts = $PSScriptRoot
$dropboxArgs = @{}
if ( $StopDropbox ) { $dropboxArgs.StopDropbox = $true }
$serverArgs = @{}
if ( $Servers.Count ) { $serverArgs.Servers = $Servers }
$roundServers = @( ( Select-TestServers -Names $Servers ).Name )

function Step {
    param( [string] $Name, [scriptblock] $Body )
    "`n##### $( Get-Date -Format 'HH:mm:ss' ) START $Name" | Tee-Object -FilePath $LogPath -Append
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { & $Body 2>&1 | Tee-Object -FilePath $LogPath -Append }
    catch { "STEP FAILED: $Name :: $_" | Tee-Object -FilePath $LogPath -Append }
    "##### $( Get-Date -Format 'HH:mm:ss' ) END $Name ($( [math]::Round( $sw.Elapsed.TotalMinutes, 1 ) ) min)" | Tee-Object -FilePath $LogPath -Append
}

function Reset-Servers {
    foreach ( $srv in ( Select-TestServers -Names $Servers ) ) {
        $null = Restart-TestServerFresh -Server $srv
        $fail = 0
        for ( $i = 1; $i -le 100; $i++ ) {
            $ep = if ( $i % 2 ) { 'alpha' } else { 'bravo' }
            try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$($srv.Port)/repro/$ep" -TimeoutSec 60 } catch { $fail++ }
        }
        "  $($srv.Name): fresh JVM, serial warm-up failures $fail / 100"
    }
}

"Round: profile=$Profile phases=$( $Phases -join ',' ) newHotfixServer=$NewHotfixServer v1Server=$V1Server v3Server=$V3Server servers=$( $roundServers -join ',' )" | Tee-Object -FilePath $LogPath -Append

# Memory: every running test server holds its whole fixed heap. Stop any test server that is up but not part
# of this test run (opt-in calibration test servers, engines left running from an earlier session).
$inRound = $roundServers
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
    # Every session below restarts its server, waits until it answers, sends 500 serial requests,
    # and only then bursts. No burst ever hits a freshly started, un-warmed server.
    Step 'contamination test: known-bad check (buggy, warm)' { & "$scripts\Test-Contamination.ps1" -Server buggy -Profile $Profile -Sessions 1 -Label control }
    Step "contamination test: $NewHotfixServer fresh JVMs, warmed"  { & "$scripts\Test-Contamination.ps1" -Server $NewHotfixServer -Profile $Profile -ColdStart -WarmRequests 500 -Label warm }
    Step "contamination test: $V1Server fresh JVMs, warmed"  { & "$scripts\Test-Contamination.ps1" -Server $V1Server -Profile $Profile -ColdStart -WarmRequests 500 -Label warm }
    if ( $roundServers -contains $V3Server ) {
        Step "contamination test: $V3Server fresh JVM, warmed" { & "$scripts\Test-Contamination.ps1" -Server $V3Server -Profile $Profile -ColdStart -Sessions 1 -WarmRequests 500 -Label warm }
    }
    # The mechanism alone (shared compiler temporary, no database): must contaminate on buggy, must not on the new hotfix server.
    Step 'contamination test: buggy tempvar (known-bad check)'        { & "$scripts\Test-Contamination.ps1" -Server buggy -Profile $Profile -Endpoints tempvar,tempvar -Sessions 1 -Label tempvar }
    Step "contamination test: $NewHotfixServer tempvar"              { & "$scripts\Test-Contamination.ps1" -Server $NewHotfixServer -Profile $Profile -Endpoints tempvar,tempvar -Sessions 1 -Label tempvar }
    # The cross-engine references have no bug; one short session each proves the workload
    # runs clean there (and that their DB wiring works) before their throughput is trusted.
    foreach ( $eng in @( 'lucee6', 'boxlang' ) ) {
        if ( $roundServers -contains $eng ) {
            Step "contamination test: $eng (no-bug reference)" { & "$scripts\Test-Contamination.ps1" -Server $eng -Profile $Profile -Sessions 1 -Label check }
        }
    }
    # Everything after needs fresh, serially warmed JVMs on every server.
    Step 'reset test servers after the contamination tests' { Reset-Servers }
}

if ( $Phases -contains 'lockwaits' ) {
    Step "evidence: $NewHotfixServer repro"  { & "$scripts\Get-LockEvidence.ps1" -Server $NewHotfixServer -Profile $Profile -Endpoint repro }
    Step "evidence: $V1Server repro"  { & "$scripts\Get-LockEvidence.ps1" -Server $V1Server -Profile $Profile -Endpoint repro }
    Step "evidence: $NewHotfixServer siblings" { & "$scripts\Get-LockEvidence.ps1" -Server $NewHotfixServer -Profile $Profile -Endpoint siblings }
}

if ( $Phases -contains 'realworkload' ) {
    Step 'throughput: real workload' { & "$scripts\Invoke-RealWorkloadBenchmark.ps1" -Profile $Profile @dropboxArgs @serverArgs }
}

if ( $Phases -contains 'construction' ) {
    Step 'throughput: construct shapes' { & "$scripts\Invoke-ConstructionBenchmark.ps1" -Profile $Profile @dropboxArgs @serverArgs }
    Step 'throughput: quickconstruct'   { & "$scripts\Invoke-ConstructionBenchmark.ps1" -Profile $Profile -Endpoint quickconstruct @dropboxArgs @serverArgs }
    Step 'throughput: fanout width'     { & "$scripts\Invoke-ConstructionBenchmark.ps1" -Profile $Profile -Widths ( $BenchProfiles[ $Profile ].Widths.Widths ) @dropboxArgs @serverArgs }
}

if ( $Phases -contains 'stress' ) {
    $stressServers = @( @( 'u23', $V1Server, $V3Server, $NewHotfixServer ) | Where-Object { $roundServers -contains $_ } | Select-Object -Unique )
    foreach ( $srv in $stressServers ) {
        Step "torture: $srv" { & "$scripts\Invoke-LockStressTests.ps1" -Server $srv -Profile $Profile }
    }
    foreach ( $srv in $stressServers ) {
        Step "torture p2 (deadlock): $srv" { & "$scripts\Invoke-LockStressTests.ps1" -Server $srv -Profile $Profile -Probes p2 -KillAfterP2 }
    }
    Step 'reset test servers after torture' { Reset-Servers }
}

if ( $Phases -contains 'endurance' ) {
    Step "soak: $NewHotfixServer" { & "$scripts\Invoke-LockSoak.ps1" -Server $NewHotfixServer -Profile $Profile @dropboxArgs }
    # The no-lock control: on this machine throughput falls over a run for reasons unrelated to
    # any lock (September 2026), so the hotfix server's curve is read against this one.
    if ( $roundServers -contains 'buggy' ) {
        Step 'soak: buggy (no-lock control)' { & "$scripts\Invoke-LockSoak.ps1" -Server buggy -Profile $Profile @dropboxArgs }
    }
}

"`n##### TEST RUN DONE $( Get-Date -Format 'HH:mm:ss' )  log: $LogPath" | Tee-Object -FilePath $LogPath -Append
