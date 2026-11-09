<#
.SYNOPSIS
    The final, short comparison: stock ColdFusion 2023 Update 23 against Update 23 with Adobe's
    fourth hotfix (v4). Answers two questions in under an hour: is the contamination fixed, and
    does v4 cost any speed?

.DESCRIPTION
    Two test servers only: u23 (stock) and localtemp-u23 (v4). Every burst hits a server that was
    restarted, answered /benchmark/engine and took serial warm-up requests first (the startup crash
    on a freshly started server is a separate bug, see github.com/homestar9/acf-startup-npe-repro,
    and is not measured here).

    Steps:
      0  stop every other test server, restart both, serial warm-up
      1  mechanism: the standalone scope-leak demo and P8 on both
      2  stock, real workload (alpha + bravo), one session: must show the bug
      3  stock, tempvar (the mechanism alone, no database): must show the bug
      4  v4, tempvar: must be clean
      5  v4, real workload, fresh JVM per session: must be clean
      6  speed, real workload, the two servers alternated per measurement
      7  speed, Quick entity + builder construction (the ORM path), alternated
      8  stop both test servers (-KeepServers leaves them running)
      9  summary.md with both tables, computed from the raw files

    Results: benchmark-results-u23\<round>\ (default round final-v4-vs-stock; $env:BENCH_ROUND or
    -Round overrides). About 47 minutes with the defaults on a quiet machine. Run
    Install-TestServers.ps1 -SkipInstall -ClearFelixCache -Servers u23,localtemp-u23 first.
    -StopDropbox pauses the Dropbox client for the run (file sync on the repo folder adds noise
    to the speed figures) and restarts it afterwards.

.EXAMPLE
    .\scripts\Invoke-FinalComparison.ps1
.EXAMPLE
    # rebuild summary.md from the files of an earlier run, without running anything
    .\scripts\Invoke-FinalComparison.ps1 -SummaryOnly
.EXAMPLE
    # two-minute dry run that proves every step works
    .\scripts\Invoke-FinalComparison.ps1 -Round final-dryrun -StockRequests 2000 -TempvarRequests 2000 -ContaminationRequests 2000 -Sessions 1 -WarmRequests 50 -SpeedRuns 1 -SpeedDuration 5s
#>
[CmdletBinding()]
param(
    [string]   $Round                 = $( if ( $env:BENCH_ROUND ) { $env:BENCH_ROUND } else { 'final-v4-vs-stock' } ),
    [string]   $StockServer           = 'u23',
    [string]   $FixServer             = 'localtemp-u23',
    [int]      $StockRequests         = 20000,
    [int]      $StockTempvarRequests  = 20000,
    [int]      $TempvarRequests       = 100000,
    [int]      $ContaminationRequests = 75000,
    [int]      $Sessions              = 2,
    [int]      $WarmRequests          = 500,
    [string[]] $Connections           = @( '8', '16', '32' ),
    [string[]] $QuickConnections      = @( '8', '32' ),
    [int]      $SpeedRuns             = 3,
    [string]   $SpeedDuration         = '30s',
    [string]   $QuickDuration         = '20s',
    [double]   $SpreadFlagPercent     = 10,
    [switch]   $StopDropbox,
    [switch]   $KeepServers,
    [switch]   $SummaryOnly
)

$ErrorActionPreference = 'Continue'
# Lists may arrive as one comma-separated string when the script is run with powershell -File.
$Connections      = @( $Connections -split ',' | Where-Object { $_ } | ForEach-Object { [int] $_ } )
$QuickConnections = @( $QuickConnections -split ',' | Where-Object { $_ } | ForEach-Object { [int] $_ } )
$env:BENCH_ROUND = $Round
. ( Join-Path $PSScriptRoot 'TestServers.ps1' )
$scripts = $PSScriptRoot
$root = Join-Path $BenchRepoRoot "benchmark-results-u23\$BenchRound"
if ( -not ( Test-Path $root ) ) { New-Item -ItemType Directory -Path $root | Out-Null }
$LogPath = Join-Path $root "final-$( Get-Date -Format 'yyyyMMdd-HHmmss' ).log"
$dirs = @{
    mechanism    = Join-Path $root 'mechanism'
    stockAb      = Join-Path $root "contamination\$StockServer-alpha-bravo"
    stockTv      = Join-Path $root "contamination\$StockServer-tempvar"
    fixTv        = Join-Path $root "contamination\$FixServer-tempvar"
    fixAb        = Join-Path $root "contamination\$FixServer-alpha-bravo"
    repro        = Join-Path $root 'repro-throughput'
    quick        = Join-Path $root 'quickconstruct'
}
foreach ( $d in $dirs.Values ) { if ( -not ( Test-Path $d ) ) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$stock = Get-TestServer -Name $StockServer
$fix   = Get-TestServer -Name $FixServer
$pair  = @( $fix, $stock )

function Write-Log {
    <# Echo and append as UTF-8 (Tee-Object -Append writes UTF-16 on Windows PowerShell 5.1). #>
    param( [Parameter(ValueFromPipeline)] $Line )
    process { $Line; Add-Content -Path $LogPath -Value $Line -Encoding UTF8 }
}

function Step {
    param( [string] $Name, [scriptblock] $Body )
    "`n##### $( Get-Date -Format 'HH:mm:ss' ) START $Name" | Write-Log
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { & $Body 2>&1 | Out-String -Width 250 | Write-Log | Out-Null }
    catch { "STEP FAILED: $Name :: $_" | Write-Log }
    $os = Get-CimInstance Win32_OperatingSystem
    ( "##### {0} END {1} ({2} min, {3:N1} GB free)" -f ( Get-Date -Format 'HH:mm:ss' ), $Name, [math]::Round( $sw.Elapsed.TotalMinutes, 1 ), ( $os.FreePhysicalMemory / 1MB ) ) | Write-Log
}

function Reset-Pair {
    foreach ( $srv in $pair ) {
        $null = Restart-TestServerFresh -Server $srv
        $fail = 0
        for ( $i = 1; $i -le 100; $i++ ) {
            $ep = if ( $i % 2 ) { 'alpha' } else { 'bravo' }
            try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$($srv.Port)/repro/$ep" -TimeoutSec 60 } catch { $fail++ }
        }
        "  $($srv.Name): fresh JVM, serial warm-up failures $fail / 100"
    }
}

function Get-Body {
    <# GET a URL and return the body even when the status is 500 (P8 answers 500 when it finds crossings). #>
    param( [string] $Url, [int] $TimeoutSec = 300 )
    try { return ( Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec ).Content }
    catch {
        $resp = $_.Exception.Response
        if ( $resp ) { $reader = New-Object System.IO.StreamReader( $resp.GetResponseStream() ); return $reader.ReadToEnd() }
        return "ERROR $($_.Exception.Message)"
    }
}

function Invoke-Contam {
    param( $Server, [string[]] $Endpoints, [int] $Requests, [int] $SessionCount, [string] $Label, [string] $OutDir )
    # 6>&1: the script reports through Write-Host, which only reaches the pipeline this way.
    & "$scripts\Test-Contamination.ps1" -Server $Server.Name -Endpoints $Endpoints -Connections 20 `
        -TotalRequests $Requests -Sessions $SessionCount -ColdStart -WarmRequests $WarmRequests -Label $Label -OutputDir $OutDir 6>&1 |
        Select-String -Pattern 'session \d+:|x  |CLEAN|CONTAMINATION|INCOMPLETE' | ForEach-Object { $_.Line }
}

"Final comparison: round=$BenchRound stock=$StockServer fix=$FixServer summaryOnly=$SummaryOnly" | Write-Log
if ( -not $SummaryOnly ) {
foreach ( $srv in $TestServers ) {
    if ( @( $StockServer, $FixServer ) -notcontains $srv.Name -and ( Get-TestServerPid -Server $srv ) ) {
        Stop-TestServer -Server $srv
        "  stopped $($srv.Name): not part of this comparison" | Write-Log
    }
}
$dropbox = $null
if ( $StopDropbox ) { $dropbox = Stop-DropboxForBenchmark }

try {
    Step '0 restart both test servers, serial warm-up' { Reset-Pair }

    Step '1 mechanism: scope-leak demo and P8' {
        foreach ( $srv in $pair ) {
            $base = "http://127.0.0.1:$($srv.Port)"
            $html = Get-Body -Url "$base/hotfixrepro/scopeleak/index.cfm"
            Set-Content -Path ( Join-Path $dirs.mechanism "scopeleak-$($srv.Name).html" ) -Value $html -Encoding utf8
            $p8 = Get-Body -Url "$base/torture/p8?threads=32&reps=50&ms=2" -TimeoutSec 180
            Set-Content -Path ( Join-Path $dirs.mechanism "p8-$($srv.Name).json" ) -Value $p8 -Encoding utf8
            $verdict = if ( $html -match 'PASS\.' ) { 'PASS' } elseif ( $html -match 'FAIL\.' ) { 'FAIL' } else { 'no verdict' }
            "  $($srv.Name): scope-leak demo $verdict; P8 $( try { ( $p8 | ConvertFrom-Json ).detail.verdict } catch { 'unreadable' } )"
        }
    }

    Step "2 contamination: $StockServer real workload (must show the bug)" { Invoke-Contam -Server $stock -Endpoints alpha,bravo -Requests $StockRequests -SessionCount 1 -Label 'alpha-bravo' -OutDir $dirs.stockAb }
    Step "3 contamination: $StockServer tempvar (must show the bug)"       { Invoke-Contam -Server $stock -Endpoints tempvar,tempvar -Requests $StockTempvarRequests -SessionCount 1 -Label 'tempvar' -OutDir $dirs.stockTv }
    Step "4 contamination: $FixServer tempvar (must be clean)"            { Invoke-Contam -Server $fix -Endpoints tempvar,tempvar -Requests $TempvarRequests -SessionCount 1 -Label 'tempvar' -OutDir $dirs.fixTv }
    Step "5 contamination: $FixServer real workload (must be clean)"      { Invoke-Contam -Server $fix -Endpoints alpha,bravo -Requests $ContaminationRequests -SessionCount $Sessions -Label 'alpha-bravo' -OutDir $dirs.fixAb }

    Step '6 speed: real workload, alternated' {
        Reset-Pair
        & "$scripts\Invoke-RealWorkloadBenchmark.ps1" -Servers $FixServer, $StockServer -Connections $Connections -Runs $SpeedRuns `
            -Duration $SpeedDuration -WarmupSeconds 20 -SerialWarmupRequests 300 -OutputDir $dirs.repro
    }
    Step '7 speed: Quick entity + builder construction, alternated' {
        & "$scripts\Invoke-ConstructionBenchmark.ps1" -Servers $FixServer, $StockServer -Endpoint quickconstruct -Count 50 `
            -Connections $QuickConnections -Runs $SpeedRuns -Duration $QuickDuration -WarmupSeconds 10 -OutputDir $dirs.quick
    }
}
finally {
    if ( -not $KeepServers ) { foreach ( $srv in $pair ) { Stop-TestServer -Server $srv; "  stopped $($srv.Name)" | Write-Log } }
    if ( $dropbox ) { Start-DropboxAfterBenchmark -ExePath $dropbox }
}
}

# ---------------------------------------------------------------- summary
function Get-Median { param( [double[]] $V ) if ( -not $V -or $V.Count -eq 0 ) { return $null }; $s = $V | Sort-Object; $n = $s.Count; if ( $n % 2 ) { return $s[ ( $n - 1 ) / 2 ] } else { return ( $s[ $n / 2 - 1 ] + $s[ $n / 2 ] ) / 2 } }
function Read-Json { param( [string] $Path ) if ( Test-Path -LiteralPath $Path ) { try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { } }; return $null }
function Fmt { param( $X, [int] $D = 1 ) if ( $null -eq $X ) { return 'n/a' }; return ( [math]::Round( [double] $X, $D ) ).ToString( "N$D" ) }

function Get-ContamCell {
    param( [string] $Dir )
    $j = Read-Json ( Join-Path $Dir 'contamination test-summary.json' )
    if ( -not $j ) { return 'not run' }
    $pct = if ( $j.completedRequests ) { 100.0 * $j.http5xx / $j.completedRequests } else { 0 }
    $rps = ( $j.perSession | ForEach-Object { [math]::Round( $_.rps ) } ) -join ', '
    $txt = if ( $j.http5xx -eq 0 ) { "**0 of {0:N0}**" -f $j.completedRequests } else { "{0:N0} of {1:N0} ({2:N1}%)" -f $j.http5xx, $j.completedRequests, $pct }
    return "$txt, $($j.verdict), $rps requests/s"
}

function Get-DemoCell {
    param( $Srv )
    $html = Get-Content -LiteralPath ( Join-Path $dirs.mechanism "scopeleak-$($Srv.Name).html" ) -Raw -ErrorAction SilentlyContinue
    if ( -not $html ) { return 'not run' }
    $t = $html -replace '<[^>]+>', ' ' -replace '\s+', ' '
    $n = foreach ( $k in @( 'Structs', 'Arrays', 'invoke\(\) argument structs' ) ) { if ( $t -match "$k carrying another thread's token: (\d+)" ) { $Matches[1] } else { '?' } }
    $verdict = if ( $t -match 'PASS\.' ) { 'PASS' } elseif ( $t -match 'FAIL\.' ) { 'FAIL' } else { '?' }
    return "$verdict, $( $n -join ' / ' ) of 3,200 crossed"
}

function Get-P8Cell {
    param( $Srv )
    $j = Read-Json ( Join-Path $dirs.mechanism "p8-$($Srv.Name).json" )
    if ( -not $j ) { return 'not run' }
    return "$( [int] $j.detail.crossings ) of $( [int] $j.detail.builds ) crossed, $( @( $j.detail.leakedKeysAfter | Where-Object { $_ } ).Count ) leaked keys"
}

# Real workload: per server, connection level and run, alpha + bravo combined; successful = rps x 2xx share.
$rw = @{}
foreach ( $f in Get-ChildItem -Path $dirs.repro -Filter '*-repro-c*-run*-*.json' -ErrorAction SilentlyContinue ) {
    if ( $f.Name -notmatch '^(.+?)-repro-c(\d+)-run(\d+)-(alpha|bravo)\.json$' ) { continue }
    $key = "$($Matches[1])|$($Matches[2])|$($Matches[3])"
    $r = ( Read-Json $f.FullName ).result
    if ( -not $r ) { continue }
    $total = $r.req1xx + $r.req2xx + $r.req3xx + $r.req4xx + $r.req5xx + $r.others
    $share = if ( $total ) { $r.req2xx / $total } else { 0 }
    if ( -not $rw.ContainsKey( $key ) ) { $rw[ $key ] = [pscustomobject]@{ Rps = 0.0; Ok = 0.0; P99 = 0.0; Fail = 0; Total = 0 } }
    $c = $rw[ $key ]
    $c.Rps += $r.rps.mean; $c.Ok += $r.rps.mean * $share; $c.Fail += ( $total - $r.req2xx ); $c.Total += $total
    $c.P99 = [math]::Max( $c.P99, $r.latency.percentiles.'99' / 1000.0 )
}
function Get-RwStat {
    param( [string] $Server, [int] $Conn )
    $runs = @( $rw.Keys | Where-Object { $_ -like "$Server|$Conn|*" } | ForEach-Object { $rw[ $_ ] } )
    if ( -not $runs.Count ) { return $null }
    $rps = @( $runs | ForEach-Object { $_.Rps } )
    $med = Get-Median $rps
    [pscustomobject]@{
        Rps = $med; Ok = Get-Median @( $runs | ForEach-Object { $_.Ok } ); P99 = Get-Median @( $runs | ForEach-Object { $_.P99 } )
        ErrPct = 100.0 * ( ( $runs | Measure-Object Fail -Sum ).Sum ) / [math]::Max( 1, ( $runs | Measure-Object Total -Sum ).Sum )
        Spread = if ( $med ) { 100.0 * ( ( $rps | Measure-Object -Maximum ).Maximum - ( $rps | Measure-Object -Minimum ).Minimum ) / $med } else { 0 }
        Runs = ( $rps | ForEach-Object { [math]::Round( $_ ) } ) -join ' / '
    }
}

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine( "# Final comparison: stock Update 23 against Update 23 + v4" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Round ``$BenchRound``, generated $( Get-Date -Format 'yyyy-MM-dd HH:mm' ). Stock = ``$StockServer``, v4 = ``$FixServer``. Log: ``$( Split-Path -Leaf $LogPath )``." )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "## 1. Is the contamination fixed?" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Contaminated requests (HTTP 5xx) of requests sent, 20 connections per endpoint, every session on a restarted server warmed with $WarmRequests serial requests." )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "| Test | Stock | v4 |" )
[void]$md.AppendLine( "|---|---|---|" )
[void]$md.AppendLine( "| Real workload (``/repro/alpha`` + ``/repro/bravo``) | $( Get-ContamCell $dirs.stockAb ) | $( Get-ContamCell $dirs.fixAb ) |" )
[void]$md.AppendLine( "| Mechanism alone (``/repro/tempvar``, no database) | $( Get-ContamCell $dirs.stockTv ) | $( Get-ContamCell $dirs.fixTv ) |" )
[void]$md.AppendLine( "| Standalone demo (``hotfixrepro/scopeleak``), struct / array / invoke() | $( Get-DemoCell $stock ) | $( Get-DemoCell $fix ) |" )
[void]$md.AppendLine( "| P8 inside the application (``/torture/p8``) | $( Get-P8Cell $stock ) | $( Get-P8Cell $fix ) |" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "## 2. Does v4 cost speed?" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Real workload, median of $SpeedRuns runs of $SpeedDuration, servers alternated per measurement. Stock loses some requests to the bug and its error pages are fast, so it is also shown counting only successful requests; the pass bar is v4 at least 0.95 of that. A cell whose runs spread by more than $SpreadFlagPercent% is marked *noisy*." )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "| Connections per endpoint | Stock, all requests | Stock failing | Stock, successful only | v4 | v4 / stock successful | v4 / stock all | p99 stock | p99 v4 | Runs stock | Runs v4 |" )
[void]$md.AppendLine( "|---|---|---|---|---|---|---|---|---|---|---|" )
foreach ( $cc in $Connections ) {
    $s = Get-RwStat -Server $StockServer -Conn $cc; $v = Get-RwStat -Server $FixServer -Conn $cc
    if ( -not $s -or -not $v ) { [void]$md.AppendLine( "| $cc | not measured | | | | | | | | | |" ); continue }
    $noisy = if ( $s.Spread -gt $SpreadFlagPercent -or $v.Spread -gt $SpreadFlagPercent ) { ' *noisy*' } else { '' }
    [void]$md.AppendLine( "| $cc | $( Fmt $s.Rps ) | $( Fmt $s.ErrPct )% | $( Fmt $s.Ok ) | **$( Fmt $v.Rps )** ($( Fmt $v.ErrPct )% failing) | **$( Fmt ( $v.Rps / $s.Ok ) 2 )**$noisy | $( Fmt ( $v.Rps / $s.Rps ) 2 ) | $( Fmt $s.P99 0 ) ms | $( Fmt $v.P99 0 ) ms | $( $s.Runs ) | $( $v.Runs ) |" )
}
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "Quick entity + builder construction (the ORM path, no database), median of $SpeedRuns runs of $($QuickDuration):" )
[void]$md.AppendLine( "" )
[void]$md.AppendLine( "| Connections | Stock | v4 | v4 / stock | Runs stock | Runs v4 |" )
[void]$md.AppendLine( "|---|---|---|---|---|---|" )
foreach ( $cc in $QuickConnections ) {
    $get = { param( $n ) @( Get-ChildItem -Path $dirs.quick -Filter "$n-quickconstruct-entity+builder-c$cc-run*.json" -ErrorAction SilentlyContinue | ForEach-Object { ( Read-Json $_.FullName ).result.rps.mean } ) }
    $sr = & $get $StockServer; $vr = & $get $FixServer
    $sm = Get-Median $sr; $vm = Get-Median $vr
    $spread = { param( $r, $m ) if ( $m ) { 100.0 * ( ( $r | Measure-Object -Maximum ).Maximum - ( $r | Measure-Object -Minimum ).Minimum ) / $m } else { 0 } }
    $noisy = if ( ( & $spread $sr $sm ) -gt $SpreadFlagPercent -or ( & $spread $vr $vm ) -gt $SpreadFlagPercent ) { ' *noisy*' } else { '' }
    $ratio = if ( $sm -and $vm ) { ( Fmt ( $vm / $sm ) 2 ) + $noisy } else { 'n/a' }
    [void]$md.AppendLine( "| $cc | $( Fmt $sm ) | $( Fmt $vm ) | **$ratio** | $( ( $sr | ForEach-Object { [math]::Round( $_ ) } ) -join ' / ' ) | $( ( $vr | ForEach-Object { [math]::Round( $_ ) } ) -join ' / ' ) |" )
}
[void]$md.AppendLine( "" )
$failed = @( Select-String -Path $LogPath -Pattern 'STEP FAILED' -SimpleMatch ).Count
[void]$md.AppendLine( "Steps that failed: $failed (see the log)." )
$summaryPath = Join-Path $root 'summary.md'
Set-Content -Path $summaryPath -Value $md.ToString() -Encoding utf8
"`n##### FINAL COMPARISON DONE $( Get-Date -Format 'HH:mm:ss' )  summary: $summaryPath  log: $LogPath" | Write-Log
