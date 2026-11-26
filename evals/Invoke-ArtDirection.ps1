[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Author', 'Capture', 'Review', 'Summarize')][string]$Stage,
    [Parameter(Mandatory)][string]$ResultsRoot,
    [string]$UnityProject,
    [string]$BaselineSkill,
    [string]$PilotBatch,
    [string]$Editor = 'C:/Program Files/Unity/Hub/Editor/6000.6.8f1/Editor/Unity.exe',
    [string]$UpdatedSkill = (Join-Path (Split-Path -Parent $PSScriptRoot) 'vfx-creator'),
    [string]$Model = 'gpt-6.2-sol',
    [ValidateSet('low', 'medium', 'high')][string]$Effort = 'medium',
    [ValidateRange(1, 6)][int]$Throttle = 4,
    [string[]]$CaseId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$results = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsRoot)
$spec = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'art-direction-cases.json') -Raw | ConvertFrom-Json -AsHashtable
$cases = @($spec.holdouts | Where-Object { !$CaseId -or $_.id -in ($CaseId -split ',') })
if (!$cases.Count -or ($CaseId -and @($CaseId -split ',' | Where-Object { $_ -notin $cases.id }).Count)) {
    throw 'Select existing holdout IDs.'
}

if ($Stage -eq 'Author') {
    if (!$UnityProject -or !$BaselineSkill) { throw 'Author needs -UnityProject and -BaselineSkill.' }
    $project = (Get-Item -LiteralPath $UnityProject).FullName
    $version = Get-Content -LiteralPath (Join-Path $project 'ProjectSettings/ProjectVersion.txt') -TotalCount 1
    if ($version -ne 'm_EditorVersion: 6000.6.8f1') { throw 'Use a disposable Unity 6000.6.8f1 URP project.' }
    $skills = @{ old = (Get-Item -LiteralPath $BaselineSkill).FullName; new = (Get-Item -LiteralPath $UpdatedSkill).FullName }
    foreach ($arm in @('old', 'new')) {
        $root = $skills[$arm]
        $entries = Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
            [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') + ' ' + (Get-FileHash -LiteralPath $_.FullName).Hash
        }
        $skills["${arm}Hash"] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($entries -join "`n")))
    }
    $runner = Join-Path $PSScriptRoot 'Invoke-BlindAuthor.ps1'
    $jobs = foreach ($case in $cases) {
        $order = if ([Array]::IndexOf($spec.holdouts, $case) % 2) { 'new', 'old' } else { 'old', 'new' }
        foreach ($arm in $order) { @{ case = $case; arm = $arm } }
    }
    $outcomes = @($jobs | ForEach-Object -Parallel {
        $case = $_.case
        $arm = $_.arm
        $path = Join-Path $using:results "runs/$($case.id)/$arm"
        $state = Join-Path $path 'run.json'
        $failure = "${path}-error.txt"
        $lock = $null
        try {
            $parent = Split-Path -Parent $path
            [void][IO.Directory]::CreateDirectory($parent)
            $lock = [IO.File]::Open((Join-Path $parent "$arm.lock"), 'OpenOrCreate', 'ReadWrite', 'None')
            $skill = ($using:skills)[$arm]
            $inputPath = Join-Path $parent "$arm-inputs.json"
            $inputs = [ordered]@{
                case = $case; model = $using:Model; effort = $using:Effort; project = $using:project
                skillHash = ($using:skills)["${arm}Hash"]
            } | ConvertTo-Json -Depth 10 -Compress
            if (Test-Path -LiteralPath $inputPath) {
                if ((Get-Content -LiteralPath $inputPath -Raw).Trim() -cne $inputs) {
                    throw 'Authoring inputs changed. Use a new results directory.'
                }
            } else { $inputs | Set-Content -LiteralPath $inputPath }
            if (Test-Path -LiteralPath $state) {
                & $using:runner Resume -Output $path | Out-Null
            } else {
                $brief = @{
                    mode = $case.mode
                    attachment = @{ anchor = 'At the provided actor origin or moving anchor.'; orientation = $case.orientation }
                }
                & $using:runner Run -Output $path -Project $using:project -SkillPath $skill -Model $using:Model -Effort $using:Effort `
                    -Brief "Actor width is $($case.actorWidth) Unity units. $($case.brief)" `
                    -CaptureJson ($case.capture | ConvertTo-Json -Compress) -GameplayBriefJson ($brief | ConvertTo-Json -Compress) `
                    -DraftFeedback Measured -DraftSampleFrames $case.frames | Out-Null
            }
            if (Test-Path -LiteralPath $failure -PathType Leaf) { Remove-Item -LiteralPath $failure }
            [pscustomobject]@{ id = $case.id; arm = $arm; ok = $true; error = '' }
        } catch {
            if ($lock) { $_.Exception.Message | Set-Content -LiteralPath $failure }
            [pscustomobject]@{ id = $case.id; arm = $arm; ok = $false; error = $_.Exception.Message }
        } finally {
            if ($lock) { $lock.Dispose() }
        }
    } -ThrottleLimit $Throttle)
    $outcomes | Sort-Object id, arm
    if ($outcomes | Where-Object { !$_.ok }) { throw 'Some authors did not export a prefab. See the reported run errors.' }
    return
}

if ($Stage -eq 'Capture') {
    if (!$UnityProject) { throw 'Capture needs -UnityProject.' }
    $project = (Get-Item -LiteralPath $UnityProject).FullName
    $folder = Join-Path $results 'gameplay'
    $items = @(if ($PilotBatch) {
        $batch = Get-Content -LiteralPath $PilotBatch -Raw | ConvertFrom-Json -AsHashtable
        foreach ($case in $spec.training) {
            $row = $batch.items | Where-Object { $_.id -eq "$($case.id)-final" -and $_.status -eq 'succeeded' }
            if (!$row) { throw "Build the sample '$($case.id)-final' first." }
            $frames = @(
                switch ($case.id) {
                    'verdigris-arc' { 4; 7; 11; 15; 25; 43 }
                    'saffron-front' { 5; 9; 17; 26; 43; 58 }
                    'prism-dart' { 10; 18; 36; 54; 62; 69 }
                }
            )
            @{ label = $case.id; effect = $row.effect; actorWidth = $case.actorWidth; eventTime = $case.eventTime; frames = $frames } + $case.capture
        }
    } else {
        foreach ($case in $cases) {
            $key = Join-Path $results "runs/$($case.id)/review-key.json"
            if (!(Test-Path -LiteralPath $key -PathType Leaf)) {
                Write-Warning "Waiting for two exported prefabs for '$($case.id)'."
                continue
            }
            $order = (Get-Content -LiteralPath $key -Raw | ConvertFrom-Json -AsHashtable).order
            foreach ($side in 0, 1) {
                $label = if ($side -eq 0) { 'A' } else { 'B' }
                $run = Get-Content -LiteralPath (Join-Path $results "runs/$($case.id)/$($order[$side])/run.json") -Raw | ConvertFrom-Json -AsHashtable
                if ($run.project -ne $project) { throw "Use the same project used to build '$($case.id)'." }
                @{
                    label = "$($case.id)/$label"; effect = $run.final.receipt.effect
                    actorWidth = $case.actorWidth; eventTime = $case.eventTime; frames = $case.frames
                } + $case.capture
            }
        }
    })
    if (!$items.Count) { throw 'There are no exported effects ready for Play Mode.' }
    foreach ($item in $items) {
        if (!(Test-Path -LiteralPath $item.effect -PathType Leaf)) { throw "Missing effect handoff for '$($item.label)'." }
    }
    [void][IO.Directory]::CreateDirectory($folder)
    $inputPath = Join-Path $results "gameplay-$([guid]::NewGuid().ToString('N')).json"
    @{ artDirection = $items; gameplayOutput = $folder } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $inputPath
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'UnitySlot.ps1')
    $slot = Wait-VfxUnitySlot
    $editorDirectory = Join-Path $project "Assets/Editor/VfxArtDirection-$([guid]::NewGuid().ToString('N'))"
    $fixture = Join-Path $editorDirectory 'EffectBriefPlayCheck.cs'
    try {
        [void][IO.Directory]::CreateDirectory($editorDirectory)
        Copy-Item -LiteralPath (Join-Path $repo 'tests/EffectBriefPlayCheck.cs') -Destination $fixture
        $log = [IO.Path]::ChangeExtension($inputPath, '.log')
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Item -LiteralPath $Editor).FullName)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        foreach ($argument in @('-batchmode', '-projectPath', $project, '-executeMethod', 'EffectBriefPlayCheck.Run',
            '-vfxPlayCheck', $inputPath, '-logFile', $log)) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        try {
            if (!$process.WaitForExit(360000)) {
                $process.Kill($true)
                $process.WaitForExit()
                throw "Play Mode timed out. See '$log'."
            }
            if ($process.ExitCode -ne 0 -or !(Select-String -LiteralPath $log -SimpleMatch 'Art direction Play Mode captures saved.' -Quiet)) {
                throw "Play Mode failed. See '$log'."
            }
        } finally { $process.Dispose() }
        Get-Item -LiteralPath $folder
    } finally {
        try {
            foreach ($path in @($fixture, "$fixture.meta", "$editorDirectory.meta")) {
                if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path }
            }
            if ((Test-Path -LiteralPath $editorDirectory) -and !(Get-ChildItem -LiteralPath $editorDirectory -Force)) {
                [IO.Directory]::Delete($editorDirectory)
            }
        } finally { $slot.Dispose() }
    }
    return
}

if ($Stage -eq 'Review') {
    $ffmpeg = (Get-Command ffmpeg -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    foreach ($case in $cases) {
        $id = $case.id
        $runs = @{}
        foreach ($arm in @('old', 'new')) {
            $path = Join-Path $results "runs/$id/$arm/run.json"
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $runs[$arm] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            }
        }
        if ($runs.Count -ne 2 -or @($runs.Values | Where-Object {
            $_.status -ne 'complete' -or !(Test-Path -LiteralPath $_.prefab -PathType Leaf)
        }).Count) {
            Write-Warning "Waiting for two exported prefabs for '$id'."
            continue
        }
        $folder = Join-Path $results "blind-review/$id"
        $key = Join-Path $results "runs/$id/review-key.json"
        if (Test-Path -LiteralPath $key -PathType Leaf) {
            $order = (Get-Content -LiteralPath $key -Raw | ConvertFrom-Json -AsHashtable).order
        } else {
            $order = @('old', 'new') | Get-Random -Count 2
            @{ order = $order } | ConvertTo-Json -Compress | Set-Content -LiteralPath $key
        }
        $pairs = @($runs[$order[0]].capture, $runs[$order[1]].capture)
        & (Join-Path $PSScriptRoot 'New-CorpusContactSheet.ps1') -Capture $pairs -Label A,B -Frame $case.frames -Cell 256 `
            -Output (Join-Path $folder 'contact-sheet.png')
        $gameplay = Join-Path $results "gameplay/$id"
        $playback = @{}
        foreach ($label in 'A', 'B') {
            $report = Join-Path $gameplay "$label/playback.json"
            if (Test-Path -LiteralPath $report -PathType Leaf) {
                $playback[$label] = (Get-Content -LiteralPath $report -Raw | ConvertFrom-Json -AsHashtable).plays
            }
        }
        $motion = $pairs
        if ($playback.Count -eq 2) {
            foreach ($context in 'dark', 'light', 'overlap') {
                $paths = @((Join-Path $gameplay "A/$context"), (Join-Path $gameplay "B/$context"))
                & (Join-Path $PSScriptRoot 'New-CorpusContactSheet.ps1') -Capture $paths -Label A,B -Frame $case.frames `
                    -Cell 256 -Output (Join-Path $folder "$context.png")
                if ($context -eq 'dark') { $motion = $paths }
            }
            $playback | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'playback.json')
        }
        $video = Join-Path $folder 'motion.mp4'
        & $ffmpeg -v error -y -framerate $case.capture.fps -i (Join-Path $motion[0] 'frame-%04d.png') `
            -framerate $case.capture.fps -i (Join-Path $motion[1] 'frame-%04d.png') `
            -filter_complex 'hstack' -map_metadata -1 -pix_fmt yuv420p $video
        if ($LASTEXITCODE) { throw "Could not encode '$id'." }
        @"
# $id

$($case.brief)

Actor width is $($case.actorWidth) units. Primary check is $($case.critical)

Watch motion.mp4 at speed. A is on the left. Use the contact sheets to cite a time. The light and overlap sheets and playback.json are from Play Mode when available. Judge event readability, silhouette, rhythm and style cohesion independently. Mark a critical failure for a candidate that materially misrepresents the event, direction or gameplay footprint. Check release against the Play Mode evidence.

Write verdict.json with preference A, B or tie, criticalFailures as an array containing any failing labels, and notes covering the four review criteria.
"@ | Set-Content -LiteralPath (Join-Path $folder 'brief.md')
    }
    return
}

if ($CaseId) { throw 'Summarize scores the complete holdout set.' }
$exports = @{}
foreach ($case in $cases) {
    $exports[$case.id] = @(foreach ($arm in 'old', 'new') {
        $path = Join-Path $results "runs/$($case.id)/$arm/run.json"
        $errorPath = Join-Path $results "runs/$($case.id)/${arm}-error.txt"
        $run = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable }
        [ordered]@{
            arm = $arm; status = if ($run) { $run.status } else { 'not-started' }
            exported = $run -and $run.status -eq 'complete' -and (Test-Path -LiteralPath $run.prefab -PathType Leaf)
            error = if (Test-Path -LiteralPath $errorPath -PathType Leaf) { (Get-Content -LiteralPath $errorPath -Raw).Trim() }
        }
    })
}
$scores = @(foreach ($case in $cases) {
    $id = $case.id
    $key = Join-Path $results "runs/$id/review-key.json"
    $path = Join-Path $results "blind-review/$id/verdict.json"
    if (!(Test-Path -LiteralPath $key) -or !(Test-Path -LiteralPath $path) -or
        @($exports[$id] | Where-Object { !$_.exported }).Count) { continue }
    $order = (Get-Content -LiteralPath $key -Raw | ConvertFrom-Json -AsHashtable).order
    $playbackPath = Join-Path $results "blind-review/$id/playback.json"
    if (!(Test-Path -LiteralPath $playbackPath -PathType Leaf)) { continue }
    $vote = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($vote['preference'] -cnotin @('A', 'B', 'tie') -or $vote['criticalFailures'] -isnot [array] -or
        @($vote.criticalFailures | Where-Object { $_ -cnotin @('A', 'B') }).Count -or [string]::IsNullOrWhiteSpace($vote['notes'])) {
        throw "Invalid or incomplete verdict for '$id'."
    }
    $updatedLabel = if ($order[0] -eq 'new') { 'A' } else { 'B' }
    $plays = (Get-Content -LiteralPath $playbackPath -Raw | ConvertFrom-Json -AsHashtable)[$updatedLabel]
    $playbackPassed = $plays.Count -eq 5 -and @($plays | Where-Object { !$_.resetClean -or !$_.played -or !$_.cleared }).Count -eq 0
    [ordered]@{
        id = $id; preference = if ($vote.preference -eq 'tie') { 'tie' } elseif ($vote.preference -eq $updatedLabel) { 'new' } else { 'old' }
        criticalUpdated = $vote.criticalFailures -ccontains $updatedLabel; playbackPassed = $playbackPassed; notes = $vote.notes
    }
})
$wins = @($scores | Where-Object preference -eq 'new').Count
$critical = @($scores | Where-Object criticalUpdated).Count
$reviewedIds = @($scores | ForEach-Object { $_.id })
$summary = [ordered]@{
    exportedPairs = @($cases | Where-Object { @($exports[$_.id] | Where-Object exported).Count -eq 2 }).Count
    reviewed = $scores.Count; expected = $cases.Count; newWins = $wins; criticalUpdated = $critical
    passed = $scores.Count -eq $cases.Count -and $wins -ge 4 -and $critical -eq 0 -and
        @($scores | Where-Object { !$_.playbackPassed }).Count -eq 0
    cases = $scores
    pending = @(foreach ($case in $cases | Where-Object { $_.id -notin $reviewedIds }) {
        [ordered]@{ id = $case.id; runs = $exports[$case.id] }
    })
}
[void][IO.Directory]::CreateDirectory($results)
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $results 'art-direction.json')
[pscustomobject]$summary
