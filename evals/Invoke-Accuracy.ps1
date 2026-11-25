[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Reference', 'Render', 'Compare')][string]$Stage,
    [Parameter(Mandatory)][string]$ResultsRoot,
    [string]$ReferenceProject,
    [string]$SourceRoot,
    [ValidateSet('teleport', 'aura')][string]$CaseId,
    [ValidateSet('old', 'new')][string]$Version
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$repo = Split-Path -Parent $PSScriptRoot
$pipeline = Join-Path $repo 'vfx-creator/scripts/vfx.ps1'
$results = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsRoot)
$cases = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'accuracy-cases.json') -Raw | ConvertFrom-Json -AsHashtable
if ($CaseId) { $cases = @($cases | Where-Object id -EQ $CaseId) }
if ($Stage -eq 'Reference' -and (!$ReferenceProject -or !$SourceRoot)) { throw 'Reference requires -ReferenceProject and -SourceRoot.' }
if ($Stage -eq 'Compare' -and !$ReferenceProject) { throw 'Compare requires -ReferenceProject.' }
$versions = if ($Version) { @($Version) } else { @('old', 'new') }
$work = Join-Path $results 'runs'

foreach ($case in $cases) {
    $id = $case.id
    $reference = Join-Path $results "references/$id"
    if ($Stage -eq 'Reference') {
        New-Item -ItemType Directory -Path $results -Force | Out-Null
        $schedule = Join-Path $results "$id-events.json"
        $case.events | ConvertTo-Json -AsArray | Set-Content -LiteralPath $schedule
        $framing = 6.0
        while ($framing -le 100) {
            $trial = Join-Path $results "reference-trials/$id-$framing"
            $learn = @{
                Project = $ReferenceProject; Source = (Join-Path $SourceRoot $case.package); Prefab = $case.prefab
                Title = $case.title; Brief = $case.title; Id = "accuracy-$id"; Recipe = (Join-Path $results "$id-learned.json")
                Size = 256; Fps = 30; Seed = 1729; CameraPitch = 20; GraphEvents = $schedule
                Framing = $framing; Duration = $case.duration; Output = $trial; Work = $work
            }
            & $pipeline Learn @learn
            $capture = Get-Content -LiteralPath (Join-Path $trial 'capture.json') -Raw | ConvertFrom-Json
            Write-Host "$id at framing $framing has $($capture.visibleFrames) visible frames and $($capture.clippedFrames) clipped frames."
            if (!$capture.clippedFrames) { break }
            $framing *= 1.5
        }
        if ($capture.clippedFrames) { throw "Reference stayed clipped for '$id'." }
        New-Item -ItemType Directory -Path $reference -Force | Out-Null
        Get-ChildItem -LiteralPath $trial -File | Copy-Item -Destination $reference
        continue
    }

    foreach ($variant in $versions) {
        $project = Join-Path $results "$variant-$id"
        $candidate = Join-Path $results "captures/$variant-$id"
        if ($Stage -eq 'Render') {
            $prefab = "Assets/VfxCreatorGenerated/$id-candidate/Effect.prefab"
            if (!(Test-Path -LiteralPath (Join-Path $project $prefab))) {
                $installed = Join-Path $project '.agents/skills/vfx-creator/scripts/vfx.ps1'
                & $installed Build -Project $project -Recipe (Join-Path $project 'candidate.json') -Id "$id-candidate" -Work $work
            }
            $settings = (Get-Content -LiteralPath (Join-Path $reference 'capture.json') -Raw | ConvertFrom-Json -AsHashtable).settings
            & $pipeline Render -Project $project -Prefab $prefab @settings -Output $candidate -Work $work
        } else {
            $compare = @{
                Project = $ReferenceProject; Reference = $reference; Candidate = $candidate
                Output = (Join-Path $results "reports/$variant-$id"); Work = $work
            }
            & $pipeline Compare @compare
        }
    }
}
