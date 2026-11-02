Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-S2FMFullPath {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-S2FMHash {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Get-S2FMFullPath $Path
    $stream = [System.IO.File]::Open(
        $fullPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Find-S2FMCs2Root {
    $steamRoots = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($registryPath in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'
    )) {
        try {
            $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            foreach ($property in @('SteamPath', 'InstallPath')) {
                $entry = $item.PSObject.Properties[$property]
                $value = if ($entry) { $entry.Value } else { $null }
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                    [void]$steamRoots.Add(([string]$value).Replace('/', '\'))
                }
            }
        } catch { }
    }
    $programFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $defaultSteam = Join-Path $programFilesX86 'Steam'
        if (Test-Path -LiteralPath $defaultSteam -PathType Container) { [void]$steamRoots.Add($defaultSteam) }
    }

    $libraries = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($steamRoot in $steamRoots) {
        [void]$libraries.Add($steamRoot)
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
        try {
            $text = [System.IO.File]::ReadAllText($vdf)
            foreach ($match in [regex]::Matches($text, '"path"\s+"(?<path>[^"]+)"', 'IgnoreCase')) {
                [void]$libraries.Add($match.Groups['path'].Value.Replace('\\', '\'))
            }
        } catch { }
    }

    foreach ($library in $libraries) {
        $candidate = Join-Path $library 'steamapps\common\Counter-Strike Global Offensive'
        if ((Test-Path -LiteralPath (Join-Path $candidate 'game\bin\win64\cs2.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'game\csgo\gameinfo.gi') -PathType Leaf)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'Counter-Strike 2 Workshop Tools were not found in any Steam library. Install them or pass -Cs2Root explicitly.'
}

function Get-S2FMPaths {
    param([Parameter(Mandatory)][string]$Cs2Root)

    $root = Get-S2FMFullPath $Cs2Root
    return [pscustomobject]@{
        Root       = $root
        GameInfo   = Join-Path $root 'game\csgo\gameinfo.gi'
        Executable = Join-Path $root 'game\bin\win64\cs2.exe'
        StateDir   = Join-Path $root 'game\csgo\s2fm_repair_backup'
        Backup     = Join-Path $root 'game\csgo\s2fm_repair_backup\gameinfo.gi.original'
        Manifest   = Join-Path $root 'game\csgo\s2fm_repair_backup\manifest.json'
        ContentCommunityRoot = Join-Path $root 'content\csgo_community_addons'
        ShaderCommunityRoot  = Join-Path $root 'src\shaders\csgo_community_addons'
    }
}

function Get-S2FMWorkshopRoot {
    param([Parameter(Mandatory)]$Paths)

    $commonRoot = Split-Path $Paths.Root
    if ([System.IO.Path]::GetFileName($commonRoot) -ine 'common') {
        throw "CS2 is not inside a standard Steam steamapps\\common directory: $($Paths.Root)"
    }
    $steamAppsRoot = Split-Path $commonRoot
    return Join-Path $steamAppsRoot 'workshop\content\730'
}

function Get-S2FMWorkshopPackage {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$WorkshopId
    )

    if ($WorkshopId -notmatch '^[0-9]+$') { throw "Unsafe Workshop ID: $WorkshopId" }
    $sourceDir = Join-Path (Get-S2FMWorkshopRoot $Paths) $WorkshopId
    $sourceIndex = Join-Path $sourceDir "${WorkshopId}_dir.vpk"
    if (-not (Test-Path -LiteralPath $sourceIndex -PathType Leaf)) {
        throw "Workshop package is missing or not downloaded: $sourceIndex"
    }
    $sourceVpks = @($sourceIndex) + @(
        Get-ChildItem -LiteralPath $sourceDir -Filter "${WorkshopId}_*.vpk" -File |
            Where-Object { $_.Name -cne "${WorkshopId}_dir.vpk" } |
            Sort-Object Name |
            Select-Object -ExpandProperty FullName
    )
    return [pscustomobject]@{
        Id       = $WorkshopId
        Directory = $sourceDir
        IndexVpk = $sourceIndex
        Vpks     = @($sourceVpks)
    }
}

function Sync-S2FMWorkshopGameMirror {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$WorkshopId,
        [Parameter(Mandatory)][string]$Map
    )

    if ($Map -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe map name: $Map" }
    $package = Get-S2FMWorkshopPackage -Paths $Paths -WorkshopId $WorkshopId
    $targetDir = Join-Path $Paths.Root "game\csgo_community_addons\$Map"
    $markerPath = Join-Path $targetDir '.s2fm_repair_workshop.json'
    $createdDirectory = -not [System.IO.Directory]::Exists($targetDir)

    if ([System.IO.Directory]::Exists($targetDir)) {
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            if ([System.IO.Directory]::GetFileSystemEntries($targetDir).Length -ne 0) {
                throw "Community addon directory is not managed by S2FM Repair Manager: $targetDir"
            }
        } else {
            $oldMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ([string]$oldMarker.map -cne $Map) {
                throw "Workshop mirror marker does not match '$Map': $markerPath"
            }
            foreach ($oldName in @($oldMarker.files)) {
                $leafName = [string]$oldName
                if ([string]::IsNullOrWhiteSpace($leafName) -or
                    [System.IO.Path]::GetFileName($leafName) -cne $leafName) {
                    throw "Unsafe file name in Workshop mirror marker: $leafName"
                }
                $oldPath = Join-Path $targetDir $leafName
                if ([System.IO.File]::Exists($oldPath)) { [System.IO.File]::Delete($oldPath) }
            }
            [System.IO.File]::Delete($markerPath)
        }
    }

    [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null
    $createdFiles = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($sourceVpk in @($package.Vpks)) {
            $sourceName = [System.IO.Path]::GetFileName($sourceVpk)
            $suffix = $sourceName.Substring($WorkshopId.Length)
            $targetName = $Map + $suffix
            $targetPath = Join-Path $targetDir $targetName
            if (Test-Path -LiteralPath $targetPath) {
                throw "Workshop mirror path is already occupied: $targetPath"
            }
            try {
                New-Item -ItemType HardLink -Path $targetPath -Target $sourceVpk -ErrorAction Stop | Out-Null
            } catch {
                if ([System.IO.File]::Exists($targetPath)) { [System.IO.File]::Delete($targetPath) }
                Write-Warning "Hardlinks are unavailable for '$targetDir'; copying $targetName instead."
                [System.IO.File]::Copy($sourceVpk, $targetPath, $false)
            }
            $createdFiles.Add($targetName)
        }

        $marker = [ordered]@{
            schemaVersion    = 1
            map              = $Map
            workshopId       = $WorkshopId
            createdDirectory = $createdDirectory
            files            = @($createdFiles)
        }
        [System.IO.File]::WriteAllText(
            $markerPath,
            ($marker | ConvertTo-Json -Depth 3),
            [System.Text.UTF8Encoding]::new($false)
        )
        return [pscustomobject]@{
            WorkshopId    = $WorkshopId
            SourceIndexVpk = $package.IndexVpk
            MirrorDir     = $targetDir
            MirrorIndexVpk = Join-Path $targetDir "${Map}_dir.vpk"
        }
    } catch {
        foreach ($name in $createdFiles) {
            $createdPath = Join-Path $targetDir $name
            if ([System.IO.File]::Exists($createdPath)) { [System.IO.File]::Delete($createdPath) }
        }
        if ([System.IO.File]::Exists($markerPath)) { [System.IO.File]::Delete($markerPath) }
        if ($createdDirectory -and [System.IO.Directory]::Exists($targetDir) -and
            [System.IO.Directory]::GetFileSystemEntries($targetDir).Length -eq 0) {
            [System.IO.Directory]::Delete($targetDir)
        }
        throw
    }
}

function Remove-S2FMWorkshopGameMirror {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$Map
    )

    if ($Map -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe map name: $Map" }
    $targetDir = Join-Path $Paths.Root "game\csgo_community_addons\$Map"
    $markerPath = Join-Path $targetDir '.s2fm_repair_workshop.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ([string]$marker.map -cne $Map) { throw "Workshop mirror marker does not match '$Map': $markerPath" }
    foreach ($name in @($marker.files)) {
        $leafName = [string]$name
        if ([string]::IsNullOrWhiteSpace($leafName) -or
            [System.IO.Path]::GetFileName($leafName) -cne $leafName) {
            throw "Unsafe file name in Workshop mirror marker: $leafName"
        }
        $path = Join-Path $targetDir $leafName
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
    }
    [System.IO.File]::Delete($markerPath)
    if ([bool]$marker.createdDirectory -and [System.IO.Directory]::Exists($targetDir) -and
        [System.IO.Directory]::GetFileSystemEntries($targetDir).Length -eq 0) {
        [System.IO.Directory]::Delete($targetDir)
    }
    return $true
}

function Remove-S2FMCommunityMirrorAtRoot {
    param(
        [Parameter(Mandatory)][string]$MirrorRoot,
        [Parameter(Mandatory)][string]$Map
    )

    $mirrorDir = Join-Path $MirrorRoot $Map
    $markerPath = Join-Path $mirrorDir '.s2fm_repair_mirror.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }

    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ([string]$marker.map -cne $Map) {
        throw "Community content mirror marker does not match '$Map': $markerPath"
    }

    foreach ($name in @($marker.files)) {
        $leafName = [string]$name
        if ([string]::IsNullOrWhiteSpace($leafName) -or
            [System.IO.Path]::GetFileName($leafName) -cne $leafName) {
            throw "Unsafe file name in community content mirror marker: $leafName"
        }
        $linkPath = Join-Path $mirrorDir $leafName
        if ([System.IO.File]::Exists($linkPath)) { [System.IO.File]::Delete($linkPath) }
    }
    [System.IO.File]::Delete($markerPath)

    $createdDirectory = $false
    if ($marker.PSObject.Properties.Name -contains 'createdDirectory') {
        $createdDirectory = [bool]$marker.createdDirectory
    }
    if ($createdDirectory -and [System.IO.Directory]::Exists($mirrorDir) -and
        [System.IO.Directory]::GetFileSystemEntries($mirrorDir).Length -eq 0) {
        [System.IO.Directory]::Delete($mirrorDir)
    }
    return $true
}

function New-S2FMCommunityMirrorAtRoot {
    param(
        [Parameter(Mandatory)][string]$MirrorRoot,
        [Parameter(Mandatory)][string]$Map,
        [Parameter(Mandatory)][string[]]$SourceVpks
    )

    $mirrorDir = Join-Path $MirrorRoot $Map
    $markerPath = Join-Path $mirrorDir '.s2fm_repair_mirror.json'
    $createdDirectory = -not [System.IO.Directory]::Exists($mirrorDir)
    [System.IO.Directory]::CreateDirectory($mirrorDir) | Out-Null
    $createdLinks = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($sourceVpk in $SourceVpks) {
            $sourceName = [System.IO.Path]::GetFileName($sourceVpk)
            $linkName = if ($sourceName -ceq "${Map}_dir.vpk") { "${Map}.vpk" } else { $sourceName }
            $linkPath = Join-Path $mirrorDir $linkName
            if (Test-Path -LiteralPath $linkPath) {
                throw "Community content mirror path is already occupied: $linkPath"
            }
            try {
                New-Item -ItemType HardLink -Path $linkPath -Target $sourceVpk -ErrorAction Stop | Out-Null
            } catch {
                if ([System.IO.File]::Exists($linkPath)) { [System.IO.File]::Delete($linkPath) }
                Write-Warning "Hardlinks are unavailable for '$mirrorDir'; temporarily copying $linkName instead."
                [System.IO.File]::Copy($sourceVpk, $linkPath, $false)
            }
            $createdLinks.Add($linkName)
        }

        $marker = [ordered]@{
            schemaVersion    = 1
            map              = $Map
            createdDirectory = $createdDirectory
            files            = @($createdLinks)
        }
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText(
            $markerPath,
            ($marker | ConvertTo-Json -Depth 3),
            $utf8NoBom
        )
        return $mirrorDir
    } catch {
        foreach ($linkName in $createdLinks) {
            $linkPath = Join-Path $mirrorDir $linkName
            if ([System.IO.File]::Exists($linkPath)) { [System.IO.File]::Delete($linkPath) }
        }
        if ($createdDirectory -and [System.IO.Directory]::Exists($mirrorDir) -and
            [System.IO.Directory]::GetFileSystemEntries($mirrorDir).Length -eq 0) {
            [System.IO.Directory]::Delete($mirrorDir)
        }
        throw
    }
}

function Remove-S2FMCommunityContentMirror {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$Map
    )

    if ($Map -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe map name: $Map" }
    $removed = $false
    foreach ($mirrorRoot in @($Paths.ContentCommunityRoot, $Paths.ShaderCommunityRoot)) {
        if (Remove-S2FMCommunityMirrorAtRoot -MirrorRoot $mirrorRoot -Map $Map) {
            $removed = $true
        }
    }
    return $removed
}

function New-S2FMCommunityContentMirror {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$Map
    )

    if ($Map -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe map name: $Map" }
    $sourceDir = Join-Path $Paths.Root "game\csgo_community_addons\$Map"
    $sourceIndex = Join-Path $sourceDir "${Map}_dir.vpk"
    if (-not (Test-Path -LiteralPath $sourceIndex -PathType Leaf)) { return $null }

    Remove-S2FMCommunityContentMirror -Paths $Paths -Map $Map | Out-Null
    $sourceVpks = @($sourceIndex) + @(
        Get-ChildItem -LiteralPath $sourceDir -Filter "${Map}_*.vpk" -File |
            Where-Object { $_.Name -cne "${Map}_dir.vpk" } |
            Sort-Object Name |
            Select-Object -ExpandProperty FullName
    )
    $mirrorDirs = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($mirrorRoot in @($Paths.ContentCommunityRoot, $Paths.ShaderCommunityRoot)) {
            $mirrorDir = New-S2FMCommunityMirrorAtRoot `
                -MirrorRoot $mirrorRoot -Map $Map -SourceVpks $sourceVpks
            $mirrorDirs.Add($mirrorDir)
        }
        return @($mirrorDirs)
    } catch {
        Remove-S2FMCommunityContentMirror -Paths $Paths -Map $Map | Out-Null
        throw
    }
}

function Assert-S2FMClosed {
    param([Parameter(Mandatory)][string]$Executable)

    $wanted = Get-S2FMFullPath $Executable
    $running = Get-Process cs2 -ErrorAction SilentlyContinue | Where-Object {
        try { (Get-S2FMFullPath $_.Path) -ieq $wanted } catch { $false }
    }
    if ($running) {
        $ids = ($running.Id | Sort-Object) -join ', '
        throw "Close the current CS2/SFM first (PID: $ids)."
    }
}

function ConvertTo-S2FMPatchedGameInfo {
    param([Parameter(Mandatory)][string]$Text)

    $pattern = '(?m)^(?<indent>\s*)"SparseShadowTrees"\s+"1"(?<tail>\s*(?://.*)?)$'
    $matches = [regex]::Matches($Text, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one enabled SparseShadowTrees setting, found $($matches.Count). The game file is from an unsupported build or is already modified."
    }

    return [regex]::Replace(
        $Text,
        $pattern,
        '${indent}"SparseShadowTrees" "0"${tail}',
        [System.Text.RegularExpressions.RegexOptions]::None,
        [TimeSpan]::FromSeconds(2)
    )
}

function Test-S2FMPatchedGameInfo {
    param([Parameter(Mandatory)][string]$Text)

    return [regex]::Matches($Text, '(?m)^\s*"SparseShadowTrees"\s+"0"').Count -eq 1
}

function Set-S2FMCommunitySearchPath {
    param(
        [Parameter(Mandatory)]$Paths,
        [string]$Map
    )

    if (-not (Test-Path -LiteralPath $Paths.Manifest -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Paths.GameInfo -PathType Leaf)) {
        throw 'The global S2FM patch must be installed before configuring community resources.'
    }

    $manifest = Get-Content -LiteralPath $Paths.Manifest -Raw | ConvertFrom-Json
    $liveHash = Get-S2FMHash $Paths.GameInfo
    if ($liveHash -ne $manifest.patchedSha256) {
        throw "Live gameinfo.gi does not match the tracked S2FM patch (current SHA-256: $liveHash)."
    }

    $text = [System.IO.File]::ReadAllText($Paths.GameInfo)
    $markerPattern = '(?ms)^[ \t]*// S2FM_REPAIR_COMMUNITY_BEGIN[ \t]*\r?\n.*?^[ \t]*// S2FM_REPAIR_COMMUNITY_END[ \t]*\r?\n?'
    $updated = [regex]::Replace($text, $markerPattern, '', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(2))
    $communityAddon = $null

    if (-not [string]::IsNullOrWhiteSpace($Map)) {
        if ($Map -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe map name: $Map" }
        $indexVpk = Join-Path $Paths.Root "game\csgo_community_addons\$Map\${Map}_dir.vpk"
        if (Test-Path -LiteralPath $indexVpk -PathType Leaf) {
            $gamePathPattern = '(?m)^(?<indent>[ \t]*)Game[ \t]+csgo[ \t]*(?<tail>(?://[^\r\n]*)?)\r?$'
            $gamePathMatches = [regex]::Matches($updated, $gamePathPattern)
            if ($gamePathMatches.Count -ne 1) {
                throw "Expected exactly one base 'Game csgo' search path, found $($gamePathMatches.Count)."
            }
            $match = $gamePathMatches[0]
            $indent = $match.Groups['indent'].Value
            $relativeVpk = "csgo_community_addons/$Map/$Map.vpk"
            $block = $indent + "// S2FM_REPAIR_COMMUNITY_BEGIN`r`n" +
                $indent + "Game`t$relativeVpk`r`n" +
                $indent + "// S2FM_REPAIR_COMMUNITY_END`r`n"
            $updated = $updated.Insert($match.Index, $block)
            $communityAddon = $Map
        }
    }

    if ($updated -ceq $text) { return $communityAddon }

    $gameInfoTemp = $Paths.GameInfo + '.s2fm-' + [guid]::NewGuid().ToString('N') + '.tmp'
    $manifestTemp = $Paths.Manifest + '.s2fm-' + [guid]::NewGuid().ToString('N') + '.tmp'
    $gameInfoSwapBackup = $Paths.GameInfo + '.s2fm-' + [guid]::NewGuid().ToString('N') + '.bak'
    $manifestSwapBackup = $Paths.Manifest + '.s2fm-' + [guid]::NewGuid().ToString('N') + '.bak'
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    try {
        [System.IO.File]::WriteAllText($gameInfoTemp, $updated, $utf8NoBom)
        $updatedHash = Get-S2FMHash $gameInfoTemp
        $manifest.schemaVersion = [Math]::Max([int]$manifest.schemaVersion, 2)
        if ($manifest.PSObject.Properties.Name -contains 'communityAddon') {
            $manifest.communityAddon = $communityAddon
        } else {
            $manifest | Add-Member -NotePropertyName communityAddon -NotePropertyValue $communityAddon
        }
        $manifest.patchedSha256 = $updatedHash
        [System.IO.File]::WriteAllText($manifestTemp, ($manifest | ConvertTo-Json -Depth 5), $utf8NoBom)

        [System.IO.File]::Replace($gameInfoTemp, $Paths.GameInfo, $gameInfoSwapBackup)
        try {
            [System.IO.File]::Replace($manifestTemp, $Paths.Manifest, $manifestSwapBackup)
        } catch {
            [System.IO.File]::Copy($gameInfoSwapBackup, $Paths.GameInfo, $true)
            throw
        }
        return $communityAddon
    } finally {
        if ([System.IO.File]::Exists($gameInfoTemp)) { [System.IO.File]::Delete($gameInfoTemp) }
        if ([System.IO.File]::Exists($manifestTemp)) { [System.IO.File]::Delete($manifestTemp) }
        if ([System.IO.File]::Exists($gameInfoSwapBackup)) { [System.IO.File]::Delete($gameInfoSwapBackup) }
        if ([System.IO.File]::Exists($manifestSwapBackup)) { [System.IO.File]::Delete($manifestSwapBackup) }
    }
}
