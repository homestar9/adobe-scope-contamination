<#
.SYNOPSIS
    Database-free CFC construction throughput test across the benchmark test servers, with a
    self-contained RPS summary.

.DESCRIPTION
    Test servers come from scripts\TestServers.ps1; stand them up first with Install-TestServers.ps1.

    Endpoints:
      construct       /benchmark/construct?count=N&shape=S[&n=W][&ms=M]   (shapes below)
      quickconstruct  /benchmark/quickconstruct?count=N   a Quick entity + query builder per
                      iteration; every Quick entity extends BaseEntity, so this is exactly the
                      shared-ancestor case a per-class construction lock collapses on.

    Shapes for construct:
      narrow, wide, closure         one class hammered (worst case for any construction lock)
      fanout                        W unrelated classes, no extends (best case for per-class locks)
      siblings                      W classes sharing one base (each nests into the base lock)
      deep                          one class at the end of a five-level extends chain
      slowfanout, slowsiblings      as above with an M ms sleep inside the pseudo-constructor
      slowinit                      M ms sleep in init(), which runs outside the lock

    Every measurement alternates test servers so drift (thermals, background work) hits all test servers
    equally. Run on a quiet machine; use -StopDropbox on this Dropbox-synced tree.

    The construct endpoint returns HTTP 500 on a checksum or identity mismatch, so
    bombardier's non-2xx count doubles as a contamination detector for the synthetic path.
    That is NOT the contamination test (Test-Contamination.ps1 is); it is a tripwire.

.PARAMETER Profile
    short (default): narrow, fanout, siblings at c=1 and 32, 2 runs of 10 s, no control runs;
    about 15 minutes for six test servers. long: eight shapes at c=1,8,16,32, 2 runs of 20 s plus
    control runs, about 90 minutes. Explicit parameters win.

.PARAMETER Widths
    When given, runs a width test: shape=fanout with n = each width, at the first value of
    -Connections only. Shows whether throughput scales with the number of distinct classes.

.EXAMPLE
    .\scripts\Invoke-ConstructionBenchmark.ps1
.EXAMPLE
    .\scripts\Invoke-ConstructionBenchmark.ps1 -Shapes narrow,wide,closure,fanout,siblings,deep,slowfanout,slowsiblings -Connections 1,8,16,32 -Runs 2 -Duration 20s -StopDropbox
.EXAMPLE
    .\scripts\Invoke-ConstructionBenchmark.ps1 -Endpoint quickconstruct -Count 50 -Connections 1,8,32 -Runs 3
.EXAMPLE
    .\scripts\Invoke-ConstructionBenchmark.ps1 -Shapes fanout -Widths 1,2,4,8,16 -Connections 32 -Runs 2
#>
[CmdletBinding()]
param(
    [string[]] $Servers           = @(),
    [ValidateSet( 'short', 'long' )]
    [string]   $Profile        = 'short',
    [ValidateSet( 'construct', 'quickconstruct' )]
    [string]   $Endpoint       = 'construct',
    [int[]]    $Connections    = @( 1, 4, 8, 16, 32 ),
    [int]      $Runs           = 3,
    [string]   $Duration       = '30s',
    [int]      $Count          = 200,
    [ValidateSet( 'narrow', 'wide', 'closure', 'fanout', 'siblings', 'deep', 'slowfanout', 'slowsiblings', 'slowinit' )]
    [string[]] $Shapes         = @( 'narrow', 'wide' ),
    [int]      $Width          = 16,
    [int]      $SleepMs        = 3,
    [int[]]    $Widths         = @(),
    [int[]]    $ControlConnections = @( 1, 8, 32 ),
    [string]   $BombardierPath = '',
    [string]   $OutputDir      = '',
    [int]      $WarmupSeconds  = 20,
    [switch]   $SkipWarmup,
    [switch]   $StopDropbox
)

$ErrorActionPreference = 'Stop'
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
$section = if ( $PSBoundParameters.ContainsKey( 'Widths' ) ) { 'Widths' } elseif ( $Endpoint -eq 'quickconstruct' ) { 'QuickConstruct' } else { 'Construct' }
Use-BenchProfile -Profile $Profile -Section $section -Bound $PSBoundParameters

$serverSet = Select-TestServers -Names $Servers
if ( -not $OutputDir ) { $OutputDir = Get-BenchResultsRoot -Profile $Profile -Kind $( if ( $PSBoundParameters.ContainsKey( 'Widths' ) ) { "$Endpoint-widths" } else { $Endpoint } ) }
if ( -not ( Test-Path $OutputDir ) ) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$BombardierPath = Get-BenchBombardierPath -Override $BombardierPath
Write-Host "bombardier: $BombardierPath" -ForegroundColor Cyan

# $Shapes carries a ValidateSet, so assigning 'entity+builder' to it would fail validation;
# the shapes actually measured live in $shapeList.
$shapeList = @( $Shapes )
if ( $Endpoint -eq 'quickconstruct' ) { $shapeList = @( 'entity+builder' ) }
$widthSweep = $Widths.Count -gt 0
if ( $widthSweep ) { $shapeList = @( 'fanout' ); $Connections = @( $Connections[0] ) }

# ---------------------------------------------------------------- preflight
Write-Host "`n=== Preflight ===" -ForegroundColor Cyan
$identities = Get-TestServerIdentities -Servers $serverSet -SaveTo $OutputDir
Write-Host "  Identities asserted; deployed-jar hashes confirmed; same JVM." -ForegroundColor Green

function Get-TargetUrl {
    param( $Port, $Kind, $Shape, $Count, $Width, $SleepMs )
    switch ( $Kind ) {
        'control'        { return "http://127.0.0.1:$Port/benchmark/control?count=$Count" }
        'quickconstruct' { return "http://127.0.0.1:$Port/benchmark/quickconstruct?count=$Count" }
        default          { return "http://127.0.0.1:$Port/benchmark/construct?count=$Count&shape=$Shape&n=$Width&ms=$SleepMs" }
    }
}

function Invoke-Measurement {
    param( $Url, $ConnectionCount, $Duration, $OutFile )
    $output = & $BombardierPath --http1 -c $ConnectionCount -d $Duration -t 5s -l -p r -o json $Url
    $text = $output -join "`n"
    try { $null = $text | ConvertFrom-Json } catch { Write-Host "    bombardier did not return JSON: $text" -ForegroundColor Red; return $false }
    Set-Content -Path $OutFile -Value $text -Encoding utf8
    return $true
}

# One request per test server/shape before anything else: a 500 here means the shape is broken
# (checksum or identity mismatch) and the whole test would just measure error pages.
foreach ( $srv in $serverSet ) {
    foreach ( $shape in $shapeList ) {
        $w = if ( $widthSweep ) { $Widths[0] } else { $Width }
        $url = Get-TargetUrl -Port $srv.Port -Kind $Endpoint -Shape $shape -Count 5 -Width $w -SleepMs 0
        try { $r = Invoke-RestMethod -Uri $url -TimeoutSec 60 }
        catch { throw "$($srv.Name): $url failed ($($_.Exception.Message)). Fix the shape before measuring." }
        if ( -not $r.ok ) { throw "$($srv.Name): $url returned ok=false (checksum $($r.checksum) vs expected $($r.expected))." }
    }
}
Write-Host "  Every shape answers ok:true on every test server." -ForegroundColor Green

$dropbox = $null
if ( $StopDropbox ) { $dropbox = Stop-DropboxForBenchmark }
try {
    # ---------------------------------------------------------------- warm up
    if ( -not $SkipWarmup ) {
        Write-Host "`n=== Warming test servers ($WarmupSeconds s per target) ===" -ForegroundColor Cyan
        foreach ( $srv in $serverSet ) {
            foreach ( $shape in $shapeList ) {
                $w = if ( $widthSweep ) { $Widths[-1] } else { $Width }
                & $BombardierPath --http1 -c 8 -d "${WarmupSeconds}s" -t 5s -q ( Get-TargetUrl -Port $srv.Port -Kind $Endpoint -Shape $shape -Count $Count -Width $w -SleepMs $SleepMs ) | Out-Null
            }
            if ( $Endpoint -eq 'construct' -and -not $widthSweep ) {
                & $BombardierPath --http1 -c 8 -d "${WarmupSeconds}s" -t 5s -q ( Get-TargetUrl -Port $srv.Port -Kind 'control' -Shape 'none' -Count $Count ) | Out-Null
            }
        }
    }

    # ---------------------------------------------------------------- work list
    $jobs = @()
    if ( $widthSweep ) {
        foreach ( $w in $Widths ) {
            foreach ( $run in 1..$Runs ) { $jobs += [pscustomobject]@{ Kind = 'construct'; Shape = 'fanout'; Width = $w; Connections = $Connections[0]; Run = $run; Label = "fanout-n$w" } }
        }
    }
    else {
        foreach ( $shape in $shapeList ) {
            foreach ( $cc in $Connections ) {
                foreach ( $run in 1..$Runs ) { $jobs += [pscustomobject]@{ Kind = $Endpoint; Shape = $shape; Width = $Width; Connections = $cc; Run = $run; Label = $shape } }
            }
        }
        if ( $Endpoint -eq 'construct' ) {
            foreach ( $cc in $ControlConnections ) {
                foreach ( $run in 1..$Runs ) { $jobs += [pscustomobject]@{ Kind = 'control'; Shape = 'none'; Width = 0; Connections = $cc; Run = $run; Label = 'control' } }
            }
        }
    }

    $total = $jobs.Count * $serverSet.Count
    Write-Host "`n=== Measuring: $total runs of $Duration ===" -ForegroundColor Cyan
    Write-Host "Rough wall clock: $( [math]::Round( ( $total * [int]( $Duration -replace '\D','' ) ) / 60 ) ) minutes`n"

    $completed = 0; $failed = 0
    foreach ( $job in $jobs ) {
        foreach ( $srv in $serverSet ) {
            $completed++
            $url     = Get-TargetUrl -Port $srv.Port -Kind $job.Kind -Shape $job.Shape -Count $Count -Width $job.Width -SleepMs $SleepMs
            $outFile = Join-Path $OutputDir "$($srv.Name)-$($job.Kind)-$($job.Label)-c$($job.Connections)-run$($job.Run).json"
            Write-Host ( "[{0,3}/{1}] {2,-13} {3,-14} {4,-12} c={5,-3} run={6}" -f $completed, $total, $srv.Name, $job.Kind, $job.Label, $job.Connections, $job.Run )
            if ( -not ( Invoke-Measurement -Url $url -ConnectionCount $job.Connections -Duration $Duration -OutFile $outFile ) ) { $failed++ }
        }
    }
}
finally {
    if ( $dropbox ) { Start-DropboxAfterBenchmark -ExePath $dropbox }
}

# ---------------------------------------------------------------- manifest
$manifest = [ordered]@{
    parameters = [ordered]@{ endpoint = $Endpoint; connections = $Connections; controlConnections = $ControlConnections; runs = $Runs; duration = $Duration; count = $Count; shapes = $shapeList; width = $Width; widths = $Widths; sleepMs = $SleepMs }
    machine    = [ordered]@{ logicalProcessors = $env:NUMBER_OF_PROCESSORS; os = [System.Environment]::OSVersion.VersionString; dropboxStopped = [bool] $StopDropbox }
    tool       = [ordered]@{ bombardierPath = $BombardierPath; bombardierHash = ( Get-FileHash -Path $BombardierPath -Algorithm SHA256 ).Hash }
    servers       = $( $m = [ordered]@{}; foreach ( $a in $serverSet ) { $m[ $a.Name ] = [ordered]@{ port = $a.Port; jar = $a.Jar; lockDesign = $a.LockDesign; identity = $identities[ $a.Name ] } }; $m )
    failedMeasurements = $failed
    generatedAt = ( Get-Date ).ToString( 'o' )
}
$manifestPath = Join-Path $OutputDir "manifest-$( Get-Date -Format 'yyyyMMdd-HHmmss' ).json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding utf8

# ---------------------------------------------------------------- summary
# Median RPS per test server/label/connections. Median of the repeat runs ignores the odd slow run
# without hand-tuning. p99 comes from bombardier's latency percentiles; on this machine it
# is only comparable within a session, never across sessions.
$labels = @( $jobs | Where-Object { $_.Kind -ne 'control' } | ForEach-Object { $_.Label } | Select-Object -Unique )
$rows = @()
foreach ( $label in $labels ) {
    foreach ( $cc in ( $jobs | Where-Object { $_.Label -eq $label } | ForEach-Object { $_.Connections } | Select-Object -Unique ) ) {
        $row = [ordered]@{ Label = $label; Connections = $cc }
        foreach ( $srv in $serverSet ) {
            $rps = @(); $p99 = @(); $non2xx = 0
            foreach ( $run in 1..$Runs ) {
                $kind = if ( $Endpoint -eq 'quickconstruct' ) { 'quickconstruct' } else { 'construct' }
                $j = Read-BombardierJson -Path ( Join-Path $OutputDir "$($srv.Name)-$kind-$label-c$cc-run$run.json" )
                if ( $j ) {
                    $rps += [double] $j.result.rps.mean
                    $p99 += [double] $j.result.latency.percentiles.'99'
                    $non2xx += [int] $j.result.req5xx + [int] $j.result.req4xx
                }
            }
            $row[ $srv.Name ]           = [math]::Round( ( Get-BenchMedian -Values $rps ), 1 )
            $row[ "$($srv.Name) p99ms" ] = [math]::Round( ( Get-BenchMedian -Values $p99 ) / 1000, 1 )
            $row[ "$($srv.Name) non2xx" ] = $non2xx
        }
        $rows += [pscustomobject] $row
    }
}

Write-Host "`n=== Throughput by test server (median RPS), $Endpoint ===" -ForegroundColor Cyan
$rows | Select-Object -Property ( @( 'Label', 'Connections' ) + @( $serverSet | ForEach-Object { $_.Name } ) ) | Format-Table -AutoSize

$stockName = if ( $serverSet.Name -contains 'u23' ) { 'u23' } elseif ( $serverSet.Name -contains 'buggy' ) { 'buggy' } else { $serverSet[0].Name }
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine( "# $Endpoint throughput round" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Median RPS over $Runs runs of $Duration, count=$Count per request, n=$Width, ms=$SleepMs. Test servers alternated per measurement. p99 in ms (same-session comparison only). Ratios are against $stockName." )
[void]$md.AppendLine( "" )
foreach ( $label in $labels ) {
    [void]$md.AppendLine( "## $label" )
    [void]$md.AppendLine( "" )
    $hdr = "| Conns |"; $sep = "|---|"
    foreach ( $srv in $serverSet ) { $hdr += " $($srv.Name) | p99 | non-2xx |"; $sep += "---|---|---|" }
    foreach ( $srv in $serverSet ) { if ( $srv.Name -ne $stockName ) { $hdr += " $($srv.Name)/$stockName |"; $sep += "---|" } }
    [void]$md.AppendLine( $hdr ); [void]$md.AppendLine( $sep )
    foreach ( $r in ( $rows | Where-Object { $_.Label -eq $label } ) ) {
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
}
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
