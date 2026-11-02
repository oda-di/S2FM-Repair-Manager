[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Cs2Root,
    [string]$Addon = 'sfm_repaired'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S2FMPatch.Common.ps1')

if ($Addon -notmatch '^[A-Za-z0-9_-]+$') { throw "Unsafe addon name: $Addon" }
$paths = Get-S2FMPaths $Cs2Root
if (-not (Test-Path -LiteralPath $paths.Executable -PathType Leaf)) {
    throw "CS2 Workshop Tools executable not found: $($paths.Executable)"
}
Assert-S2FMClosed $paths.Executable

$gameAddon = Join-Path $paths.Root "game\csgo_addons\$Addon"
$contentAddon = Join-Path $paths.Root "content\csgo_addons\$Addon"
$directories = @(
    $gameAddon,
    (Join-Path $gameAddon 'maps'),
    (Join-Path $gameAddon 'elements\sessions'),
    $contentAddon
)
foreach ($directory in $directories) {
    if ($PSCmdlet.ShouldProcess($directory, 'Create S2FM addon directory')) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
}

$addonInfo = Join-Path $gameAddon 'addoninfo.txt'
if (-not (Test-Path -LiteralPath $addonInfo) -and
    $PSCmdlet.ShouldProcess($addonInfo, 'Create addon metadata')) {
    $text = @'
<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->
{
}
'@
    [System.IO.File]::WriteAllText($addonInfo, $text, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "S2FM addon is ready: $Addon"
Write-Host "Game path: $gameAddon"
Write-Host "Content path: $contentAddon"
