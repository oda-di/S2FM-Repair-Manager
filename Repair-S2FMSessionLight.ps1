[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Session,
    [string]$Cs2Root,
    [string]$LightName = 'dirlight1',
    [ValidateRange(0.0, 100.0)][double]$Intensity = 2.8,
    [ValidateCount(3, 3)][ValidateRange(0, 255)][int[]]$Color = @(248, 212, 171),
    [bool]$CastShadows = $true
)

. (Join-Path $PSScriptRoot 'S2FMPatch.Common.ps1')
if ([string]::IsNullOrWhiteSpace($Cs2Root)) { $Cs2Root = Find-S2FMCs2Root }

function Get-DmxBlocks {
    param([Parameter(Mandatory)][string]$Text, [string]$Type)
    $pattern = [regex]::new('(?ms)^"(?<type>[^"\r\n]+)"\r?\n\{\r?\n.*?^\}\r?\n?')
    $blocks = $pattern.Matches($Text)
    if ($Type) { return @($blocks | Where-Object { $_.Groups['type'].Value -eq $Type }) }
    return @($blocks)
}

function Get-DmxBlockById {
    param([string]$Text, [string]$Type, [string]$Id)
    $matches = @(Get-DmxBlocks $Text $Type | Where-Object {
        $_.Value -match ('(?m)^\s*"id"\s+"elementid"\s+"' + [regex]::Escape($Id) + '"\s*$')
    })
    if ($matches.Count -ne 1) { throw "Expected one $Type block with id '$Id', found $($matches.Count)." }
    return $matches[0]
}

function Get-DmxProperty {
    param([string]$Block, [string]$Name)
    $match = [regex]::Match($Block, ('(?m)^\s*"' + [regex]::Escape($Name) + '"\s+"[^"]+"\s+"(?<value>[^"]*)"\s*$'))
    if (-not $match.Success) { throw "Property '$Name' was not found." }
    return $match.Groups['value'].Value
}

function Set-DmxBlockProperty {
    param([string]$Text, [string]$Type, [string]$Id, [string]$Name, [string]$ValueType, [string]$Value)
    $block = Get-DmxBlockById $Text $Type $Id
    $propertyPattern = '(?m)^(?<indent>\s*)"' + [regex]::Escape($Name) + '"\s+"' +
        [regex]::Escape($ValueType) + '"\s+"[^"]*"\s*$'
    $propertyMatches = [regex]::Matches($block.Value, $propertyPattern)
    if ($propertyMatches.Count -ne 1) {
        throw "Expected one $Type.$Name property on '$Id', found $($propertyMatches.Count)."
    }
    $replacement = '${indent}"' + $Name + '" "' + $ValueType + '" "' + $Value + '"'
    $newBlock = [regex]::Replace($block.Value, $propertyPattern, $replacement)
    return $Text.Remove($block.Index, $block.Length).Insert($block.Index, $newBlock)
}

function Find-DmxChannel {
    param([string]$Text, [string]$ToElement, [string]$ToAttribute)
    # Channels may be top-level DMX elements or embedded inside a channels clip.
    # The graph fields precede the nested log, so match only up to toAttribute
    # and do not cross into the next DmeChannel.
    $pattern = '(?ms)"DmeChannel"\s*\{(?:(?!"DmeChannel").)*?' +
        '"toElement"\s+"element"\s+"' + [regex]::Escape($ToElement) + '"' +
        '(?:(?!"DmeChannel").)*?' +
        '"toAttribute"\s+"string"\s+"' + [regex]::Escape($ToAttribute) + '"'
    $matches = @([regex]::Matches($Text, $pattern))
    if ($matches.Count -ne 1) {
        throw "Expected one channel to $ToElement.$ToAttribute, found $($matches.Count)."
    }
    return $matches[0]
}

$paths = Get-S2FMPaths $Cs2Root
Assert-S2FMClosed $paths.Executable
$sessionPath = [System.IO.Path]::GetFullPath($Session)
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) { throw "Session not found: $sessionPath" }
$dmxConvert = Join-Path $paths.Root 'game\bin\win64\dmxconvert.exe'
if (-not (Test-Path -LiteralPath $dmxConvert -PathType Leaf)) { throw "dmxconvert.exe not found: $dmxConvert" }

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("s2fm-session-light-{0}" -f [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($tempDir) | Out-Null
$patchedPath = $null
try {
    $keyValuesPath = Join-Path $tempDir 'session.keyvalues2.dmx'
    $patchedPath = Join-Path (Split-Path $sessionPath) ('.s2fm-light-{0}.dmx' -f [guid]::NewGuid().ToString('N'))
    & $dmxConvert -i $sessionPath -o $keyValuesPath -oe keyvalues2 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $keyValuesPath -PathType Leaf)) {
        throw 'Failed to decode the SFM session.'
    }

    $text = [System.IO.File]::ReadAllText($keyValuesPath)
    $lightBlocks = @(Get-DmxBlocks $text 'DmeGameDirectionalLight' | Where-Object {
        $_.Value -match ('(?m)^\s*"name"\s+"string"\s+"' + [regex]::Escape($LightName) + '"\s*$')
    })
    if ($lightBlocks.Count -ne 1) {
        throw "Expected one directional light named '$LightName', found $($lightBlocks.Count)."
    }
    $lightId = Get-DmxProperty $lightBlocks[0].Value 'id'

    $intensityChannel = Find-DmxChannel $text $lightId 'intensity'
    $intensityOperatorId = Get-DmxProperty $intensityChannel.Value 'fromElement'
    $operatorBlock = Get-DmxBlockById $text 'DmeExpressionOperator' $intensityOperatorId
    $operatorHigh = [double]::Parse((Get-DmxProperty $operatorBlock.Value 'hi'), [Globalization.CultureInfo]::InvariantCulture)
    if ($operatorHigh -le 0) { throw 'Directional-light intensity operator has an invalid high range.' }
    $normalizedIntensity = $Intensity / $operatorHigh
    $controlChannel = Find-DmxChannel $text $intensityOperatorId 'value'
    $intensityControlId = Get-DmxProperty $controlChannel.Value 'fromElement'

    $colorChannel = Find-DmxChannel $text $lightId 'color'
    $colorOperatorId = Get-DmxProperty $colorChannel.Value 'fromElement'
    $componentNames = @('red', 'green', 'blue')
    $componentControlIds = @{}
    foreach ($component in $componentNames) {
        $componentChannel = Find-DmxChannel $text $colorOperatorId $component
        $componentControlIds[$component] = Get-DmxProperty $componentChannel.Value 'fromElement'
    }

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $intensityText = $Intensity.ToString('0.##########', $culture)
    $normalizedText = $normalizedIntensity.ToString('0.##########', $culture)
    $colorText = "$($Color[0]) $($Color[1]) $($Color[2]) 255"
    $componentValues = @(
        ($Color[0] / 255.0).ToString('0.##########', $culture),
        ($Color[1] / 255.0).ToString('0.##########', $culture),
        ($Color[2] / 255.0).ToString('0.##########', $culture)
    )
    $castShadowsText = if ($CastShadows) { '1' } else { '0' }

    $text = Set-DmxBlockProperty $text 'DmeGameDirectionalLight' $lightId 'intensity' 'float' $intensityText
    $text = Set-DmxBlockProperty $text 'DmeGameDirectionalLight' $lightId 'color' 'color' $colorText
    $text = Set-DmxBlockProperty $text 'DmeGameDirectionalLight' $lightId 'castShadows' 'bool' $castShadowsText
    $text = Set-DmxBlockProperty $text 'DmeExpressionOperator' $intensityOperatorId 'result' 'float' $intensityText
    $text = Set-DmxBlockProperty $text 'DmeExpressionOperator' $intensityOperatorId 'value' 'float' $normalizedText
    $text = Set-DmxBlockProperty $text 'DmElement' $intensityControlId 'value' 'float' $normalizedText
    $text = Set-DmxBlockProperty $text 'DmElement' $intensityControlId 'defaultValue' 'float' $normalizedText
    $text = Set-DmxBlockProperty $text 'DmePackColorOperator' $colorOperatorId 'color' 'color' $colorText
    for ($i = 0; $i -lt 3; $i++) {
        $component = $componentNames[$i]
        $text = Set-DmxBlockProperty $text 'DmePackColorOperator' $colorOperatorId $component 'float' $componentValues[$i]
        $controlId = $componentControlIds[$component]
        $text = Set-DmxBlockProperty $text 'DmElement' $controlId 'value' 'float' $componentValues[$i]
        $text = Set-DmxBlockProperty $text 'DmElement' $controlId 'defaultValue' 'float' $componentValues[$i]
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($keyValuesPath, $text, $utf8NoBom)
    & $dmxConvert -i $keyValuesPath -ie keyvalues2 -o $patchedPath -oe binary 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $patchedPath -PathType Leaf)) {
        throw 'Failed to encode the patched SFM session.'
    }

    $verifyPath = Join-Path $tempDir 'verify.keyvalues2.dmx'
    & $dmxConvert -i $patchedPath -o $verifyPath -oe keyvalues2 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to verify the patched SFM session.' }
    $verifyText = [System.IO.File]::ReadAllText($verifyPath)
    $verifyLight = @(Get-DmxBlocks $verifyText 'DmeGameDirectionalLight' | Where-Object {
        $_.Value -match ('(?m)^\s*"name"\s+"string"\s+"' + [regex]::Escape($LightName) + '"\s*$')
    })
    if ($verifyLight.Count -ne 1 -or
        (Get-DmxProperty $verifyLight[0].Value 'castShadows') -ne $castShadowsText -or
        [math]::Abs(([double]::Parse((Get-DmxProperty $verifyLight[0].Value 'intensity'), $culture)) - $Intensity) -gt 0.0001) {
        throw 'Patched directional light failed verification.'
    }

    $backupDir = Join-Path $paths.StateDir 'session_lights'
    [System.IO.Directory]::CreateDirectory($backupDir) | Out-Null
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $backupPath = Join-Path $backupDir ("{0}.{1}.original.dmx" -f [IO.Path]::GetFileNameWithoutExtension($sessionPath), $stamp)
    if ($PSCmdlet.ShouldProcess($sessionPath, "Set directional light '$LightName' to intensity $intensityText (castShadows=$CastShadows)")) {
        [System.IO.File]::Replace($patchedPath, $sessionPath, $backupPath)
        Write-Host "Session light repaired: $sessionPath"
        Write-Host "Backup: $backupPath"
    }
} finally {
    if ($patchedPath -and (Test-Path -LiteralPath $patchedPath -PathType Leaf)) { [System.IO.File]::Delete($patchedPath) }
    if ([System.IO.Directory]::Exists($tempDir)) { [System.IO.Directory]::Delete($tempDir, $true) }
}
