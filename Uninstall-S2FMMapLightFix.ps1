[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Cs2Root,
    [string]$Addon = 'sfm_repaired',
    [string[]]$Map = @('de_overpass')
)

. (Join-Path $PSScriptRoot 'S2FMPatch.Common.ps1')
if ([string]::IsNullOrWhiteSpace($Cs2Root)) { $Cs2Root = Find-S2FMCs2Root }

$paths = Get-S2FMPaths $Cs2Root
Assert-S2FMClosed $paths.Executable
$stateDir = Join-Path $paths.StateDir 'map_light_overrides'

function Remove-S2FMEmptyParentDirectories {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$StopAt
    )

    $stopFull = [System.IO.Path]::GetFullPath($StopAt).TrimEnd('\')
    $directory = Split-Path ([System.IO.Path]::GetFullPath($FilePath))
    while ($directory -and
        $directory.StartsWith($stopFull + '\', [StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Directory]::Exists($directory) -and
        [System.IO.Directory]::GetFileSystemEntries($directory).Length -eq 0) {
        [System.IO.Directory]::Delete($directory)
        $directory = Split-Path $directory
    }
}

foreach ($mapName in $Map) {
    if ($mapName -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe map name: $mapName" }
    $manifestPath = Join-Path $stateDir "$Addon.$mapName.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "No map-light manifest found for '$mapName': $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $hasV3Paths = $manifest.PSObject.Properties.Name -contains 'looseCompiledPath'
    $hasLegacyPath = $manifest.PSObject.Properties.Name -contains 'compiledPath'
    $loosePath = if ($hasV3Paths) { $manifest.looseCompiledPath } elseif ($hasLegacyPath) { $manifest.compiledPath } else { $null }
    $looseHash = if ($hasV3Paths) { $manifest.looseCompiledSha256 } elseif ($hasLegacyPath) { $manifest.compiledSha256 } else { $null }
    if ($loosePath -and -not (Test-Path -LiteralPath $loosePath -PathType Leaf)) {
        throw "Tracked override is missing: $loosePath"
    }
    if ($loosePath -and (Get-S2FMHash $loosePath) -ne $looseHash) {
        throw "Tracked override was edited; refusing to remove it: $loosePath"
    }
    if ($manifest.schemaVersion -ge 3) {
        if (-not (Test-Path -LiteralPath $manifest.addonVpkPath -PathType Leaf) -or
            (Get-S2FMHash $manifest.addonVpkPath) -ne $manifest.addonVpkSha256) {
            throw "Tracked addon VPK is missing or was edited: $($manifest.addonVpkPath)"
        }
    }
    $companionVpks = if ($manifest.PSObject.Properties.Name -contains 'companionVpks') {
        @($manifest.companionVpks)
    } else {
        @()
    }
    foreach ($companion in $companionVpks) {
        if (-not (Test-Path -LiteralPath $companion.addonVpkPath -PathType Leaf) -or
            (Get-S2FMHash $companion.addonVpkPath) -ne $companion.addonVpkSha256) {
            throw "Tracked skybox VPK is missing or was edited: $($companion.addonVpkPath)"
        }
    }
    $workshopCachePath = $null
    if ($manifest.PSObject.Properties.Name -contains 'workshopId' -and
        -not [string]::IsNullOrWhiteSpace([string]$manifest.workshopId) -and
        $manifest.PSObject.Properties.Name -contains 'sourceVpk' -and $manifest.sourceVpk) {
        $cacheRoot = Join-Path $paths.StateDir 'workshop_maps'
        $workshopCachePath = [System.IO.Path]::GetFullPath([string]$manifest.sourceVpk)
        $cacheRootFull = [System.IO.Path]::GetFullPath($cacheRoot).TrimEnd('\')
        if (-not $workshopCachePath.StartsWith($cacheRootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete Workshop cache outside the managed cache root: $workshopCachePath"
        }
    }

    if ($PSCmdlet.ShouldProcess($mapName, "Remove S2FM map-light override from addon '$Addon'")) {
        $gameMapsRoot = Join-Path $paths.Root "game\csgo_addons\$Addon\maps"
        if ($loosePath) { [System.IO.File]::Delete($loosePath) }
        if ($manifest.schemaVersion -ge 3) { [System.IO.File]::Delete($manifest.addonVpkPath) }
        foreach ($companion in $companionVpks) {
            [System.IO.File]::Delete($companion.addonVpkPath)
        }
        [System.IO.File]::Delete($manifestPath)
        if ($loosePath) { Remove-S2FMEmptyParentDirectories -FilePath $loosePath -StopAt $gameMapsRoot }
        foreach ($companion in $companionVpks) {
            Remove-S2FMEmptyParentDirectories -FilePath $companion.addonVpkPath -StopAt $gameMapsRoot
        }
        Remove-S2FMCommunityContentMirror -Paths $paths -Map $mapName | Out-Null
        if ($manifest.PSObject.Properties.Name -contains 'workshopId' -and
            -not [string]::IsNullOrWhiteSpace([string]$manifest.workshopId)) {
            Remove-S2FMWorkshopGameMirror -Paths $paths -Map $mapName | Out-Null
            if ($workshopCachePath) {
                $cacheRoot = Join-Path $paths.StateDir 'workshop_maps'
                if ([System.IO.File]::Exists($workshopCachePath)) {
                    [System.IO.File]::Delete($workshopCachePath)
                    Remove-S2FMEmptyParentDirectories -FilePath $workshopCachePath -StopAt $cacheRoot
                }
            }
        }
        Write-Host "Mounted map files removed: $mapName"
    }
}
