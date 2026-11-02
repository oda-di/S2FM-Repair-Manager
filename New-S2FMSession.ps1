[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Cs2Root,
    [string]$Addon = 'sfm_repaired',
    [Parameter(Mandatory)][string]$SessionName,
    [Parameter(Mandatory)][string]$Map,
    [string]$Source2ViewerCli,
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'S2FMPatch.Common.ps1')
if ([string]::IsNullOrWhiteSpace($Cs2Root)) { $Cs2Root = Find-S2FMCs2Root }

function Find-Source2ViewerCli {
    param([string]$ExplicitPath)
    $candidates = @(
        $ExplicitPath,
        (Join-Path $PSScriptRoot 'tools\ValveResourceFormat\Source2Viewer-CLI.exe'),
        (Join-Path $PSScriptRoot 'tools\Source2Viewer-CLI.exe'),
        (Get-Command Source2Viewer-CLI.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-SessionMap {
    param([Parameter(Mandatory)][string]$Text)
    $match = [regex]::Match($Text, '(?m)^\s*"mapname"\s+"string"\s+"maps/(?<map>[A-Za-z0-9_]+)\.vmap"\s*$')
    if (-not $match.Success) { throw 'The session does not contain a valid mapname.' }
    return $match.Groups['map'].Value
}

function Write-SessionResult {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $resultFullPath = [System.IO.Path]::GetFullPath($ResultPath)
        [System.IO.Directory]::CreateDirectory((Split-Path $resultFullPath)) | Out-Null
        [System.IO.File]::WriteAllText($resultFullPath, $Path, [System.Text.UTF8Encoding]::new($false))
    }
}

function Get-SpawnCamera {
    param([string]$EntityText)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $blocks = [regex]::Matches($EntityText, '(?ms)^====\d+====\s*\r?\n(?<body>.*?)(?=^====\d+====|\z)')
    foreach ($block in $blocks) {
        $body = $block.Groups['body'].Value
        if ($body -notmatch '(?m)^classname\s+"info_player_[^"]+"\s*$') { continue }
        $origin = [regex]::Match($body, '(?m)^origin\s+\[\s*(?<x>-?[0-9.]+),\s*(?<y>-?[0-9.]+),\s*(?<z>-?[0-9.]+)\s*\]\s*$')
        if (-not $origin.Success) { continue }
        $angles = [regex]::Match($body, '(?m)^angles\s+\[\s*(?<pitch>-?[0-9.]+),\s*(?<yaw>-?[0-9.]+),\s*(?<roll>-?[0-9.]+)\s*\]\s*$')
        $x = [double]::Parse($origin.Groups['x'].Value, $culture)
        $y = [double]::Parse($origin.Groups['y'].Value, $culture)
        $z = [double]::Parse($origin.Groups['z'].Value, $culture) + 64.0
        $yaw = if ($angles.Success) { [double]::Parse($angles.Groups['yaw'].Value, $culture) } else { 0.0 }
        $halfYaw = $yaw * [Math]::PI / 360.0
        return [pscustomobject]@{
            Position = '{0} {1} {2}' -f $x.ToString('0.##########', $culture), $y.ToString('0.##########', $culture), $z.ToString('0.##########', $culture)
            Orientation = '0 0 {0} {1}' -f ([Math]::Sin($halfYaw)).ToString('0.##########', $culture), ([Math]::Cos($halfYaw)).ToString('0.##########', $culture)
        }
    }
    return [pscustomobject]@{ Position = '0 0 128'; Orientation = '0 0 0 1' }
}

$SessionName = [System.IO.Path]::GetFileNameWithoutExtension($SessionName.Trim())
if ($SessionName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') {
    throw 'Session name must contain 1-64 Latin letters, digits, underscores or hyphens.'
}
if ($Map -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe map name: $Map" }
if ($Addon -notmatch '^[A-Za-z0-9_-]+$') { throw "Unsafe addon name: $Addon" }

$paths = Get-S2FMPaths $Cs2Root
Assert-S2FMClosed $paths.Executable
$dmxConvert = Join-Path $paths.Root 'game\bin\win64\dmxconvert.exe'
if (-not (Test-Path -LiteralPath $dmxConvert -PathType Leaf)) { throw "dmxconvert.exe not found: $dmxConvert" }
$mapVpk = Join-Path $paths.Root "game\csgo\maps\$Map.vpk"
$addonMapVpk = Join-Path $paths.Root "game\csgo_addons\$Addon\maps\$Map.vpk"
if (-not (Test-Path -LiteralPath $mapVpk -PathType Leaf) -and
    -not (Test-Path -LiteralPath $addonMapVpk -PathType Leaf)) {
    throw "Map VPK was not found in CS2 or the prepared addon: $Map"
}
$templatePath = Join-Path $PSScriptRoot 'templates\blank-session.dmx.b64'
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Session template not found: $templatePath" }

$sessionsDir = Join-Path $paths.Root "game\csgo_addons\$Addon\elements\sessions"
[System.IO.Directory]::CreateDirectory($sessionsDir) | Out-Null
$sessionPath = Join-Path $sessionsDir "$SessionName.dmx"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("s2fm-session-{0}" -f [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempDir) | Out-Null

try {
    $decodedPath = Join-Path $tempDir 'session.keyvalues2.dmx'
    $readSessionMap = {
        param([string]$Path)
        if (Test-Path -LiteralPath $decodedPath -PathType Leaf) { [System.IO.File]::Delete($decodedPath) }
        & $dmxConvert -i $Path -o $decodedPath -oe keyvalues2 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $decodedPath -PathType Leaf)) {
            throw "Existing session could not be decoded: $Path"
        }
        return Get-SessionMap ([System.IO.File]::ReadAllText($decodedPath))
    }

    if (Test-Path -LiteralPath $sessionPath -PathType Leaf) {
        $existingMap = & $readSessionMap $sessionPath
        Write-Host "Session already exists (map '$existingMap'); opening it without changes: $sessionPath"
        Write-SessionResult $sessionPath
        return
    }

    if (-not $PSCmdlet.ShouldProcess($sessionPath, "Create SFM session for map '$Map'")) { return }

    $templateBinary = Join-Path $tempDir 'template.dmx'
    [System.IO.File]::WriteAllBytes($templateBinary, [Convert]::FromBase64String(([System.IO.File]::ReadAllText($templatePath).Trim())))
    & $dmxConvert -i $templateBinary -o $decodedPath -oe keyvalues2 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $decodedPath -PathType Leaf)) {
        throw 'Failed to decode the bundled blank-session template.'
    }

    $text = [System.IO.File]::ReadAllText($decodedPath)
    $idMap = @{}
    foreach ($match in [regex]::Matches($text, '(?i)\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b')) {
        if (-not $idMap.ContainsKey($match.Value)) { $idMap[$match.Value] = [guid]::NewGuid().ToString() }
    }
    foreach ($oldId in $idMap.Keys) { $text = $text.Replace($oldId, $idMap[$oldId]) }
    $text = $text.Replace('"name" "string" "session16"', '"name" "string" "' + $SessionName + '"')
    $text = $text.Replace('maps/ar_baggage.vmap', "maps/$Map.vmap")

    $camera = [pscustomobject]@{ Position = '0 0 128'; Orientation = '0 0 0 1' }
    $viewer = Find-Source2ViewerCli $Source2ViewerCli
    $compiledEntities = Join-Path $paths.Root "game\csgo_addons\$Addon\maps\$Map\entities\default_ents.vents_c"
    if ($viewer -and (Test-Path -LiteralPath $compiledEntities -PathType Leaf)) {
        $entityTextPath = Join-Path $tempDir 'entities.vents'
        & $viewer -i $compiledEntities -o $entityTextPath -d 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $entityTextPath -PathType Leaf)) {
            $camera = Get-SpawnCamera ([System.IO.File]::ReadAllText($entityTextPath))
        }
    }
    $text = $text.Replace('377.6309509277 -1757.1176757812 167.2098999023', $camera.Position)
    $text = $text.Replace('0.0079704998 -0.0066026752 0.7700504065 0.6378991008', $camera.Orientation)
    $text = [regex]::Replace($text, '(?ms)\r?\n\s*"worldLayerVisibility"\s+"DmElement"\s*\{.*?\r?\n\s*\}\s*(?=\r?\n\})', '')

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($decodedPath, $text, $utf8NoBom)
    $binaryPath = Join-Path $tempDir "$SessionName.dmx"
    & $dmxConvert -i $decodedPath -o $binaryPath -oe binary 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $binaryPath -PathType Leaf)) {
        throw 'Failed to compile the new SFM session.'
    }

    $verifyPath = Join-Path $tempDir 'verify.keyvalues2.dmx'
    & $dmxConvert -i $binaryPath -o $verifyPath -oe keyvalues2 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Get-SessionMap ([System.IO.File]::ReadAllText($verifyPath))) -ine $Map) {
        throw 'New SFM session failed binary round-trip verification.'
    }
    [System.IO.File]::Move($binaryPath, $sessionPath)
    Write-Host "Created SFM session '$SessionName' for map '$Map': $sessionPath"
    Write-Host "Initial camera: $($camera.Position)"
    Write-SessionResult $sessionPath
} finally {
    if ([System.IO.Directory]::Exists($tempDir)) { [System.IO.Directory]::Delete($tempDir, $true) }
}
