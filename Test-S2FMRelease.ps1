[CmdletBinding()]
param([string]$Cs2Root)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$kitRoot = $PSScriptRoot
$errors = [System.Collections.Generic.List[string]]::new()

if (-not [Environment]::Is64BitOperatingSystem) { $errors.Add('Windows x64 is required.') }
if ($PSVersionTable.PSVersion -lt [version]'5.1') { $errors.Add('Windows PowerShell 5.1 or newer is required.') }

$required = @(
    'S2FM Repair Manager.exe',
    'S2FMPatch.Common.ps1',
    'Initialize-S2FMAddon.ps1',
    'Install-S2FMPatch.ps1',
    'Uninstall-S2FMPatch.ps1',
    'Install-S2FMMapLightFix.ps1',
    'Uninstall-S2FMMapLightFix.ps1',
    'Start-S2FMPatched.ps1',
    'Clear-S2FMCommunitySearchPath.ps1',
    'New-S2FMSession.ps1',
    'Convert-S2FMExportToMp4.ps1',
    'templates\blank-session.dmx.b64',
    'tools\S2FMEntityPatcher.exe',
    'tools\S2FMVpkPatcher.exe',
    'tools\ValveResourceFormat\Source2Viewer-CLI.exe',
    'tools\ffmpeg\bin\ffmpeg.exe'
)
foreach ($relativePath in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $kitRoot $relativePath) -PathType Leaf)) {
        $errors.Add("Missing release file: $relativePath")
    }
}

$viewer = Join-Path $kitRoot 'tools\ValveResourceFormat\Source2Viewer-CLI.exe'
if (Test-Path -LiteralPath $viewer -PathType Leaf) {
    $viewerOutput = @(& $viewer --version 2>&1)
    $viewerExitCode = $LASTEXITCODE
    if ($viewerExitCode -ne 0) { $errors.Add('Source2Viewer-CLI.exe failed to start.') }
    else { Write-Host "ValveResourceFormat: $($viewerOutput | Select-Object -First 1)" }
}

$ffmpeg = Join-Path $kitRoot 'tools\ffmpeg\bin\ffmpeg.exe'
if (Test-Path -LiteralPath $ffmpeg -PathType Leaf) {
    $ffmpegOutput = @(& $ffmpeg -hide_banner -version 2>&1)
    $ffmpegExitCode = $LASTEXITCODE
    if ($ffmpegExitCode -ne 0) { $errors.Add('ffmpeg.exe failed to start.') }
    else {
        Write-Host "FFmpeg: $($ffmpegOutput | Select-Object -First 1)"
        $encoders = (& $ffmpeg -hide_banner -encoders 2>&1 | Out-String)
        if ($encoders -notmatch '(?m)^\s*V\S*\s+(libopenh264|h264_mf|h264_nvenc|h264_amf|libx264|mpeg4)\s') {
            $errors.Add('Bundled FFmpeg has no supported MP4 video encoder.')
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($Cs2Root)) {
    $root = [System.IO.Path]::GetFullPath($Cs2Root)
    foreach ($relativePath in @(
        'game\bin\win64\cs2.exe',
        'game\bin\win64\dmxconvert.exe',
        'game\csgo\gameinfo.gi',
        'game\csgo\maps',
        'content\csgo'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath))) {
            $errors.Add("CS2 Workshop Tools file is missing: $relativePath")
        }
    }

    $writeTestDir = Join-Path $root 'game\csgo'
    if (Test-Path -LiteralPath $writeTestDir -PathType Container) {
        $writeTest = Join-Path $writeTestDir ('.s2fm-write-test-' + [guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::WriteAllText($writeTest, 'test')
        } catch {
            $errors.Add("No write access to CS2: $writeTestDir")
        } finally {
            if ([System.IO.File]::Exists($writeTest)) { [System.IO.File]::Delete($writeTest) }
        }
    }
}

if ($errors.Count -gt 0) {
    foreach ($message in $errors) { Write-Error $message }
    exit 1
}
Write-Host 'S2FM Repair Manager release check passed.' -ForegroundColor Green

