<#
.SYNOPSIS
    Long mixed-load endurance test of one test server, looking for the slow failures a short benchmark cannot
    see: deadlock, creeping lock contention, throughput decay, and an ever-growing lock map.

.DESCRIPTION
    Adobe v3 keeps one ReentrantLock per CFC path in a static map and holds a class's lock
    together with every ancestor's lock while the component body runs. That design has three
    long-run risks that a 20-second benchmark will not show:

      - a hard deadlock when two pseudo-constructors lazily construct each other (no timeout);
      - contention that grows as more classes and more request threads pile up;
      - a lock map that grows without bound.

    The endurance test drives four targets at once for -Minutes, in -SliceMinutes slices:

        /repro/alpha                                  c = ReproConnections
        /repro/bravo                                  c = ReproConnections
        /benchmark/construct?count=200&shape=fanout   c = FanoutConnections
        /benchmark/quickconstruct?count=50            c = QuickConnections

    and every -SampleSeconds while a slice runs it takes a `Thread.print -l` dump, a
    `GC.heap_info`, and reads the lock-map size from /torture/locks (falling back to
    /benchmark/engine constructionLocks). Dump parsing is LockEvidence.Common.ps1, the same
    rules as Get-LockEvidence.ps1.

    Pass (plan, endurance test row):
      - 0 5xx and 0 transport errors across every slice and target;
      - no Java-level deadlock in any dump;
      - lock waiters per dump (parked + BLOCKED on resolveName) over the last 2 slices
        <= 1.2 x the first 2 slices (below 1 waiter/dump on both sides is treated as noise);
      - combined RPS over the last 2 slices >= 90% of the first 2 slices;
      - lock-map size levels off (the last two readings are equal). Required on a per-class
        test server; reported as n/a on test servers without a map.

    Exit code 0 on pass, 1 on fail.

.EXAMPLE
    .\scripts\Invoke-LockSoak.ps1 -Server perclass-u23 -StopDropbox
    .\scripts\Invoke-LockSoak.ps1 -Server lock-u23 -Minutes 480 -SliceMinutes 20 -StopDropbox
    .\scripts\Invoke-LockSoak.ps1 -Server perclass-u23 -Minutes 10 -SliceMinutes 2 -SampleSeconds 30
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Server,
    [ValidateSet( 'short', 'long' )]
    [string] $Profile            = 'short',
    [int]    $Minutes            = 45,
    [int]    $SliceMinutes       = 5,
    [int]    $ReproConnections   = 16,
    [int]    $FanoutConnections  = 8,
    [int]    $QuickConnections   = 8,
    [int]    $SampleSeconds      = 60,
    [string] $OutputDir          = '',
    [string] $BombardierPath     = '',
    [string] $JcmdPath           = '',
    [switch] $StopDropbox
)

$ErrorActionPreference = 'Stop'

. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
Use-BenchProfile -Profile $Profile -Section 'Soak' -Bound $PSBoundParameters
. ( Join-Path $PSScriptRoot 'LockEvidence.Common.ps1' )

$serverInfo = Get-TestServer -Name $Server
if ( -not $OutputDir ) { $OutputDir = Get-BenchResultsRoot -Profile $Profile -Kind "soak-$Server" }
if ( -not ( Test-Path $OutputDir ) ) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if ( $SliceMinutes -le 0 -or $Minutes -le 0 ) { throw "-Minutes and -SliceMinutes must be positive." }
$sliceCount = [int] [math]::Ceiling( $Minutes / $SliceMinutes )

$BombardierPath = Get-BenchBombardierPath -Override $BombardierPath
$JcmdPath       = Get-BenchJdkTool -Tool jcmd -Override $JcmdPath

# ---------------------------------------------------------------- preflight
$identity = Get-TestServerIdentity -Server $serverInfo -TimeoutSeconds 30
if ( -not $identity ) { throw "The $Server test server is not answering /benchmark/engine on port $($serverInfo.Port). Start it first." }
$identity | ConvertTo-Json -Depth 6 | Set-Content -Path ( Join-Path $OutputDir "engine-$Server.json" ) -Encoding utf8
$jvmPid = Get-TestServerPid -Server $serverInfo
if ( -not $jvmPid ) { throw "No process is listening on port $($serverInfo.Port) for $Server." }
Write-Host "$Server : CF $($identity.productVersion), JVM $($identity.jvmVersion), PID $jvmPid, lock design $($serverInfo.LockDesign)" -ForegroundColor Cyan

$logsMoved = Move-BenchLogsAside -Label "soak-$Server"
if ( $logsMoved ) { Write-Host "Previous logs moved to $logsMoved" }

$base    = "http://127.0.0.1:$($serverInfo.Port)"
$targets = @(
    [pscustomobject]@{ Key = 'alpha';          Url = "$base/repro/alpha";                                Connections = $ReproConnections }
    [pscustomobject]@{ Key = 'bravo';          Url = "$base/repro/bravo";                                Connections = $ReproConnections }
    [pscustomobject]@{ Key = 'fanout';         Url = "$base/benchmark/construct?count=200&shape=fanout"; Connections = $FanoutConnections }
    [pscustomobject]@{ Key = 'quickconstruct'; Url = "$base/benchmark/quickconstruct?count=50";          Connections = $QuickConnections }
)

function Get-SoakMapSize {
    <#
        The per-class lock map size, or $null. /torture/locks is the cheap source; test servers without
        the lock stress test handler 404, so fall back to the reflective constructionLocks block in
        /benchmark/engine. Both failures are tolerated: a missing reading is reported, not fatal.
    #>
    try {
        $r = Invoke-RestMethod -Uri "$base/torture/locks" -TimeoutSec 10
        if ( $r -and $r.PSObject.Properties.Name -contains 'mapSize' -and $null -ne $r.mapSize ) { return [int] $r.mapSize }
    }
    catch { }
    try {
        $e = Invoke-RestMethod -Uri "$base/benchmark/engine" -TimeoutSec 10
        if ( $e -and $e.PSObject.Properties.Name -contains 'constructionLocks' ) {
            $cl = $e.constructionLocks
            foreach ( $p in @( 'mapSize', 'size' ) ) {
                if ( $cl.PSObject.Properties.Name -contains $p -and $null -ne $cl.$p ) { return [int] $cl.$p }
            }
        }
    }
    catch { }
    return $null
}

function Get-SoakHeapUsedMb {
    <# 'garbage-first heap   total 2097152K, used 812345K' -> 793.3 #>
    param( [string] $Text )
    if ( $Text -match 'total\s+(\d+)K,\s+used\s+(\d+)K' ) { return [math]::Round( [double] $matches[2] / 1024, 1 ) }
    return $null
}

function Get-SoakMean {
    param( [double[]] $Values )
    $v = @( $Values )
    if ( $v.Count -eq 0 ) { return 0 }
    return ( $v | Measure-Object -Average ).Average
}

# ---------------------------------------------------------------- run
$dropboxExe      = $null
$slices          = New-Object System.Collections.Generic.List[object]
$allMeasurements = New-Object System.Collections.Generic.List[object]
$mapReadings     = New-Object System.Collections.Generic.List[object]
$dumpFailures    = 0
$jobs            = @()
$startedAt       = Get-Date

try {
    if ( $StopDropbox ) { $dropboxExe = Stop-DropboxForBenchmark }

    for ( $slice = 1; $slice -le $sliceCount; $slice++ ) {
        $sliceTag = '{0:D2}' -f $slice
        Write-Host "`n=== Slice $slice/$sliceCount ($SliceMinutes min) ===" -ForegroundColor Cyan

        $jobs = @( foreach ( $t in $targets ) {
            $out = Join-Path $OutputDir "slice-$sliceTag-$($t.Key).json"
            Start-Job -ScriptBlock {
                param( $exe, $url, $c, $d, $out )
                $o = & $exe --http1 -c $c -d $d -t 15s -l -p r -o json $url
                Set-Content -Path $out -Value ( $o -join "`n" ) -Encoding utf8
            } -ArgumentList $BombardierPath, $t.Url, $t.Connections, "$( $SliceMinutes * 60 )s", $out
        } )

        $sliceMeasurements = New-Object System.Collections.Generic.List[object]
        $sliceMap  = $null
        $sliceHeap = $null
        $k = 0
        while ( $true ) {
            # Wait-Job returns early when every job has finished, so the last sample of a
            # slice is never taken against an idle server.
            Wait-Job -Job $jobs -Timeout $SampleSeconds | Out-Null
            if ( @( $jobs | Where-Object { $_.State -eq 'Running' } ).Count -eq 0 ) { break }
            $k++
            $tag = '{0}-{1:D2}' -f $sliceTag, $k

            try {
                $text = Get-ThreadDumpText -JcmdPath $JcmdPath -Pid $jvmPid
                Set-Content -Path ( Join-Path $OutputDir "dump-$tag.txt" ) -Value $text -Encoding utf8
                $m = Measure-ThreadDump -Text $text -Label "dump-$tag.txt"
                $sliceMeasurements.Add( $m )
                $allMeasurements.Add( $m )
                if ( $m.deadlockDetected ) { Write-Host "  DEADLOCK reported in dump-$tag.txt" -ForegroundColor Red }
            }
            catch {
                $dumpFailures++
                Write-Host "  thread dump $tag failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }

            try {
                $heap = @( & $JcmdPath $jvmPid GC.heap_info ) -join "`r`n"
                Set-Content -Path ( Join-Path $OutputDir "heap-$tag.txt" ) -Value $heap -Encoding utf8
                $h = Get-SoakHeapUsedMb -Text $heap
                if ( $null -ne $h ) { $sliceHeap = $h }
            }
            catch { Write-Host "  heap info $tag failed: $($_.Exception.Message)" -ForegroundColor Yellow }

            $size = Get-SoakMapSize
            if ( $null -ne $size ) {
                $sliceMap = $size
                $mapReadings.Add( [pscustomobject]@{ sample = $tag; at = ( Get-Date ).ToString( 'o' ); mapSize = $size } )
            }

            $last = $sliceMeasurements | Select-Object -Last 1
            $waitNow = if ( $last ) { $last.parkedOnResolveName + $last.blockedOnResolveName } else { '?' }
            Write-Host ( "  sample {0}: resolveName waiters {1}, mapSize {2}, heap used {3} MB" -f $tag, $waitNow, $( if ( $null -ne $size ) { $size } else { 'n/a' } ), $( if ( $null -ne $sliceHeap ) { $sliceHeap } else { '?' } ) )
        }

        Receive-Job -Job $jobs -ErrorAction SilentlyContinue | Out-Null
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        $jobs = @()

        # ---- load results for this slice
        $rps = 0.0; $completed = 0; $http5xx = 0; $errors = 0
        $missing = New-Object System.Collections.Generic.List[string]
        $perTarget = [ordered]@{}
        foreach ( $t in $targets ) {
            $json = Read-BombardierJson -Path ( Join-Path $OutputDir "slice-$sliceTag-$($t.Key).json" )
            if ( -not $json ) { $missing.Add( $t.Key ); continue }
            $c = Get-BombardierCounts -Json $json
            $rps += $c.Rps; $completed += $c.Completed; $http5xx += $c.Http5xx; $errors += $c.Errors
            $perTarget[ $t.Key ] = [ordered]@{ rps = [math]::Round( $c.Rps, 1 ); completed = $c.Completed; http5xx = $c.Http5xx; errors = $c.Errors }
        }

        $agg = Merge-ThreadDumpMeasurements -Measurements $sliceMeasurements.ToArray()
        $record = [pscustomobject][ordered]@{
            slice                         = $slice
            rps                           = [math]::Round( $rps, 1 )
            completed                     = $completed
            http5xx                       = $http5xx
            errors                        = $errors
            missingResults                = $missing.ToArray()
            dumps                         = $agg.dumps
            avgParkedOnResolveNamePerDump = $agg.avgParkedOnResolveNamePerDump
            avgBlockedOnResolveNamePerDump= $agg.avgBlockedOnResolveNamePerDump
            lockWaitersPerDump            = [math]::Round( $agg.avgParkedOnResolveNamePerDump + $agg.avgBlockedOnResolveNamePerDump, 2 )
            avgDistinctLocksPerDump       = $agg.avgDistinctLocksPerDump
            deadlock                      = $agg.anyDeadlock
            mapSize                       = $sliceMap
            heapUsedMb                    = $sliceHeap
            perTarget                     = $perTarget
        }
        $slices.Add( $record )
        Write-Host ( "  slice {0}: rps {1}, completed {2}, 5xx {3}, errors {4}, waiters/dump {5}, mapSize {6}" -f $slice, $record.rps, $completed, $http5xx, $errors, $record.lockWaitersPerDump, $( if ( $null -ne $sliceMap ) { $sliceMap } else { 'n/a' } ) )
        if ( $missing.Count -gt 0 ) { Write-Host "  no bombardier result for: $( $missing -join ', ' )" -ForegroundColor Yellow }
    }
}
finally {
    if ( $jobs.Count -gt 0 ) {
        $jobs | Stop-Job -ErrorAction SilentlyContinue
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    if ( $dropboxExe ) { Start-DropboxAfterBenchmark -ExePath $dropboxExe }
}

# ---------------------------------------------------------------- evaluate
$s = $slices.ToArray()
$n = $s.Count
# First and last two slices; with fewer than four slices the windows overlap, which is noted.
$firstWin = @( $s | Select-Object -First ( [math]::Min( 2, $n ) ) )
$lastWin  = @( $s | Select-Object -Last  ( [math]::Min( 2, $n ) ) )
$overlap  = $n -lt 4

$reasons = New-Object System.Collections.Generic.List[string]
$checks  = [ordered]@{}

$tot5xx     = ( $s | Measure-Object -Property http5xx -Sum ).Sum
$totErrors  = ( $s | Measure-Object -Property errors -Sum ).Sum
$missingAll = @( $s | ForEach-Object { $_.missingResults } | Where-Object { $_ } )
$okErrors   = ( $tot5xx -eq 0 -and $totErrors -eq 0 -and $missingAll.Count -eq 0 -and $n -gt 0 )
$checks.noErrors = [ordered]@{ pass = $okErrors; http5xx = $tot5xx; errors = $totErrors; missingResults = $missingAll.Count }
if ( -not $okErrors ) { $reasons.Add( "errors: $tot5xx 5xx, $totErrors transport errors, $($missingAll.Count) missing bombardier results" ) }

$overall   = Merge-ThreadDumpMeasurements -Measurements $allMeasurements.ToArray()
$okDead    = -not $overall.anyDeadlock
$checks.noDeadlock = [ordered]@{ pass = $okDead; dumps = $overall.dumps; deadlockDumps = $overall.deadlockDumps }
if ( -not $okDead ) { $reasons.Add( "deadlock reported in $( $overall.deadlockDumps -join ', ' )" ) }
if ( $overall.dumps -eq 0 ) { $reasons.Add( 'no thread dump succeeded, contention could not be judged' ) }

# Waiters = parked (v3) + BLOCKED (v1) on resolveName, so the same rule works for either lock.
$waitFirst = Get-SoakMean -Values @( $firstWin | ForEach-Object { $_.lockWaitersPerDump } )
$waitLast  = Get-SoakMean -Values @( $lastWin  | ForEach-Object { $_.lockWaitersPerDump } )
# Below one waiter per dump the ratio is sampling noise (0.2 -> 0.4 is "2x" but meaningless).
$okWait = ( $overall.dumps -gt 0 ) -and ( ( $waitLast -le 1.2 * $waitFirst ) -or ( $waitFirst -lt 1 -and $waitLast -lt 1 ) )
$checks.contentionStable = [ordered]@{ pass = $okWait; firstMean = [math]::Round( $waitFirst, 2 ); lastMean = [math]::Round( $waitLast, 2 ); limit = [math]::Round( 1.2 * $waitFirst, 2 ); windowsOverlap = $overlap }
if ( -not $okWait -and $overall.dumps -gt 0 ) { $reasons.Add( ( "lock waiters/dump grew: last {0:N2} > 1.2 x first {1:N2}" -f $waitLast, $waitFirst ) ) }

$rpsFirst = Get-SoakMean -Values @( $firstWin | ForEach-Object { $_.rps } )
$rpsLast  = Get-SoakMean -Values @( $lastWin  | ForEach-Object { $_.rps } )
$okRps    = ( $rpsFirst -gt 0 ) -and ( $rpsLast -ge 0.9 * $rpsFirst )
$checks.throughputStable = [ordered]@{ pass = $okRps; firstMean = [math]::Round( $rpsFirst, 1 ); lastMean = [math]::Round( $rpsLast, 1 ); ratio = $( if ( $rpsFirst -gt 0 ) { [math]::Round( $rpsLast / $rpsFirst, 3 ) } else { $null } ); windowsOverlap = $overlap }
if ( -not $okRps ) { $reasons.Add( ( "throughput fell: last {0:N1} rps < 90% of first {1:N1} rps" -f $rpsLast, $rpsFirst ) ) }

$readings = @( $mapReadings | ForEach-Object { $_.mapSize } )
if ( $readings.Count -ge 2 ) {
    $okMap = ( $readings[-1] -eq $readings[-2] )
    $checks.mapLevelsOff = [ordered]@{ pass = $okMap; applicable = $true; readings = $readings.Count; first = $readings[0]; last = $readings[-1]; previous = $readings[-2] }
    if ( -not $okMap ) { $reasons.Add( "lock map still growing: last readings $($readings[-2]) -> $($readings[-1])" ) }
}
elseif ( $serverInfo.LockDesign -eq 'perclass' ) {
    # On the per-class test server the map is the thing under test; no reading means no evidence.
    $checks.mapLevelsOff = [ordered]@{ pass = $false; applicable = $true; readings = $readings.Count }
    $reasons.Add( "lock map size unavailable ($($readings.Count) readings) on a per-class test server; /torture/locks or /benchmark/engine constructionLocks must report it" )
}
else {
    $checks.mapLevelsOff = [ordered]@{ pass = $true; applicable = $false; readings = $readings.Count; note = "test server lock design '$($serverInfo.LockDesign)' has no per-class map" }
}

$pass = ( $reasons.Count -eq 0 )
if ( $dumpFailures -gt 0 ) { Write-Host "Note: $dumpFailures thread dump(s) failed during the soak." -ForegroundColor Yellow }

# ---------------------------------------------------------------- report
Write-Host "`n=== Soak summary: $Server, $n x $SliceMinutes min ===" -ForegroundColor Cyan
$hdr = "{0,5} {1,9} {2,10} {3,6} {4,7} {5,8} {6,8} {7,8} {8,8}"
Write-Host ( $hdr -f 'slice', 'rps', 'completed', '5xx', 'errors', 'parked', 'blocked', 'mapSize', 'heapMB' )
foreach ( $r in $s ) {
    Write-Host ( $hdr -f $r.slice, $r.rps, $r.completed, $r.http5xx, $r.errors, $r.avgParkedOnResolveNamePerDump, $r.avgBlockedOnResolveNamePerDump, $( if ( $null -ne $r.mapSize ) { $r.mapSize } else { 'n/a' } ), $( if ( $null -ne $r.heapUsedMb ) { $r.heapUsedMb } else { '?' } ) )
}
Write-Host "(parked / blocked = average threads per dump waiting on the construction lock in resolveName)"

if ( @( $overall.topLocks ).Count -gt 0 ) {
    Write-Host "`nMost contended ReentrantLocks over the soak:" -ForegroundColor Cyan
    foreach ( $l in $overall.topLocks ) { Write-Host ( "  {0,-20} {1,7}  {2,-32} {3}" -f $l.addr, $l.waiters, $l.ownerCfc, $l.ownerThread ) }
}

$summary = [ordered]@{
    server            = $Server
    lockDesign     = $serverInfo.LockDesign
    pass           = $pass
    reasons        = $reasons.ToArray()
    startedAt      = $startedAt.ToString( 'o' )
    finishedAt     = ( Get-Date ).ToString( 'o' )
    parameters     = [ordered]@{
        minutes = $Minutes; sliceMinutes = $SliceMinutes; slices = $sliceCount; sampleSeconds = $SampleSeconds
        reproConnections = $ReproConnections; fanoutConnections = $FanoutConnections; quickConnections = $QuickConnections
        targets = @( $targets | ForEach-Object { [ordered]@{ key = $_.Key; url = $_.Url; connections = $_.Connections } } )
        stopDropbox = [bool] $StopDropbox
    }
    pid            = $jvmPid
    identity       = $identity
    logsMovedTo    = $logsMoved
    checks         = $checks
    slices         = $s
    mapReadings    = $mapReadings.ToArray()
    dumpFailures   = $dumpFailures
    contention     = [ordered]@{
        dumps                          = $overall.dumps
        avgParkedOnResolveNamePerDump  = $overall.avgParkedOnResolveNamePerDump
        avgBlockedOnResolveNamePerDump = $overall.avgBlockedOnResolveNamePerDump
        distinctLocksContended         = $overall.distinctLocksContended
        avgDistinctLocksPerDump        = $overall.avgDistinctLocksPerDump
        maxDistinctLocksPerDump        = $overall.maxDistinctLocksPerDump
        dominantLockShare              = $overall.dominantLockShare
        topLocks                       = $overall.topLocks
        topMonitors                    = $overall.topMonitors
        topBlockSites                  = $overall.topBlockSites
        deadlockText                   = $overall.deadlockText
    }
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path ( Join-Path $OutputDir 'soak-summary.json' ) -Encoding utf8

$md = New-Object System.Collections.Generic.List[string]
$md.Add( "# Lock soak: $Server" )
$md.Add( '' )
$md.Add( "Result: **$( if ( $pass ) { 'PASS' } else { 'FAIL' } )**. $n slices of $SliceMinutes min, started $($startedAt.ToString( 'yyyy-MM-dd HH:mm' )), CF $($identity.productVersion), JVM $($identity.jvmVersion), lock design $($serverInfo.LockDesign)." )
$md.Add( '' )
$md.Add( "Load per slice: alpha c=$ReproConnections, bravo c=$ReproConnections, fanout c=$FanoutConnections, quickconstruct c=$QuickConnections. One thread dump, heap info and map-size read every $SampleSeconds s." )
$md.Add( '' )
$md.Add( '| Slice | RPS | Completed | 5xx | Errors | Parked/dump | Blocked/dump | Map size | Heap MB |' )
$md.Add( '|---:|---:|---:|---:|---:|---:|---:|---:|---:|' )
foreach ( $r in $s ) {
    $md.Add( "| $($r.slice) | $($r.rps) | $($r.completed) | $($r.http5xx) | $($r.errors) | $($r.avgParkedOnResolveNamePerDump) | $($r.avgBlockedOnResolveNamePerDump) | $( if ( $null -ne $r.mapSize ) { $r.mapSize } else { 'n/a' } ) | $( if ( $null -ne $r.heapUsedMb ) { $r.heapUsedMb } else { '?' } ) |" )
}
$md.Add( '' )
$md.Add( 'Parked/Blocked: average threads per dump waiting on the construction lock in `TemplateProxyFactory.resolveName` (v3 parks on a ReentrantLock, v1 blocks on a monitor).' )
$md.Add( '' )
$md.Add( '| Check | Result | Detail |' )
$md.Add( '|---|---|---|' )
$md.Add( "| 0 5xx, 0 errors | $( if ( $checks.noErrors.pass ) { 'pass' } else { 'FAIL' } ) | $tot5xx 5xx, $totErrors errors, $($missingAll.Count) missing results |" )
$md.Add( "| No deadlock | $( if ( $checks.noDeadlock.pass ) { 'pass' } else { 'FAIL' } ) | $($overall.dumps) dumps$( if ( -not $okDead ) { '; ' + ( $overall.deadlockDumps -join ', ' ) } ) |" )
$md.Add( ( "| Waiters last 2 <= 1.2 x first 2 | {0} | {1:N2} vs {2:N2} |" -f $( if ( $okWait ) { 'pass' } else { 'FAIL' } ), $waitLast, $waitFirst ) )
$md.Add( ( "| RPS last 2 >= 90% of first 2 | {0} | {1:N1} vs {2:N1} |" -f $( if ( $okRps ) { 'pass' } else { 'FAIL' } ), $rpsLast, $rpsFirst ) )
$mapResult = if ( -not $checks.mapLevelsOff.applicable ) { 'n/a' } elseif ( $checks.mapLevelsOff.pass ) { 'pass' } else { 'FAIL' }
$mapDetail = if ( $readings.Count -ge 2 ) { "first $($readings[0]), last two $($readings[-2]) -> $($readings[-1])" } else { "$($readings.Count) readings" }
$md.Add( "| Lock map levels off | $mapResult | $mapDetail |" )
if ( $overlap ) { $md.Add( '' ); $md.Add( 'Fewer than four slices: the first-2 and last-2 windows overlap.' ) }
if ( $reasons.Count -gt 0 ) {
    $md.Add( '' ); $md.Add( 'Reasons:' ); $md.Add( '' )
    foreach ( $x in $reasons ) { $md.Add( "- $x" ) }
}
if ( @( $overall.topLocks ).Count -gt 0 ) {
    $md.Add( '' )
    $md.Add( "Contended construction locks: $($overall.distinctLocksContended) distinct (per dump avg $($overall.avgDistinctLocksPerDump), max $($overall.maxDistinctLocksPerDump)); busiest lock took $([math]::Round( $overall.dominantLockShare * 100, 1 ))% of parked waits." )
    $md.Add( '' )
    $md.Add( '| Lock | Waiters | Owner CFC | Owner thread |' )
    $md.Add( '|---|---:|---|---|' )
    foreach ( $l in $overall.topLocks ) { $md.Add( "| ``$($l.addr)`` | $($l.waiters) | $($l.ownerCfc) | $($l.ownerThread) |" ) }
}
$md.Add( '' )
$md.Add( 'Raw data: `slice-NN-<target>.json` (bombardier), `dump-NN-KK.txt` (Thread.print -l), `heap-NN-KK.txt` (GC.heap_info), `soak-summary.json`.' )
Set-Content -Path ( Join-Path $OutputDir 'soak-summary.md' ) -Value ( $md -join "`r`n" ) -Encoding utf8

Write-Host ""
if ( $pass ) {
    Write-Host "SOAK PASS ($Server)" -ForegroundColor Green
}
else {
    Write-Host "SOAK FAIL ($Server)" -ForegroundColor Red
    foreach ( $x in $reasons ) { Write-Host "  - $x" -ForegroundColor Red }
}
Write-Host "Summary: $( Join-Path $OutputDir 'soak-summary.md' )"

if ( $pass ) { exit 0 }
exit 1
