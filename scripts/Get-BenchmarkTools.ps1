<#
.SYNOPSIS
    Downloads the load-testing tools the hotfix benchmark needs into ./tools.

.DESCRIPTION
    Reads scripts/tool-versions.json for the pinned version and SHA256 of each tool, then
    downloads the asset matching this machine's OS and CPU and checks its hash. A file whose
    hash does not match is deleted and the script fails.

    The binaries are deliberately not committed to the repository. Pinning version + hash
    here means every benchmark result can be traced back to an exact tool build, which a
    committed binary would not guarantee.

.PARAMETER Force
    Re-download even if the tool is already present and its hash already matches.

.EXAMPLE
    .\scripts\Get-BenchmarkTools.ps1
#>
[CmdletBinding()]
param(
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Parent $PSScriptRoot
$toolsDir     = Join-Path $repoRoot 'tools'
$versionsFile = Join-Path $PSScriptRoot 'tool-versions.json'

if ( -not ( Test-Path $versionsFile ) ) {
    throw "Missing $versionsFile"
}

$config = Get-Content $versionsFile -Raw | ConvertFrom-Json

if ( -not ( Test-Path $toolsDir ) ) {
    New-Item -ItemType Directory -Path $toolsDir | Out-Null
}

<#
.SYNOPSIS
    Returns the "<os>-<arch>" key used in tool-versions.json for the current machine.
#>
function Get-PlatformKey {
    if ( $IsLinux )       { $os = 'linux' }
    elseif ( $IsMacOS )   { $os = 'darwin' }
    else                  { $os = 'windows' }

    # PROCESSOR_ARCHITECTURE is the reliable one on Windows PowerShell 5.1, where the
    # $IsLinux/$IsMacOS automatic variables do not exist at all.
    $machine = if ( $env:PROCESSOR_ARCHITECTURE ) { $env:PROCESSOR_ARCHITECTURE } else { ( uname -m ) }

    switch -Regex ( $machine ) {
        'ARM64|aarch64' { $arch = 'arm64' }
        default         { $arch = 'amd64' }
    }

    return "$os-$arch"
}

$platform = Get-PlatformKey
Write-Host "Platform: $platform" -ForegroundColor Cyan

foreach ( $toolName in $config.PSObject.Properties.Name ) {

    if ( $toolName -like '_*' ) { continue }

    $tool = $config.$toolName

    if ( -not $tool.assets ) {
        Write-Host "SKIP  $toolName - not downloadable. $($tool.note)" -ForegroundColor DarkGray
        continue
    }

    # Tools that ship one artifact for every platform use the "any" key.
    $assetKey = if ( $tool.assets.PSObject.Properties.Name -contains $platform ) { $platform }
                elseif ( $tool.assets.PSObject.Properties.Name -contains 'any' ) { 'any' }
                else { $null }

    if ( -not $assetKey ) {
        $message = "No $toolName asset pinned for platform $platform."
        if ( $tool.required ) { throw $message }
        Write-Host "SKIP  $message" -ForegroundColor Yellow
        continue
    }

    $asset      = $tool.assets.$assetKey
    $targetPath = Join-Path $toolsDir $asset.target

    if ( ( Test-Path $targetPath ) -and -not $Force ) {
        $existingHash = ( Get-FileHash -Path $targetPath -Algorithm SHA256 ).Hash
        if ( $existingHash -ieq $asset.sha256 ) {
            Write-Host "OK    $toolName $($tool.version) already present" -ForegroundColor Green
            continue
        }
        Write-Host "STALE $toolName hash differs from the pin, re-downloading" -ForegroundColor Yellow
    }

    $url = $tool.urlTemplate.Replace( '{version}', $tool.version ).Replace( '{asset}', $asset.asset )
    Write-Host "GET   $toolName $($tool.version) from $url"

    # A partial download must never be left behind looking like a verified tool, so write to
    # a temp file and only move it into place after the hash checks out.
    $tempPath = "$targetPath.download"

    try {
        $previousProgress       = $ProgressPreference
        $ProgressPreference     = 'SilentlyContinue'   # Invoke-WebRequest is far slower with the progress bar on.
        Invoke-WebRequest -Uri $url -OutFile $tempPath -UseBasicParsing
        $ProgressPreference     = $previousProgress

        $actualHash = ( Get-FileHash -Path $tempPath -Algorithm SHA256 ).Hash

        if ( $actualHash -ine $asset.sha256 ) {
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
            throw "SHA256 mismatch for $toolName`n  expected: $($asset.sha256)`n  actual:   $actualHash`nRefusing to install. Either the pin in tool-versions.json is wrong or the download was tampered with."
        }

        Move-Item -Path $tempPath -Destination $targetPath -Force
        Write-Host "OK    $toolName $($tool.version) verified -> $targetPath" -ForegroundColor Green
    }
    catch {
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        if ( $tool.required ) { throw }
        Write-Host "WARN  $toolName failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Tools are in $toolsDir (gitignored)." -ForegroundColor Cyan
