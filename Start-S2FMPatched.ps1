[CmdletBinding()]
param(
    [string]$Cs2Root,
    [string]$Addon = 'sfm_repaired',
    [string]$Session,
    [string]$Map,
    [switch]$Wait
)

. (Join-Path $PSScriptRoot 'S2FMPatch.Common.ps1')
if ([string]::IsNullOrWhiteSpace($Cs2Root)) { $Cs2Root = Find-S2FMCs2Root }

function Get-S2FMSessionMapName {
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$DmxConvert
    )

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("s2fm-read-session-{0}" -f [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($tempDir) | Out-Null
    try {
        $textPath = Join-Path $tempDir 'session.keyvalues2.dmx'
        & $DmxConvert -i $SessionPath -o $textPath -oe keyvalues2 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $textPath -PathType Leaf)) {
            throw "Could not decode SFM session: $SessionPath"
        }
        $match = [regex]::Match(
            [System.IO.File]::ReadAllText($textPath),
            '(?m)^\s*"mapname"\s+"string"\s+"maps/(?<map>[A-Za-z0-9_]+)\.vmap"\s*$'
        )
        if (-not $match.Success) { throw "The SFM session does not contain a supported map name: $SessionPath" }
        return $match.Groups['map'].Value
    } finally {
        if ([System.IO.Directory]::Exists($tempDir)) { [System.IO.Directory]::Delete($tempDir, $true) }
    }
}

$paths = Get-S2FMPaths $Cs2Root
if (-not (Test-Path -LiteralPath $paths.Executable -PathType Leaf)) {
    throw "CS2 executable not found: $($paths.Executable)"
}

$gameInfoText = [System.IO.File]::ReadAllText($paths.GameInfo)
if (-not (Test-S2FMPatchedGameInfo $gameInfoText)) {
    throw 'Lighting patch is not installed. Run Install-S2FMPatch.ps1 after closing CS2/SFM.'
}

$launchMap = $Map
if ([string]::IsNullOrWhiteSpace($launchMap) -and $Session) {
    $dmxConvert = Join-Path $paths.Root 'game\bin\win64\dmxconvert.exe'
    if (-not (Test-Path -LiteralPath $dmxConvert -PathType Leaf)) { throw "dmxconvert.exe not found: $dmxConvert" }
    $launchMap = Get-S2FMSessionMapName -SessionPath $Session -DmxConvert $dmxConvert
}
if ($launchMap -and $launchMap -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe map name: $launchMap" }
$communityAddon = $null
$communityMirror = $null
try {
    if ($launchMap) {
        $communityMirror = New-S2FMCommunityContentMirror -Paths $paths -Map $launchMap
    }
    $communityAddon = Set-S2FMCommunitySearchPath -Paths $paths -Map $launchMap
} catch {
    try { Set-S2FMCommunitySearchPath -Paths $paths -Map $null | Out-Null } catch { }
    if ($communityMirror -and $launchMap) {
        try { Remove-S2FMCommunityContentMirror -Paths $paths -Map $launchMap | Out-Null } catch { }
    }
    throw
}

$arguments = [System.Collections.Generic.List[string]]::new()
@('-tools', '-tool', 'sfm', '-addon', $Addon, '-novid', '-insecure', '-condebug',
  '+con_enable', '1', '+sparseshadowtree_enable_rendering', '0') |
    ForEach-Object { $arguments.Add($_) }

if ($communityAddon) {
    Write-Host "Community resources mounted for '$communityAddon' (game + tool roots)."
}

if ($Session) {
    $arguments.Add('-sfm_loadsession')
    # Start-Process joins ArgumentList items into one command line. Quote paths
    # explicitly so a CS2 install directory containing spaces is not truncated.
    $arguments.Add(('"{0}"' -f $Session.Replace('"', '\"')))
}

$cleanupScript = Join-Path $PSScriptRoot 'Clear-S2FMCommunitySearchPath.ps1'
if (-not (Test-Path -LiteralPath $cleanupScript -PathType Leaf)) {
    throw "SFM cleanup helper not found: $cleanupScript"
}
$restoreScript = Join-Path $PSScriptRoot 'Uninstall-S2FMPatch.ps1'
if (-not (Test-Path -LiteralPath $restoreScript -PathType Leaf)) {
    throw "Global patch restore helper not found: $restoreScript"
}

$start = @{
    FilePath         = $paths.Executable
    ArgumentList     = $arguments
    WorkingDirectory = Split-Path $paths.Executable
    PassThru         = $true
}
try {
    $process = Start-Process @start
} catch {
    try { Set-S2FMCommunitySearchPath -Paths $paths -Map $null | Out-Null } catch { }
    if ($communityAddon) {
        try { Remove-S2FMCommunityContentMirror -Paths $paths -Map $communityAddon | Out-Null } catch { }
    }
    try { & $restoreScript -Cs2Root $paths.Root | Out-Null } catch { }
    throw
}
Write-Host "Started patched SFM (PID $($process.Id), addon '$Addon')."
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cleanupCommand = "& '" + $cleanupScript.Replace("'", "''") + "' -Cs2Root '" +
    $paths.Root.Replace("'", "''") + "' -ProcessId " + $process.Id
if ($communityAddon) {
    $cleanupCommand += " -CommunityAddon '" + $communityAddon.Replace("'", "''") + "'"
}
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupCommand))
Start-Process -FilePath $powerShell -ArgumentList @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-EncodedCommand', $encodedCommand
) -WindowStyle Hidden | Out-Null
if ($Wait) {
    $process.WaitForExit()
    exit $process.ExitCode
}
