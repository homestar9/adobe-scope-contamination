<#
.SYNOPSIS
    Database-free throughput test of Quick entity construction across the test servers, with a
    self-contained RPS summary.

.DESCRIPTION
    Test servers come from scripts\TestServers.ps1; stand them up first with Install-TestServers.ps1.

    Endpoint: /benchmark/quickconstruct?count=N builds a Quick entity and its query builder per
    iteration (the ORM construction path, no database). It returns HTTP 500 when a builder's table
    does not match its entity, so bombardier's non-2xx count doubles as a tripwire. That is NOT the
    contamination test (Test-Contamination.ps1 is).

    Every measurement alternates test servers so drift (thermals, background work) hits all test
    servers equally. Run on a quiet machine. -StopDropbox pauses the Dropbox client for the run.

    Earlier versions also measured synthetic construction shapes for the lock-based hotfixes; they
    are kept at git tag research-notes-2026-10.

.PARAMETER Profile
    short (default) or long; see $BenchProfiles in TestServers.ps1. Explicit parameters win.

.EXAMPLE
    .\scripts\Invoke-ConstructionBenchmark.ps1 -Servers localtemp-u23,u23 -Count 50 -Connections 8,32 -Runs 3
#>
[CmdletBinding()]
param(
    [string[]] $Servers        = @(),
    [ValidateSet( 'short', 'long' )]
    [string]   $Profile        = 'short',
    [ValidateSet( 'quickconstruct' )]
    [string]   $Endpoint       = 'quickconstruct',
    [int[]]    $Connections    = @( 1, 8, 32 ),
    [int]      $Runs           = 3,
    [string]   $Duration       = '20s',
    [int]      $Count          = 50,
    [string]   $BombardierPath = '',
    [string]   $OutputDir      = '',
    [int]      $WarmupSeconds  = 20,
    [switch]   $SkipWarmup,
    [switch]   $StopDropbox
)

$ErrorActionPreference = 'Stop'
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
Use-BenchProfile -Profile $Profile -Section 'QuickConstruct' -Bound $PSBoundParameters

$serverSet = Select-TestServers -Names $Servers
if ( -not $OutputDir ) { $OutputDir = Get-BenchResultsRoot -Profile $Profile -Kind $Endpoint }
if ( -not ( Test-Path $OutputDir ) ) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$BombardierPath = Get-BenchBombardierPath -Override $BombardierPath
Write-Host "bombardier: $BombardierPath" -ForegroundColor Cyan

# The label is part of every result file name: <server>-quickconstruct-entity+builder-c<N>-run<R>.json
$label = 'entity+builder'

# ---------------------------------------------------------------- preflight
Write-Host "`n=== Preflight ===" -ForegroundColor Cyan
$identities = Get-TestServerIdentities -Servers $serverSet -SaveTo $OutputDir
Write-Host "  Identities asserted; deployed-jar hashes confirmed; same JVM." -ForegroundColor Green

function Get-TargetUrl {
    param( $Port, $Count )
    return "http://127.0.0.1:$Port/benchmark/quickconstruct?count=$Count"
}

function Invoke-Measurement {
    param( $Url, $ConnectionCount, $Duration, $OutFile )
    $output = & $BombardierPath --http1 -c $ConnectionCount -d $Duration -t 5s -l -p r -o json $Url
    $text = $output -join "`n"
    try { $null = $text | ConvertFrom-Json } catch { Write-Host "    bombardier did not return JSON: $text" -ForegroundColor Red; return $false }
    Set-Content -Path $OutFile -Value $text -Encoding utf8
    return $true
}

# One request per test server before anything else: a 500 here means the endpoint is broken and
# the whole test would just measure error pages.
foreach ( $srv in $serverSet ) {
    $url = Get-TargetUrl -Port $srv.Port -Count 5
    try { $r = Invoke-RestMethod -Uri $url -TimeoutSec 60 }
    catch { throw "$($srv.Name): $url failed ($($_.Exception.Message))." }
    if ( -not $r.ok ) { throw "$($srv.Name): $url returned ok=false (checksum $($r.checksum) vs expected $($r.expected))." }
}
Write-Host "  The endpoint answers ok:true on every test server." -ForegroundColor Green

$jobs = @()
foreach ( $cc in $Connections ) {
    foreach ( $run in 1..$Runs ) { $jobs += [pscustomobject]@{ Connections = $cc; Run = $run } }
}

$dropbox = $null
if ( $StopDropbox ) { $dropbox = Stop-DropboxForBenchmark }
$failed = 0
try {
    # ---------------------------------------------------------------- warm up
    if ( -not $SkipWarmup ) {
        Write-Host "`n=== Warming test servers ($WarmupSeconds s each) ===" -ForegroundColor Cyan
        foreach ( $srv in $serverSet ) {
            & $BombardierPath --http1 -c 8 -d "${WarmupSeconds}s" -t 5s -q ( Get-TargetUrl -Port $srv.Port -Count $Count ) | Out-Null
        }
    }

    # ---------------------------------------------------------------- measure
    $total = $jobs.Count * $serverSet.Count
    Write-Host "`n=== Measuring: $total runs of $Duration ===" -ForegroundColor Cyan
    $completed = 0
    foreach ( $job in $jobs ) {
        foreach ( $srv in $serverSet ) {
            $completed++
            $url     = Get-TargetUrl -Port $srv.Port -Count $Count
            $outFile = Join-Path $OutputDir "$($srv.Name)-$Endpoint-$label-c$($job.Connections)-run$($job.Run).json"
            Write-Host ( "[{0,3}/{1}] {2,-13} c={3,-3} run={4}" -f $completed, $total, $srv.Name, $job.Connections, $job.Run )
            if ( -not ( Invoke-Measurement -Url $url -ConnectionCount $job.Connections -Duration $Duration -OutFile $outFile ) ) { $failed++ }
        }
    }
}
finally {
    if ( $dropbox ) { Start-DropboxAfterBenchmark -ExePath $dropbox }
}

# ---------------------------------------------------------------- manifest
$manifest = [ordered]@{
    parameters = [ordered]@{ endpoint = $Endpoint; connections = $Connections; runs = $Runs; duration = $Duration; count = $Count }
    machine    = [ordered]@{ logicalProcessors = $env:NUMBER_OF_PROCESSORS; os = [System.Environment]::OSVersion.VersionString; dropboxStopped = [bool] $StopDropbox }
    tool       = [ordered]@{ bombardierPath = $BombardierPath; bombardierHash = ( Get-FileHash -Path $BombardierPath -Algorithm SHA256 ).Hash }
    servers    = $( $m = [ordered]@{}; foreach ( $a in $serverSet ) { $m[ $a.Name ] = [ordered]@{ port = $a.Port; jar = $a.Jar; lockDesign = $a.LockDesign; identity = $identities[ $a.Name ] } }; $m )
    failedMeasurements = $failed
    generatedAt = ( Get-Date ).ToString( 'o' )
}
$manifestPath = Join-Path $OutputDir "manifest-$( Get-Date -Format 'yyyyMMdd-HHmmss' ).json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8

# ---------------------------------------------------------------- summary
# Median RPS per test server and connection count. p99 comes from bombardier's latency
# percentiles and is only comparable within one session.
$rows = @()
foreach ( $cc in $Connections ) {
    $row = [ordered]@{ Connections = $cc }
    foreach ( $srv in $serverSet ) {
        $rps = @(); $p99 = @(); $non2xx = 0
        foreach ( $run in 1..$Runs ) {
            $j = Read-BombardierJson -Path ( Join-Path $OutputDir "$($srv.Name)-$Endpoint-$label-c$cc-run$run.json" )
            if ( $j ) {
                $rps += [double] $j.result.rps.mean
                $p99 += [double] $j.result.latency.percentiles.'99'
                $non2xx += [int] $j.result.req5xx + [int] $j.result.req4xx
            }
        }
        $row[ $srv.Name ]             = [math]::Round( ( Get-BenchMedian -Values $rps ), 1 )
        $row[ "$($srv.Name) p99ms" ]  = [math]::Round( ( Get-BenchMedian -Values $p99 ) / 1000, 1 )
        $row[ "$($srv.Name) non2xx" ] = $non2xx
    }
    $rows += [pscustomobject] $row
}

Write-Host "`n=== Throughput by test server (median RPS), $Endpoint ===" -ForegroundColor Cyan
$rows | Select-Object -Property ( @( 'Connections' ) + @( $serverSet | ForEach-Object { $_.Name } ) ) | Format-Table -AutoSize

$stockName = if ( $serverSet.Name -contains 'u23' ) { 'u23' } elseif ( $serverSet.Name -contains 'buggy' ) { 'buggy' } else { $serverSet[0].Name }
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine( "# $Endpoint throughput round" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Median RPS over $Runs runs of $Duration, count=$Count per request. Test servers alternated per measurement. p99 in ms (same-session comparison only). Ratios are against $stockName." )
[void]$md.AppendLine( "" )
$hdr = "| Conns |"; $sep = "|---|"
foreach ( $srv in $serverSet ) { $hdr += " $($srv.Name) | p99 | non-2xx |"; $sep += "---|---|---|" }
foreach ( $srv in $serverSet ) { if ( $srv.Name -ne $stockName ) { $hdr += " $($srv.Name)/$stockName |"; $sep += "---|" } }
[void]$md.AppendLine( $hdr ); [void]$md.AppendLine( $sep )
foreach ( $r in $rows ) {
    $line = "| $($r.Connections) |"
    foreach ( $srv in $serverSet ) { $line += " $($r.($srv.Name)) | $($r."$($srv.Name) p99ms") | $($r."$($srv.Name) non2xx") |" }
    foreach ( $srv in $serverSet ) {
        if ( $srv.Name -ne $stockName ) {
            $ratio = if ( $r.$stockName -gt 0 ) { "$( [math]::Round( $r.($srv.Name) / $r.$stockName, 2 ) )x" } else { 'n/a' }
            $line += " $ratio |"
        }
    }
    [void]$md.AppendLine( $line )
}
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Test server identity:" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "| Test server | CF version | JVM | NeoPageContext from |" )
[void]$md.AppendLine( "|---|---|---|---|" )
foreach ( $srv in $serverSet ) {
    $id = $identities[ $srv.Name ]
    $src = Split-Path $id.classSources.$BenchPageContextClass -Leaf
    [void]$md.AppendLine( "| $($srv.Name) | $($id.productVersion) $($id.productLevel) | $($id.jvmVersion) | ``$src`` |" )
}
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Manifest: ``$( Split-Path -Leaf $manifestPath )``" )
$summaryPath = Join-Path $OutputDir "summary-$( Get-Date -Format 'yyyyMMdd-HHmmss' ).md"
$md.ToString() | Set-Content -Path $summaryPath -Encoding utf8

if ( $failed -gt 0 ) { Write-Host "`n$failed measurement(s) failed to produce JSON." -ForegroundColor Yellow }
Write-Host "`nResults + $( Split-Path -Leaf $summaryPath ) in $OutputDir" -ForegroundColor Green
