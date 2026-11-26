[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UnityProject,
    [string]$Editor = 'C:/Program Files/Unity/Hub/Editor/6000.6.8f1/Editor/Unity.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$repo = Split-Path -Parent $PSScriptRoot
$project = (Get-Item -LiteralPath $UnityProject).FullName
$editorPath = (Get-Item -LiteralPath $Editor).FullName
$skill = Join-Path $repo 'vfx-creator'
$skills = Join-Path $project '.agents/skills'
$installed = Join-Path $skills 'vfx-creator'
if (!(Test-Path -LiteralPath $installed)) {
    [void][IO.Directory]::CreateDirectory($skills)
    Copy-Item -LiteralPath $skill -Destination $installed -Recurse
}
$pipeline = Join-Path $installed 'scripts/vfx.ps1'
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$work = Join-Path $repo ".vfx-work/effect-brief-tests-$suffix"
[void][IO.Directory]::CreateDirectory($work)

function Write-Fixture([string]$Name, $Contents) {
    $path = Join-Path $work "$Name.json"
    $Contents | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path
    return $path
}

function Assert-FailedBuild($Brief, [string]$Recipe, [string]$Message) {
    $assets = Join-Path $project 'Assets/VfxCreatorGenerated'
    $before = @(Get-ChildItem -LiteralPath $assets -Directory | ForEach-Object Name)
    $output = Join-Path $work "failure-$([guid]::NewGuid().ToString('N'))"
    $inputPath = Write-Fixture "$($Brief.id)-failure" $Brief
    try {
        $null = & $pipeline Build -Project $project -Editor $editorPath -Recipe $Recipe -EffectBrief $inputPath -Output $output -Work $work
        throw 'Expected the build to fail.'
    } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
    }
    if (Test-Path -LiteralPath (Join-Path $output 'effect.json')) { throw 'A failed build wrote effect.json.' }
    $after = @(Get-ChildItem -LiteralPath $assets -Directory | ForEach-Object Name)
    if (Compare-Object $before $after) { throw 'A failed build changed the generated asset directories.' }
}

$cases = Get-Content -LiteralPath (Join-Path $repo 'evals/gameplay-briefs.json') -Raw | ConvertFrom-Json -AsHashtable
$effects = @()
foreach ($case in $cases) {
    $brief = $case.brief
    $brief.id += "-$suffix"
    $briefPath = Write-Fixture "$($brief.id)-brief" $brief
    $recipePath = Write-Fixture "$($brief.id)-recipe" $case.recipe
    $output = Join-Path $work $brief.id
    $built = & $pipeline Build -Project $project -Editor $editorPath -Recipe $recipePath -EffectBrief $briefPath -Output $output -Work $work
    $prefab = Join-Path $project $built.prefab
    $effect = Get-Content -LiteralPath $built.effect -Raw | ConvertFrom-Json -AsHashtable
    $capture = Get-Content -LiteralPath (Join-Path $built.capture 'capture.json') -Raw | ConvertFrom-Json -AsHashtable
    if (!$built.ok -or !$built.visible -or $built.recipe -ne $recipePath -or
        !(Test-Path -LiteralPath $prefab -PathType Leaf) -or
        $effect.version -ne 1 -or $effect.id -ne $brief.id -or $effect.mode -ne $brief.mode -or
        $effect.prefab -ne $built.prefab -or $effect.attachment.anchor -ne $brief.attachment.anchor -or
        $effect.attachment.orientation -ne $brief.attachment.orientation -or
        $built.dependencies -notcontains $built.prefab -or $capture.clippedFrames -ne 0) {
        throw "Invalid capture or handoff for '$($brief.id)'."
    }
    foreach ($key in $brief.capture.Keys) {
        if ([Math]::Abs($capture.settings[$key] - $brief.capture[$key]) -gt 0.0001) {
            throw "Capture did not honor '$key' from the brief."
        }
    }
    $effects += $built.effect
    Write-Host "Built $($brief.mode) at $($built.prefab)"
}

$impact = $cases[0]
$existingPath = Join-Path $project "Assets/VfxCreatorGenerated/$($impact.brief.id)/Effect.prefab"
$original = (Get-FileHash -LiteralPath $existingPath).Hash
$originalMeta = (Get-FileHash -LiteralPath "$existingPath.meta").Hash
$impactRecipe = Join-Path $work "$($impact.brief.id)-recipe.json"
Assert-FailedBuild $impact.brief $impactRecipe 'already exists'
if ((Get-FileHash -LiteralPath $existingPath).Hash -ne $original -or (Get-FileHash -LiteralPath "$existingPath.meta").Hash -ne $originalMeta) {
    throw 'An occupied ID did not preserve the original prefab and its GUID.'
}
$badMode = $impact.brief.Clone()
$badMode.id = "bad-mode-$suffix"
$badMode.mode = 'loop'
Assert-FailedBuild $badMode $impactRecipe 'needs a looping start emitter'

$trail = $cases[2]
$noMotion = $trail.brief.Clone()
$noMotion.id = "no-motion-$suffix"
$noMotion.capture = @{}
Assert-FailedBuild $noMotion (Join-Path $work "$($trail.brief.id)-recipe.json") 'needs nonzero'

$invisible = $impact.brief.Clone()
$invisible.id = "invisible-$suffix"
$invisibleRecipe = @{ version = 1; id = $invisible.id; layers = @(@{ name = 'Empty emitter' }) }
Assert-FailedBuild $invisible (Write-Fixture 'invisible-recipe' $invisibleRecipe) 'no visible frames'

$editorDir = Join-Path $project "Assets/Editor/EffectBriefCheck_$suffix"
[void][IO.Directory]::CreateDirectory($editorDir)
$fixture = Join-Path $editorDir 'EffectBriefPlayCheck.cs'
$runtimeLog = Join-Path $work 'play-mode.log'
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'EffectBriefPlayCheck.cs') -Destination $fixture
    $inputs = Write-Fixture 'playback' @{ effects = $effects }
    $start = [Diagnostics.ProcessStartInfo]::new($editorPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in @('-batchmode', '-projectPath', $project, '-executeMethod', 'EffectBriefPlayCheck.Run',
        '-vfxPlayCheck', $inputs, '-logFile', $runtimeLog)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (!$process.WaitForExit(240000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Play Mode timed out. See '$runtimeLog'."
        }
        if ($process.ExitCode -ne 0 -or !(Select-String -LiteralPath $runtimeLog -SimpleMatch 'Effect brief Play Mode checks passed.' -Quiet)) {
            throw "Play Mode checks failed. See '$runtimeLog'."
        }
    } finally {
        $process.Dispose()
    }
} finally {
    foreach ($path in @($fixture, "$fixture.meta", "$editorDir.meta")) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path }
    }
    if (!(Get-ChildItem -LiteralPath $editorDir -Force)) { [IO.Directory]::Delete($editorDir) }
}
Write-Output "Effect brief checks passed. Captures and Play Mode log: $work"
