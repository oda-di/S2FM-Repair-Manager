[CmdletBinding()]
param([string]$Version = '1.2.2')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'release'))
$stage = [System.IO.Path]::GetFullPath((Join-Path $releaseRoot "S2FM-Repair-Manager-$Version-source"))
$zipPath = [System.IO.Path]::GetFullPath((Join-Path $releaseRoot "S2FM-Repair-Manager-$Version-source.zip"))
if (-not $stage.StartsWith($releaseRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe source staging path: $stage"
}

[System.IO.Directory]::CreateDirectory($releaseRoot) | Out-Null
if ([System.IO.Directory]::Exists($stage)) { [System.IO.Directory]::Delete($stage, $true) }
if ([System.IO.File]::Exists($zipPath)) { [System.IO.File]::Delete($zipPath) }
if ([System.IO.File]::Exists("$zipPath.sha256")) { [System.IO.File]::Delete("$zipPath.sha256") }
[System.IO.Directory]::CreateDirectory($stage) | Out-Null

function Copy-SourceFile {
    param([Parameter(Mandatory)][string]$RelativePath)

    $source = Join-Path $PSScriptRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source file not found: $RelativePath" }
    $destination = Join-Path $stage $RelativePath
    [System.IO.Directory]::CreateDirectory((Split-Path $destination)) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
}

$rootFiles = @(
    '.gitattributes',
    '.gitignore',
    'Build-S2FMRelease.ps1',
    'Build-S2FMSourceArchive.ps1',
    'Clear-S2FMCommunitySearchPath.ps1',
    'Convert-S2FMExportToMp4.ps1',
    'Initialize-S2FMAddon.ps1',
    'Install-S2FMMapLightFix.ps1',
    'Install-S2FMPatch.ps1',
    'New-S2FMSession.ps1',
    'README.md',
    'Repair-S2FMSessionLight.ps1',
    'S2FMPatch.Common.ps1',
    'SOURCE_BUILD.md',
    'Start-S2FMPatched.ps1',
    'TECHNICAL_ANALYSIS.md',
    'THIRD_PARTY_NOTICES.txt',
    'Test-S2FMRelease.ps1',
    'Uninstall-S2FMMapLightFix.ps1',
    'Uninstall-S2FMPatch.ps1'
)
foreach ($relativePath in $rootFiles) { Copy-SourceFile $relativePath }

$sourceTrees = @(
    '.github',
    'app\S2FMRepairManager',
    'templates',
    'tools\S2FMEntityPatcher',
    'tools\S2FMVpkPatcher'
)
foreach ($tree in $sourceTrees) {
    $treeRoot = Join-Path $PSScriptRoot $tree
    Get-ChildItem -LiteralPath $treeRoot -File -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } |
        ForEach-Object {
            $relativePath = [System.IO.Path]::GetRelativePath($PSScriptRoot, $_.FullName)
            Copy-SourceFile $relativePath
        }
}
Copy-SourceFile 'third_party\ValveResourceFormat\README.md'
Copy-SourceFile 'third_party\ffmpeg\README.md'

[System.IO.File]::WriteAllText(
    (Join-Path $stage 'SOURCE_VERSION.txt'),
    "S2FM Repair Manager source $Version`r`nCreated: $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC`r`n",
    [System.Text.UTF8Encoding]::new($false)
)

$forbidden = Get-ChildItem -LiteralPath $stage -File -Recurse | Where-Object {
    $relativePath = [System.IO.Path]::GetRelativePath($stage, $_.FullName)
    $_.Length -ge 100MB -or $_.Extension -in @('.exe', '.dll', '.zip', '.pdb') -or
    $relativePath -match '(^|[\\/])(bin|obj|release|\.git)([\\/]|$)'
}
if ($forbidden) {
    throw "Forbidden generated/binary file entered the source archive: $($forbidden.FullName -join ', ')"
}

$checksumPath = Join-Path $stage 'checksums.sha256'
$checksumLines = Get-ChildItem -LiteralPath $stage -File -Recurse |
    Where-Object { $_.FullName -ne $checksumPath } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = [System.IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/')
        '{0} *{1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
    }
[System.IO.File]::WriteAllLines($checksumPath, $checksumLines, [System.Text.UTF8Encoding]::new($false))

Compress-Archive -LiteralPath $stage -DestinationPath $zipPath -CompressionLevel Optimal
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    "$zipPath.sha256",
    "$zipHash *$([System.IO.Path]::GetFileName($zipPath))`r`n",
    [System.Text.UTF8Encoding]::new($false)
)
Write-Host "Source directory: $stage"
Write-Host "Source archive: $zipPath"
Write-Host "SHA-256: $zipHash"
