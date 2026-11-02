[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Cs2Root,
    [string]$Addon = 'sfm_repaired',
    [string[]]$Map = @('de_overpass'),
    [string]$WorkshopId,
    [string]$Source2ViewerCli,
    [string]$EntityPatcher,
    [string]$VpkPatcher
)

. (Join-Path $PSScriptRoot 'S2FMPatch.Common.ps1')
if ([string]::IsNullOrWhiteSpace($Cs2Root)) { $Cs2Root = Find-S2FMCs2Root }

if ([string]::IsNullOrWhiteSpace($EntityPatcher)) {
    $EntityPatcher = Join-Path $PSScriptRoot 'tools\S2FMEntityPatcher.exe'
}
if ([string]::IsNullOrWhiteSpace($VpkPatcher)) {
    $VpkPatcher = Join-Path $PSScriptRoot 'tools\S2FMVpkPatcher.exe'
}

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
    throw 'Source2Viewer-CLI.exe was not found. Pass its full path with -Source2ViewerCli.'
}

function Get-EntityBlocks {
    param([Parameter(Mandatory)][string]$Text)
    return [regex]::Split($Text, '(?m)(?=^====\d+====\s*$)') | Where-Object { $_ -match '\S' }
}

function New-S2FMPatchedVpk {
    param(
        [Parameter(Mandatory)][string]$SourceVpk,
        [Parameter(Mandatory)][string]$EntityEntry,
        [Parameter(Mandatory)][string]$OutputVpk,
        [Parameter(Mandatory)][string]$WorkingDir,
        [string]$DirectLightMode
    )

    [System.IO.Directory]::CreateDirectory($WorkingDir) | Out-Null
    $rawEntity = Join-Path $WorkingDir 'default_ents.original.vents_c'
    $rawTextPath = Join-Path $WorkingDir 'default_ents.original.vents'
    $patchedEntity = Join-Path $WorkingDir 'default_ents.vents_c'
    $verifyTextPath = Join-Path $WorkingDir 'verify.vents'

    $listOutput = & $viewer -i $SourceVpk --vpk_list -e 'vents_c' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not list entity lumps in $SourceVpk" }
    $foundEntry = $listOutput | ForEach-Object {
        if ($_ -match '^(.+?\.vents_c)\s+CRC:') { $matches[1] }
    } | Where-Object { $_ -ieq $EntityEntry } | Select-Object -First 1
    if (-not $foundEntry) { throw "Entity lump '$EntityEntry' was not found in $SourceVpk" }

    & $viewer -i $SourceVpk -o $rawEntity -f $foundEntry 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $rawEntity -PathType Leaf)) {
        throw "Failed to extract $foundEntry"
    }
    & $viewer -i $rawEntity -o $rawTextPath -d 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $rawTextPath -PathType Leaf)) {
        throw "Could not decompile $foundEntry"
    }

    $rawText = [System.IO.File]::ReadAllText($rawTextPath)
    $has3dSkybox = $rawText -match '(?m)^classname\s+"skybox_reference"\s*$'
    $mode = if ([string]::IsNullOrWhiteSpace($DirectLightMode)) {
        if ($has3dSkybox) { '2' } else { '3' }
    } else {
        $DirectLightMode
    }

    $patchOutput = & $EntityPatcher $rawEntity $patchedEntity $mode 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $patchedEntity -PathType Leaf)) {
        throw "Entity patch failed for '$EntityEntry': $($patchOutput -join [Environment]::NewLine)"
    }
    & $viewer -i $patchedEntity -o $verifyTextPath -d 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $verifyTextPath -PathType Leaf)) {
        throw "Could not decompile patched entity lump '$EntityEntry' for verification"
    }

    $environmentBlocks = @(Get-EntityBlocks ([System.IO.File]::ReadAllText($verifyTextPath)) | Where-Object {
        $_ -match '(?m)^classname\s+"light_environment"\s*$'
    })
    if ($environmentBlocks.Count -eq 0 -or
        ($environmentBlocks | Where-Object { $_ -notmatch ("(?m)^directlight\s+`"$mode`"\s*$") })) {
        throw "Patched override verification failed for '$EntityEntry': not every light_environment uses mode $mode"
    }

    $vpkPatchOutput = & $VpkPatcher $SourceVpk $EntityEntry $patchedEntity $OutputVpk 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputVpk -PathType Leaf)) {
        throw "Map VPK patch failed for '$SourceVpk': $($vpkPatchOutput -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        RawText            = $rawText
        RawEntity          = $rawEntity
        PatchedEntity      = $patchedEntity
        OutputVpk          = $OutputVpk
        EnvironmentCount   = $environmentBlocks.Count
        Has3dSkybox        = $has3dSkybox
        DirectLightMode    = [int]$mode
    }
}

$paths = Get-S2FMPaths $Cs2Root
Assert-S2FMClosed $paths.Executable
$viewer = Find-Source2ViewerCli $Source2ViewerCli
if (-not (Test-Path -LiteralPath $EntityPatcher -PathType Leaf)) {
    throw "Entity patcher not found: $EntityPatcher"
}
$EntityPatcher = [System.IO.Path]::GetFullPath($EntityPatcher)
if (-not (Test-Path -LiteralPath $VpkPatcher -PathType Leaf)) {
    throw "VPK patcher not found: $VpkPatcher"
}
$VpkPatcher = [System.IO.Path]::GetFullPath($VpkPatcher)

$gameAddon = Join-Path $paths.Root "game\csgo_addons\$Addon"
if (-not (Test-Path -LiteralPath $gameAddon -PathType Container)) {
    throw "Addon '$Addon' does not exist: $gameAddon"
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$stateDir = Join-Path $paths.StateDir 'map_light_overrides'
[System.IO.Directory]::CreateDirectory($stateDir) | Out-Null

foreach ($mapName in $Map) {
    if ($mapName -notmatch '^[A-Za-z0-9_]+$') { throw "Unsafe map name: $mapName" }
    $manifestPath = Join-Path $stateDir "$Addon.$mapName.json"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $preflightManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $preflightWorkshopId = if ($preflightManifest.PSObject.Properties.Name -contains 'workshopId') {
            [string]$preflightManifest.workshopId
        } else { '' }
        $requestedWorkshopId = if ([string]::IsNullOrWhiteSpace($WorkshopId)) { '' } else { $WorkshopId }
        if ($preflightWorkshopId -cne $requestedWorkshopId) {
            throw "Installed map source differs for '$mapName'. Remove the existing map-light patch before switching between game and Workshop versions."
        }
    }

    $workshopSourceIndex = $null
    if (-not [string]::IsNullOrWhiteSpace($WorkshopId)) {
        $workshopMirror = Sync-S2FMWorkshopGameMirror -Paths $paths -WorkshopId $WorkshopId -Map $mapName
        $workshopSourceIndex = $workshopMirror.SourceIndexVpk
        $cacheDir = Join-Path $paths.StateDir "workshop_maps\$WorkshopId"
        [System.IO.Directory]::CreateDirectory($cacheDir) | Out-Null
        $vpk = Join-Path $cacheDir "$mapName.vpk"
        $cacheTemp = $vpk + '.s2fm-' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            $mapEntry = "maps/$mapName.vpk"
            $packageList = & $viewer -i $workshopSourceIndex --vpk_list 2>&1
            if ($LASTEXITCODE -ne 0 -or -not ($packageList | Where-Object {
                $_ -match '^(.+?)\s+CRC:' -and $matches[1] -ieq $mapEntry
            } | Select-Object -First 1)) {
                throw "Map VPK '$mapEntry' was not found in Workshop package $WorkshopId."
            }
            & $viewer -i $workshopSourceIndex -o $cacheTemp -f $mapEntry 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $cacheTemp -PathType Leaf)) {
                throw "Failed to extract '$mapEntry' from Workshop package $WorkshopId."
            }
            [System.IO.File]::Copy($cacheTemp, $vpk, $true)
        } finally {
            if ([System.IO.File]::Exists($cacheTemp)) { [System.IO.File]::Delete($cacheTemp) }
        }
    } else {
        $installedFromWorkshop = $false
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $preflightManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $installedFromWorkshop = $preflightManifest.PSObject.Properties.Name -contains 'workshopId' -and
                -not [string]::IsNullOrWhiteSpace([string]$preflightManifest.workshopId)
        }
        if (-not $installedFromWorkshop) {
            Remove-S2FMWorkshopGameMirror -Paths $paths -Map $mapName | Out-Null
        }
        $vpk = Join-Path $paths.Root "game\csgo\maps\$mapName.vpk"
        if (-not (Test-Path -LiteralPath $vpk -PathType Leaf)) { throw "Map VPK not found: $vpk" }
    }
    $communityAddonDir = Join-Path $paths.Root "game\csgo_community_addons\$mapName"
    $communityIndexVpk = Join-Path $communityAddonDir "${mapName}_dir.vpk"
    $hasCommunityResources = Test-Path -LiteralPath $communityIndexVpk -PathType Leaf

    $compiledPath = Join-Path $gameAddon "maps\$mapName\entities\default_ents.vents_c"
    $addonVpkPath = Join-Path $gameAddon "maps\$mapName.vpk"
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $existing = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $hasV3Paths = $existing.PSObject.Properties.Name -contains 'looseCompiledPath'
        $hasLegacyPath = $existing.PSObject.Properties.Name -contains 'compiledPath'
        $trackedLoosePath = if ($hasV3Paths) { $existing.looseCompiledPath } elseif ($hasLegacyPath) { $existing.compiledPath } else { $null }
        $trackedLooseHash = if ($hasV3Paths) { $existing.looseCompiledSha256 } elseif ($hasLegacyPath) { $existing.compiledSha256 } else { $null }
        if ($trackedLoosePath -and
            (-not (Test-Path -LiteralPath $trackedLoosePath -PathType Leaf) -or
             (Get-S2FMHash $trackedLoosePath) -ne $trackedLooseHash)) {
            throw "Installed override is missing or was edited: $compiledPath"
        }
        if ($existing.schemaVersion -ge 3 -and
            (-not (Test-Path -LiteralPath $existing.addonVpkPath -PathType Leaf) -or
             (Get-S2FMHash $existing.addonVpkPath) -ne $existing.addonVpkSha256)) {
            throw "Installed addon VPK is missing or was edited: $($existing.addonVpkPath)"
        }
        $trackedSource = if ($existing.PSObject.Properties.Name -contains 'sourceVpk') { $existing.sourceVpk } else { $vpk }
        if ($existing.PSObject.Properties.Name -contains 'sourceVpkSha256' -and
            (-not (Test-Path -LiteralPath $trackedSource -PathType Leaf) -or
             (Get-S2FMHash $trackedSource) -ne $existing.sourceVpkSha256)) {
            throw "Source map VPK changed after installation. Remove and reinstall the map-light patch: $mapName"
        }
        if ($existing.PSObject.Properties.Name -contains 'currentVpkSha256' -and
            (Get-S2FMHash $vpk) -ne $existing.currentVpkSha256) {
            throw "Current map VPK changed after installation. Remove and reinstall the map-light patch: $mapName"
        }
        if ($existing.PSObject.Properties.Name -contains 'communityIndexVpkSha256' -and
            (-not (Test-Path -LiteralPath $existing.communityIndexVpk -PathType Leaf) -or
             (Get-S2FMHash $existing.communityIndexVpk) -ne $existing.communityIndexVpkSha256)) {
            throw "Community resource package changed after installation. Remove and reinstall the map-light patch: $mapName"
        }
        if ($existing.PSObject.Properties.Name -contains 'workshopSourceIndexSha256' -and
            (-not (Test-Path -LiteralPath $existing.workshopSourceIndex -PathType Leaf) -or
             (Get-S2FMHash $existing.workshopSourceIndex) -ne $existing.workshopSourceIndexSha256)) {
            throw "Workshop package changed after installation. Remove and reinstall the map-light patch: $mapName"
        }
        if ($existing.PSObject.Properties.Name -contains 'companionVpks') {
            foreach ($companion in @($existing.companionVpks)) {
                if ($companion.PSObject.Properties.Name -contains 'sourceContainerVpk') {
                    if (-not (Test-Path -LiteralPath $companion.sourceContainerVpk -PathType Leaf) -or
                        (Get-S2FMHash $companion.sourceContainerVpk) -ne $companion.sourceContainerVpkSha256) {
                        throw "Community package containing the referenced skybox changed: $($companion.sourceContainerVpk)"
                    }
                } elseif (-not (Test-Path -LiteralPath $companion.sourceVpk -PathType Leaf) -or
                    (Get-S2FMHash $companion.sourceVpk) -ne $companion.sourceVpkSha256) {
                    throw "Referenced skybox VPK changed after installation: $($companion.sourceVpk)"
                }
                if (-not (Test-Path -LiteralPath $companion.addonVpkPath -PathType Leaf) -or
                    (Get-S2FMHash $companion.addonVpkPath) -ne $companion.addonVpkSha256) {
                    throw "Installed skybox VPK is missing or was edited: $($companion.addonVpkPath)"
                }
            }
        }
        Write-Host "Map light fix is already installed: $mapName"
        continue
    }
    if (Test-Path -LiteralPath $compiledPath -PathType Leaf) {
        throw "An untracked map override already exists; refusing to overwrite it: $compiledPath"
    }
    if (Test-Path -LiteralPath $addonVpkPath -PathType Leaf) {
        throw "An untracked addon map VPK already exists; refusing to overwrite it: $addonVpkPath"
    }
    if (-not $PSCmdlet.ShouldProcess($mapName, "Install S2FM lighting-compatible map into addon '$Addon'")) { continue }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("s2fm-light-{0}" -f [guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($tempDir) | Out-Null
    $createdCompanionPaths = @()
    try {
        $patchedVpk = Join-Path $tempDir "$mapName.vpk"
        $expectedVpkPath = "maps/$mapName/entities/default_ents.vents_c"
        $mainResult = New-S2FMPatchedVpk -SourceVpk $vpk -EntityEntry $expectedVpkPath `
            -OutputVpk $patchedVpk -WorkingDir (Join-Path $tempDir 'main')

        $skyboxTargets = @(Get-EntityBlocks $mainResult.RawText | Where-Object {
            $_ -match '(?m)^classname\s+"skybox_reference"\s*$'
        } | ForEach-Object {
            $match = [regex]::Match($_, '(?m)^targetmapname\s+"([^"]+)"\s*$')
            if ($match.Success) { $match.Groups[1].Value.Replace('\\', '/') }
        } | Where-Object { $_ } | Sort-Object -Unique)

        $companionResults = @()
        $companionIndex = 0
        foreach ($targetMap in $skyboxTargets) {
            if ($targetMap -notmatch '^maps/[A-Za-z0-9_./-]+\.vmap$' -or $targetMap.Contains('..')) {
                throw "Unsafe skybox target map path: $targetMap"
            }
            $resourceBase = $targetMap.Substring(0, $targetMap.Length - 5)
            $relativeVpk = "$resourceBase.vpk"
            $sourceSkyVpk = Join-Path (Join-Path $paths.Root 'game\csgo') ($relativeVpk.Replace('/', '\'))
            $addonSkyVpk = Join-Path $gameAddon ($relativeVpk.Replace('/', '\'))
            $patchSourceSkyVpk = $sourceSkyVpk
            $sourceContainerVpk = $null
            if (-not (Test-Path -LiteralPath $patchSourceSkyVpk -PathType Leaf)) {
                if (-not $hasCommunityResources) {
                    throw "Referenced skybox VPK was not found: $sourceSkyVpk"
                }
                $containerList = & $viewer -i $communityIndexVpk --vpk_list 2>&1
                if ($LASTEXITCODE -ne 0 -or -not ($containerList | Where-Object {
                    $_ -match '^(.+?)\s+CRC:' -and $matches[1] -ieq $relativeVpk
                } | Select-Object -First 1)) {
                    throw "Referenced skybox VPK '$relativeVpk' was not found in community package: $communityIndexVpk"
                }
                $patchSourceSkyVpk = Join-Path $tempDir ("community-skybox-source-{0}.vpk" -f $companionIndex)
                & $viewer -i $communityIndexVpk -o $patchSourceSkyVpk -f $relativeVpk 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $patchSourceSkyVpk -PathType Leaf)) {
                    throw "Failed to extract '$relativeVpk' from community package: $communityIndexVpk"
                }
                $sourceContainerVpk = $communityIndexVpk
            }
            if (Test-Path -LiteralPath $addonSkyVpk -PathType Leaf) {
                throw "An untracked addon skybox VPK already exists; refusing to overwrite it: $addonSkyVpk"
            }

            $skyPatchedVpk = Join-Path $tempDir ("skybox-{0}.vpk" -f $companionIndex)
            $skyEntityEntry = "$resourceBase/entities/default_ents.vents_c"
            $skyResult = New-S2FMPatchedVpk -SourceVpk $patchSourceSkyVpk -EntityEntry $skyEntityEntry `
                -OutputVpk $skyPatchedVpk -WorkingDir (Join-Path $tempDir ("skybox-{0}" -f $companionIndex)) `
                -DirectLightMode '2'
            $companionResults += [pscustomobject]@{
                TargetMap       = $targetMap
                SourceVpk       = $sourceSkyVpk
                PatchSourceVpk  = $patchSourceSkyVpk
                SourceContainerVpk = $sourceContainerVpk
                SourceEntry     = if ($sourceContainerVpk) { $relativeVpk } else { $null }
                AddonVpkPath    = $addonSkyVpk
                PatchResult     = $skyResult
            }
            $companionIndex++
        }

        [System.IO.Directory]::CreateDirectory((Split-Path $compiledPath)) | Out-Null
        [System.IO.File]::Copy($mainResult.PatchedEntity, $compiledPath, $false)
        foreach ($companion in $companionResults) {
            [System.IO.Directory]::CreateDirectory((Split-Path $companion.AddonVpkPath)) | Out-Null
            [System.IO.File]::Copy($companion.PatchResult.OutputVpk, $companion.AddonVpkPath, $false)
            $createdCompanionPaths += $companion.AddonVpkPath
        }
        [System.IO.File]::Copy($patchedVpk, $addonVpkPath, $false)

        $companionManifest = @($companionResults | ForEach-Object {
            $entry = [ordered]@{
                targetMap            = $_.TargetMap
                addonVpkPath         = $_.AddonVpkPath
                addonVpkSha256       = Get-S2FMHash $_.AddonVpkPath
                environmentCount     = $_.PatchResult.EnvironmentCount
                directLightMode      = $_.PatchResult.DirectLightMode
            }
            if ($_.SourceContainerVpk) {
                $entry.sourceContainerVpk = $_.SourceContainerVpk
                $entry.sourceContainerVpkSha256 = Get-S2FMHash $_.SourceContainerVpk
                $entry.sourceEntry = $_.SourceEntry
                $entry.sourceEntrySha256 = Get-S2FMHash $_.PatchSourceVpk
            } else {
                $entry.sourceVpk = $_.SourceVpk
                $entry.sourceVpkSha256 = Get-S2FMHash $_.SourceVpk
            }
            $entry
        })

        $manifest = [ordered]@{
            schemaVersion      = 8
            installedAtUtc     = [DateTime]::UtcNow.ToString('o')
            addon              = $Addon
            map                = $mapName
            workshopId         = if ([string]::IsNullOrWhiteSpace($WorkshopId)) { $null } else { $WorkshopId }
            workshopSourceIndex = $workshopSourceIndex
            workshopSourceIndexSha256 = if ($workshopSourceIndex) { Get-S2FMHash $workshopSourceIndex } else { $null }
            patchStrategy      = if ($skyboxTargets.Count -gt 0) { 'dynamic-world-and-skybox' } else { 'stationary-entity-override' }
            sourceVpk          = $vpk
            sourceVpkSha256    = Get-S2FMHash $vpk
            currentVpk         = $vpk
            currentVpkSha256   = Get-S2FMHash $vpk
            communityAddon     = if ($hasCommunityResources) { $mapName } else { $null }
            communityIndexVpk  = if ($hasCommunityResources) { $communityIndexVpk } else { $null }
            communityIndexVpkSha256 = if ($hasCommunityResources) { Get-S2FMHash $communityIndexVpk } else { $null }
            sourceEntitySha256 = Get-S2FMHash $mainResult.RawEntity
            looseCompiledPath  = $compiledPath
            looseCompiledSha256 = Get-S2FMHash $compiledPath
            addonVpkPath       = $addonVpkPath
            addonVpkSha256     = Get-S2FMHash $addonVpkPath
            environmentCount   = $mainResult.EnvironmentCount
            has3dSkybox        = $mainResult.Has3dSkybox
            directLightMode    = $mainResult.DirectLightMode
            companionVpks      = $companionManifest
            patcherSha256      = Get-S2FMHash $EntityPatcher
            vpkPatcherSha256   = Get-S2FMHash $VpkPatcher
        }
        [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 3), $utf8NoBom)

        $modeName = if ($mainResult.DirectLightMode -eq 2) { 'dynamic' } else { 'stationary' }
        Write-Host "Map light fix installed: $mapName ($($mainResult.EnvironmentCount) main environment light(s) set to $modeName)."
        if ($companionManifest.Count -gt 0) {
            Write-Host "Patched referenced 3D skybox VPK(s): $($companionManifest.Count)."
        }
        Write-Host "Addon map VPK: $addonVpkPath"
    } catch {
        if ((Test-Path -LiteralPath $compiledPath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            [System.IO.File]::Delete($compiledPath)
        }
        if ((Test-Path -LiteralPath $addonVpkPath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            [System.IO.File]::Delete($addonVpkPath)
        }
        foreach ($companionPath in $createdCompanionPaths) {
            if ((Test-Path -LiteralPath $companionPath -PathType Leaf) -and
                -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                [System.IO.File]::Delete($companionPath)
            }
        }
        throw
    } finally {
        if ([System.IO.Directory]::Exists($tempDir)) { [System.IO.Directory]::Delete($tempDir, $true) }
    }
}
