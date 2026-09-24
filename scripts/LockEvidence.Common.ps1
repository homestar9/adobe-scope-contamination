<#
.SYNOPSIS
    Thread-dump parsing shared by Get-LockEvidence.ps1 and Invoke-LockSoak.ps1. Dot-source it:

        . ( Join-Path $PSScriptRoot 'LockEvidence.Common.ps1' )

.DESCRIPTION
    Two hotfix lock designs leave two different fingerprints in a `jcmd <pid> Thread.print -l`
    dump, and this file recognises both.

    Adobe v1 (test server lock-u23): one global `synchronized ( CONSTRUCTION_LOCK )` monitor.

        "XNIO-1 task-2" #113 ... waiting for monitor entry
           java.lang.Thread.State: BLOCKED (on object monitor)
            at coldfusion.runtime.TemplateProxyFactory.resolveName(TemplateProxyFactory.java:202)
            - waiting to lock <0x00000000828f4ce0> (a java.lang.Object)

      The owner is the one thread whose stack carries `- locked <0x00000000828f4ce0>`.

    Adobe v3 (test server perclass-u23): one ReentrantLock per CFC path, held together with every
    ancestor's lock until the outermost construction returns.

        "XNIO-1 task-7" #118 ... waiting on condition
           java.lang.Thread.State: WAITING (parking)
            at jdk.internal.misc.Unsafe.park(java.base@17.0.20/Native Method)
            - parking to wait for  <0x000000008a1b2c30> (a java.util.concurrent.locks.ReentrantLock$NonfairSync)
            ...
            at coldfusion.runtime.TemplateProxyFactory.resolveName(...)

           Locked ownable synchronizers:
            - None

      A ReentrantLock owner is not visible in its stack frames; it only appears (with -l) in
      its "Locked ownable synchronizers" section. That section is separated from the stack by
      a blank line, which is why a block here runs to the next thread header rather than to
      the next blank line.

    Attribution. A thread counts as waiting "on resolveName" when it has a
    TemplateProxyFactory.resolveName frame AND the first non-JDK frame (the code that actually
    asked for the lock) is inside TemplateProxyFactory. The second condition stops a thread
    that holds the construction lock, runs a pseudo-constructor, and then waits on some
    unrelated lock deeper down from being booked as construction-lock contention. The raw
    "resolveName frame anywhere in the stack" counts are reported alongside (...AnyDepth) so a
    large gap between the two is visible rather than hidden.

    Addresses are object addresses at the moment of the dump. G1 can move the lock object
    between dumps, so a union of addresses across dumps can over-count distinct locks; the
    per-dump distinct counts (avg/max) are the robust figure.
#>

# A real thread header is '"name" #nn ...' or '"VM Thread" os_prio=...'. The deadlock report
# lists threads as '"name":' which this pattern deliberately does not match.
$LockEvidenceHeaderPattern      = '^"[^"]+"\s'
# Everything from these lines on is not a thread block (deadlock report, JNI summary).
$LockEvidenceTrailerPattern     = '^(Found one Java-level deadlock|Found \d+ Java-level deadlocks|JNI global ref)'
$LockEvidenceDeadlockPattern    = 'Found one Java-level deadlock|Found \d+ Java-level deadlocks'
$LockEvidenceResolveNamePattern = 'TemplateProxyFactory\.resolveName'
$LockEvidenceTpfSitePattern     = '^coldfusion\.runtime\.TemplateProxyFactory[.$]'
$LockEvidenceJdkFramePattern    = '^(java\.|javax\.|jdk\.|sun\.)'

function Split-ThreadDump {
    <# Splits a Thread.print dump into one text block per thread (header through its ownable-synchronizers section). #>
    param( [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text )
    $lines   = [regex]::Split( $Text, '\r?\n' )
    $blocks  = New-Object System.Collections.Generic.List[string]
    $current = $null
    foreach ( $line in $lines ) {
        if ( $line -match $LockEvidenceTrailerPattern ) { break }
        if ( $line -match $LockEvidenceHeaderPattern ) {
            if ( $null -ne $current ) { $blocks.Add( ( $current -join "`n" ).TrimEnd() ) }
            $current = New-Object System.Collections.Generic.List[string]
            $current.Add( $line )
            continue
        }
        # Lines before the first header are the jcmd preamble and the SMR info; skip them.
        if ( $null -ne $current ) { $current.Add( $line ) }
    }
    if ( $null -ne $current ) { $blocks.Add( ( $current -join "`n" ).TrimEnd() ) }
    return $blocks.ToArray()
}

function Get-LockEvidenceCfcName {
    <# Decodes the top-most compiled CFC frame (cfBaseEntity2ecfc123...) to 'BaseEntity.cfc'; falls back to the first coldfusion. frame. #>
    param( [string[]] $Frames )
    foreach ( $f in $Frames ) {
        # '2ecfc' is CF's mangling of '.cfc'; the digits after it are a hash of the path.
        if ( $f -match '^cf([A-Za-z0-9_]+?)2ecfc' ) { return "$($matches[1]).cfc" }
    }
    foreach ( $f in $Frames ) {
        if ( $f -match '^coldfusion\.' ) { return $f }
    }
    return ''
}

function ConvertFrom-ThreadBlock {
    <# Parses one thread block into an object describing its state, what it waits on and what it owns. #>
    param( [Parameter(Mandatory)] [AllowEmptyString()] [string] $Block )
    $lines          = [regex]::Split( $Block, '\r?\n' )
    $name           = ''
    if ( $lines.Count -gt 0 -and $lines[0] -match '^"([^"]+)"' ) { $name = $matches[1] }
    $state          = ''
    $frames         = New-Object System.Collections.Generic.List[string]
    $owned          = New-Object System.Collections.Generic.List[string]
    $lockedMonitors = New-Object System.Collections.Generic.List[string]
    $blockedMonitor = $null
    $parkedOn       = $null
    $inOwnable      = $false

    foreach ( $line in $lines ) {
        if ( $line -match 'java\.lang\.Thread\.State:\s+(.+?)\s*$' ) { $state = $matches[1]; continue }
        if ( $line -match '^\s*Locked ownable synchronizers:' ) { $inOwnable = $true; continue }
        if ( $inOwnable ) {
            if ( $line -match '^\s*-\s*<(0x[0-9a-fA-F]+)>' ) { $owned.Add( $matches[1].ToLowerInvariant() ) }
            continue
        }
        if ( $line -match '^\s+at\s+(.+?)\s*$' ) { $frames.Add( $matches[1] ); continue }
        # jcmd prints two spaces after 'parking to wait for'; \s+ covers either spacing.
        if ( $line -match '^\s*-\s+waiting to lock\s+<(0x[0-9a-fA-F]+)>\s*\(a\s+([^)]+)\)' ) {
            if ( -not $blockedMonitor ) { $blockedMonitor = [pscustomobject]@{ Address = $matches[1].ToLowerInvariant(); Class = $matches[2].Trim() } }
            continue
        }
        if ( $line -match '^\s*-\s+parking to wait for\s+<(0x[0-9a-fA-F]+)>\s*\(a\s+([^)]+)\)' ) {
            if ( -not $parkedOn ) { $parkedOn = [pscustomobject]@{ Address = $matches[1].ToLowerInvariant(); Class = $matches[2].Trim() } }
            continue
        }
        if ( $line -match '^\s*-\s+locked\s+<(0x[0-9a-fA-F]+)>' ) {
            # v1 re-enters the same monitor once per ancestor, so the same address repeats.
            $a = $matches[1].ToLowerInvariant()
            if ( -not $lockedMonitors.Contains( $a ) ) { $lockedMonitors.Add( $a ) }
        }
    }

    $frameArray = $frames.ToArray()
    $topFrame   = if ( $frameArray.Count -gt 0 ) { $frameArray[0] } else { '' }
    $waitSite   = ''
    foreach ( $f in $frameArray ) { if ( $f -notmatch $LockEvidenceJdkFramePattern ) { $waitSite = $f; break } }
    $hasResolve = $false
    foreach ( $f in $frameArray ) { if ( $f -match $LockEvidenceResolveNamePattern ) { $hasResolve = $true; break } }

    return [pscustomobject]@{
        Name                        = $name
        State                       = $state
        TopFrame                    = $topFrame
        WaitSite                    = $waitSite
        Frames                      = $frameArray
        IsBlockedOnMonitor          = ( $state -match '^BLOCKED' )
        BlockedMonitor              = $blockedMonitor
        IsParked                    = ( $state -match '^(TIMED_)?WAITING \(parking\)' )
        ParkedOn                    = $parkedOn
        OwnedSynchronizers          = $owned.ToArray()
        LockedMonitors              = $lockedMonitors.ToArray()
        HasResolveNameFrame         = $hasResolve
        WaitsInTemplateProxyFactory = ( $waitSite -match $LockEvidenceTpfSitePattern )
        OwnerCfc                    = ( Get-LockEvidenceCfcName -Frames $frameArray )
    }
}

function New-LockEvidenceEntry {
    param( [string] $Address, [string] $Class, $Owner )
    $ownerThread = ''; $ownerCfc = ''; $ownerState = ''
    if ( $Owner ) { $ownerThread = $Owner.Name; $ownerCfc = $Owner.OwnerCfc; $ownerState = $Owner.State }
    return [pscustomobject]@{
        addr               = $Address
        class              = $Class
        waiters            = 0
        resolveNameWaiters = 0
        ownerThread        = $ownerThread
        ownerCfc           = $ownerCfc
        ownerState         = $ownerState
    }
}

function Measure-ThreadDump {
    <# Summarises one dump: BLOCKED (v1) and parked-on-ReentrantLock (v3) threads, per-lock waiters and owners, block sites, deadlock. #>
    param( [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text, [string] $Label = '' )

    $threads = @( Split-ThreadDump -Text $Text | ForEach-Object { ConvertFrom-ThreadBlock -Block $_ } )

    # Who owns what: ReentrantLocks via "Locked ownable synchronizers", monitors via "- locked".
    $syncOwner    = @{}
    $monitorOwner = @{}
    foreach ( $t in $threads ) {
        foreach ( $a in $t.OwnedSynchronizers ) { $syncOwner[ $a ] = $t }
        foreach ( $a in $t.LockedMonitors ) { if ( -not $monitorOwner.ContainsKey( $a ) ) { $monitorOwner[ $a ] = $t } }
    }

    $blockedTotal = 0; $blockedOnResolve = 0; $blockedAnyDepth = 0
    $parkedTotal  = 0; $parkedOnRl = 0; $parkedOnResolve = 0; $parkedAnyDepth = 0
    $locks = @{}; $monitors = @{}; $blockSites = @{}

    foreach ( $t in $threads ) {
        $attributed = $t.HasResolveNameFrame -and $t.WaitsInTemplateProxyFactory

        if ( $t.IsBlockedOnMonitor ) {
            $blockedTotal++
            if ( $t.HasResolveNameFrame ) { $blockedAnyDepth++ }
            if ( $attributed ) { $blockedOnResolve++ }
            $site = "BLOCKED  $($t.TopFrame)"
            if ( -not $blockSites.ContainsKey( $site ) ) { $blockSites[ $site ] = 0 }
            $blockSites[ $site ]++
            if ( $t.BlockedMonitor ) {
                $a = $t.BlockedMonitor.Address
                if ( -not $monitors.ContainsKey( $a ) ) { $monitors[ $a ] = New-LockEvidenceEntry -Address $a -Class $t.BlockedMonitor.Class -Owner $monitorOwner[ $a ] }
                $monitors[ $a ].waiters++
                if ( $attributed ) { $monitors[ $a ].resolveNameWaiters++ }
            }
        }

        if ( $t.IsParked ) {
            $parkedTotal++
            # Only ReentrantLock sync objects are lock waits. Idle pool threads park on an
            # AbstractQueuedSynchronizer$ConditionObject and must not be counted as contention.
            if ( $t.ParkedOn -and $t.ParkedOn.Class -match 'ReentrantLock' ) {
                $parkedOnRl++
                if ( $t.HasResolveNameFrame ) { $parkedAnyDepth++ }
                if ( $attributed ) { $parkedOnResolve++ }
                # The top frame of a parked thread is always Unsafe.park; the useful site is
                # the first non-JDK frame, i.e. the code that called lock().
                $site = "PARKED   $($t.WaitSite)"
                if ( -not $blockSites.ContainsKey( $site ) ) { $blockSites[ $site ] = 0 }
                $blockSites[ $site ]++
                $a = $t.ParkedOn.Address
                if ( -not $locks.ContainsKey( $a ) ) { $locks[ $a ] = New-LockEvidenceEntry -Address $a -Class $t.ParkedOn.Class -Owner $syncOwner[ $a ] }
                $locks[ $a ].waiters++
                if ( $attributed ) { $locks[ $a ].resolveNameWaiters++ }
            }
        }
    }

    $deadlock     = [regex]::Match( $Text, $LockEvidenceDeadlockPattern )
    $deadlockText = ''
    if ( $deadlock.Success ) {
        $deadlockText = $Text.Substring( $deadlock.Index ).Trim()
        if ( $deadlockText.Length -gt 20000 ) { $deadlockText = $deadlockText.Substring( 0, 20000 ) + "`n...(truncated)" }
    }

    return [pscustomobject]@{
        label                      = $Label
        threadCount                = $threads.Count
        blockedTotal               = $blockedTotal
        blockedOnResolveName       = $blockedOnResolve
        blockedResolveNameAnyDepth = $blockedAnyDepth
        parkedTotal                = $parkedTotal
        parkedOnReentrantLock      = $parkedOnRl
        parkedOnResolveName        = $parkedOnResolve
        parkedResolveNameAnyDepth  = $parkedAnyDepth
        distinctLocksContended     = @( $locks.Values    | Where-Object { $_.resolveNameWaiters -gt 0 } ).Count
        distinctMonitorsContended  = @( $monitors.Values | Where-Object { $_.resolveNameWaiters -gt 0 } ).Count
        locks                      = $locks
        monitors                   = $monitors
        blockSites                 = $blockSites
        deadlockDetected           = $deadlock.Success
        deadlockText               = $deadlockText
    }
}

function Merge-LockEvidenceEntries {
    <# Aggregates per-dump lock/monitor tables by address; the owner is taken from the dump with the most waiters that named one. #>
    param( [object[]] $Tables, [int] $Top = 8 )
    $agg = @{}
    foreach ( $table in $Tables ) {
        if ( -not $table ) { continue }
        foreach ( $e in $table.Values ) {
            if ( -not $agg.ContainsKey( $e.addr ) ) {
                $agg[ $e.addr ] = [pscustomobject]@{
                    addr = $e.addr; class = $e.class; waiters = 0; resolveNameWaiters = 0; dumpsSeen = 0
                    ownerThread = ''; ownerCfc = ''; ownerState = ''; bestWaiters = -1
                }
            }
            $x = $agg[ $e.addr ]
            $x.waiters            += $e.waiters
            $x.resolveNameWaiters += $e.resolveNameWaiters
            $x.dumpsSeen++
            # A just-released ReentrantLock can have queued waiters and no owner for an
            # instant; prefer the busiest dump that actually named the owner.
            if ( $e.ownerThread -and $e.waiters -gt $x.bestWaiters ) {
                $x.bestWaiters = $e.waiters; $x.ownerThread = $e.ownerThread; $x.ownerCfc = $e.ownerCfc; $x.ownerState = $e.ownerState
            }
        }
    }
    $all = @( $agg.Values | Sort-Object -Property @{ Expression = 'waiters'; Descending = $true } )
    $topEntries = @( $all | Select-Object -First $Top | ForEach-Object {
        [ordered]@{
            addr = $_.addr; class = $_.class; waiters = $_.waiters; resolveNameWaiters = $_.resolveNameWaiters
            dumpsSeen = $_.dumpsSeen; ownerThread = $_.ownerThread; ownerCfc = $_.ownerCfc; ownerState = $_.ownerState
        }
    } )
    $bestResolve = 0
    foreach ( $x in $all ) { if ( $x.resolveNameWaiters -gt $bestResolve ) { $bestResolve = $x.resolveNameWaiters } }
    return [pscustomobject]@{
        Distinct           = @( $all | Where-Object { $_.resolveNameWaiters -gt 0 } ).Count
        MaxResolveWaiters  = $bestResolve
        Top                = $topEntries
    }
}

function Merge-ThreadDumpMeasurements {
    <# Aggregates Measure-ThreadDump results: totals, per-dump averages, distinct contended locks, top locks/monitors/sites, deadlocks. #>
    param( [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Measurements )
    $ms = @( $Measurements | Where-Object { $_ } )
    $n  = $ms.Count

    $sum = @{}
    foreach ( $k in @( 'blockedTotal', 'blockedOnResolveName', 'blockedResolveNameAnyDepth', 'parkedTotal',
                       'parkedOnReentrantLock', 'parkedOnResolveName', 'parkedResolveNameAnyDepth', 'distinctLocksContended' ) ) {
        $s = 0
        foreach ( $m in $ms ) { $s += [int] $m.$k }
        $sum[ $k ] = $s
    }
    $avg = { param( $total ) if ( $n -eq 0 ) { 0 } else { [math]::Round( $total / $n, 2 ) } }

    $lockAgg    = Merge-LockEvidenceEntries -Tables @( $ms | ForEach-Object { $_.locks } )    -Top 8
    $monitorAgg = Merge-LockEvidenceEntries -Tables @( $ms | ForEach-Object { $_.monitors } ) -Top 8

    $sites = @{}
    foreach ( $m in $ms ) {
        foreach ( $k in $m.blockSites.Keys ) {
            if ( -not $sites.ContainsKey( $k ) ) { $sites[ $k ] = 0 }
            $sites[ $k ] += $m.blockSites[ $k ]
        }
    }
    $topSites = @( $sites.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 |
                   ForEach-Object { [ordered]@{ frame = $_.Key; count = $_.Value } } )

    # "Global lock in disguise": one address absorbing nearly all construction waits.
    $dominantLockShare    = 0
    if ( $sum.parkedOnResolveName -gt 0 )  { $dominantLockShare    = [math]::Round( $lockAgg.MaxResolveWaiters / $sum.parkedOnResolveName, 3 ) }
    $dominantMonitorShare = 0
    if ( $sum.blockedOnResolveName -gt 0 ) { $dominantMonitorShare = [math]::Round( $monitorAgg.MaxResolveWaiters / $sum.blockedOnResolveName, 3 ) }

    $maxDistinct = 0
    foreach ( $m in $ms ) { if ( $m.distinctLocksContended -gt $maxDistinct ) { $maxDistinct = $m.distinctLocksContended } }
    $deadlockDumps = @( $ms | Where-Object { $_.deadlockDetected } | ForEach-Object { $_.label } )
    $firstDeadlock = $ms | Where-Object { $_.deadlockDetected } | Select-Object -First 1
    $deadlockText  = ''
    if ( $firstDeadlock ) { $deadlockText = $firstDeadlock.deadlockText }

    return [pscustomobject][ordered]@{
        dumps                          = $n
        blockedTotal                   = $sum.blockedTotal
        blockedOnResolveName           = $sum.blockedOnResolveName
        blockedResolveNameAnyDepth     = $sum.blockedResolveNameAnyDepth
        parkedTotal                    = $sum.parkedTotal
        parkedOnReentrantLock          = $sum.parkedOnReentrantLock
        parkedOnResolveName            = $sum.parkedOnResolveName
        parkedResolveNameAnyDepth      = $sum.parkedResolveNameAnyDepth
        avgBlockedPerDump              = & $avg $sum.blockedTotal
        avgBlockedOnResolveNamePerDump = & $avg $sum.blockedOnResolveName
        avgParkedPerDump               = & $avg $sum.parkedOnReentrantLock
        avgParkedOnResolveNamePerDump  = & $avg $sum.parkedOnResolveName
        distinctLocksContended         = $lockAgg.Distinct
        avgDistinctLocksPerDump        = & $avg $sum.distinctLocksContended
        maxDistinctLocksPerDump        = $maxDistinct
        distinctMonitorsContended      = $monitorAgg.Distinct
        dominantLockShare              = $dominantLockShare
        dominantMonitorShare           = $dominantMonitorShare
        topLocks                       = $lockAgg.Top
        topMonitors                    = $monitorAgg.Top
        topBlockSites                  = $topSites
        anyDeadlock                    = ( $deadlockDumps.Count -gt 0 )
        deadlockDumps                  = $deadlockDumps
        deadlockText                   = $deadlockText
    }
}

function Get-ThreadDumpText {
    <#
        `jcmd <pid> Thread.print -l` as one string. -l adds the "Locked ownable synchronizers"
        section, without which a ReentrantLock owner cannot be identified. The parameter is
        $ProcessId with a -Pid alias because $PID is a read-only automatic variable.
        stderr is not redirected: in Windows PowerShell 5.1, 2>&1 on a native command under
        ErrorActionPreference=Stop turns any stderr line into a terminating error.
    #>
    param(
        [Parameter(Mandatory)] [string] $JcmdPath,
        [Parameter(Mandatory)] [Alias('Pid')] [int] $ProcessId
    )
    $out = & $JcmdPath $ProcessId Thread.print -l
    if ( $LASTEXITCODE -ne 0 ) { throw "jcmd Thread.print failed for PID $ProcessId (exit $LASTEXITCODE)." }
    return ( @( $out ) -join "`r`n" )
}
