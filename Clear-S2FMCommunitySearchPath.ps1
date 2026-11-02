[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Cs2Root,
    [Parameter(Mandatory)][int]$ProcessId,
    [string]$CommunityAddon
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S2FMPatch.Common.ps1')

Wait-Process -Id $ProcessId -ErrorAction SilentlyContinue
$paths = Get-S2FMPaths $Cs2Root

# CS2 tools may hand off to another process. Wait for every process belonging to
# this installation so gameinfo.gi is never changed underneath a running client.
while ($true) {
    $stillRunning = @(Get-Process cs2 -ErrorAction SilentlyContinue | Where-Object {
        try { (Get-S2FMFullPath $_.Path) -ieq (Get-S2FMFullPath $paths.Executable) } catch { $false }
    })
    if ($stillRunning.Count -eq 0) { break }
    $stillRunning | Wait-Process -ErrorAction SilentlyContinue
}
if (-not (Test-Path -LiteralPath $paths.Manifest -PathType Leaf)) { exit 0 }

$manifest = Get-Content -LiteralPath $paths.Manifest -Raw | ConvertFrom-Json
$selected = if ($manifest.PSObject.Properties.Name -contains 'communityAddon') { $manifest.communityAddon } else { $null }
if ($selected -or [System.IO.File]::ReadAllText($paths.GameInfo).Contains('S2FM_REPAIR_COMMUNITY_BEGIN')) {
    Set-S2FMCommunitySearchPath -Paths $paths -Map $null | Out-Null
}
foreach ($mapName in @($selected, $CommunityAddon) | Where-Object { $_ } | Sort-Object -Unique) {
    Remove-S2FMCommunityContentMirror -Paths $paths -Map $mapName | Out-Null
}

$restoreScript = Join-Path $PSScriptRoot 'Uninstall-S2FMPatch.ps1'
if (-not (Test-Path -LiteralPath $restoreScript -PathType Leaf)) {
    throw "Global patch restore helper not found: $restoreScript"
}
& $restoreScript -Cs2Root $paths.Root
if (-not $?) { throw 'Failed to restore official-client gameinfo.gi after SFM closed.' }
