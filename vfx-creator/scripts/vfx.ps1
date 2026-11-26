[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Init', 'Inventory', 'Learn', 'Find', 'Build', 'BuildBatch', 'Render', 'Compare')]
    [string]$Action,
    [string]$Project,
    [string]$Editor,
    [string]$Version = '6000.6.8f1',
    [string]$Source,
    [string]$Nested,
    [switch]$ExpandNested,
    [string]$Prefab,
    [string]$Title,
    [string]$Brief,
    [string]$Signature,
    [string]$Id,
    [string]$Recipe,
    [string]$Output,
    [string]$ResourceRoot,
    [string]$Work,
    [string]$Reference,
    [string]$Candidate,
    [string]$Limits,
    [switch]$ReferenceStand,
    [switch]$MetadataOnly,
    [switch]$RenderAfterBuild,
    [ValidateRange(32, 2048)][int]$Size = 384,
    [ValidateRange(1, 120)][int]$Fps = 30,
    [ValidateRange(0.05, 20.0)][float]$Duration = 1.2,
    [ValidateRange(0.1, 100.0)][float]$Framing = 3,
    [ValidateRange(-89, 89)][float]$CameraPitch = 0,
    [string]$GraphEvents,
    [ValidateRange(0, 100.0)][float]$Travel = 0,
    [ValidateRange(0, 100.0)][float]$Arc = 0,
    [ValidateRange(1, 2147483647)][int]$Seed = 1729,
    [ValidateRange(1, 180)][int]$TimeoutMinutes = 12,
    [string]$EffectBrief,
    [string]$Manifest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. "$PSScriptRoot/Archive.ps1"

$skill = Split-Path -Parent $PSScriptRoot
$hasSignature = $PSBoundParameters.ContainsKey('Signature')
if ($hasSignature -and $Action -ne 'Find') { throw '-Signature is only supported by Find.' }

$graphSchedule = $null
if ($PSBoundParameters.ContainsKey('GraphEvents')) {
    if ($Action -notin @('Learn', 'Render') -or $MetadataOnly) {
        throw '-GraphEvents requires a Learn or Render capture.'
    }
    $graphSchedule = Get-Content -LiteralPath $GraphEvents -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($graphSchedule -isnot [array] -or !$graphSchedule.Count) {
        throw '-GraphEvents must point to a nonempty JSON array of {frame, name} entries.'
    }
    $lastFrame = [math]::Ceiling([double]([single]($Duration * $Fps)))
    foreach ($event in $graphSchedule) {
        if ($event -isnot [System.Collections.IDictionary] -or
            $event['frame'] -isnot [long] -or $event['frame'] -lt 0 -or $event['frame'] -gt $lastFrame -or
            $event['name'] -isnot [string] -or [string]::IsNullOrWhiteSpace($event['name'])) {
            throw "Each graph event needs an integer frame from 0 to $lastFrame and a nonempty name."
        }
    }
}

function Require-VfxArgument([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Action requires -$Name." }
}

function Full-VfxPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-VfxEffectBrief($Data, $Capture) {
    if ($data -isnot [System.Collections.IDictionary] -or $data['version'] -isnot [long] -or $data['version'] -ne 1) {
        throw 'An effect brief must be a JSON object with version 1.'
    }
    if ($data['id'] -isnot [string] -or $data['id'] -cnotmatch '\A[a-z0-9][a-z0-9-]{0,63}\z') {
        throw 'The effect brief id must contain 1–64 lowercase letters, digits or hyphens.'
    }
    if ($data['mode'] -isnot [string] -or $data['mode'] -cnotin @('oneShot', 'loop', 'trail')) {
        throw 'The effect brief mode must be oneShot, loop or trail.'
    }
    if ($data['description'] -isnot [string] -or [string]::IsNullOrWhiteSpace($data['description'])) {
        throw 'The effect brief needs a description of the expected appearance.'
    }
    $attachment = $data['attachment']
    if ($attachment -isnot [System.Collections.IDictionary] -or
        $attachment['anchor'] -isnot [string] -or [string]::IsNullOrWhiteSpace($attachment['anchor']) -or
        $attachment['orientation'] -isnot [string] -or [string]::IsNullOrWhiteSpace($attachment['orientation'])) {
        throw 'The effect brief needs attachment.anchor and attachment.orientation strings.'
    }
    if ($null -ne $data['capture']) {
        if ($data['capture'] -isnot [System.Collections.IDictionary]) { throw 'Effect brief capture must be an object.' }
        $limits = @{
            size = @(32, 2048); fps = @(1, 120); duration = @(0.05, 20); framing = @(0.1, 100)
            cameraPitch = @(-89, 89); travel = @(0, 100); arc = @(0, 100); seed = @(1, 2147483647)
        }
        foreach ($key in $data['capture'].Keys) {
            if ($key -cnotin $limits.Keys) { throw "Unknown effect brief capture setting '$key'." }
            $value = $data['capture'][$key]
            $min, $max = $limits[$key]
            $integer = $key -in @('size', 'fps', 'seed')
            $number = $value -is [long] -or (!$integer -and $value -is [double] -and [double]::IsFinite($value))
            if (!$number -or $value -lt $min -or $value -gt $max) {
                throw "Effect brief capture.$key must be a number from $min to $max$(if ($integer) { ' and must be an integer' })."
            }
            $Capture[$key] = $value
        }
    }
    if ($data['mode'] -eq 'trail' -and [single]$Capture.travel -eq 0 -and [single]$Capture.arc -eq 0) {
        throw 'A trail effect brief needs nonzero capture.travel or capture.arc.'
    }
}

function Find-VfxEditor([string]$Release) {
    if ($Editor) { return (Get-Item -LiteralPath (Full-VfxPath $Editor)).FullName }
    $roots = if ($IsWindows) {
        @("$env:ProgramFiles/Unity/Hub/Editor", "$env:ProgramFiles/Unity Hub/Editor")
    } elseif ($IsMacOS) {
        @('/Applications/Unity/Hub/Editor')
    } else {
        @("$env:HOME/Unity/Hub/Editor", '/opt/unity/Hub/Editor')
    }
    $suffix = if ($IsWindows) { 'Editor/Unity.exe' } elseif ($IsMacOS) { 'Unity.app/Contents/MacOS/Unity' } else { 'Editor/Unity' }
    foreach ($root in $roots) {
        $path = Join-Path $root "$Release/$suffix"
        if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Item -LiteralPath $path).FullName }
    }
    throw "Unity $Release was not found. Pass the executable via -Editor."
}

function Get-VfxProject([string]$Path) {
    if (!$Path) {
        $directory = Get-Item -LiteralPath (Get-Location).Path
        while ($directory -and !(Test-Path -LiteralPath (Join-Path $directory.FullName 'ProjectSettings/ProjectVersion.txt'))) {
            $directory = $directory.Parent
        }
        if (!$directory) { throw 'Run from a Unity project or pass -Project.' }
        $Path = $directory.FullName
    }
    $fullPath = (Get-Item -LiteralPath (Full-VfxPath $Path)).FullName
    $versionFile = Join-Path $fullPath 'ProjectSettings/ProjectVersion.txt'
    $manifest = Join-Path $fullPath 'Packages/manifest.json'
    $match = [regex]::Match((Get-Content -LiteralPath $versionFile -Raw), '(?m)^m_EditorVersion:\s*(\S+)')
    if (!$match.Success -or !(Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "'$fullPath' is not a Unity project."
    }
    return @{ path = $fullPath; editor = (Find-VfxEditor $match.Groups[1].Value); release = $match.Groups[1].Value }
}

function New-VfxDirectory([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path)
    return $Path
}

function Initialize-VfxProject {
    Require-VfxArgument 'Project' $Project
    $projectPath = Full-VfxPath $Project
    if ((Test-Path -LiteralPath $projectPath) -and @(Get-ChildItem -LiteralPath $projectPath -Force).Count) {
        throw "Init requires an empty directory: '$projectPath'."
    }
    $unityPath = Find-VfxEditor $Version
    $binaryDirectory = Split-Path -Parent $unityPath
    $data = if ($IsMacOS) { Join-Path (Split-Path -Parent $binaryDirectory) 'Resources' } else { Join-Path $binaryDirectory 'Data/Resources' }
    $templatePath = Join-Path $data 'PackageManager/ProjectTemplates'
    $template = Get-ChildItem -LiteralPath $templatePath -File |
        Where-Object Name -Match '^com\.unity\.template\.(urp-blank|3d-cross-platform)-.*\.tgz$' |
        Sort-Object Name -Descending | Select-Object -First 1
    if (!$template) { throw "Unity's URP template is missing in '$templatePath'. Create a Universal 3D project in Unity Hub and pass its path." }
    [void](New-VfxDirectory $projectPath)
    & tar -xf $template.FullName -C $projectPath --strip-components 2 'package/ProjectData~/Assets' 'package/ProjectData~/Packages' 'package/ProjectData~/ProjectSettings'
    if (!(Test-Path -LiteralPath (Join-Path $projectPath 'Packages/manifest.json') -PathType Leaf)) {
        throw "Could not extract the Universal 3D template from '$($template.FullName)'."
    }
    Set-Content -LiteralPath (Join-Path $projectPath 'ProjectSettings/ProjectVersion.txt') -Value "m_EditorVersion: $Version"
    $manifestPath = Join-Path $projectPath 'Packages/manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    $urpVersion = $manifest.dependencies['com.unity.render-pipelines.universal']
    if (!$urpVersion) { throw 'The template did not specify an URP package version.' }
    $manifest.dependencies['com.unity.modules.particlesystem'] = '1.0.0'
    if ($ReferenceStand) {
        $manifest.dependencies['com.unity.visualeffectgraph'] = $urpVersion
        Set-Content -LiteralPath (Join-Path $projectPath '.vfx-reference') -Value $Version
    }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath
    [pscustomobject]@{ project = $projectPath; version = $Version; referenceStand = [bool]$ReferenceStand }
}

function Get-VfxTokens([string]$Value) {
    return @([regex]::Matches($Value.ToLowerInvariant(), '[\p{L}\p{Nd}]{2,}') | ForEach-Object Value | Sort-Object -Unique)
}

function Find-VfxRecipe {
    Require-VfxArgument 'Brief' $Brief
    $query = Get-VfxTokens $Brief
    $requested = if ($hasSignature) { Read-VfxSignature $Signature }
    $profiles = if ($requested) {
        Get-Content -LiteralPath (Join-Path $skill 'catalog-signatures.json') -Raw | ConvertFrom-Json -AsHashtable
    }
    $ranked = Get-ChildItem -LiteralPath (Join-Path $skill 'catalog') -Filter '*.json' -File | ForEach-Object {
        $file = $_
        $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $keyTokens = Get-VfxTokens ("$($data.title) " + ($data.tags -join ' '))
        $otherTokens = Get-VfxTokens $data.description
        $score = 0
        foreach ($word in $query) {
            if ($word -in $keyTokens) { $score += 3 }
            elseif ($word -in $otherTokens) { $score++ }
        }
        $result = [pscustomobject]@{ score = $score; id = $data.id; title = $data.title; path = $file.FullName }
        if ($requested) {
            $profile = $profiles[$data.id] ?? @{}
            $same = $different = 0
            foreach ($field in @('mode', 'silhouette', 'motion')) {
                if (!$requested.Contains($field) -or !$profile.Contains($field)) { continue }
                if ($requested[$field] -eq $profile[$field]) { $same++ } else { $different++ }
            }
            $beatDistance = Get-VfxSignatureDistance $requested $profile 'beatCount'
            $durationDistance = Get-VfxSignatureDistance $requested $profile 'visibleDurationSec'
            if ($score -or $same -or [double]::IsFinite($beatDistance) -or [double]::IsFinite($durationDistance)) {
                [pscustomobject]@{
                    result = $result; matches = $same; conflicts = $different
                    beatDistance = $beatDistance; durationDistance = $durationDistance
                }
            }
        } elseif ($score) { $result }
    }
    if ($requested) {
        $ranked | Sort-Object @{ Expression = 'matches'; Descending = $true }, conflicts, beatDistance, durationDistance,
            @{ Expression = { $_.result.score }; Descending = $true }, @{ Expression = { $_.result.id } } |
            ForEach-Object result
    } else {
        $ranked | Sort-Object @{ Expression = 'score'; Descending = $true }, id
    }
}

function Read-VfxSignature([string]$Json) {
    if ([string]::IsNullOrWhiteSpace($Json)) { throw '-Signature needs a nonempty JSON object.' }
    $data = ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate
    if ($data -isnot [System.Collections.IDictionary] -or !$data.Count) {
        throw '-Signature needs a nonempty JSON object.'
    }
    $choices = @{
        mode = 'oneShot', 'loop', 'trail'
        silhouette = 'star', 'ring', 'vortex', 'cloud', 'crescent', 'specks', 'angular', 'orb', 'beam', 'column', 'text', 'ribbon', 'figurative'
        motion = 'hold', 'travel', 'expand', 'contract', 'rotate', 'drift', 'sweep', 'rise', 'fall'
    }
    foreach ($field in $data.Keys) {
        $value = $data[$field]
        if ($choices.Keys -ccontains $field) {
            if ($value -isnot [string] -or $value -notin $choices[$field]) {
                throw "Invalid -Signature $field. Expected one of: $($choices[$field] -join ', ')."
            }
        } elseif ($field -ceq 'beatCount') {
            if ($value -isnot [long] -or $value -lt 1) { throw '-Signature beatCount must be a positive integer.' }
        } elseif ($field -ceq 'visibleDurationSec') {
            if (($value -isnot [long] -and $value -isnot [double]) -or $value -le 0 -or ![double]::IsFinite($value)) {
                throw '-Signature visibleDurationSec must be a positive, finite number.'
            }
        } else {
            throw "Unknown -Signature field '$field'."
        }
    }
    return $data
}

function Get-VfxSignatureDistance($Query, $Profile, [string]$Field) {
    if (!$Query.Contains($Field) -or !$Profile.Contains($Field)) { return [double]::PositiveInfinity }
    return [Math]::Abs([double]$Query[$Field] - [double]$Profile[$Field])
}

function Set-VfxDefaults($Data, $Defaults) {
    foreach ($key in $Defaults.Keys) {
        if (!$Data.Contains($key)) { $Data[$key] = $Defaults[$key] }
    }
}

function ConvertTo-VfxBuildRecipe([string]$InputPath, [string]$Destination) {
    $data = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -AsHashtable
    if ($data.version -ne 1 -or !$data.id -or !$data.layers) {
        throw 'A recipe needs version 1, an id and at least one layer.'
    }
    $one = @{ x = 1; y = 1; z = 1 }
    $white = @{ r = 1; g = 1; b = 1; a = 1 }
    $zero = @{ max = 0 }
    $ramp = @{ mode = 'curve'; multiplier = 1; keys = @(@{ time = 0; value = 1 }, @{ time = 1; value = 0 }) }
    Set-VfxDefaults $data @{ seed = 1729; duration = 1 }
    foreach ($layer in $data.layers) {
        if (!$layer.Contains('enabledModules')) {
            $layer.enabledModules = @('shape', 'colorOverLife', 'sizeOverLife', 'rotation3D', 'spinOverLife', 'spinOverLife3D', 'velocityX', 'velocityY', 'velocityZ', 'trail' |
                Where-Object { $layer.Contains($_) -and $null -ne $layer[$_] })
        }
        Set-VfxDefaults $layer @{
            phase = 'body'; kind = 'particles'; scale = $one; duration = $data.duration; playOnAwake = $true; maxParticles = 512
            delay = $zero; lifetime = @{ max = 0.35 }; speed = $zero; size = @{ max = 0.25 }; rotation = $zero
            gravity = $zero; rate = $zero; distanceRate = $zero; render = 'Billboard'; alignment = 'View'; lengthScale = 1
            tint = $white; startColor = @{ max = $white }; glow = 1; blend = 'add'; noiseFrequency = 0.7; texture = @{}
        }
        if ($null -ne $layer.texture) {
            Set-VfxDefaults $layer.texture @{ animateFrameCurve = $layer.texture.Contains('frameOverLife') }
            Set-VfxDefaults $layer.texture @{ kind = 'glow'; resolution = 128; tilesX = 1; tilesY = 1; falloff = 2; detail = 0.4; spokes = 6 }
        }
        if ($null -ne $layer['shape']) {
            Set-VfxDefaults $layer.shape @{ type = 'Sphere'; radius = 0.12; thickness = 1; angle = 20; arc = 360; length = 1; scale = $one }
        }
        if ($null -ne $layer['trail']) {
            Set-VfxDefaults $layer.trail @{ time = 0.22; minDistance = 0.04; ratio = 1; dieWithParticles = $true; inheritParticleColor = $true; ribbons = 1; corners = 4; caps = 3; width = $ramp }
        }
        foreach ($burst in $layer['bursts']) {
            Set-VfxDefaults $burst @{ count = @{ max = 1 }; cycles = 1; interval = 0.01; probability = 1 }
        }
        foreach ($link in $layer['subEmitters']) { Set-VfxDefaults $link @{ chance = 1 } }
    }
    $data | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Destination
}

function Get-VfxWork([string]$Root) {
    $location = if ($Work) { Full-VfxPath $Work } else { Join-Path $Root '.vfx-work' }
    return New-VfxDirectory $location
}

function Remove-VfxUnityBridge([string]$ProjectPath, [string]$Location) {
    $bridge = Get-VfxSafePath $ProjectPath $Location
    if (Test-Path -LiteralPath $bridge -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $bridge -File) {
            Remove-Item -LiteralPath $file.FullName
        }
        if (!(Get-ChildItem -LiteralPath $bridge -Force)) { [IO.Directory]::Delete($bridge) }
    }
    if (Test-Path -LiteralPath "$bridge.meta") { Remove-Item -LiteralPath "$bridge.meta" }
}

function Invoke-VfxUnity($Unity, $Request, [string]$Run) {
    $requestPath = Join-Path $Run 'request.json'
    $responsePath = Join-Path $Run 'response.json'
    $logPath = Join-Path $Run 'unity.log'
    $Request.response = $responsePath
    $Request | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $requestPath
    $bridgeLocation = "Assets/Editor/VfxCreatorBridge_$([guid]::NewGuid().ToString('N'))"
    $bridge = Get-VfxSafePath $Unity.path $bridgeLocation
    $lockPath = Join-Path (New-VfxDirectory (Join-Path $Unity.path '.vfx-work')) 'unity-bridge.lock'
    try {
        $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [IO.IOException] {
        throw "Could not acquire the Unity bridge lock '$lockPath'. Finish the active run before retrying."
    }
    $bridgeRecorded = $false
    try {
        $reader = [IO.StreamReader]::new($lock, [Text.Encoding]::UTF8, $false, 1024, $true)
        try { $previous = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($previous -cmatch '\AAssets/Editor/VfxCreatorBridge_[0-9a-f]{32}\z') {
            Remove-VfxUnityBridge $Unity.path $previous
        }
        $lock.SetLength(0)
        $lock.Position = 0
        $owner = [Text.Encoding]::UTF8.GetBytes($bridgeLocation)
        $lock.Write($owner, 0, $owner.Length)
        $lock.Flush()
        $bridgeRecorded = $true
        [void](New-VfxDirectory $bridge)
        $bridgeFiles = @(Get-ChildItem -LiteralPath (Join-Path $skill 'unity/Editor') -Filter '*.cs' -File)
        foreach ($file in $bridgeFiles) { Copy-Item -LiteralPath $file.FullName -Destination $bridge }
        $info = [Diagnostics.ProcessStartInfo]::new($Unity.editor)
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        foreach ($argument in @('-batchmode', '-projectPath', $Unity.path, '-executeMethod', 'VfxCreator.Editor.Pipeline.Execute', '-vfxRequest', $requestPath, '-logFile', $logPath)) {
            $info.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($info)
        try {
            if (!$process.WaitForExit($TimeoutMinutes * 60000)) {
                throw "Unity timed out. See '$logPath'."
            }
            $exitCode = $process.ExitCode
        } finally {
            if (!$process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $process.Dispose()
        }
        if (!(Test-Path -LiteralPath $responsePath -PathType Leaf)) {
            throw "Unity exited with code $exitCode before responding. See '$logPath'."
        }
        $result = Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json -AsHashtable
        if ($exitCode -or !$result.ok) { throw "Unity failed: $($result.error) See '$logPath'." }
        return [pscustomobject]$result
    } finally {
        try {
            if ($bridgeRecorded) {
                Remove-VfxUnityBridge $Unity.path $bridgeLocation
                $lock.SetLength(0)
                if ($Request.action -eq 'buildbatch') {
                    # A killed editor cannot dispose the staging folder for the item it was building.
                    foreach ($item in $Request.items) {
                        $staging = Get-VfxSafePath $Unity.path "Assets/VfxCreatorGenerated/staging-$($item.stagingToken)"
                        if (Test-Path -LiteralPath $staging -PathType Container) { Remove-Item -LiteralPath $staging -Recurse -Force }
                        if (Test-Path -LiteralPath "$staging.meta" -PathType Leaf) { Remove-Item -LiteralPath "$staging.meta" }
                    }
                }
            }
        } finally {
            $lock.Dispose()
        }
    }
}

$effectSpec = $null
$captureSettings = @{ size = $Size; fps = $Fps; duration = $Duration; framing = $Framing; cameraPitch = $CameraPitch; travel = $Travel; arc = $Arc; seed = $Seed }
if ($PSBoundParameters.ContainsKey('Manifest') -and $Action -ne 'BuildBatch') { throw '-Manifest requires BuildBatch.' }
if ($PSBoundParameters.ContainsKey('EffectBrief')) {
    if ($Action -ne 'Build') { throw '-EffectBrief requires Build.' }
    foreach ($name in @('Id') + @($captureSettings.Keys)) {
        if ($PSBoundParameters.ContainsKey($name)) { throw "-$name belongs in the effect brief when using -EffectBrief." }
    }
    $effectSpec = Get-Content -LiteralPath (Full-VfxPath $EffectBrief) -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    Test-VfxEffectBrief $effectSpec $captureSettings
    $Id = $effectSpec.id
}

if ($Action -eq 'Init') { Initialize-VfxProject; return }
if ($Action -eq 'Find') { Find-VfxRecipe; return }

if ($Action -eq 'BuildBatch') {
    Require-VfxArgument 'Manifest' $Manifest
    Require-VfxArgument 'Output' $Output
    foreach ($name in @('Id', 'Recipe', 'ResourceRoot', 'RenderAfterBuild') + @($captureSettings.Keys)) {
        if ($PSBoundParameters.ContainsKey($name)) { throw "-$name belongs in the manifest or effect brief for BuildBatch." }
    }
    if (!$PSBoundParameters.ContainsKey('TimeoutMinutes')) { $TimeoutMinutes = 60 }
    . "$PSScriptRoot/Batch.ps1"
    Invoke-VfxBuildBatch (Get-VfxProject $Project) (Full-VfxPath $Manifest) (Full-VfxPath $Output) $captureSettings
    return
}

if ($Action -eq 'Inventory') {
    Require-VfxArgument 'Source' $Source
    $item = Get-Item -LiteralPath (Full-VfxPath $Source)
    if ($item.PSIsContainer) {
        $assets = Join-Path $item.FullName 'Assets'
        if (Test-Path -LiteralPath $assets -PathType Container) {
            Get-ChildItem -LiteralPath $assets -Recurse -File -Filter '*.prefab' | Sort-Object FullName | ForEach-Object {
                [pscustomobject]@{ package = $item.FullName; path = [IO.Path]::GetRelativePath($item.FullName, $_.FullName).Replace('\', '/') }
            }
            return
        }
        $archives = @(Get-ChildItem -LiteralPath $item.FullName -File -Filter '*.unitypackage')
    } else { $archives = @($item) }
    foreach ($archive in $archives) {
        $path = if ($ExpandNested) { Resolve-VfxArchive $archive.FullName (Get-VfxWork (Get-Location).Path) $Nested } else { $archive.FullName }
        $index = Get-VfxArchiveIndex $path
        $index.Values | Where-Object path -match '\.(prefab|vfx|unitypackage)$' | Sort-Object path | ForEach-Object {
            [pscustomobject]@{ package = $archive.FullName; path = $_.path }
        }
    }
    return
}

$unity = Get-VfxProject $Project
$workRoot = Get-VfxWork $unity.path
$run = New-VfxDirectory (Join-Path $workRoot ("$($Action.ToLowerInvariant())-" + [guid]::NewGuid().ToString('N').Substring(0, 12)))
$request = @{
    action = $Action.ToLowerInvariant()
    output = if ($Output) { Full-VfxPath $Output } else { Join-Path $run 'output' }
    prefab = $Prefab
    id = $Id
    capture = $captureSettings
    graphEvents = $graphSchedule
}
if ($effectSpec) {
    if ((Test-Path -LiteralPath $request.output -PathType Leaf) -or
        ((Test-Path -LiteralPath $request.output -PathType Container) -and
        (Get-ChildItem -LiteralPath $request.output -Force | Select-Object -First 1))) {
        throw 'An effect brief build requires a fresh or empty output directory.'
    }
    $request.effectBrief = $effectSpec
}

if ($Action -eq 'Learn') {
    Require-VfxArgument 'Source' $Source
    Require-VfxArgument 'Prefab' $Prefab
    Require-VfxArgument 'Title' $Title
    Require-VfxArgument 'Brief' $Brief
    Require-VfxArgument 'Id' $Id
    if (!(Test-Path -LiteralPath (Join-Path $unity.path '.vfx-reference') -PathType Leaf)) {
        throw 'Learn stages source assets in a disposable stand. Use Init with -ReferenceStand.'
    }
    $item = Get-Item -LiteralPath (Full-VfxPath $Source)
    if ($item.PSIsContainer) {
        if ($item.FullName -eq $unity.path) { throw 'Use separate source and reference projects.' }
        $request.prefab = Install-VfxProjectPrefab $item.FullName $Prefab $unity.path
    } else {
        $archivePath = Resolve-VfxArchive $item.FullName $workRoot $Nested
        $request.prefab = Install-VfxPackagePrefab $archivePath $Prefab $unity.path
    }
    $request.title = $Title
    $request.brief = $Brief
    $request.metadataOnly = [bool]$MetadataOnly
    $request.recipe = if ($Recipe) { Full-VfxPath $Recipe } else { Join-Path $run "$Id.json" }
}
if ($Action -eq 'Build') {
    Require-VfxArgument 'Recipe' $Recipe
    $request.sourceRecipe = (Get-Item -LiteralPath (Full-VfxPath $Recipe)).FullName
    $request.recipe = Join-Path $run 'recipe.json'
    ConvertTo-VfxBuildRecipe $request.sourceRecipe $request.recipe
    $request.resourceRoot = if ($ResourceRoot) { (Get-Item -LiteralPath (Full-VfxPath $ResourceRoot)).FullName } else { Split-Path -Parent $request.sourceRecipe }
    $request.shader = Join-Path $skill 'unity/Layer.shader'
    $request.renderAfterBuild = [bool]$RenderAfterBuild
}
if ($Action -eq 'Render') { Require-VfxArgument 'Prefab' $Prefab }
if ($Action -eq 'Compare') {
    Require-VfxArgument 'Reference' $Reference
    Require-VfxArgument 'Candidate' $Candidate
    $request.reference = (Get-Item -LiteralPath (Full-VfxPath $Reference)).FullName
    $request.candidate = (Get-Item -LiteralPath (Full-VfxPath $Candidate)).FullName
    if ($Limits) { $request.limits = (Get-Item -LiteralPath (Full-VfxPath $Limits)).FullName }
}

Invoke-VfxUnity $unity $request $run
