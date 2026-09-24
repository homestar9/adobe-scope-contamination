<#
.SYNOPSIS
    Runs the scope-contamination contamination test against one benchmark test server.

.DESCRIPTION
    Static analysis cannot prove a build actually stops the contamination under load.
    This contamination test does. It drives concurrent traffic at the two repro endpoints at the same
    time (the bug shows up when a fresh Alpha CFC and a fresh Bravo CFC construct
    concurrently and overwrite each other's variables scope), then counts:

      - HTTP 5xx responses (every caught repro failure),
      - bombardier transport errors (timeouts: a HUNG test server shows up here, not as 5xx),
      - completed requests (must equal the target, or the run is incomplete),
      - the test server's classified contamination tally from /repro/status,
      - new lines in logs\contamination_log.txt and logs\repro_errors.txt, with a
        signature histogram of the errors (the cold-failure of every request until restart NPE is NOT classified, so a
        dead JVM reads "100% 5xx, 0 classified").

    A clean pass is 0 of everything over the request target. Run this against the
    `buggy` test server first as a known-bad check: it must report contaminations > 0, or a clean
    result on any other test server proves nothing.

    Cold sessions: the cold class-init window is the highest-risk case and it is bimodal.
    -ColdStart kills the test server's JVM and starts it fresh before EVERY session, including the
    first, and the first requests of the session are the concurrent burst.

.PARAMETER Test server
    Test server name from scripts\TestServers.ps1 (u23, lock-u23, buggy, perclass-u23).

.PARAMETER Profile
    short (default): 2 sessions x 20,000 requests, about 5 minutes on a locked test server.
    long: 3 sessions x 100,000, the report-grade number. Explicit parameters win.

.PARAMETER Endpoints
    The two /repro endpoints driven at the same time (default alpha,bravo: the Quick workload).
    wire = six unrelated WireBox-built transients per request with no Quick and no shared base
    class. Examples: -Endpoints alpha,wire (Quick against unrelated construction) or
    -Endpoints wire,wire (unrelated construction only).

.PARAMETER TotalRequests
    Combined request target per session, split evenly across the two endpoints.

.PARAMETER Connections
    Concurrent connections per endpoint (so total in-flight is ~2x this).

.PARAMETER Sessions
    Number of sessions to run. Requests accumulate across sessions.

.PARAMETER ColdStart
    Fresh JVM before every session (kill + start).

.PARAMETER WarmRequests
    Serial single-connection requests (alternating alpha/bravo) sent and discarded before
    each session's burst. 0 for a cold burst; 2000 for the documented "warm" contamination test.

.EXAMPLE
    # known-bad check - expect contaminations > 0
    .\scripts\Test-Contamination.ps1 -Server buggy -TotalRequests 20000 -Connections 20

.EXAMPLE
    # the fresh-start contamination test - expect 0 over 300k across 3 fresh JVMs
    .\scripts\Test-Contamination.ps1 -Server perclass-u23 -ColdStart -TotalRequests 100000 -Connections 20 -Sessions 3

.EXAMPLE
    # the warmed-up contamination test - 2000 serial requests discarded first, then 20k concurrent
    .\scripts\Test-Contamination.ps1 -Server perclass-u23 -WarmRequests 2000 -TotalRequests 20000 -Label warm
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Server,
    [ValidateSet( 'short', 'long' )]
    [string] $Profile        = 'short',
    [ValidateSet( 'alpha', 'bravo', 'wire' )]
    [string[]] $Endpoints    = @( 'alpha', 'bravo' ),
    [int]    $TotalRequests  = 20000,
    [int]    $Connections    = 20,
    [int]    $Sessions       = 1,
    [switch] $ColdStart,
    [int]    $WarmRequests   = 0,
    [string] $Label          = '',
    [string] $BombardierPath = '',
    [string] $OutputDir      = ''
)

$ErrorActionPreference = 'Stop'
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
Use-BenchProfile -Profile $Profile -Section 'Contamination' -Bound $PSBoundParameters

$serverObj = Get-TestServer -Name $Server
if ( -not $Label ) { $Label = if ( $ColdStart ) { 'cold' } elseif ( $WarmRequests -gt 0 ) { 'warm' } else { 'contamination test' } }
if ( -not $OutputDir ) { $OutputDir = Get-BenchResultsRoot -Profile $Profile -Kind "contamination test-$Server-$Label" }
if ( -not ( Test-Path $OutputDir ) ) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$BombardierPath = Get-BenchBombardierPath -Override $BombardierPath
$logsDir = Join-Path $BenchRepoRoot 'logs'

function Get-Status {
    param( [int] $Port )
    try { return Invoke-RestMethod -Uri "http://127.0.0.1:$Port/repro/status" -TimeoutSec 15 }
    catch { return $null }
}

function Get-LineCount {
    param( [string] $Path )
    if ( -not ( Test-Path $Path ) ) { return 0 }
    return @( Get-Content $Path | Where-Object { $_.Trim() } ).Count
}

# The error log is one JSON object per line with a "type" and an exception message. A
# histogram of the first 60 characters of each message is enough to tell the failure of every request until restart NPE
# from a contaminated UPDATE from something unrelated.
function Get-ErrorSignatures {
    param( [string] $Path, [int] $Skip )
    $hist = @{}
    if ( -not ( Test-Path $Path ) ) { return $hist }
    $lines = @( Get-Content $Path | Where-Object { $_.Trim() } )
    if ( $lines.Count -le $Skip ) { return $hist }
    foreach ( $line in $lines[ $Skip..( $lines.Count - 1 ) ] ) {
        $sig = $line
        try {
            $o = $line | ConvertFrom-Json
            $type = if ( $o.PSObject.Properties.Name -contains 'type' ) { $o.type } else { '?' }
            $msg  = if ( $o.PSObject.Properties.Name -contains 'message' ) { [string] $o.message } elseif ( $o.PSObject.Properties.Name -contains 'detail' ) { [string] $o.detail } else { '' }
            $sig  = "$type :: " + $msg.Substring( 0, [math]::Min( 60, $msg.Length ) )
        } catch { $sig = $line.Substring( 0, [math]::Min( 80, $line.Length ) ) }
        if ( -not $hist.ContainsKey( $sig ) ) { $hist[ $sig ] = 0 }
        $hist[ $sig ]++
    }
    return $hist
}

$perEndpoint = [math]::Max( 1, [int]( $TotalRequests / 2 ) )
$grand = [ordered]@{ target = 0; completed = 0; http5xx = 0; errors = 0; classifiedDelta = 0; logContamination = 0; logErrors = 0 }
$sessionResults = @()
$signatures = @{}

Write-Host "=== contamination test: test server=$Server ($($serverObj.Role)) port=$($serverObj.Port) label=$Label ===" -ForegroundColor Cyan
if ( $Endpoints.Count -ne 2 ) { throw "-Endpoints takes exactly two endpoints (they may be the same)." }
Write-Host "Target: $TotalRequests requests/session x $Sessions session(s), $Connections conns/endpoint ($( $Endpoints -join '+' ) concurrent), coldStart=$ColdStart, warmRequests=$WarmRequests`n"

# Preflight: identity must match the table (jar bytes, lock design) before the numbers mean anything.
$identity = Get-TestServerIdentity -Server $serverObj -TimeoutSeconds 15
if ( -not $identity -and -not $ColdStart ) { throw "The $Server test server is not answering on port $($serverObj.Port). Start it (Install-TestServers.ps1)." }
if ( $identity ) { Assert-TestServerIdentity -Server $serverObj -Identity $identity }

$logsAside = Move-BenchLogsAside -Label "contamination test-$Server-$Label"
if ( $logsAside ) { Write-Host "Previous logs moved to $logsAside" }

for ( $session = 1; $session -le $Sessions; $session++ ) {
    if ( $ColdStart ) {
        Write-Host "`n--- Session ${session}: fresh JVM for $Server ---" -ForegroundColor Yellow
        $identity = Restart-TestServerFresh -Server $serverObj
        Assert-TestServerIdentity -Server $serverObj -Identity $identity
    }

    if ( $WarmRequests -gt 0 ) {
        Write-Host "[session $session] $WarmRequests serial warm-up requests (discarded)..."
        $warmFail = 0
        for ( $i = 1; $i -le $WarmRequests; $i++ ) {
            $ep = $Endpoints[ $i % 2 ]
            try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$($serverObj.Port)/repro/$ep" -TimeoutSec 30 } catch { $warmFail++ }
        }
        Write-Host "  warm-up failures: $warmFail (not counted)"
    }

    $before = Get-Status -Port $serverObj.Port
    $beforeCount = if ( $before ) { [int] $before.contaminations } else { 0 }
    $logContBefore = Get-LineCount ( Join-Path $logsDir 'contamination_log.txt' )
    $logErrBefore  = Get-LineCount ( Join-Path $logsDir 'repro_errors.txt' )

    Write-Host "`n[session $session] driving $( $Endpoints -join ' + ' ) concurrently ($perEndpoint requests each)..."

    # Names stay s<N>-alpha.json / s<N>-bravo.json for the default pair; a repeated endpoint gets a suffix.
    $name1 = $Endpoints[0]; $name2 = if ( $Endpoints[1] -eq $Endpoints[0] ) { "$($Endpoints[1])2" } else { $Endpoints[1] }
    $alphaOut = Join-Path $OutputDir "s$session-$name1.json"
    $bravoOut = Join-Path $OutputDir "s$session-$name2.json"

    # Alpha and bravo AT THE SAME TIME: concurrency between the two entity types is what
    # triggers the cross-contamination. Alpha as a background job, bravo in the foreground.
    $alphaJob = Start-Job -ScriptBlock {
        param( $bomb, $url, $n, $c, $out )
        $o = & $bomb --http1 -c $c -n $n -t 15s -l -p r -o json $url
        Set-Content -Path $out -Value ( $o -join "`n" ) -Encoding utf8
    } -ArgumentList $BombardierPath, "http://127.0.0.1:$($serverObj.Port)/repro/$($Endpoints[0])", $perEndpoint, $Connections, $alphaOut

    $bravoRaw = & $BombardierPath --http1 -c $Connections -n $perEndpoint -t 15s -l -p r -o json "http://127.0.0.1:$($serverObj.Port)/repro/$($Endpoints[1])"
    Set-Content -Path $bravoOut -Value ( $bravoRaw -join "`n" ) -Encoding utf8
    Receive-Job -Job $alphaJob -Wait | Out-Null
    Remove-Job -Job $alphaJob -Force

    $alpha = Read-BombardierJson -Path $alphaOut
    $bravo = Read-BombardierJson -Path $bravoOut

    $after = Get-Status -Port $serverObj.Port
    $afterCount = if ( $after ) { [int] $after.contaminations } else { 0 }
    $logContAfter = Get-LineCount ( Join-Path $logsDir 'contamination_log.txt' )
    $logErrAfter  = Get-LineCount ( Join-Path $logsDir 'repro_errors.txt' )

    $sess = [ordered]@{ session = $session; target = $perEndpoint * 2; completed = 0; http5xx = 0; errors = 0; rps = 0.0; classifiedDelta = $afterCount - $beforeCount; logContamination = $logContAfter - $logContBefore; logErrors = $logErrAfter - $logErrBefore; statusReachable = [bool] $after }
    foreach ( $r in @( $alpha, $bravo ) ) {
        if ( $r ) {
            $c = Get-BombardierCounts -Json $r
            $sess.completed += $c.Completed; $sess.http5xx += $c.Http5xx; $sess.errors += $c.Errors; $sess.rps += $c.Rps
        }
    }
    $sigs = Get-ErrorSignatures -Path ( Join-Path $logsDir 'repro_errors.txt' ) -Skip $logErrBefore
    foreach ( $k in $sigs.Keys ) { if ( -not $signatures.ContainsKey( $k ) ) { $signatures[ $k ] = 0 }; $signatures[ $k ] += $sigs[ $k ] }
    $sess.signatures = $sigs

    Write-Host ( "  session {0}: completed={1}/{2}  http5xx={3}  errors={4}  classified={5}  log-contamination={6}  log-errors={7}  rps={8}" -f $session, $sess.completed, $sess.target, $sess.http5xx, $sess.errors, $sess.classifiedDelta, $sess.logContamination, $sess.logErrors, [math]::Round( $sess.rps, 1 ) )
    if ( -not $sess.statusReachable ) { Write-Host "  /repro/status did not answer after the session: the test server may be hung or dead." -ForegroundColor Red }

    $sessionResults += [pscustomobject] $sess
    ( [pscustomobject] $sess ) | ConvertTo-Json -Depth 4 | Set-Content -Path ( Join-Path $OutputDir "s$session-summary.json" ) -Encoding utf8

    $grand.target += $sess.target; $grand.completed += $sess.completed; $grand.http5xx += $sess.http5xx; $grand.errors += $sess.errors
    $grand.classifiedDelta += $sess.classifiedDelta; $grand.logContamination += $sess.logContamination; $grand.logErrors += $sess.logErrors
}

# ---------------------------------------------------------------- verdict
Write-Host "`n=== contamination test result: $Server ($Label) ===" -ForegroundColor Cyan
Write-Host ( "  requests completed / target     : {0} / {1}" -f $grand.completed, $grand.target )
Write-Host ( "  HTTP 5xx responses              : {0}" -f $grand.http5xx )
Write-Host ( "  transport errors (timeouts etc) : {0}" -f $grand.errors )
Write-Host ( "  classified contaminations       : {0}" -f $grand.classifiedDelta )
Write-Host ( "  contamination_log.txt new lines : {0}" -f $grand.logContamination )
Write-Host ( "  repro_errors.txt new lines      : {0}" -f $grand.logErrors )
if ( $signatures.Count ) {
    Write-Host "  error signatures:"
    $signatures.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object { Write-Host ( "    {0,7}x  {1}" -f $_.Value, $_.Key ) }
}

$complete = ( $grand.completed -eq $grand.target )
$clean    = ( $grand.http5xx -eq 0 -and $grand.errors -eq 0 -and $grand.classifiedDelta -eq 0 -and $grand.logContamination -eq 0 -and $grand.logErrors -eq 0 )
$verdict  = if ( -not $complete ) { 'INCOMPLETE' } elseif ( $clean ) { 'CLEAN' } else { 'CONTAMINATION' }

$summary = [ordered]@{
    server                     = $Server
    label                   = $Label
    port                    = $serverObj.Port
    lockDesign              = $serverObj.LockDesign
    identity                = $identity
    coldStart               = [bool] $ColdStart
    warmRequests            = $WarmRequests
    sessions                = $Sessions
    endpoints               = $Endpoints
    connectionsPerEndpoint  = $Connections
    targetRequests          = $grand.target
    completedRequests       = $grand.completed
    http5xx                 = $grand.http5xx
    transportErrors         = $grand.errors
    classifiedContamination = $grand.classifiedDelta
    logContaminationLines   = $grand.logContamination
    logErrorLines           = $grand.logErrors
    errorSignatures         = $signatures
    perSession              = $sessionResults
    verdict                 = $verdict
    generatedAt             = ( Get-Date ).ToString( 'o' )
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path ( Join-Path $OutputDir 'contamination test-summary.json' ) -Encoding utf8

switch ( $verdict ) {
    'CLEAN' {
        Write-Host "`nCLEAN: 0 contamination, 0 errors over $($grand.completed) requests." -ForegroundColor Green
        Write-Host "(Only meaningful if the buggy known-bad check test server reported contaminations > 0 today.)" -ForegroundColor Yellow
        $exit = 0
    }
    'INCOMPLETE' {
        Write-Host "`nINCOMPLETE: $($grand.completed) of $($grand.target) requests completed. The test server hung or died; check the dumps and logs before reading any counter." -ForegroundColor Red
        $exit = 2
    }
    default {
        Write-Host "`nCONTAMINATION OBSERVED. Good if this is the buggy known-bad check; a FAILURE for a new hotfix server." -ForegroundColor Red
        $exit = 1
    }
}
Write-Host "Raw bombardier JSON + contamination test-summary.json in $OutputDir" -ForegroundColor Cyan
exit $exit
