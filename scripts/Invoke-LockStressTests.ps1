<#
.SYNOPSIS
    Runs the adversarial construction-lock probes (handlers/Torture.cfc) against one test server.

.DESCRIPTION
    Each probe isolates one consequence of how a test server locks CFC construction (plan section
    2d). The probes are the same on every test server; the test server's lock design decides the outcome,
    so run this on u23, lock-u23 and perclass-u23 and compare.

    Rules this script follows:
      - Every HTTP call has a timeout. The script never hangs on a hung test server.
      - Any timeout or HTTP 500 gets a `jcmd <pid> Thread.print -l` dump saved next to the
        response, because a hung construction lock is only visible in a dump.
      - Non-destructive probes run first, in the order given. p2 (mutual lazy init) leaves
        threads parked forever on a per-class lock jar, so it only runs when asked for
        explicitly, always runs last, and is followed by a JVM restart (-KillAfterP2, on by
        default whenever p2 is included).
      - The report is the result: the exit code is 0 whatever the probes found. Only a
        preflight failure (test server unreachable) throws.

.PARAMETER Test server
    Test server name from scripts\TestServers.ps1 (u23, lock-u23, buggy, perclass-u23).

.PARAMETER Probes
    Probes to run, in order. Default p4,p3,p5,p6,p7,p8,p1. Add p2 explicitly (it is moved to
    the end regardless of where it is listed). p8 is the shared-compiler-temporary probe that
    Adobe's fourth hotfix targets; it fails on stock, v1 and v3 by design.

.PARAMETER Ms
    P1 pseudo-constructor sleep in milliseconds.

.PARAMETER Reps
    P1 repetitions per pair (median reported).

.PARAMETER KillAfterP2
    Restart the test server after p2 (and between p2both and the two-request variant when p2both
    left threads parked). Defaults to on when p2 is included; pass -KillAfterP2:$false to
    leave the parked threads in place for manual inspection.

.EXAMPLE
    .\scripts\Invoke-LockStressTests.ps1 -Server perclass-u23

.EXAMPLE
    # everything, including the destructive mutual-init deadlock probe
    .\scripts\Invoke-LockStressTests.ps1 -Server perclass-u23 -Probes p4,p3,p5,p6,p7,p1,p2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $Server,
    [string[]] $Probes    = @( 'p4', 'p3', 'p5', 'p6', 'p7', 'p8', 'p1' ),
    [string]   $OutputDir = '',
    [int]      $Ms        = 200,
    [ValidateSet( 'short', 'long' )]
    [string]   $Profile   = 'short',
    [int]      $Reps      = 5,
    [switch]   $KillAfterP2,
    [string]   $JcmdPath  = ''
)

$ErrorActionPreference = 'Stop'
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
Use-BenchProfile -Profile $Profile -Section 'Torture' -Bound $PSBoundParameters

$serverObj = Get-TestServer -Name $Server
$base   = "http://127.0.0.1:$($serverObj.Port)"
if ( -not $OutputDir ) { $OutputDir = Get-BenchResultsRoot -Profile $Profile -Kind "torture-$Server" }
if ( -not ( Test-Path $OutputDir ) ) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# Accept both -Probes p1,p2 and -Probes 'p1,p2' (the latter is what powershell -File passes).
$Probes = @( $Probes | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ } )
$known  = @( 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8' )
foreach ( $p in $Probes ) { if ( $known -notcontains $p ) { throw "Unknown probe '$p'. Known: $( $known -join ', ' )" } }
$runP2  = $Probes -contains 'p2'
$ordered = @( $Probes | Where-Object { $_ -ne 'p2' } | Select-Object -Unique )
if ( $runP2 ) { $ordered += 'p2' }
if ( -not $PSBoundParameters.ContainsKey( 'KillAfterP2' ) ) { $KillAfterP2 = [switch] $runP2 }

# ---------------------------------------------------------------- helpers
function Invoke-TortureCall {
    <#
        One bounded GET. Returns what happened instead of throwing: HTTP status, whether the
        client timed out, the parsed JSON body (500 bodies included; they carry the detail),
        and the raw text. The response is saved as <Name>.json.
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $PathAndQuery,
        [int] $TimeoutSec = 60
    )
    $url = "$base$PathAndQuery"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $status = 0; $timedOut = $false; $body = ''; $err = ''
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec
        $status = [int] $resp.StatusCode
        $body = $resp.Content
    }
    catch {
        $ex = $_.Exception
        $err = $ex.Message
        if ( $ex -is [System.Net.WebException] -and $ex.Status -eq [System.Net.WebExceptionStatus]::Timeout ) { $timedOut = $true }
        elseif ( $err -match 'timed out|timeout' ) { $timedOut = $true }
        if ( $ex.Response ) {
            try { $status = [int] $ex.Response.StatusCode } catch { }
            if ( $_.ErrorDetails -and $_.ErrorDetails.Message ) { $body = $_.ErrorDetails.Message }
            else {
                try {
                    $reader = New-Object System.IO.StreamReader( $ex.Response.GetResponseStream() )
                    $body = $reader.ReadToEnd()
                    $reader.Dispose()
                } catch { }
            }
        }
    }
    $sw.Stop()
    $json = $null
    if ( $body ) { try { $json = $body | ConvertFrom-Json } catch { $json = $null } }

    $record = [pscustomobject]@{
        name       = $Name
        url        = $url
        httpStatus = $status
        timedOut   = $timedOut
        clientMs   = [int] $sw.ElapsedMilliseconds
        error      = $err
        response   = $json
    }
    if ( -not $json -and $body ) { $record | Add-Member -NotePropertyName rawBody -NotePropertyValue $body }
    $record | ConvertTo-Json -Depth 20 | Set-Content -Path ( Join-Path $OutputDir "$Name.json" ) -Encoding utf8
    return $record
}

function Save-ThreadDump {
    <#
        jcmd Thread.print -l into dump-<Label>.txt. -l adds "Locked ownable synchronizers",
        which is where ReentrantLock owners show up (they are not monitors). Bounded: jcmd is
        killed after 60 s so a wedged JVM cannot hang the script.
    #>
    param( [Parameter(Mandatory)] [string] $Label )
    $out = Join-Path $OutputDir "dump-$Label.txt"
    try {
        $jcmd = Get-BenchJdkTool -Tool jcmd -Override $JcmdPath
        $armPid = Get-TestServerPid $serverObj
        if ( -not $armPid ) { Set-Content -Path $out -Value "no process listening on port $($serverObj.Port)" -Encoding utf8; return $out }
        $errFile = "$out.stderr"
        $proc = Start-Process -FilePath $jcmd -ArgumentList @( "$armPid", 'Thread.print', '-l' ) -NoNewWindow -PassThru `
                    -RedirectStandardOutput $out -RedirectStandardError $errFile
        if ( -not $proc.WaitForExit( 60000 ) ) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Add-Content -Path $out -Value "`n[jcmd killed after 60 s]"
        }
        if ( ( Test-Path $errFile ) -and ( Get-Item $errFile ).Length -eq 0 ) { Remove-Item $errFile -Force }
        Write-Host "    thread dump -> $out" -ForegroundColor DarkYellow
    }
    catch {
        Set-Content -Path $out -Value "thread dump failed: $($_.Exception.Message)" -Encoding utf8
    }
    return $out
}

function Test-ConstructionDeadlock {
    <#
        Deadlock evidence in a dump, either form:
          - the JVM's own detector ("Found one Java-level deadlock"; HotSpot reports
            ReentrantLock cycles too, via ownable synchronizers), or
          - at least two threads with a resolveName frame parked on DIFFERENT
            ReentrantLock$NonfairSync addresses (two parties each waiting on a different
            lock is the cycle shape even when the detector output is missing).
    #>
    param( [Parameter(Mandatory)] [string] $DumpPath )
    $result = [ordered]@{ deadlockDetected = $false; jvmReported = $false; parkedResolveNameThreads = 0; distinctLockAddresses = @() }
    if ( -not ( Test-Path $DumpPath ) ) { return [pscustomobject] $result }
    $text = Get-Content $DumpPath -Raw
    if ( -not $text ) { return [pscustomobject] $result }
    if ( $text -match 'Found one Java-level deadlock' ) { $result.jvmReported = $true }

    # Thread blocks start with a quoted thread name at column 0.
    $blocks = [regex]::Split( $text, '(?m)^(?=")' )
    $addresses = @()
    foreach ( $b in $blocks ) {
        if ( $b -notmatch 'resolveName' ) { continue }
        $m = [regex]::Match( $b, 'parking to wait for\s+<(0x[0-9a-fA-F]+)>\s+\(a java\.util\.concurrent\.locks\.ReentrantLock\$NonfairSync\)' )
        if ( $m.Success ) {
            $result.parkedResolveNameThreads++
            $addresses += $m.Groups[1].Value
        }
    }
    $result.distinctLockAddresses = @( $addresses | Sort-Object -Unique )
    $result.deadlockDetected = $result.jvmReported -or ( @( $result.distinctLockAddresses ).Count -ge 2 )
    return [pscustomobject] $result
}

$summaryRows = New-Object System.Collections.Generic.List[object]

function Add-ProbeResult {
    <# Records one call in the summary and takes a dump when it failed hard. #>
    param( [Parameter(Mandatory)] [string] $Probe, [Parameter(Mandatory)] [string] $Variant, [Parameter(Mandatory)] $Call, [switch] $NoDump )
    $r = $Call.response
    $ok = [bool] ( $r -and $r.ok -eq $true -and $Call.httpStatus -eq 200 )
    $verdict = ''
    $expected = ''
    $expectedDesign = if ( $serverObj.LockDesign ) { $serverObj.LockDesign } else { 'none' }
    if ( $r -and $r.detail ) {
        if ( $r.detail.PSObject.Properties.Name -contains 'verdict' ) { $verdict = [string] $r.detail.verdict }
        if ( $r.detail.PSObject.Properties.Name -contains 'expected' -and $r.detail.expected ) { $expected = [string] $r.detail.expected.$expectedDesign }
        if ( $r.detail.PSObject.Properties.Name -contains 'lockTimeout' ) { $verdict = "lockTimeout=$($r.detail.lockTimeout)" }
        if ( $r.detail.PSObject.Properties.Name -contains 'timedOut' -and $Probe -in @( 'p2', 'p5' ) ) { $verdict = "timedOut=$($r.detail.timedOut)" }
    }
    $dump = ''
    if ( -not $NoDump -and ( $Call.timedOut -or $Call.httpStatus -ge 500 -or $Call.httpStatus -eq 0 ) ) {
        $dump = Save-ThreadDump -Label $Call.name
    }
    $row = [pscustomobject]@{
        probe      = $Probe
        variant    = $Variant
        ok         = $ok
        httpStatus = $Call.httpStatus
        timedOut   = $Call.timedOut
        verdict    = $verdict
        expected   = $expected
        elapsedMs  = if ( $r ) { $r.elapsedMs } else { $Call.clientMs }
        file       = "$($Call.name).json"
        dump       = if ( $dump ) { Split-Path -Leaf $dump } else { '' }
    }
    $summaryRows.Add( $row )
    $color = if ( $ok ) { 'Green' } else { 'Red' }
    Write-Host ( "  {0,-4} {1,-18} ok={2,-5} http={3} {4}" -f $Probe, $Variant, $ok, $Call.httpStatus, $verdict ) -ForegroundColor $color
    return $row
}

# ---------------------------------------------------------------- preflight
Write-Host "=== Lock torture: test server=$Server ($($serverObj.Role)) port=$($serverObj.Port) ===" -ForegroundColor Cyan
Write-Host "Probes: $( $ordered -join ', ' )   ms=$Ms reps=$Reps killAfterP2=$KillAfterP2   out=$OutputDir`n"

$identity = Get-TestServerIdentity -Server $serverObj -TimeoutSeconds 15
if ( -not $identity ) { throw "The $Server test server is not answering /benchmark/engine on port $($serverObj.Port). Start it (Install-TestServers.ps1)." }
$identity | ConvertTo-Json -Depth 6 | Set-Content -Path ( Join-Path $OutputDir "engine-$Server.json" ) -Encoding utf8

$locks = Invoke-TortureCall -Name 'locks-before' -PathAndQuery '/torture/locks' -TimeoutSec 30
if ( $locks.httpStatus -ne 200 ) {
    # A newly added handler/route is picked up on a framework reinit (no password in this app).
    Write-Host "  /torture/locks answered $($locks.httpStatus); reinitialising ColdBox once..." -ForegroundColor Yellow
    try { $null = Invoke-WebRequest -Uri "$base/?fwreinit=1" -UseBasicParsing -TimeoutSec 60 } catch { }
    $locks = Invoke-TortureCall -Name 'locks-before' -PathAndQuery '/torture/locks' -TimeoutSec 30
    if ( $locks.httpStatus -ne 200 ) { throw "The $Server test server answers /benchmark/engine but not /torture/locks (HTTP $($locks.httpStatus)). Is handlers\Torture.cfc deployed?" }
}
$fingerprint = $locks.response.detail
Write-Host "  CF $($identity.productVersion), lock design (reflected): $($fingerprint.design), map size: $($fingerprint.mapSize)`n"

$p2Evidence = $null

# ---------------------------------------------------------------- probes
foreach ( $probe in $ordered ) {
    switch ( $probe ) {
        'p4' {
            $call = Invoke-TortureCall -Name 'p4-n200-c16' -PathAndQuery '/torture/p4?n=200&c=16' -TimeoutSec 120
            $null = Add-ProbeResult -Probe 'p4' -Variant 'n200-c16' -Call $call
        }
        'p3' {
            foreach ( $holder in @( 'cfc', 'thread' ) ) {
                foreach ( $variant in @( 'same', 'unrelated' ) ) {
                    $call = Invoke-TortureCall -Name "p3-$variant-$holder" -PathAndQuery "/torture/p3?variant=$variant&holder=$holder" -TimeoutSec 60
                    $null = Add-ProbeResult -Probe 'p3' -Variant "$variant-$holder" -Call $call
                }
            }
        }
        'p5' {
            foreach ( $target in @( 'same', 'sibling', 'unrelated' ) ) {
                $call = Invoke-TortureCall -Name "p5-$target" -PathAndQuery "/torture/p5?target=$target&joinMs=3000" -TimeoutSec 60
                $null = Add-ProbeResult -Probe 'p5' -Variant $target -Call $call
            }
        }
        'p6' {
            $call = Invoke-TortureCall -Name 'p6-dup-vs-construct' -PathAndQuery '/torture/p6?reps=200' -TimeoutSec 60
            $null = Add-ProbeResult -Probe 'p6' -Variant 'dup-vs-construct' -Call $call
        }
        'p7' {
            $call = Invoke-TortureCall -Name 'p7-many64' -PathAndQuery '/torture/p7' -TimeoutSec 60
            $row = Add-ProbeResult -Probe 'p7' -Variant 'many64' -Call $call
            if ( $call.response -and $call.response.detail.PSObject.Properties.Name -contains 'mapGrowth' ) {
                $row.verdict = "mapGrowth=$($call.response.detail.mapGrowth)"
            }
        }
        'p8' {
            # The shared compiler temporary (Adobe v4's target): 32 threads x 50 builds of three
            # literal forms on one singleton. verdict = crossings and leaked keys.
            $call = Invoke-TortureCall -Name 'p8-tempvar' -PathAndQuery '/torture/p8?threads=32&reps=50&ms=2' -TimeoutSec 180
            $null = Add-ProbeResult -Probe 'p8' -Variant 'tempvar' -Call $call -NoDump
        }
        'p1' {
            # One call per pair so one hung pair cannot hide the others. Each rep's join is
            # bounded at max(10 s, 8 x ms) server side, so this client timeout always wins last.
            $pairs = @( 'same', 'unrelated', 'siblings', 'slowinit', 'alias', 'mapping', 'outer' )
            $perRepSec = [math]::Max( 10, [math]::Ceiling( $Ms * 8 / 1000 ) )
            $timeout = [int] ( $Reps * $perRepSec + 30 )
            foreach ( $pair in $pairs ) {
                $call = Invoke-TortureCall -Name "p1-$pair" -PathAndQuery "/torture/p1?pair=$pair&ms=$Ms&reps=$Reps" -TimeoutSec $timeout
                $null = Add-ProbeResult -Probe 'p1' -Variant $pair -Call $call
            }
        }
        'p2' {
            Write-Host "`n  p2 is destructive on a per-class lock jar: parked threads cannot be interrupted." -ForegroundColor Yellow
            $p2Evidence = [ordered]@{}

            # (1) single request, two threads.
            $null = Invoke-TortureCall -Name 'p2-reset-1' -PathAndQuery '/torture/reset' -TimeoutSec 30
            $bothId = 'both' + ( [guid]::NewGuid().ToString( 'N' ) )
            $call = Invoke-TortureCall -Name 'p2-both' -PathAndQuery "/torture/p2both?runId=$bothId&joinMs=10000" -TimeoutSec 30
            $null = Add-ProbeResult -Probe 'p2' -Variant 'both' -Call $call -NoDump
            # Always dump here: the dump IS the evidence for this probe, pass or fail.
            $dumpBoth = Save-ThreadDump -Label 'p2-both'
            $evBoth = Test-ConstructionDeadlock -DumpPath $dumpBoth
            $p2Evidence.both = $evBoth
            $summaryRows[ $summaryRows.Count - 1 ].dump = Split-Path -Leaf $dumpBoth

            # A deadlock from (1) holds MutualA's and MutualB's locks forever, which would make
            # (2) measure "blocked behind (1)" instead of a fresh two-request deadlock.
            $bothParked = $call.timedOut -or ( $call.response -and $call.response.detail.timedOut -eq $true )
            if ( $bothParked -and $KillAfterP2 ) {
                Write-Host "  p2both left threads parked; restarting $Server before the two-request variant..." -ForegroundColor Yellow
                Stop-TestServer -Server $serverObj
                $null = Start-TestServer -Server $serverObj
                $p2Evidence.restartedBetween = $true
            }
            elseif ( $bothParked ) {
                $p2Evidence.sidesConfoundedByP2both = $true
            }

            # (2) two concurrent HTTP requests, one per side, sharing one run id.
            $null = Invoke-TortureCall -Name 'p2-reset-2' -PathAndQuery '/torture/reset' -TimeoutSec 30
            $sideId = 'sides' + ( [guid]::NewGuid().ToString( 'N' ) )
            $jobs = foreach ( $side in @( 'a', 'b' ) ) {
                Start-Job -ScriptBlock {
                    param( $url )
                    $status = 0; $body = ''; $timedOut = $false; $err = ''
                    try {
                        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
                        $status = [int] $r.StatusCode; $body = $r.Content
                    }
                    catch {
                        $err = $_.Exception.Message
                        if ( $err -match 'timed out|timeout' ) { $timedOut = $true }
                        if ( $_.Exception.Response ) {
                            try { $status = [int] $_.Exception.Response.StatusCode } catch { }
                            if ( $_.ErrorDetails ) { $body = $_.ErrorDetails.Message }
                        }
                    }
                    [pscustomobject]@{ url = $url; httpStatus = $status; timedOut = $timedOut; error = $err; body = $body }
                } -ArgumentList "$base/torture/p2?side=$side&runId=$sideId&joinMs=10000"
            }
            $null = Wait-Job -Job $jobs -Timeout 60
            $sideNames = @( 'a', 'b' )
            for ( $i = 0; $i -lt 2; $i++ ) {
                $j = $jobs[ $i ]
                $raw = if ( $j.State -eq 'Completed' ) { Receive-Job -Job $j } else { $null }
                $json = $null
                if ( $raw -and $raw.body ) { try { $json = $raw.body | ConvertFrom-Json } catch { } }
                $sideCall = [pscustomobject]@{
                    name       = "p2-side-$( $sideNames[ $i ] )"
                    url        = if ( $raw ) { $raw.url } else { "$base/torture/p2?side=$( $sideNames[ $i ] )" }
                    httpStatus = if ( $raw ) { $raw.httpStatus } else { 0 }
                    timedOut   = if ( $raw ) { $raw.timedOut } else { $true }
                    clientMs   = 0
                    error      = if ( $raw ) { $raw.error } else { "job state $($j.State)" }
                    response   = $json
                }
                $sideCall | ConvertTo-Json -Depth 20 | Set-Content -Path ( Join-Path $OutputDir "$($sideCall.name).json" ) -Encoding utf8
                $null = Add-ProbeResult -Probe 'p2' -Variant "side-$( $sideNames[ $i ] )" -Call $sideCall -NoDump
            }
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue

            $dumpSides = Save-ThreadDump -Label 'p2-sides'
            $evSides = Test-ConstructionDeadlock -DumpPath $dumpSides
            $p2Evidence.sides = $evSides
            $p2Evidence.deadlockDetected = [bool] ( $evBoth.deadlockDetected -or $evSides.deadlockDetected )
            foreach ( $row in $summaryRows ) { if ( $row.probe -eq 'p2' -and $row.variant -like 'side-*' ) { $row.dump = Split-Path -Leaf $dumpSides } }
            Write-Host ( "  p2 deadlockDetected={0} (both: jvm={1} parked={2}; sides: jvm={3} parked={4})" -f `
                $p2Evidence.deadlockDetected, $evBoth.jvmReported, $evBoth.parkedResolveNameThreads, $evSides.jvmReported, $evSides.parkedResolveNameThreads ) `
                -ForegroundColor $( if ( $p2Evidence.deadlockDetected ) { 'Red' } else { 'Green' } )

            if ( $KillAfterP2 ) {
                Write-Host "  restarting $Server to clear parked threads..." -ForegroundColor Yellow
                Stop-TestServer -Server $serverObj
                $null = Start-TestServer -Server $serverObj
                $p2Evidence.restartedAfter = $true
            }
            else {
                Write-Host "  -KillAfterP2:`$false: $Server is left running with any parked threads. Restart it before the next measurement." -ForegroundColor Yellow
            }
        }
    }
}

# ---------------------------------------------------------------- summary
$summary = [ordered]@{
    server              = $Server
    port             = $serverObj.Port
    lockDesignTable  = $serverObj.LockDesign
    lockFingerprint  = $fingerprint
    identity         = $identity
    ms               = $Ms
    reps             = $Reps
    probes           = $summaryRows
    deadlockDetected = if ( $p2Evidence ) { $p2Evidence.deadlockDetected } else { $null }
    p2Evidence       = $p2Evidence
    finishedAt       = ( Get-Date ).ToString( 'o' )
}
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path ( Join-Path $OutputDir 'torture-summary.json' ) -Encoding utf8

Write-Host "`n=== Torture summary: $Server (lock design $($fingerprint.design)) ===" -ForegroundColor Cyan
$summaryRows | Format-Table probe, variant, ok, httpStatus, timedOut, verdict, expected, elapsedMs, dump -AutoSize | Out-String -Width 200 | Write-Host
if ( $p2Evidence ) { Write-Host "p2 deadlockDetected: $($p2Evidence.deadlockDetected)" }
Write-Host "Responses, dumps and torture-summary.json in $OutputDir" -ForegroundColor Cyan
exit 0
