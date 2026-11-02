[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Frames,

    [string]$Audio,
    [string]$Output,

    [ValidateRange(1, 240)]
    [double]$FrameRate = 23.976,

    [ValidateSet('Auto', 'libx264', 'libopenh264', 'h264_nvenc', 'h264_mf', 'h264_amf', 'mpeg4')]
    [string]$VideoEncoder = 'Auto',

    [string]$FfmpegPath,
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-Ffmpeg {
    if ($FfmpegPath) {
        if (-not (Test-Path -LiteralPath $FfmpegPath -PathType Leaf)) {
            throw "FFmpeg not found: $FfmpegPath"
        }
        return [System.IO.Path]::GetFullPath($FfmpegPath)
    }

    foreach ($candidate in @(
        (Join-Path $PSScriptRoot 'tools\ffmpeg\bin\ffmpeg.exe'),
        (Join-Path $PSScriptRoot 'tools\ffmpeg\ffmpeg.exe'),
        (Join-Path $PSScriptRoot 'tools\ffmpeg.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $command = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    $capCutRoot = Join-Path $env:LOCALAPPDATA 'CapCut\Apps'
    if (Test-Path -LiteralPath $capCutRoot) {
        $candidate = Get-ChildItem -LiteralPath $capCutRoot -Filter ffmpeg.exe -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object { try { [version]$_.Directory.Name } catch { [version]'0.0' } } -Descending |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }

    throw 'FFmpeg was not found in the repair kit, on PATH, or under CapCut. Pass -FfmpegPath explicitly.'
}

function Resolve-Sequence {
    param([Parameter(Mandatory)][string]$InputPath)

    if ($InputPath -match '%(?:0\d+)?d') {
        $directory = Split-Path $InputPath
        if (-not $directory) { $directory = (Get-Location).Path }
        return [pscustomobject]@{
            Pattern     = [System.IO.Path]::GetFullPath($InputPath)
            Directory   = [System.IO.Path]::GetFullPath($directory)
            Prefix      = 'render'
            StartNumber = 0
            Count       = $null
        }
    }

    $resolved = [System.IO.Path]::GetFullPath($InputPath)
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $directory = $resolved
        $files = Get-ChildItem -LiteralPath $directory -File | Where-Object {
            $_.Extension -match '^\.(png|tga|jpg|jpeg|bmp|exr)$' -and
            $_.BaseName -match '^(?<prefix>.*?)(?<number>\d+)$'
        }
        if (-not $files) { throw "No numbered image sequence found in $directory" }

        $groups = @($files | Group-Object {
            [regex]::Match($_.BaseName, '^(?<prefix>.*?)(?<number>\d+)$').Groups['prefix'].Value + '|' + $_.Extension.ToLowerInvariant()
        } | Sort-Object Count -Descending)
        if ($groups.Count -gt 1 -and $groups[0].Count -eq $groups[1].Count) {
            throw 'More than one equally-sized image sequence was found. Pass the first frame path explicitly.'
        }
        $firstFile = $groups[0].Group | Sort-Object Name | Select-Object -First 1
    } elseif (Test-Path -LiteralPath $resolved -PathType Leaf) {
        $firstFile = Get-Item -LiteralPath $resolved
        $directory = $firstFile.DirectoryName
    } else {
        throw "Frames path does not exist and is not an FFmpeg pattern: $InputPath"
    }

    $match = [regex]::Match($firstFile.BaseName, '^(?<prefix>.*?)(?<number>\d+)$')
    if (-not $match.Success) {
        throw "Frame filename must end in a number: $($firstFile.Name)"
    }

    $prefix = $match.Groups['prefix'].Value
    $digits = $match.Groups['number'].Value.Length
    $extension = $firstFile.Extension.ToLowerInvariant()
    $sequenceFiles = Get-ChildItem -LiteralPath $directory -File | Where-Object {
        $_.Extension.ToLowerInvariant() -eq $extension -and
        $_.BaseName -match ('^' + [regex]::Escape($prefix) + '\d{' + $digits + '}$')
    }
    $numbers = @($sequenceFiles | ForEach-Object {
        [int64]([regex]::Match($_.BaseName, '(\d+)$').Groups[1].Value)
    } | Sort-Object)
    if (-not $numbers) { throw 'The image sequence is empty.' }

    $first = $numbers[0]
    $last = $numbers[-1]
    $expectedCount = $last - $first + 1
    if ($expectedCount -ne $numbers.Count) {
        $known = [System.Collections.Generic.HashSet[long]]::new()
        $numbers | ForEach-Object { [void]$known.Add($_) }
        $missing = for ($n = $first; $n -le $last -and $n -lt ($first + 100000); $n++) {
            if (-not $known.Contains($n)) { $n }
        }
        $preview = ($missing | Select-Object -First 20) -join ', '
        throw "Image sequence has missing frames (first missing: $preview)."
    }

    return [pscustomobject]@{
        Pattern     = Join-Path $directory ($prefix + ('%0{0}d' -f $digits) + $extension)
        Directory   = $directory
        Prefix      = if ($prefix) { $prefix.TrimEnd('_', '-', '.') } else { 'render' }
        StartNumber = $first
        Count       = $numbers.Count
    }
}

$ffmpeg = Find-Ffmpeg
$sequence = Resolve-Sequence $Frames

if ($Audio) {
    $audioPath = [System.IO.Path]::GetFullPath($Audio)
    if (-not (Test-Path -LiteralPath $audioPath -PathType Leaf)) {
        throw "Audio file not found: $audioPath"
    }
} else {
    $wavFiles = @(Get-ChildItem -LiteralPath $sequence.Directory -Filter '*.wav' -File)
    if ($wavFiles.Count -eq 1) {
        $audioPath = $wavFiles[0].FullName
    } elseif ($wavFiles.Count -eq 0) {
        $audioPath = $null
    } else {
        throw 'Multiple WAV files found. Pass the intended one with -Audio.'
    }
}

if ($Output) {
    $outputPath = [System.IO.Path]::GetFullPath($Output)
} else {
    $safeName = if ($sequence.Prefix) { $sequence.Prefix } else { 'render' }
    $outputPath = Join-Path $sequence.Directory ($safeName + '.mp4')
}
if ([System.IO.Path]::GetExtension($outputPath) -ine '.mp4') {
    throw 'Output must have an .mp4 extension.'
}
if ((Test-Path -LiteralPath $outputPath) -and -not $Overwrite) {
    throw "Output already exists: $outputPath. Use -Overwrite to replace it."
}

$encoderText = (& $ffmpeg -hide_banner -encoders 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw "Could not query FFmpeg encoders: $ffmpeg" }
$available = @('libx264', 'libopenh264', 'h264_mf', 'h264_nvenc', 'h264_amf', 'mpeg4') | Where-Object {
    $encoderText -match ('(?m)^\s*V\S*\s+' + [regex]::Escape($_) + '\s')
}
if ($VideoEncoder -eq 'Auto') {
    if (-not $available) { throw 'No supported MP4 video encoder is available in this FFmpeg build.' }
    $chosenEncoder = $available[0]
} else {
    if ($available -notcontains $VideoEncoder) {
        throw "Requested encoder '$VideoEncoder' is not available. Available choices: $($available -join ', ')"
    }
    $chosenEncoder = $VideoEncoder
}

$ffmpegArgs = [System.Collections.Generic.List[string]]::new()
@('-hide_banner', '-loglevel', 'warning') | ForEach-Object { $ffmpegArgs.Add($_) }
$ffmpegArgs.Add($(if ($Overwrite) { '-y' } else { '-n' }))
@('-framerate', $FrameRate.ToString([System.Globalization.CultureInfo]::InvariantCulture),
  '-start_number', [string]$sequence.StartNumber, '-i', $sequence.Pattern) |
    ForEach-Object { $ffmpegArgs.Add($_) }
if ($audioPath) {
    @('-i', $audioPath) | ForEach-Object { $ffmpegArgs.Add($_) }
}
@('-map', '0:v:0') | ForEach-Object { $ffmpegArgs.Add($_) }
if ($audioPath) { @('-map', '1:a:0') | ForEach-Object { $ffmpegArgs.Add($_) } }
@('-c:v', $chosenEncoder, '-pix_fmt', 'yuv420p', '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2') |
    ForEach-Object { $ffmpegArgs.Add($_) }

switch ($chosenEncoder) {
    'libx264'    { @('-crf', '18', '-preset', 'slow') | ForEach-Object { $ffmpegArgs.Add($_) } }
    'libopenh264'{ @('-b:v', '20000000') | ForEach-Object { $ffmpegArgs.Add($_) } }
    'h264_nvenc' { @('-cq', '19', '-b:v', '0') | ForEach-Object { $ffmpegArgs.Add($_) } }
    'mpeg4'      { @('-q:v', '2') | ForEach-Object { $ffmpegArgs.Add($_) } }
    default      { @('-b:v', '20000000') | ForEach-Object { $ffmpegArgs.Add($_) } }
}
if ($audioPath) {
    @('-c:a', 'aac', '-b:a', '256k', '-shortest') | ForEach-Object { $ffmpegArgs.Add($_) }
}
@('-movflags', '+faststart', $outputPath) | ForEach-Object { $ffmpegArgs.Add($_) }

Write-Host "FFmpeg: $ffmpeg"
Write-Host "Frames: $($sequence.Pattern)"
if ($sequence.Count) { Write-Host "Frame count: $($sequence.Count)" }
Write-Host "Audio: $(if ($audioPath) { $audioPath } else { '(none)' })"
Write-Host "Encoder: $chosenEncoder"
Write-Host "Output: $outputPath"

& $ffmpeg @ffmpegArgs
if ($LASTEXITCODE -ne 0) {
    throw "FFmpeg failed with exit code $LASTEXITCODE. Try -VideoEncoder h264_mf or mpeg4 if the selected hardware encoder is unavailable at runtime."
}

$result = Get-Item -LiteralPath $outputPath
Write-Host "MP4 created successfully: $($result.FullName) ($([math]::Round($result.Length / 1MB, 2)) MiB)"
