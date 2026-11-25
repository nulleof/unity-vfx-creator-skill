[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Init', 'Inventory', 'Learn', 'Find', 'Build', 'Render', 'Compare')]
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
    [ValidateRange(1, 180)][int]$TimeoutMinutes = 12
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. "$PSScriptRoot/Archive.ps1"

$skill = Split-Path -Parent $PSScriptRoot

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
    Get-ChildItem -LiteralPath (Join-Path $skill 'catalog') -Filter '*.json' -File | ForEach-Object {
        $file = $_
        $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $keyTokens = Get-VfxTokens ("$($data.title) " + ($data.tags -join ' '))
        $otherTokens = Get-VfxTokens $data.description
        $score = 0
        foreach ($word in $query) {
            if ($word -in $keyTokens) { $score += 3 }
            elseif ($word -in $otherTokens) { $score++ }
        }
        if ($score) { [pscustomobject]@{ score = $score; id = $data.id; title = $data.title; path = $file.FullName } }
    } | Sort-Object -Property @{ Expression = 'score'; Descending = $true }, id
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
            $layer.enabledModules = @('shape', 'colorOverLife', 'sizeOverLife', 'spinOverLife', 'velocityX', 'velocityY', 'velocityZ', 'trail' |
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

function Invoke-VfxUnity($Unity, $Request, [string]$Run) {
    $requestPath = Join-Path $Run 'request.json'
    $responsePath = Join-Path $Run 'response.json'
    $logPath = Join-Path $Run 'unity.log'
    $Request.response = $responsePath
    $Request | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $requestPath
    $bridgeLocation = "Assets/Editor/VfxCreatorBridge_$([guid]::NewGuid().ToString('N'))"
    $bridge = Get-VfxSafePath $Unity.path $bridgeLocation
    [void](New-VfxDirectory $bridge)
    try {
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
                $process.Kill($true)
                $process.WaitForExit()
                throw "Unity timed out. See '$logPath'."
            }
            $exitCode = $process.ExitCode
        } finally {
            $process.Dispose()
        }
        if (!(Test-Path -LiteralPath $responsePath -PathType Leaf)) {
            throw "Unity exited with code $exitCode before responding. See '$logPath'."
        }
        $result = Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json -AsHashtable
        if ($exitCode -or !$result.ok) { throw "Unity failed: $($result.error) See '$logPath'." }
        return [pscustomobject]$result
    } finally {
        foreach ($file in Get-ChildItem -LiteralPath $bridge -File -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $file.FullName
        }
        if (!(Get-ChildItem -LiteralPath $bridge -Force)) { [IO.Directory]::Delete($bridge) }
        if (Test-Path -LiteralPath "$bridge.meta") { Remove-Item -LiteralPath "$bridge.meta" }
    }
}

if ($Action -eq 'Init') { Initialize-VfxProject; return }
if ($Action -eq 'Find') { Find-VfxRecipe; return }

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
    capture = @{ size = $Size; fps = $Fps; duration = $Duration; framing = $Framing; cameraPitch = $CameraPitch; travel = $Travel; arc = $Arc; seed = $Seed }
    graphEvents = $graphSchedule
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
