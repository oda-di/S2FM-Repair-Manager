[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Cs2Root
)

. (Join-Path $PSScriptRoot 'S2FMPatch.Common.ps1')
if ([string]::IsNullOrWhiteSpace($Cs2Root)) { $Cs2Root = Find-S2FMCs2Root }

$paths = Get-S2FMPaths $Cs2Root
if (-not (Test-Path -LiteralPath $paths.Executable -PathType Leaf)) {
    throw "CS2 executable not found: $($paths.Executable)"
}
if (-not (Test-Path -LiteralPath $paths.GameInfo -PathType Leaf)) {
    throw "gameinfo.gi not found: $($paths.GameInfo)"
}
Assert-S2FMClosed $paths.Executable

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$currentText = [System.IO.File]::ReadAllText($paths.GameInfo)
$currentHash = Get-S2FMHash $paths.GameInfo

if (Test-S2FMPatchedGameInfo $currentText) {
    if (-not (Test-Path -LiteralPath $paths.Backup -PathType Leaf) -or
        -not (Test-Path -LiteralPath $paths.Manifest -PathType Leaf)) {
        throw 'SparseShadowTrees is already disabled, but no valid rollback state exists. Restore a stock gameinfo.gi with Steam before installing this patch.'
    }
    $installedManifest = Get-Content -LiteralPath $paths.Manifest -Raw | ConvertFrom-Json
    $backupHash = Get-S2FMHash $paths.Backup
    if ($backupHash -ne $installedManifest.originalSha256 -or
        $currentHash -ne $installedManifest.patchedSha256) {
        throw 'The live patch or its backup does not match the recorded SHA-256 hashes.'
    }
    Write-Host "Lighting patch is already installed. gameinfo.gi SHA-256: $currentHash"
    exit 0
}

$patchedText = ConvertTo-S2FMPatchedGameInfo $currentText

if (-not $PSCmdlet.ShouldProcess($paths.GameInfo, 'Back up and disable SparseShadowTrees for SFM')) {
    exit 0
}

$reuseBackup = $false
if (Test-Path -LiteralPath $paths.StateDir) {
    if (-not (Test-Path -LiteralPath $paths.Backup -PathType Leaf) -or
        -not (Test-Path -LiteralPath $paths.Manifest -PathType Leaf)) {
        throw "Existing patch state is incomplete. Refusing to overwrite it: $($paths.StateDir)"
    }

    $backupHash = Get-S2FMHash $paths.Backup
    $oldManifest = Get-Content -LiteralPath $paths.Manifest -Raw | ConvertFrom-Json
    if (-not $oldManifest.originalSha256 -or $backupHash -ne $oldManifest.originalSha256) {
        throw "Existing backup hash does not match its manifest: $($paths.Backup)"
    }

    if ($currentHash -eq $oldManifest.originalSha256) {
        $reuseBackup = $true
    } else {
        $archive = $paths.StateDir + '.previous.' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        [System.IO.Directory]::Move($paths.StateDir, $archive)
        Write-Host "Archived backup from the previous Steam build: $archive"
    }
}

[System.IO.Directory]::CreateDirectory($paths.StateDir) | Out-Null
if (-not $reuseBackup) {
    [System.IO.File]::Copy($paths.GameInfo, $paths.Backup, $false)
}
[System.IO.File]::WriteAllText($paths.GameInfo, $patchedText, $utf8NoBom)
$patchedHash = Get-S2FMHash $paths.GameInfo

$manifest = [ordered]@{
    schemaVersion   = 1
    installedAtUtc = [DateTime]::UtcNow.ToString('o')
    cs2Root        = $paths.Root
    originalSha256 = $currentHash
    patchedSha256  = $patchedHash
    setting        = 'SceneSystem.SparseShadowTrees'
    originalValue  = 1
    patchedValue   = 0
}
[System.IO.File]::WriteAllText(
    $paths.Manifest,
    ($manifest | ConvertTo-Json -Depth 3),
    $utf8NoBom
)

Write-Host 'S2FM lighting patch installed.'
Write-Host "Original SHA-256: $currentHash"
Write-Host "Patched  SHA-256: $patchedHash"
Write-Host "Backup: $($paths.Backup)"
