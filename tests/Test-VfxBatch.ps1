[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UnityProject,
    [string]$Editor,
    [switch]$Benchmark,
    [switch]$Interruption
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$repo = Split-Path -Parent $PSScriptRoot
$project = (Get-Item -LiteralPath $UnityProject).FullName
$install = Join-Path $project '.agents/skills/vfx-creator'
if (!(Test-Path -LiteralPath $install)) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $install))
    Copy-Item -LiteralPath (Join-Path $repo 'vfx-creator') -Destination $install -Recurse
}
$pipeline = Join-Path $install 'scripts/vfx.ps1'
$unity = @{ Project = $project }
if ($Editor) { $unity.Editor = $Editor }
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$work = Join-Path $repo ".vfx-work/batch-tests-$suffix"
[void][IO.Directory]::CreateDirectory($work)
$unity.Work = $work
$cases = Get-Content -LiteralPath (Join-Path $repo 'evals/gameplay-briefs.json') -Raw | ConvertFrom-Json -AsHashtable

function Write-JsonFile([string]$Name, $Value) {
    $path = Join-Path $work "$Name.json"
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path
    return $path
}

function New-BatchFixture([string]$Name, [int]$Case, $Changes) {
    $brief = $cases[$Case].brief.Clone()
    $recipe = $cases[$Case].recipe
    $brief.id = "$Name-$suffix"
    $brief.capture = $brief.capture.Clone()
    $brief.capture.size = 128
    $brief.capture.fps = 20
    if ($Changes) { $recipe = & $Changes $brief $recipe }
    $briefPath = Write-JsonFile "$($brief.id).brief" $brief
    $recipePath = Write-JsonFile "$($brief.id).recipe" $recipe
    return @{ recipe = Split-Path -Leaf $recipePath; effectBrief = Split-Path -Leaf $briefPath }
}

function Invoke-Batch([string]$Name, $Items, $Arguments = @{}) {
    $manifest = Write-JsonFile "$Name.input" @{ version = 1; items = @($Items) }
    & $pipeline BuildBatch @unity @Arguments -Manifest $manifest -Output (Join-Path $work $Name)
}

function Assert-Status($Batch, [string[]]$Expected) {
    $actual = $Batch.items.status -join ','
    if ($actual -ne ($Expected -join ',')) { throw "Unexpected statuses '$actual'. See '$($Batch.report)'." }
    if (!(Test-Path -LiteralPath $Batch.gallery)) { throw 'The batch gallery is missing.' }
    $saved = Get-Content -LiteralPath $Batch.report -Raw | ConvertFrom-Json -AsHashtable
    if (($saved.items.status -join ',') -ne $actual) { throw 'The written report differs from the returned batch.' }
}

function Get-FrameHashes([string]$Capture) {
    Get-ChildItem -LiteralPath $Capture -Filter 'frame-*.png' -File | Sort-Object Name | Get-FileHash | ForEach-Object Hash
}

$left = New-BatchFixture 'batch-impact' 0
$right = New-BatchFixture 'batch-trail' 2
$badLayer = New-BatchFixture 'bad-layer' 0 { param($brief, $recipe)
    @{ version = 1; id = $recipe.id; layers = @(@{ name = 'Broken layer'; kind = 'invalid' }) }
}
$invisible = New-BatchFixture 'invisible' 0 { param($brief, $recipe)
    @{ version = 1; id = $recipe.id; layers = @(@{ name = 'Empty emitter' }) }
}
$badRecipe = New-BatchFixture 'bad-recipe' 0 { param($brief, $recipe)
    @{ version = 2; id = $recipe.id }
}
$clipped = New-BatchFixture 'clipped' 0 { param($brief, $recipe)
    $brief.capture.framing = 0.15
    $recipe
}
$occupied = New-BatchFixture 'batch-occupied' 1
$baseline = & $pipeline Build @unity -Recipe (Join-Path $work $occupied.recipe) -EffectBrief (Join-Path $work $occupied.effectBrief)
$prefab = Join-Path $project $baseline.prefab
$original = @(Get-FileHash -LiteralPath $prefab, "$prefab.meta" | ForEach-Object Hash)

$invalid = $false
try { $null = Invoke-Batch 'duplicates' @($left, $left) } catch {
    if ($_.Exception.Message -notlike '*Duplicate batch effect ID*') { throw }
    $invalid = $true
}
if (!$invalid -or (Test-Path -LiteralPath (Join-Path $work 'duplicates'))) { throw 'Duplicate batch IDs were accepted.' }

$batch = Invoke-Batch 'mixed' @($left, $badLayer, $invisible, $badRecipe, $occupied, $right, $clipped)
Assert-Status $batch @('succeeded', 'failed', 'failed', 'failed', 'failed', 'succeeded', 'succeeded')
if ($batch.ok -or $batch.unityLaunches -ne 1 -or $batch.items[1].error -notlike '*Unknown layer kind*' -or
    $batch.items[2].visibleFrames -ne 0 -or $batch.items[2].effect -or $batch.items[3].receipt -or
    $batch.items[4].error -notlike '*already exists*' -or $batch.items[6].clippedFrames -le 0 -or
    (Compare-Object $original @(Get-FileHash -LiteralPath $prefab, "$prefab.meta" | ForEach-Object Hash) -SyncWindow 0)) {
    throw "Incorrect isolation or occupied ID handling. See '$($batch.report)'."
}
foreach ($item in $batch.items | Where-Object status -eq 'succeeded') {
    if (!(Test-Path -LiteralPath (Join-Path $project $item.prefab)) -or !(Test-Path -LiteralPath $item.effect) -or !$item.keyFrames.Count) {
        throw "Missing deliverables for '$($item.id)'."
    }
}
Write-Host "Batch error and success cases passed. $($batch.report)"

if ($Benchmark) {
    $fixtures = @(for ($i = 0; $i -lt 12; $i++) { New-BatchFixture "benchmark-$i" ($i % 3) })
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $packed = Invoke-Batch 'benchmark-batch' $fixtures
    $timer.Stop()
    $batchSeconds = $timer.Elapsed.TotalSeconds
    Assert-Status $packed (@('succeeded') * 12)
    if (!$packed.ok -or $packed.unityLaunches -ne 1) { throw 'Expected one Unity launch for 12 items.' }
    $timer.Restart()
    $sequential = @(for ($i = 0; $i -lt $fixtures.Count; $i++) {
        $brief = Get-Content -LiteralPath (Join-Path $work $fixtures[$i].effectBrief) -Raw | ConvertFrom-Json -AsHashtable
        $brief.id = "benchmark-single-$i-$suffix"
        $path = Write-JsonFile "$($brief.id).brief" $brief
        & $pipeline Build @unity -Recipe (Join-Path $work $fixtures[$i].recipe) -EffectBrief $path
    })
    $timer.Stop()
    for ($i = 0; $i -lt $fixtures.Count; $i++) {
        $first = @(Get-FrameHashes $packed.items[$i].capture)
        $second = @(Get-FrameHashes $sequential[$i].capture)
        if ($first.Count -ne $second.Count -or (Compare-Object $first $second -SyncWindow 0)) {
            throw "Frame mismatch for '$($packed.items[$i].id)'. Inspect '$work'."
        }
    }
    $timing = Write-JsonFile 'benchmark-timing' @{
        items = 12; batchUnityLaunches = 1; sequentialUnityLaunches = 12
        batchSeconds = $batchSeconds; sequentialSeconds = $timer.Elapsed.TotalSeconds; framesMatch = $true
    }
    if ($batchSeconds -ge $timer.Elapsed.TotalSeconds) { throw "Batch was slower. See '$timing'." }
    Write-Host "Images matched across all 12 builds. Timing at $timing"
}

if ($Interruption) {
    $first = New-BatchFixture 'timeout-first' 0
    $slow = New-BatchFixture 'timeout-slow' 1 { param($brief, $recipe)
        $brief.capture.size = 2048
        $brief.capture.fps = 120
        $brief.capture.duration = 20
        $recipe
    }
    $last = New-BatchFixture 'timeout-last' 2
    $generated = Join-Path $project 'Assets/VfxCreatorGenerated'
    $stagingBefore = @(Get-ChildItem -LiteralPath $generated -Filter 'staging-*' | ForEach-Object Name)
    $partial = Invoke-Batch 'timeout' @($first, $slow, $last) @{ TimeoutMinutes = 1 }
    Assert-Status $partial @('succeeded', 'interrupted', 'interrupted')
    if ($partial.error -notlike '*timed out*') { throw 'Expected the Unity timeout diagnostic.' }
    $stagingAfter = @(Get-ChildItem -LiteralPath $generated -Filter 'staging-*' | ForEach-Object Name)
    if (Compare-Object $stagingBefore $stagingAfter) { throw 'The interrupted build left staged assets in the project.' }
    $firstPrefab = Join-Path $project $partial.items[0].prefab
    $confirmed = @(Get-FileHash -LiteralPath $firstPrefab, "$firstPrefab.meta" | ForEach-Object Hash)
    $retry = Invoke-Batch 'timeout-retry' @($last)
    Assert-Status $retry @('succeeded')
    if (Compare-Object $confirmed @(Get-FileHash -LiteralPath $firstPrefab, "$firstPrefab.meta" | ForEach-Object Hash) -SyncWindow 0) {
        throw 'The retry changed the confirmed prefab or GUID.'
    }
    Write-Host "Interruption and selective retry passed. $($partial.report)"
}
