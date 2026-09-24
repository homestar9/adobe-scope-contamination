<#
.SYNOPSIS
    Real-workload throughput test: /repro/alpha and /repro/bravo driven concurrently against
    each benchmark test server, the same Quick ORM path production runs.

.DESCRIPTION
    Test servers come from scripts\TestServers.ps1; stand them up first with Install-TestServers.ps1.

    /benchmark/construct isolates CFC construction; this test measures the production code
    path (entity construction through WireBox, Quick metadata, a real UPDATE), which is what
    Adobe's customers will actually feel. Every Quick entity extends BaseEntity, so every
    construction on the per-class-lock test server also takes the shared BaseEntity lock.

    Test servers whose 5xx rate is above -MaxErrorPercent are reported INVALID: their RPS measures
    error-page generation, not work. Stock Update 23 fails every request until restart under a cold concurrent burst,
    so it is warmed SERIALLY first (-SerialWarmupRequests, one connection, alternating alpha
    and bravo); that makes it a single-variable stock reference when it survives. If it does
    not, buggy (2023.0.21, no lock, a few percent 5xx) is the no-lock reference.

    Every measurement alternates test servers so drift hits all test servers equally. Only one test server receives
    load at a time (they share the SQL Server rows and the CPU).

.PARAMETER Profile
    short (default): c=1,8,32, 2 runs of 10 s, about 8 minutes for six test servers.
    long: c=1,4,8,16,32, 3 runs of 30 s, about 35 minutes. Explicit parameters win.

.EXAMPLE
    .\scripts\Invoke-RealWorkloadBenchmark.ps1
.EXAMPLE
    .\scripts\Invoke-RealWorkloadBenchmark.ps1 -Profile long -StopDropbox
#>
[CmdletBinding()]
param(
    [string[]] $Servers            = @(),
    [ValidateSet( 'short', 'long' )]
    [string]   $Profile         = 'short',
    [int[]]    $Connections     = @( 1, 4, 8, 16, 32 ),   # per endpoint, so total in-flight is ~2x this
    [int]      $Runs            = 3,
    [string]   $Duration        = '30s',
    [int]      $WarmupSeconds   = 20,
    [int]      $SerialWarmupRequests = 200,
    [double]   $MaxErrorPercent = 10,
    [string]   $BombardierPath  = '',
    [string]   $OutputDir       = '',
    [switch]   $SkipWarmup,
    [switch]   $StopDropbox
)

$ErrorActionPreference = 'Stop'
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
Use-BenchProfile -Profile $Profile -Section 'Repro' -Bound $PSBoundParameters

$serverSet = Select-TestServers -Names $Servers
if ( -not $OutputDir ) { $OutputDir = Get-BenchResultsRoot -Profile $Profile -Kind 'repro-throughput' }
if ( -not ( Test-Path $OutputDir ) ) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$BombardierPath = Get-BenchBombardierPath -Override $BombardierPath
Write-Host "bombardier: $BombardierPath" -ForegroundColor Cyan

# ---------------------------------------------------------------- preflight
Write-Host "`n=== Preflight ===" -ForegroundColor Cyan
$identities = Get-TestServerIdentities -Servers $serverSet -SaveTo $OutputDir

# Serial warm-up FIRST, before any concurrent request touches the test server: stock Update 23's
# fresh-start failure is triggered by concurrent first-time metadata population, and once it
# fires the JVM is dead for the rest of the run.
if ( $SerialWarmupRequests -gt 0 ) {
    Write-Host "`n=== Serial warm-up ($SerialWarmupRequests requests per test server, one at a time) ===" -ForegroundColor Cyan
    foreach ( $srv in $serverSet ) {
        $failures = 0
        for ( $i = 1; $i -le $SerialWarmupRequests; $i++ ) {
            $ep = if ( $i % 2 ) { 'alpha' } else { 'bravo' }
            try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$($srv.Port)/repro/$ep" -TimeoutSec 30 }
            catch { $failures++ }
        }
        Write-Host ( "  {0,-13} {1} failures of {2}" -f $srv.Name, $failures, $SerialWarmupRequests )
        if ( $srv.ExpectClean -and $failures -gt 0 ) { throw "The $($srv.Name) test server failed serial single-connection requests. Check the DB (.env creds, adobe-temp schema) before measuring." }
    }
}

$logsAside = Move-BenchLogsAside -Label 'repro-throughput'
if ( $logsAside ) { Write-Host "Previous logs moved to $logsAside" }

# ---------------------------------------------------------------- load helper
# Alpha and bravo AT THE SAME TIME for a fixed duration. Concurrency between the two entity
# types is what exercises the contested construction path; a single endpoint under-drives it.
function Invoke-ReproMeasurement {
    param( [int] $Port, [int] $ConnectionCount, [string] $Duration, [string] $AlphaOut, [string] $BravoOut )

    $alphaJob = Start-Job -ScriptBlock {
        param( $bomb, $url, $c, $d, $out )
        $o = & $bomb --http1 -c $c -d $d -t 15s -l -p r -o json $url
        Set-Content -Path $out -Value ( $o -join "`n" ) -Encoding utf8
    } -ArgumentList $BombardierPath, "http://127.0.0.1:$Port/repro/alpha", $ConnectionCount, $Duration, $AlphaOut

    $bravoRaw = & $BombardierPath --http1 -c $ConnectionCount -d $Duration -t 15s -l -p r -o json "http://127.0.0.1:$Port/repro/bravo"
    Set-Content -Path $BravoOut -Value ( $bravoRaw -join "`n" ) -Encoding utf8

    Receive-Job -Job $alphaJob -Wait | Out-Null
    Remove-Job -Job $alphaJob -Force

    $alpha = Read-BombardierJson -Path $AlphaOut
    $bravo = try { ( $bravoRaw -join "`n" ) | ConvertFrom-Json } catch { $null }
    if ( -not $alpha -or -not $bravo ) { return $null }
    return [pscustomobject]@{ Alpha = $alpha; Bravo = $bravo }
}

$dropbox = $null
if ( $StopDropbox ) { $dropbox = Stop-DropboxForBenchmark }
try {
    # ---------------------------------------------------------------- warm up
    if ( -not $SkipWarmup ) {
        Write-Host "`n=== Warming test servers ($WarmupSeconds s each, alpha+bravo concurrent) ===" -ForegroundColor Cyan
        foreach ( $srv in $serverSet ) {
            Write-Host "  warming $($srv.Name)..."
            $null = Invoke-ReproMeasurement -Port $srv.Port -ConnectionCount 8 -Duration "${WarmupSeconds}s" `
                        -AlphaOut ( Join-Path $OutputDir "$($srv.Name)-warmup-alpha.json" ) `
                        -BravoOut ( Join-Path $OutputDir "$($srv.Name)-warmup-bravo.json" )
        }
    }

    # ---------------------------------------------------------------- measure
    $total = $Connections.Count * $Runs * $serverSet.Count
    Write-Host "`n=== Measuring: $total runs of $Duration (alpha+bravo concurrent per run) ===" -ForegroundColor Cyan

    $completed = 0; $failed = 0
    foreach ( $cc in $Connections ) {
        foreach ( $run in 1..$Runs ) {
            foreach ( $srv in $serverSet ) {
                $completed++
                Write-Host ( "[{0,3}/{1}] {2,-13} c={3,-3} run={4}" -f $completed, $total, $srv.Name, $cc, $run )
                $result = Invoke-ReproMeasurement -Port $srv.Port -ConnectionCount $cc -Duration $Duration `
                              -AlphaOut ( Join-Path $OutputDir "$($srv.Name)-repro-c$cc-run$run-alpha.json" ) `
                              -BravoOut ( Join-Path $OutputDir "$($srv.Name)-repro-c$cc-run$run-bravo.json" )
                if ( -not $result ) { $failed++; Write-Host "    bombardier did not return JSON" -ForegroundColor Red }
            }
        }
    }
}
finally {
    if ( $dropbox ) { Start-DropboxAfterBenchmark -ExePath $dropbox }
}

# ---------------------------------------------------------------- manifest
$manifest = [ordered]@{
    parameters = [ordered]@{ connections = $Connections; runs = $Runs; duration = $Duration; warmupSeconds = $WarmupSeconds; serialWarmupRequests = $SerialWarmupRequests; maxErrorPercent = $MaxErrorPercent }
    machine    = [ordered]@{ logicalProcessors = $env:NUMBER_OF_PROCESSORS; os = [System.Environment]::OSVersion.VersionString; dropboxStopped = [bool] $StopDropbox }
    tool       = [ordered]@{ bombardierPath = $BombardierPath; bombardierHash = ( Get-FileHash -Path $BombardierPath -Algorithm SHA256 ).Hash }
    quick      = [ordered]@{ baseEntitySha = ( Get-FileHash ( Join-Path $BenchRepoRoot 'modules\quick\models\BaseEntity.cfc' ) -Algorithm SHA256 ).Hash }
    servers       = $( $m = [ordered]@{}; foreach ( $a in $serverSet ) { $m[ $a.Name ] = [ordered]@{ port = $a.Port; jar = $a.Jar; lockDesign = $a.LockDesign; identity = $identities[ $a.Name ] } }; $m )
    failedMeasurements = $failed
    generatedAt = ( Get-Date ).ToString( 'o' )
}
$manifestPath = Join-Path $OutputDir "manifest-$( Get-Date -Format 'yyyyMMdd-HHmmss' ).json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8

# ---------------------------------------------------------------- summary
$rows = @()
foreach ( $cc in $Connections ) {
    $row = [ordered]@{ Connections = $cc }
    foreach ( $srv in $serverSet ) {
        $rps = @(); $p99 = @(); $reqTotal = 0; $req5xx = 0; $errors = 0
        foreach ( $run in 1..$Runs ) {
            $combined = 0.0
            foreach ( $ep in @( 'alpha', 'bravo' ) ) {
                $j = Read-BombardierJson -Path ( Join-Path $OutputDir "$($srv.Name)-repro-c$cc-run$run-$ep.json" )
                if ( $j ) {
                    $c = Get-BombardierCounts -Json $j
                    $combined += $c.Rps
                    $reqTotal += $c.Completed
                    $req5xx   += $c.Http5xx
                    $errors   += $c.Errors
                    $p99      += [double] $j.result.latency.percentiles.'99'
                }
            }
            if ( $combined -gt 0 ) { $rps += $combined }
        }
        $errPct = if ( $reqTotal -gt 0 ) { [math]::Round( 100.0 * $req5xx / $reqTotal, 1 ) } else { 100 }
        $median = [math]::Round( ( Get-BenchMedian -Values $rps ), 1 )
        $row[ $srv.Name ]              = if ( $errPct -gt $MaxErrorPercent ) { "INVALID ($errPct% err)" } else { $median }
        $row[ "$($srv.Name) err%" ]    = $errPct
        $row[ "$($srv.Name) errors" ]  = $errors
        $row[ "$($srv.Name) p99ms" ]   = [math]::Round( ( Get-BenchMedian -Values $p99 ) / 1000, 1 )
    }
    $rows += [pscustomobject] $row
}

Write-Host "`n=== Repro throughput by test server (median combined alpha+bravo RPS) ===" -ForegroundColor Cyan
$rows | Format-Table -AutoSize

function Get-Ratio { param( $a, $b ) if ( ( $a -is [double] -or $a -is [int] ) -and ( $b -is [double] -or $b -is [int] ) -and $b -gt 0 ) { return "$( [math]::Round( $a / $b, 2 ) )x" }; return 'n/a' }
$stockName = if ( $serverSet.Name -contains 'u23' ) { 'u23' } elseif ( $serverSet.Name -contains 'buggy' ) { 'buggy' } else { $serverSet[0].Name }
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine( "# Real-workload (/repro) throughput round" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Median combined alpha+bravo RPS over $Runs runs of $Duration. Test servers alternated per measurement. p99 in ms, same-session only." )
[void]$md.AppendLine( "A test server whose HTTP 5xx rate is above $MaxErrorPercent% is reported INVALID: its RPS measures error-page generation, not work." )
[void]$md.AppendLine( "'errors' are transport errors (timeouts); a hung test server shows up there, not in 5xx." )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Notes:" )
[void]$md.AppendLine( "- u23 is stock Update 23, serially warmed ($SerialWarmupRequests requests) so it does not failure of every request until restart; if it is INVALID anyway, read ratios against buggy." )
[void]$md.AppendLine( "- buggy (2023.0.21, no lock) normally shows a few percent 5xx: the bug itself firing. Its RPS is the no-lock speed reference." )
[void]$md.AppendLine( "" )
$hdr = "| Conns |"; $sep = "|---|"
foreach ( $srv in $serverSet ) { $hdr += " $($srv.Name) | err% | errors | p99 |"; $sep += "---|---|---|---|" }
foreach ( $srv in $serverSet ) { if ( $srv.Name -ne $stockName ) { $hdr += " $($srv.Name)/$stockName |"; $sep += "---|" } }
if ( $serverSet.Name -contains 'lock-u23' -and $serverSet.Name -contains 'perclass-u23' ) { $hdr += " perclass/lock |"; $sep += "---|" }
[void]$md.AppendLine( $hdr ); [void]$md.AppendLine( $sep )
foreach ( $r in $rows ) {
    $line = "| $($r.Connections) |"
    foreach ( $srv in $serverSet ) { $line += " $($r.($srv.Name)) | $($r."$($srv.Name) err%") | $($r."$($srv.Name) errors") | $($r."$($srv.Name) p99ms") |" }
    foreach ( $srv in $serverSet ) { if ( $srv.Name -ne $stockName ) { $line += " $( Get-Ratio $r.($srv.Name) $r.$stockName ) |" } }
    if ( $serverSet.Name -contains 'lock-u23' -and $serverSet.Name -contains 'perclass-u23' ) { $line += " $( Get-Ratio $r.'perclass-u23' $r.'lock-u23' ) |" }
    [void]$md.AppendLine( $line )
}
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Test server identity:" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "| Test server | CF version | JVM | Lock design | TemplateProxyFactory from |" )
[void]$md.AppendLine( "|---|---|---|---|---|" )
foreach ( $srv in $serverSet ) {
    $id = $identities[ $srv.Name ]
    $src = Split-Path $id.classSources.$BenchTpfClass -Leaf
    [void]$md.AppendLine( "| $($srv.Name) | $($id.productVersion) $($id.productLevel) | $($id.jvmVersion) | $($id.constructionLocks.design) | ``$src`` |" )
}
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Manifest: ``$( Split-Path -Leaf $manifestPath )``" )
$summaryPath = Join-Path $OutputDir "summary-$( Get-Date -Format 'yyyyMMdd-HHmmss' ).md"
$md.ToString() | Set-Content -Path $summaryPath -Encoding utf8

if ( $failed -gt 0 ) { Write-Host "`n$failed measurement(s) failed to produce JSON." -ForegroundColor Yellow }
Write-Host "`nResults + $( Split-Path -Leaf $summaryPath ) in $OutputDir" -ForegroundColor Green
Write-Host "Lock evidence under this workload: .\scripts\Get-LockEvidence.ps1 -Server perclass-u23 -Endpoint repro" -ForegroundColor Cyan
