[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UnityProject,
    [Parameter(Mandatory)][string]$Output,
    [ValidateSet('Block', 'Corrected', 'Final')][string[]]$Phase = @('Block', 'Corrected', 'Final')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$project = (Get-Item -LiteralPath $UnityProject).FullName
$skill = Join-Path $project '.agents/skills/vfx-creator'
$pipeline = Join-Path $skill 'scripts/vfx.ps1'
if (!(Test-Path -LiteralPath $pipeline -PathType Leaf)) { throw 'Install the whole skill in the disposable Unity project first.' }
$version = Get-Content -LiteralPath (Join-Path $project 'ProjectSettings/ProjectVersion.txt') -TotalCount 1
if ($version -ne 'm_EditorVersion: 6000.6.8f1') { throw 'Use Unity 6000.6.8f1.' }
$root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
$inputs = Join-Path $root 'inputs'
[void][IO.Directory]::CreateDirectory($inputs)
$spec = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'art-direction-cases.json') -Raw | ConvertFrom-Json -AsHashtable
$items = @(foreach ($case in $spec.training) {
    $source = Join-Path $skill "examples/$($case.id).json"
    foreach ($pass in $Phase) {
        $id = "$($case.id)-$($pass.ToLowerInvariant())"
        $briefFile = Join-Path $inputs "$id-brief.json"
        @{
            version = 1; id = $id; description = $case.brief; mode = $case.mode; capture = $case.capture
            attachment = @{ anchor = 'At the actor or moving origin.'; orientation = 'Local Y up. Action toward +X.' }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $briefFile
        $recipeFile = $source
        if ($pass -ne 'Final') {
            $recipe = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json -AsHashtable
            $recipe.id = $id
            $recipe.title += " ($pass)"
            switch ($case.id) {
                'verdigris-arc' {
                    $recipe.layers = @($recipe.layers[0], $recipe.layers[1])
                    $sweep, $contact = $recipe.layers
                    $sweep.texture = @{ kind = 'crescent'; detail = 0.57; falloff = 1.1; resolution = 128 }
                    $sweep.size = @{ max = 1.35 }
                    $sweep.rotation = @{ max = 0.34 }
                    $sweep.sizeOverLife = @{ mode = 'curve'; keys = @(
                        @{ time = 0; value = 0.36 }, @{ time = 0.44; value = 0.95 },
                        @{ time = 0.70; value = 1 }, @{ time = 1; value = 0.80 }
                    ) }
                    if ($pass -eq 'Block') { $contact.bursts[0].time = 0.17 }
                }
                'saffron-front' {
                    $recipe.layers = @($recipe.layers[0], $recipe.layers[1], $recipe.layers[2])
                    $front = $recipe.layers[1]
                    $front.texture = @{ kind = 'streak'; detail = 0.8; falloff = 0.42; resolution = 128 }
                    $front.position.y = 0.26
                    $front.sizeOverLife = @{ mode = 'curve'; keys = @(
                        @{ time = 0; value = 0.34 }, @{ time = 0.53; value = 1 }, @{ time = 1; value = 0.9 }
                    ) }
                    if ($pass -eq 'Block') { $front.velocityX = @{ max = 1.05 } }
                }
                'prism-dart' {
                    $recipe.layers = @($recipe.layers[0], $recipe.layers[2])
                    $wake, $head = $recipe.layers
                    if ($pass -eq 'Block') { $wake.trail.time = 0.32 }
                    $wake.trail.color.gradient.Remove('colors')
                    $head.texture = @{ kind = 'star'; detail = 0.55; falloff = 0.68; resolution = 128 }
                    $head.size = @{ max = 0.30 }
                }
            }
            for ($index = 0; $index -lt $recipe.layers.Count; $index++) {
                $layer = $recipe.layers[$index]
                $value = if ($index -eq 1) { 0.84 } else { 0.62 }
                $alpha = if ($layer['tint']) { $layer.tint['a'] ?? 1 } else { 1 }
                $layer.tint = @{ r = $value; g = $value; b = $value; a = $alpha }
                $layer.glow = 1
            }
            $recipeFile = Join-Path $inputs "$id-recipe.json"
            $recipe | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $recipeFile
        }
        @{ recipe = $recipeFile; effectBrief = $briefFile; resourceRoot = $skill }
    }
})
$manifest = Join-Path $inputs 'batch-input.json'
@{ version = 1; items = $items } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifest
$batch = & $pipeline BuildBatch -Project $project -Manifest $manifest -Output (Join-Path $root 'build')
$batch
if (!$batch.ok) { throw "See the per-item build results in '$($batch.report)'." }
