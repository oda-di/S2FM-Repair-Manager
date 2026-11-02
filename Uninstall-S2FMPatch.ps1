[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Cs2Root
)

. (Join-Path $PSScriptRoot 'S2FMPatch.Common.ps1')
if ([string]::IsNullOrWhiteSpace($Cs2Root)) { $Cs2Root = Find-S2FMCs2Root }

$paths = Get-S2FMPaths $Cs2Root
if (-not (Test-Path -LiteralPath $paths.Backup -PathType Leaf) -or
    -not (Test-Path -LiteralPath $paths.Manifest -PathType Leaf)) {
    throw "Patch backup/manifest not found under $($paths.StateDir). Nothing can be restored safely."
}
if (-not (Test-Path -LiteralPath $paths.GameInfo -PathType Leaf)) {
    throw "Live gameinfo.gi not found: $($paths.GameInfo)"
}
Assert-S2FMClosed $paths.Executable

$manifest = Get-Content -LiteralPath $paths.Manifest -Raw | ConvertFrom-Json
$backupHash = Get-S2FMHash $paths.Backup
$liveHash = Get-S2FMHash $paths.GameInfo
if ($backupHash -ne $manifest.originalSha256) {
    throw 'Backup SHA-256 does not match the manifest. Refusing an unsafe restore.'
}
if ($liveHash -ne $manifest.patchedSha256) {
    throw "Live gameinfo.gi changed after installation (current SHA-256: $liveHash). Refusing to overwrite a Steam update or user edit."
}

if (-not $PSCmdlet.ShouldProcess($paths.GameInfo, 'Restore the original gameinfo.gi')) {
    exit 0
}

[System.IO.File]::Copy($paths.Backup, $paths.GameInfo, $true)
$restoredHash = Get-S2FMHash $paths.GameInfo
if ($restoredHash -ne $manifest.originalSha256) {
    throw 'Restore completed but verification failed.'
}

Write-Host 'Original lighting configuration restored.'
Write-Host "Restored SHA-256: $restoredHash"
Write-Host "Backup directory retained for audit: $($paths.StateDir)"
