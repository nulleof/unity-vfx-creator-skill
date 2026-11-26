[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UnityProject,
    [string]$Editor = 'C:/Program Files/Unity/Hub/Editor/6000.6.8f1/Editor/Unity.exe',
    [switch]$Android
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$repo = Split-Path -Parent $PSScriptRoot
$project = (Get-Item -LiteralPath $UnityProject).FullName
$editorPath = (Get-Item -LiteralPath $Editor).FullName
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$work = Join-Path $repo ".vfx-work/ui-effect-tests-$suffix"
$installRoot = Join-Path $project ".vfx-work/ui-effect-tests-$suffix/.agents/skills"
[void][IO.Directory]::CreateDirectory($work)
[void][IO.Directory]::CreateDirectory($installRoot)
$installed = Join-Path $installRoot 'vfx-creator'
Copy-Item -LiteralPath (Join-Path $repo 'vfx-creator') -Destination $installed -Recurse
$pipeline = Join-Path $installed 'scripts/vfx.ps1'
$examples = Join-Path $installed 'examples/ui'
$generated = Join-Path $project 'Assets/VfxCreatorGenerated'
$buildArgs = @{ Project = $project; Editor = $editorPath; Work = $work }

function Write-Input([string]$Name, $Data) {
    $path = Join-Path $work "$Name.json"
    $Data | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path
    return $path
}

function Assert-Failure([scriptblock]$Command, [string]$Message) {
    try {
        $null = & $Command
    } catch {
        if (!$_.Exception.Message.Contains($Message)) { throw }
        return
    }
    throw "Expected a UI build failure mentioning '$Message'."
}

function Get-GeneratedNames {
    if (Test-Path -LiteralPath $generated -PathType Container) {
        Get-ChildItem -LiteralPath $generated -Force | Sort-Object Name | ForEach-Object Name
    }
}

function Invoke-CheckProcess([string]$Executable, [string[]]$Arguments, [string]$Log, [int]$Timeout) {
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (!$process.WaitForExit($Timeout * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "UI check timed out. See '$Log'."
        }
        if ($process.ExitCode) { throw "UI check exited with code $($process.ExitCode). See '$Log'." }
    } finally {
        $process.Dispose()
    }
}

$buttonBrief = "$examples/ui-button-confirm.brief.json"
$buttonRecipe = "$examples/ui-button-confirm.recipe.json"
$missing = Join-Path $work 'missing-project'
$invalid = Get-Content -LiteralPath $buttonBrief -Raw | ConvertFrom-Json -AsHashtable
$invalid.anchor.x = 1.2
$invalidPath = Write-Input 'invalid-anchor' $invalid
Assert-Failure { & $pipeline BuildUi -Project $missing -UiBrief $invalidPath -Recipe $buttonRecipe } 'UI brief.anchor.x'
$invalid.anchor.x = 0.2
$invalid.retrigger = 'queue'
$invalidPath = Write-Input 'invalid-retrigger' $invalid
Assert-Failure { & $pipeline BuildUi -Project $missing -UiBrief $invalidPath -Recipe $buttonRecipe } 'UI brief.retrigger'
$invalidRecipe = Get-Content -LiteralPath $buttonRecipe -Raw | ConvertFrom-Json -AsHashtable
$reducedLayer = $invalidRecipe.layers | Where-Object { $_.Contains('reduced') } | Select-Object -First 1
$reducedLayer.reduced.keys[0].position = @{ x = 0; y = 0 }
$invalidRecipePath = Write-Input 'reduced-motion-with-movement' $invalidRecipe
Assert-Failure { & $pipeline BuildUi -Project $missing -UiBrief $buttonBrief -Recipe $invalidRecipePath } 'reduced.keys[0].position'

$effects = foreach ($pilot in 'ui-button-confirm', 'ui-cooldown-ready', 'ui-reward-reveal') {
    $brief = Get-Content -LiteralPath "$examples/$pilot.brief.json" -Raw | ConvertFrom-Json -AsHashtable
    $brief.id += "-$suffix"
    $briefPath = Write-Input $brief.id $brief
    $recipePath = "$examples/$pilot.recipe.json"
    $result = & $pipeline BuildUi @buildArgs -UiBrief $briefPath -Recipe $recipePath -Output (Join-Path $work $pilot)
    $effect = Get-Content -LiteralPath $result.effect -Raw | ConvertFrom-Json -AsHashtable
    $directory = (Split-Path -Parent $result.prefab).Replace('\', '/')
    $assets = @('Effect.prefab', 'Idle.anim', 'Standard.anim', 'Reduced.anim', 'Effect.controller')
    if (!$result.ok -or $effect.version -ne 1 -or $effect.id -ne $brief.id -or
        $effect.canvas -ne 'screenSpaceOverlay' -or $effect.prefab -ne $result.prefab -or
        $effect.standardDurationSec -le $effect.reducedDurationSec -or
        $effect.placement.trigger -ne $brief.trigger -or $effect.placement.target -ne $brief.target -or
        [Math]::Abs($effect.placement.anchor.x - $brief.anchor.x) -gt 0.00001 -or
        [Math]::Abs($effect.placement.footprint.y - $brief.footprint.y) -gt 0.00001 -or
        $effect.placement.order -ne $brief.order -or $effect.placement.clipping -ne $brief.clipping -or
        $effect.placement.retrigger -ne $brief.retrigger -or $effect.placement.reducedMotion -ne $brief.reducedMotion) {
        throw "Unexpected UI handoff for '$pilot'."
    }
    foreach ($asset in $assets) {
        if ($result.dependencies -notcontains "$directory/$asset") { throw "Missing '$asset' for '$pilot'." }
    }
    if (!($result.dependencies -like "$directory/*.png")) { throw "Missing generated sprites for '$pilot'." }
    Write-Host "Built $pilot at $($result.prefab)"
    $result.effect
}

$last = Get-Content -LiteralPath $effects[-1] -Raw | ConvertFrom-Json -AsHashtable
$existing = Join-Path $project $last.prefab
$original = (Get-FileHash -LiteralPath $existing).Hash
$originalMeta = (Get-FileHash -LiteralPath "$existing.meta").Hash
$before = @(Get-GeneratedNames)
$duplicateOutput = Join-Path $work 'duplicate'
Assert-Failure {
    & $pipeline BuildUi @buildArgs -UiBrief "$work/$($last.id).json" -Recipe "$examples/ui-reward-reveal.recipe.json" -Output $duplicateOutput
} 'already exists'
if ((Get-FileHash -LiteralPath $existing).Hash -ne $original -or (Get-FileHash -LiteralPath "$existing.meta").Hash -ne $originalMeta -or
    (Test-Path -LiteralPath (Join-Path $duplicateOutput 'ui-effect.json'))) {
    throw 'An occupied UI ID did not preserve the original prefab and GUID.'
}

$blocked = Join-Path $work 'blocked-output'
Set-Content -LiteralPath $blocked -Value 'Deliberate handoff write failure'
$rollback = Get-Content -LiteralPath $buttonBrief -Raw | ConvertFrom-Json -AsHashtable
$rollback.id = "ui-rollback-$suffix"
$rollbackBrief = Write-Input $rollback.id $rollback
Assert-Failure {
    & $pipeline BuildUi @buildArgs -UiBrief $rollbackBrief -Recipe $buttonRecipe -Output (Join-Path $blocked 'child')
} 'blocked-output'
if ((Compare-Object $before @(Get-GeneratedNames)) -or
    (Get-Content -LiteralPath $blocked -Raw).Trim() -ne 'Deliberate handoff write failure') {
    throw 'Failed UI publication changed the generated directory or the existing output file.'
}

$fixtureRoot = Join-Path $project "Assets/VfxCreatorUiCheck_$suffix"
$fixtureEditor = Join-Path $fixtureRoot 'Editor'
$fixtureRuntimeScript = Join-Path $fixtureRoot 'UiEffectsPlayCheck.cs'
$fixtureReviewScript = Join-Path $fixtureRoot 'UiEffectsReview.cs'
$fixtureEditorScript = Join-Path $fixtureEditor 'UiEffectsPlayerBuild.cs'
$fixtureScene = Join-Path $fixtureRoot 'OverlayPilot.unity'
$player = Join-Path $work 'player/OverlayPilot.exe'
$apk = Join-Path $work 'player/OverlayPilot.apk'
$buildLog = Join-Path $work 'player-build.log'
$runLog = Join-Path $work 'play-mode.log'
$manifest = Write-Input 'player-input' @{
    effects = $effects
    scene = "Assets/VfxCreatorUiCheck_$suffix/OverlayPilot.unity"
    player = $player
    androidPlayer = $apk
}
function Test-MobileReview([int]$Height, [string]$Layout, [switch]$MotionFrames) {
    $directory = Join-Path $work $Layout
    [void][IO.Directory]::CreateDirectory($directory)
    $log = Join-Path $directory 'player.log'
    $flags = @('-screen-width', '480', '-screen-height', "$Height", '-screen-fullscreen', '0',
        '-popupwindow', '-vfxUiReviewOutput', $directory, '-vfxUiMobileReview', '-logFile', $log)
    if ($MotionFrames) { $flags += '-vfxUiMotionFrames' }
    Invoke-CheckProcess $player $flags $log 180
    $report = Get-Content -LiteralPath (Join-Path $directory 'review.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($report.width -ne 480 -or $report.height -ne $Height -or $report.deviceSafeArea -or $report.captures.Count -ne 4 -or
        (Select-String -LiteralPath $log -Pattern 'Exception:|Error:' -Quiet)) {
        throw "Unexpected '$Layout' mobile review results. See '$log'."
    }
    foreach ($theme in 'dark', 'light') {
        foreach ($mode in 'standard', 'reduced') {
            $frame = "$theme-$mode-peak.png"
            if ($frame -notin $report.captures -or !(Test-Path -LiteralPath (Join-Path $directory $frame) -PathType Leaf)) {
                throw "Missing '$Layout' composite '$frame'."
            }
        }
    }
    if ($MotionFrames) {
        foreach ($mode in 'standard', 'reduced') {
            foreach ($sequence in 'confirm', 'ready', 'reward', 'overlap') {
                $frames = @(Get-ChildItem -LiteralPath (Join-Path $directory "motion/$mode/$sequence") -Filter '*.png' -File)
                if ($frames.Count -ne 90) { throw "Incomplete motion capture for '$mode/$sequence'." }
            }
        }
    }
}
try {
    [void][IO.Directory]::CreateDirectory($fixtureEditor)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'UiEffectsPlayCheck.cs') -Destination $fixtureRuntimeScript
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'UiEffectsReview.cs') -Destination $fixtureReviewScript
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'UiEffectsPlayerBuild.cs') -Destination $fixtureEditorScript
    Invoke-CheckProcess $editorPath @('-batchmode', '-quit', '-projectPath', $project, '-buildTarget', 'Win64', '-executeMethod',
        'UiEffectsPlayerBuild.Run', '-vfxUiPlayerInput', $manifest, '-logFile', $buildLog) $buildLog 300
    if (!(Test-Path -LiteralPath $player -PathType Leaf)) { throw "Unity did not build the preview player. See '$buildLog'." }
    Invoke-CheckProcess $player @('-screen-width', '480', '-screen-height', '854', '-screen-fullscreen', '0',
        '-vfxUiReviewOutput', $work, '-logFile', $runLog) $runLog 90
    $summary = Get-Content -LiteralPath (Join-Path $work 'playback.json') -Raw | ConvertFrom-Json -AsHashtable
    if (!$summary.passed -or $summary.confirmedClicks -ne 4 -or $summary.captures.Count -ne 4 -or
        (Select-String -LiteralPath $runLog -Pattern 'Exception:|Error:' -Quiet)) {
        throw "UI Play Mode checks failed. See '$runLog'."
    }
    foreach ($frame in $summary.captures) {
        if (!(Test-Path -LiteralPath (Join-Path $work $frame) -PathType Leaf)) { throw "Missing composite '$frame'." }
    }
    Test-MobileReview 854 'compact' -MotionFrames
    Test-MobileReview 1067 'tall'
    if ($Android) {
        $androidLog = Join-Path $work 'android-build.log'
        Invoke-CheckProcess $editorPath @('-batchmode', '-quit', '-projectPath', $project, '-buildTarget', 'Android',
            '-executeMethod', 'UiEffectsPlayerBuild.Run', '-vfxUiPlayerInput', $manifest, '-logFile', $androidLog) $androidLog 900
        if (!(Test-Path -LiteralPath $apk -PathType Leaf)) { throw "Unity did not build the Android fixture. See '$androidLog'." }
        Write-Output "Android review APK: $apk"
    }
} finally {
    foreach ($file in @($fixtureRuntimeScript, $fixtureReviewScript, "$fixtureReviewScript.meta", $fixtureEditorScript, $fixtureScene, "$fixtureScene.meta",
            "$fixtureEditorScript.meta", "$fixtureRuntimeScript.meta", "$fixtureEditor.meta", "$fixtureRoot.meta")) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file }
    }
    foreach ($directory in @($fixtureEditor, $fixtureRoot)) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and !(Get-ChildItem -LiteralPath $directory -Force)) {
            [IO.Directory]::Delete($directory)
        }
    }
}
Write-Output "UI effect checks passed. Overlay Play Mode captures and logs: $work"
