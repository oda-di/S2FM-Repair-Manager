[CmdletBinding()]
param(
    [string]$Version = '1.2.2',
    [string]$ValveResourceFormatRoot = (Join-Path $PSScriptRoot 'third_party\ValveResourceFormat'),
    [string]$FfmpegRoot = (Join-Path $PSScriptRoot 'third_party\ffmpeg')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'release'))
$stage = [System.IO.Path]::GetFullPath((Join-Path $releaseRoot "S2FM-Repair-Manager-$Version"))
$zipPath = [System.IO.Path]::GetFullPath((Join-Path $releaseRoot "S2FM-Repair-Manager-$Version-win-x64.zip"))
if (-not $stage.StartsWith($releaseRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe release staging path: $stage"
}
[System.IO.Directory]::CreateDirectory($releaseRoot) | Out-Null
if ([System.IO.Directory]::Exists($stage)) { [System.IO.Directory]::Delete($stage, $true) }
if ([System.IO.File]::Exists($zipPath)) { [System.IO.File]::Delete($zipPath) }
[System.IO.Directory]::CreateDirectory($stage) | Out-Null

$project = Join-Path $PSScriptRoot 'app\S2FMRepairManager\S2FMRepairManager.csproj'
$publish = Join-Path $PSScriptRoot 'app\S2FMRepairManager\bin\Release\publish-win-x64'
& dotnet publish $project -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:Version=$Version -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Manager publish failed.' }
Copy-Item -LiteralPath (Join-Path $publish 'S2FM Repair Manager.exe') -Destination $stage

$rootFiles = @(
    'S2FMPatch.Common.ps1',
    'Initialize-S2FMAddon.ps1',
    'Install-S2FMPatch.ps1',
    'Uninstall-S2FMPatch.ps1',
    'Install-S2FMMapLightFix.ps1',
    'Uninstall-S2FMMapLightFix.ps1',
    'New-S2FMSession.ps1',
    'Start-S2FMPatched.ps1',
    'Clear-S2FMCommunitySearchPath.ps1',
    'Repair-S2FMSessionLight.ps1',
    'Convert-S2FMExportToMp4.ps1',
    'Test-S2FMRelease.ps1',
    'README.md',
    'THIRD_PARTY_NOTICES.txt'
)
foreach ($name in $rootFiles) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $stage $name)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'templates') -Destination $stage -Recurse

$tools = Join-Path $stage 'tools'
[System.IO.Directory]::CreateDirectory($tools) | Out-Null
$helperProjects = @(
    [pscustomobject]@{ Name = 'S2FMEntityPatcher'; Project = 'tools\S2FMEntityPatcher\S2FMEntityPatcher.csproj' },
    [pscustomobject]@{ Name = 'S2FMVpkPatcher'; Project = 'tools\S2FMVpkPatcher\S2FMVpkPatcher.csproj' }
)
foreach ($helper in $helperProjects) {
    $helperProject = Join-Path $PSScriptRoot $helper.Project
    $helperPublish = Join-Path (Split-Path $helperProject) 'bin\Release\publish-win-x64'
    & dotnet publish $helperProject -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=true -p:PublishTrimmed=true -p:TrimMode=link `
        -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
        -o $helperPublish
    if ($LASTEXITCODE -ne 0) { throw "$($helper.Name) publish failed." }
    $helperExe = Join-Path $helperPublish "$($helper.Name).exe"
    if (-not (Test-Path -LiteralPath $helperExe -PathType Leaf)) {
        throw "Published helper executable was not found: $helperExe"
    }
    Copy-Item -LiteralPath $helperExe -Destination (Join-Path $tools "$($helper.Name).exe")
}

$viewer = Join-Path $ValveResourceFormatRoot 'Source2Viewer-CLI.exe'
if (-not (Test-Path -LiteralPath $viewer -PathType Leaf)) { throw "ValveResourceFormat CLI not found: $viewer" }
Copy-Item -LiteralPath $ValveResourceFormatRoot -Destination (Join-Path $tools 'ValveResourceFormat') -Recurse

$ffmpeg = Get-ChildItem -LiteralPath $FfmpegRoot -Filter 'ffmpeg.exe' -File -Recurse | Select-Object -First 1
if (-not $ffmpeg) { throw "FFmpeg not found under: $FfmpegRoot" }
$ffmpegPackageRoot = Split-Path (Split-Path $ffmpeg.FullName)
$ffmpegTarget = Join-Path $tools 'ffmpeg'
$ffmpegBinTarget = Join-Path $ffmpegTarget 'bin'
[System.IO.Directory]::CreateDirectory($ffmpegBinTarget) | Out-Null
Copy-Item -LiteralPath $ffmpeg.FullName -Destination $ffmpegBinTarget
Get-ChildItem -LiteralPath $ffmpeg.DirectoryName -Filter '*.dll' -File |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $ffmpegBinTarget }
$ffmpegLicense = Join-Path $ffmpegPackageRoot 'LICENSE.txt'
if (-not (Test-Path -LiteralPath $ffmpegLicense -PathType Leaf)) { throw "FFmpeg license not found: $ffmpegLicense" }
Copy-Item -LiteralPath $ffmpegLicense -Destination (Join-Path $ffmpegTarget 'LICENSE.txt')

$releaseInfo = @"
S2FM Repair Manager $Version
Windows x64 portable release
Built: $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC
ValveResourceFormat: 20.1
FFmpeg: N-128142-g28fda48e0b-20261028 (LGPL shared)
"@
[System.IO.File]::WriteAllText(
    (Join-Path $stage 'VERSION.txt'),
    $releaseInfo,
    [System.Text.UTF8Encoding]::new($false)
)

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
[System.IO.File]::WriteAllText("$zipPath.sha256", "$zipHash *$([System.IO.Path]::GetFileName($zipPath))`r`n")
Write-Host "Release directory: $stage"
Write-Host "Release archive: $zipPath"
Write-Host "SHA-256: $zipHash"

