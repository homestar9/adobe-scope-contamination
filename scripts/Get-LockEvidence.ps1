<#
.SYNOPSIS
    Samples thread dumps while a test server is under load, to see threads waiting on the hotfix's
    construction lock, and for per-class locks, which lock and which CFC holds it.

.DESCRIPTION
    A throughput curve only lets you infer serialization. This names it.

    Adobe v1 (test server lock-u23) adds one process-wide monitor to TemplateProxyFactory:

        private static final Object CONSTRUCTION_LOCK;
        public static TemplateProxy resolveName( ... ) {
            synchronized ( CONSTRUCTION_LOCK ) { return resolveNameLocked( ... ); }
        }

    Contention shows as threads "BLOCKED (on object monitor)" at resolveName with
    "waiting to lock <0x...> (a java.lang.Object)", all on the same address.

    Adobe v3 (test server perclass-u23) replaces it with one java.util.concurrent.locks.ReentrantLock
    per CFC path, held together with every ancestor's lock until the outermost construction
    returns. Contention shows as threads "WAITING (parking)" with
    "parking to wait for <0x...> (a java.util.concurrent.locks.ReentrantLock$NonfairSync)" and
    resolveName on the stack. Dumps are taken with `Thread.print -l` so each thread lists the
    ReentrantLocks it OWNS under "Locked ownable synchronizers"; that maps every contended
    address to its owner thread, and the owner's top compiled-CFC frame (cfBaseEntity2ecfc...)
    names the CFC. The question for v3: how many DISTINCT addresses are contended, and does
    one address (owned inside e.g. quick.models.BaseEntity) take nearly all the waits? If so
    it is a global lock in disguise (see dominantLockShare).

    Parsing lives in LockEvidence.Common.ps1 so Invoke-LockSoak.ps1 uses the same rules.

    Run it against lock-u23 and perclass-u23; u23 / buggy are controls and should show
    effectively no waiting on this path.

.PARAMETER Test server
    Any test server in TestServers.ps1 (u23, lock-u23, buggy, perclass-u23).

.PARAMETER Endpoint
    Load driven while sampling:
      construct       /benchmark/construct?count=<Count>&shape=<Shape>
      fanout          /benchmark/construct?count=<Count>&shape=fanout
      siblings        /benchmark/construct?count=<Count>&shape=siblings
      quickconstruct  /benchmark/quickconstruct?count=<Count>
      repro           /repro/alpha + /repro/bravo concurrently (the real ORM workload)
      mixed           /repro/alpha + /repro/bravo + construct?shape=siblings concurrently
    Each target gets -Connections connections.

.PARAMETER ServerPid
    (Alias -Pid.) Override the JVM PID instead of taking the process listening on the test server's port.

.EXAMPLE
    .\scripts\Get-LockEvidence.ps1 -Server lock-u23
    .\scripts\Get-LockEvidence.ps1 -Server perclass-u23 -Endpoint repro
    .\scripts\Get-LockEvidence.ps1 -Server perclass-u23 -Endpoint fanout -Connections 32 -Samples 20
    .\scripts\Get-LockEvidence.ps1 -Server perclass-u23 -Endpoint quickconstruct -Pid 12345
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Server,
    [ValidateSet( 'construct', 'repro', 'quickconstruct', 'fanout', 'siblings', 'mixed' )]
    [string] $Endpoint        = 'construct',
    [ValidateSet( 'short', 'long' )]
    [string] $Profile         = 'short',
    [int]    $Connections     = 32,
    [int]    $Count           = 200,
    [string] $Shape           = 'wide',
    [int]    $Samples         = 20,
    [int]    $SampleIntervalSeconds = 1,
    [string] $BombardierPath  = '',
    [string] $JcmdPath        = '',
    # Not $Pid: that is a read-only automatic variable. -Pid still works through the alias.
    [Alias('Pid')]
    [int]    $ServerPid       = 0,
    [string] $OutputDir       = ''
)

$ErrorActionPreference = 'Stop'

. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
Use-BenchProfile -Profile $Profile -Section 'LockEvidence' -Bound $PSBoundParameters
. ( Join-Path $PSScriptRoot 'LockEvidence.Common.ps1' )

$serverInfo = Get-TestServer -Name $Server
if ( -not $OutputDir ) { $OutputDir = Get-BenchResultsRoot -Profile $Profile -Kind 'lock-evidence' }

# ---------------------------------------------------------------- locate tools
$BombardierPath = Get-BenchBombardierPath -Override $BombardierPath
$JcmdPath       = Get-BenchJdkTool -Tool jcmd -Override $JcmdPath
Write-Host "bombardier: $BombardierPath"
Write-Host "jcmd      : $JcmdPath"

# ---------------------------------------------------------------- identity and process
$identity = Get-TestServerIdentity -Server $serverInfo -TimeoutSeconds 15
if ( -not $identity ) { throw "The $Server test server is not answering /benchmark/engine on port $($serverInfo.Port)." }
$lockInfo = ''
if ( $identity.PSObject.Properties.Name -contains 'constructionLocks' ) { $lockInfo = " lock=$($identity.constructionLocks.design)" }
Write-Host "$Server : CF $($identity.productVersion), JVM $($identity.jvmVersion)$lockInfo"

# The JVM that owns the port is the test server; an explicit -Pid wins for odd setups (e.g. a launcher
# process holding the socket).
if ( $ServerPid -gt 0 ) { $jvmPid = $ServerPid }
else { $jvmPid = Get-TestServerPid -Server $serverInfo }
if ( -not $jvmPid ) { throw "No process is listening on port $($serverInfo.Port) for $Server. Pass -Pid." }
Write-Host "$Server JVM PID: $jvmPid" -ForegroundColor Cyan

if ( -not ( Test-Path $OutputDir ) ) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$dumpDir = Join-Path $OutputDir "threaddumps-$Server-$Endpoint"
if ( -not ( Test-Path $dumpDir ) ) { New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null }
$stale = @( Get-ChildItem -Path $dumpDir -Filter 'dump-*.txt' -ErrorAction SilentlyContinue )
if ( $stale.Count -gt $Samples ) {
    Write-Host "Note: $dumpDir holds $($stale.Count) older dumps; only this run's $Samples are analysed." -ForegroundColor Yellow
}

# ---------------------------------------------------------------- targets
$base = "http://127.0.0.1:$($serverInfo.Port)"
switch ( $Endpoint ) {
    'construct'      { $urls = @( "$base/benchmark/construct?count=$Count&shape=$Shape" );    $timeout = '5s' }
    'fanout'         { $urls = @( "$base/benchmark/construct?count=$Count&shape=fanout" );    $timeout = '5s' }
    'siblings'       { $urls = @( "$base/benchmark/construct?count=$Count&shape=siblings" );  $timeout = '5s' }
    'quickconstruct' { $urls = @( "$base/benchmark/quickconstruct?count=$Count" );            $timeout = '15s' }
    # Alpha and bravo must run at the same time: contamination and contention both come from
    # two different components being constructed concurrently.
    'repro'          { $urls = @( "$base/repro/alpha", "$base/repro/bravo" );                 $timeout = '15s' }
    # Real ORM entities and synthetic siblings together: unrelated classes that a per-class
    # lock should let proceed in parallel and a global lock would not.
    'mixed'          { $urls = @( "$base/repro/alpha", "$base/repro/bravo", "$base/benchmark/construct?count=$Count&shape=siblings" ); $timeout = '15s' }
}

# ---------------------------------------------------------------- load + sample
$loadDuration = ( $Samples * $SampleIntervalSeconds ) + 10
Write-Host "`nDriving load: c=$Connections per target for ${loadDuration}s at $( $urls -join ' + ' )" -ForegroundColor Cyan

$dumpTexts = New-Object System.Collections.Generic.List[object]
$loadJobs  = @()
try {
    $loadJobs = @( foreach ( $url in $urls ) {
        Start-Job -ScriptBlock {
            param( $exe, $connections, $duration, $timeout, $target )
            & $exe --http1 -c $connections -d $duration -t $timeout -q $target
        } -ArgumentList $BombardierPath, $Connections, "${loadDuration}s", $timeout, $url
    } )

    Start-Sleep -Seconds 5   # let the load ramp before sampling

    Write-Host "Taking $Samples thread dumps (Thread.print -l)..." -ForegroundColor Cyan
    for ( $i = 1; $i -le $Samples; $i++ ) {
        $dumpFile = Join-Path $dumpDir ( "dump-{0:D3}.txt" -f $i )
        # Parsing is deferred until after the load so it does not stretch the sample interval.
        $text = Get-ThreadDumpText -JcmdPath $JcmdPath -Pid $jvmPid
        Set-Content -Path $dumpFile -Value $text -Encoding utf8
        $dumpTexts.Add( [pscustomobject]@{ Label = ( Split-Path -Leaf $dumpFile ); Text = $text } )
        Write-Host "  $i/$Samples" -NoNewline
        Write-Host "`r" -NoNewline
        Start-Sleep -Seconds $SampleIntervalSeconds
    }

    Write-Host "`nWaiting for load to finish..."
    Wait-Job -Job $loadJobs | Out-Null
    foreach ( $j in $loadJobs ) {
        if ( $j.State -ne 'Completed' ) { Write-Host "  load job for $($j.Id) ended as $($j.State)" -ForegroundColor Yellow }
    }
}
finally {
    if ( $loadJobs.Count -gt 0 ) {
        $loadJobs | Stop-Job -ErrorAction SilentlyContinue
        $loadJobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- analyse
$measurements = @( foreach ( $d in $dumpTexts ) { Measure-ThreadDump -Text $d.Text -Label $d.Label } )
$agg = Merge-ThreadDumpMeasurements -Measurements $measurements

Write-Host "`n=== Analysis of $($agg.dumps) dumps ($Server test server, $Endpoint) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "v1 signature: BLOCKED (on object monitor)"
Write-Host "  threads BLOCKED on a monitor (all dumps)   : $($agg.blockedTotal)   avg/dump $($agg.avgBlockedPerDump)"
Write-Host "  ...waiting in TemplateProxyFactory.resolveName : $($agg.blockedOnResolveName)   avg/dump $($agg.avgBlockedOnResolveNamePerDump)   (resolveName anywhere in stack: $($agg.blockedResolveNameAnyDepth))" -ForegroundColor $( if ( $agg.blockedOnResolveName -gt 0 ) { 'Red' } else { 'Green' } )
Write-Host "v3 signature: WAITING (parking) on ReentrantLock"
Write-Host "  threads parked on a ReentrantLock          : $($agg.parkedOnReentrantLock)   avg/dump $($agg.avgParkedPerDump)   (all parked threads: $($agg.parkedTotal))"
Write-Host "  ...waiting in TemplateProxyFactory.resolveName : $($agg.parkedOnResolveName)   avg/dump $($agg.avgParkedOnResolveNamePerDump)   (resolveName anywhere in stack: $($agg.parkedResolveNameAnyDepth))" -ForegroundColor $( if ( $agg.parkedOnResolveName -gt 0 ) { 'Red' } else { 'Green' } )
Write-Host ""
Write-Host "Distinct construction locks contended        : $($agg.distinctLocksContended)   per dump avg $($agg.avgDistinctLocksPerDump), max $($agg.maxDistinctLocksPerDump)"
Write-Host "Share of parked waits on the busiest lock    : $([math]::Round( $agg.dominantLockShare * 100, 1 ))%"
Write-Host "Distinct monitors contended (v1)             : $($agg.distinctMonitorsContended)   busiest share $([math]::Round( $agg.dominantMonitorShare * 100, 1 ))%"

if ( @( $agg.topLocks ).Count -gt 0 ) {
    Write-Host "`nMost contended ReentrantLocks:" -ForegroundColor Cyan
    Write-Host ( "  {0,-20} {1,7} {2,11}  {3,-32} {4}" -f 'addr', 'waiters', 'resolveName', 'ownerCfc', 'ownerThread' )
    foreach ( $l in $agg.topLocks ) {
        Write-Host ( "  {0,-20} {1,7} {2,11}  {3,-32} {4}" -f $l.addr, $l.waiters, $l.resolveNameWaiters, $l.ownerCfc, $l.ownerThread )
    }
}
if ( @( $agg.topMonitors ).Count -gt 0 ) {
    Write-Host "`nMost contended monitors:" -ForegroundColor Cyan
    Write-Host ( "  {0,-20} {1,7} {2,11}  {3,-24} {4,-32} {5}" -f 'addr', 'waiters', 'resolveName', 'class', 'ownerCfc', 'ownerThread' )
    foreach ( $m in $agg.topMonitors ) {
        Write-Host ( "  {0,-20} {1,7} {2,11}  {3,-24} {4,-32} {5}" -f $m.addr, $m.waiters, $m.resolveNameWaiters, $m.class, $m.ownerCfc, $m.ownerThread )
    }
}
if ( @( $agg.topBlockSites ).Count -gt 0 ) {
    Write-Host "`nTop wait sites:" -ForegroundColor Cyan
    foreach ( $s in $agg.topBlockSites ) { Write-Host ( "  {0,5}x  {1}" -f $s.count, $s.frame ) }
}

if ( $agg.anyDeadlock ) {
    Write-Host "`nJava-level DEADLOCK reported in: $( $agg.deadlockDumps -join ', ' )" -ForegroundColor Red
}
else {
    Write-Host "`nNo Java-level deadlock reported." -ForegroundColor Green
}

# ---------------------------------------------------------------- write
$perDump = @( $measurements | ForEach-Object {
    [ordered]@{
        label = $_.label; threads = $_.threadCount
        blocked = $_.blockedTotal; blockedOnResolveName = $_.blockedOnResolveName
        parkedOnReentrantLock = $_.parkedOnReentrantLock; parkedOnResolveName = $_.parkedOnResolveName
        distinctLocksContended = $_.distinctLocksContended; deadlock = $_.deadlockDetected
    }
} )

$summary = [ordered]@{
    server                            = $Server
    lockDesign                     = $serverInfo.LockDesign
    endpoint                       = $Endpoint
    urls                           = $urls
    pid                            = $jvmPid
    capturedAt                     = ( Get-Date ).ToString( 'o' )
    samples                        = $Samples
    sampleIntervalSeconds          = $SampleIntervalSeconds
    connections                    = $Connections
    shape                          = $Shape
    count                          = $Count
    identity                       = $identity
    dumps                          = $agg.dumps
    blockedTotal                   = $agg.blockedTotal
    blockedOnResolveName           = $agg.blockedOnResolveName
    blockedResolveNameAnyDepth     = $agg.blockedResolveNameAnyDepth
    avgBlockedPerDump              = $agg.avgBlockedPerDump
    avgBlockedOnResolveNamePerDump = $agg.avgBlockedOnResolveNamePerDump
    parkedTotal                    = $agg.parkedTotal
    parkedOnReentrantLock          = $agg.parkedOnReentrantLock
    parkedOnResolveName            = $agg.parkedOnResolveName
    parkedResolveNameAnyDepth      = $agg.parkedResolveNameAnyDepth
    avgParkedPerDump               = $agg.avgParkedPerDump
    avgParkedOnResolveNamePerDump  = $agg.avgParkedOnResolveNamePerDump
    distinctLocksContended         = $agg.distinctLocksContended
    avgDistinctLocksPerDump        = $agg.avgDistinctLocksPerDump
    maxDistinctLocksPerDump        = $agg.maxDistinctLocksPerDump
    dominantLockShare              = $agg.dominantLockShare
    distinctMonitorsContended      = $agg.distinctMonitorsContended
    dominantMonitorShare           = $agg.dominantMonitorShare
    topLocks                       = $agg.topLocks
    topMonitors                    = $agg.topMonitors
    topBlockSites                  = $agg.topBlockSites
    deadlockDetected               = $agg.anyDeadlock
    deadlockDumps                  = $agg.deadlockDumps
    deadlockText                   = $agg.deadlockText
    perDump                        = $perDump
    dumpDir                        = $dumpDir
}

$summaryPath = Join-Path $OutputDir "lock-evidence-$Server-$Endpoint.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryPath -Encoding utf8

Write-Host "`nSummary written to $summaryPath" -ForegroundColor Green
Write-Host "Raw dumps in $dumpDir"
