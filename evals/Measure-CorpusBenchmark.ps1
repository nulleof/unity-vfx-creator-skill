[CmdletBinding()]
param(
    [ValidateSet('Compare', 'Summarize')][string]$Stage = 'Summarize',
    [Parameter(Mandatory)][string]$ResultsRoot,
    [string]$Manifest = (Join-Path $PSScriptRoot 'corpus-holdouts.json'),
    [string]$Project,
    [string[]]$CaseId,
    [switch]$Calibration
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'UnitySlot.ps1')
$results = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsRoot)
$pipeline = Join-Path (Split-Path -Parent $PSScriptRoot) 'vfx-creator/scripts/vfx.ps1'
$allCases = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json -AsHashtable)
$cases = if ($CaseId) { @($allCases | Where-Object id -In $CaseId) } else { $allCases }
if (!$cases.Count) { throw 'No cases were selected.' }

function Read-Json([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
}

$assignments = @{}
if ($Calibration) {
    $assignmentPath = Join-Path $results 'calibration-labels.json'
    $assignments = Read-Json $assignmentPath
    if (!$assignments -and $Stage -eq 'Compare') {
        $ids = @($allCases | ForEach-Object id | Get-Random -Shuffle)
        $assignments = @{}
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $assignments[$ids[$i]] = if ($i % 2) { 'new' } else { 'old' }
        }
        [void][IO.Directory]::CreateDirectory($results)
        $temporary = "$assignmentPath.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            $assignments | ConvertTo-Json | Set-Content -LiteralPath $temporary
            [IO.File]::Move($temporary, $assignmentPath)
        } catch [IO.IOException] {
            $assignments = Read-Json $assignmentPath
            if (!$assignments) { throw }
        } finally {
            [IO.File]::Delete($temporary)
        }
    }
    if (!$assignments) { throw 'Run Calibration Compare first to assign the review labels.' }
    foreach ($case in $allCases) {
        if ($assignments[$case.id] -cnotin @('old', 'new') -or !$case['calibration']) {
            throw "Calibration manifest or label assignment is missing data for '$($case.id)'."
        }
    }
}

function Get-Median([double[]]$Values) {
    $sorted = @($Values | Sort-Object)
    if (!$sorted.Count) { return $null }
    $half = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return $sorted[$half] }
    return ($sorted[$half - 1] + $sorted[$half]) / 2
}

function Get-CaptureStatus($Capture) {
    if (!$Capture) { return 'pending' }
    if ($Capture.visibleFrames -le 0) { return 'invisible' }
    if ($Capture.clippedFrames -gt 0) { return 'clipped' }
    return 'valid'
}

function Get-RunResources($Run) {
    if (!$Run) { return $null }
    $phases = @($Run['draft'], $Run['final'] | Where-Object { $_ })
    $external = @($phases | ForEach-Object { $_['author'] } | Where-Object { $_ -and $_['mode'] -eq 'external' })
    $attempts = @($Run['cliAttempts'] | Where-Object { $_ }) + $external
    $usage = @($attempts | ForEach-Object { $_['usage'] } | Where-Object { $_ })
    $tokens = [ordered]@{}
    foreach ($key in @('input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens')) {
        $values = @($usage | ForEach-Object { $_[$key] } | Where-Object { $null -ne $_ })
        $tokens[$key] = if ($values.Count) { ($values | Measure-Object -Sum).Sum }
    }
    $buildSeconds = @($phases | ForEach-Object { $_['buildSeconds'] } | Where-Object { $null -ne $_ })
    $waitSeconds = @($phases | ForEach-Object { $_['unityWaitSeconds'] } | Where-Object { $null -ne $_ })
    [ordered]@{
        wallSeconds = $Run['elapsedSeconds']
        authorSeconds = if ($attempts.Count) { ($attempts | ForEach-Object { $_.seconds } | Measure-Object -Sum).Sum }
        buildSeconds = if ($buildSeconds.Count) { ($buildSeconds | Measure-Object -Sum).Sum }
        unityWaitSeconds = if ($waitSeconds.Count) { ($waitSeconds | Measure-Object -Sum).Sum }
        externalTurns = $external.Count
        measuredTurns = $usage.Count
        tokens = $tokens
    }
}

function Get-CalibrationError($Comparison, $Case, [int]$Size) {
    $timeline = $Comparison.timeline
    switch ($Case.calibration.metric) {
        'peakArea' {
            $frame = $Comparison.referencePeak
            if ($frame -lt 0) { throw "Reference '$($Case.id)' has no peak." }
            return [Math]::Abs($timeline[$frame].candidate.area - $timeline[$frame].reference.area)
        }
        'trajectory' {
            $frames = @($Case.calibration.times | ForEach-Object { [int][Math]::Round($_ * $Comparison.fps) })
            if (!$frames.Count) { throw "Reference '$($Case.id)' has no trajectory samples." }
            $squaredError = 0.0
            foreach ($frame in $frames) {
                if ($frame -lt 0 -or $frame -ge $timeline.Count -or !$timeline[$frame].reference.area) {
                    throw "Reference '$($Case.id)' has no foreground for trajectory sample $frame."
                }
                $reference = $timeline[$frame].reference
                $candidate = $timeline[$frame].candidate
                if (!$reference.Contains('centerX') -or !$candidate.Contains('centerX')) {
                    throw "Calibration trajectory needs a comparison with centroid data for '$($Case.id)'."
                }
                if ($candidate.area) {
                    $dx = $candidate.centerX - $reference.centerX
                    $dy = $candidate.centerY - $reference.centerY
                    $squaredError += $dx * $dx + $dy * $dy
                } else {
                    $squaredError += 2.0 * $Size * $Size
                }
            }
            return [Math]::Sqrt($squaredError / $frames.Count)
        }
        'steadyArea' {
            $reference = Get-Timing $Comparison $Case reference
            $candidate = Get-Timing $Comparison $Case candidate
            if (!$reference['steadyVisible']) { throw "Reference '$($Case.id)' has no visible steady phase." }
            return [Math]::Abs($candidate.steadyArea - $reference.steadyArea)
        }
        default { throw "Unknown calibration metric for '$($Case.id)'." }
    }
}

function Get-Timing($Comparison, $Case, [string]$Side) {
    $areas = @($Comparison.timeline | ForEach-Object { $_[$Side].area })
    $timing = [ordered]@{
        onset = $Comparison["${Side}Onset"]
        peak = $Comparison["${Side}Peak"]
        end = $Comparison["${Side}End"]
    }
    if ($null -ne $Case['steadyAfter']) {
        $start = [int][Math]::Ceiling($Case['steadyAfter'] * $Comparison.fps)
        if ($start -ge $areas.Count) { throw "Steady-state onset is outside capture for '$($Case.id)'." }
        $steady = @($areas[$start..($areas.Count - 1)])
        $timing.steadyVisible = @($steady | Where-Object { $_ -gt 0 }).Count / $steady.Count
        $timing.steadyArea = Get-Median $steady
    }
    if ($Case['beats']) {
        $timing.beats = @(foreach ($beat in $Case['beats']) {
            $start = [int][Math]::Ceiling($beat.start * $Comparison.fps)
            $end = [Math]::Min($areas.Count - 1, [int][Math]::Floor($beat.end * $Comparison.fps))
            if ($start -lt 0 -or $start -gt $end) { throw "Invalid beat window for '$($Case.id)'." }
            $peakArea = 0
            $onset = $peak = $last = $null
            for ($frame = $start; $frame -le $end; $frame++) {
                if ($areas[$frame] -le 0) { continue }
                if ($null -eq $onset) { $onset = $frame }
                $last = $frame
                if ($areas[$frame] -gt $peakArea) {
                    $peak = $frame
                    $peakArea = $areas[$frame]
                }
            }
            [ordered]@{ onset = $onset; peak = $peak; end = $last }
        })
    }
    return $timing
}

$rows = @(foreach ($case in $cases) {
    $id = $case.id
    $caseIndex = [Array]::IndexOf($allCases, $case)
    $oldAtA = if ($Calibration) { $assignments[$id] -eq 'old' } else { $caseIndex % 2 -eq 0 }
    $versions = if ($oldAtA) { [ordered]@{ A = 'old'; B = 'new' } } else { [ordered]@{ A = 'new'; B = 'old' } }
    $reference = Join-Path $results "references/$id"
    $refManifest = Read-Json (Join-Path $reference 'capture.json')
    $refStatus = Get-CaptureStatus $refManifest
    $captures = @{}
    foreach ($label in $versions.Keys) {
        $version = $versions[$label]
        $run = Read-Json (Join-Path $results "runs/$id/$version/run.json")
        $directory = if ($run -and $run['final'] -and $run['final']['receipt']) { $run['final']['receipt']['capture'] }
        $manifestData = if ($directory) { Read-Json (Join-Path $directory 'capture.json') }
        $captures[$label] = [ordered]@{ directory = $directory; status = (Get-CaptureStatus $manifestData); run = $run }
    }
    $reviewRoot = Join-Path $results "review/$id"
    $reviewPacket = if ($Calibration) { Join-Path $results "blind-review/$id" } else { $reviewRoot }
    $valid = $refStatus -eq 'valid' -and $captures.A.status -eq 'valid' -and $captures.B.status -eq 'valid'
    $metrics = @{}
    $comparison = $null
    foreach ($label in $versions.Keys) {
        if (!$valid) { continue }
        $comparisonRoot = Join-Path $reviewRoot $label
        $comparisonFile = Join-Path $comparisonRoot 'comparison.json'
        if ($Stage -eq 'Compare' -and !(Test-Path -LiteralPath $comparisonFile -PathType Leaf)) {
            if (!$Project) { throw 'Compare requires -Project.' }
            $lock = Wait-VfxUnitySlot
            try {
                & $pipeline Compare -Project $Project -Reference $reference -Candidate $captures[$label].directory `
                    -Output $comparisonRoot -Work (Join-Path $results 'compare-runs') | Out-Null
            } finally { $lock.Dispose() }
        }
        $comparison = Read-Json $comparisonFile
        if ($comparison) {
            $metrics[$versions[$label]] = [ordered]@{
                foregroundIoU = $comparison.foregroundIoU
                colorError = $comparison.meanColorError
                referenceTiming = Get-Timing $comparison $case 'reference'
                candidateTiming = Get-Timing $comparison $case 'candidate'
            }
            if ($Calibration) {
                $metrics[$versions[$label]].calibrationError = Get-CalibrationError $comparison $case $refManifest.settings.size
            }
        }
    }
    if ($Stage -eq 'Compare' -and $metrics.Count -eq 2) {
        $reviewFrames = @(0, 0.05, 0.15, 0.35, 0.65, 0.9 | ForEach-Object {
            [int][Math]::Round($_ * ($comparison.frames - 1))
        })
        $reviewFrames += @($metrics.old.referenceTiming.peak, $metrics.old.candidateTiming.peak, $metrics.new.candidateTiming.peak)
        if ($Calibration -and $case.calibration['times']) {
            $reviewFrames += @($case.calibration.times | ForEach-Object { [int][Math]::Round($_ * $comparison.fps) })
        }
        $reviewFrames = @($reviewFrames | Where-Object { $_ -ge 0 } | Sort-Object -Unique)
        & (Join-Path $PSScriptRoot 'New-CorpusContactSheet.ps1') `
            -Capture @($reference, $captures.A.directory, $captures.B.directory) -Label @('Reference', 'A', 'B') `
            -Frame $reviewFrames -Output (Join-Path $reviewPacket 'contact-sheet.png') | Out-Null
    }
    $review = Read-Json (Join-Path $reviewPacket 'verdict.json')
    if ($review -and $review['preference'] -cnotin @('A', 'B', 'tie')) { throw "Invalid visual preference for '$id'." }
    $vote = if ($review) { $review['preference'] }
    $preference = if ($vote -eq 'tie') { 'tie' } elseif ($vote) { $versions[$vote] }
    $scored = $valid -and $metrics.Count -eq 2
    $oldLabel = if ($versions.A -eq 'old') { 'A' } else { 'B' }
    $newLabel = if ($oldLabel -eq 'A') { 'B' } else { 'A' }
    $row = [ordered]@{
        id = $id
        reference = $refStatus
        oldCapture = $captures[$oldLabel].status
        newCapture = $captures[$newLabel].status
        exported = $null -ne $captures.A.directory -and $null -ne $captures.B.directory
        scored = $scored
        metrics = $metrics
        iouGain = if ($scored) { $metrics.new.foregroundIoU - $metrics.old.foregroundIoU }
        colorErrorChange = if ($scored) { $metrics.new.colorError - $metrics.old.colorError }
        preference = $preference
        reviewNotes = if ($review) { $review['notes'] }
        resources = [ordered]@{ old = Get-RunResources $captures[$oldLabel].run; new = Get-RunResources $captures[$newLabel].run }
    }
    if ($Calibration) {
        $row.rehearsal = [bool]$case['rehearsal']
        $row.calibrationMetric = $case.calibration.metric
        $row.calibrationGain = if ($scored) { $metrics.old.calibrationError - $metrics.new.calibrationError }
        $row.calibrationWin = $scored -and $preference -eq 'new' -and $row.calibrationGain -gt 0
    }
    $row
})
$scoredRows = @($rows | Where-Object { $_.scored })
$reviewed = @($scoredRows | Where-Object { $_.preference })
$newWins = @($reviewed | Where-Object { $_.preference -eq 'new' }).Count
$iouGain = Get-Median @($scoredRows | ForEach-Object iouGain)
$colorChange = Get-Median @($scoredRows | ForEach-Object colorErrorChange)
$totalResources = [ordered]@{}
foreach ($version in @('old', 'new')) {
    $runs = @($rows | ForEach-Object { $_.resources[$version] } | Where-Object { $_ })
    $totals = [ordered]@{ measuredTurns = ($runs | ForEach-Object measuredTurns | Measure-Object -Sum).Sum }
    $totals.externalTurns = ($runs | ForEach-Object externalTurns | Measure-Object -Sum).Sum
    foreach ($key in @('input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens')) {
        $values = @($runs | ForEach-Object { $_.tokens[$key] } | Where-Object { $null -ne $_ })
        $totals[$key] = if ($values.Count) { ($values | Measure-Object -Sum).Sum }
    }
    $totals.medianAuthorSeconds = Get-Median @($runs | ForEach-Object authorSeconds | Where-Object { $null -ne $_ })
    foreach ($key in @('authorSeconds', 'buildSeconds', 'unityWaitSeconds')) {
        $values = @($runs | ForEach-Object { $_[$key] } | Where-Object { $null -ne $_ })
        $totals[$key] = if ($values.Count) { ($values | Measure-Object -Sum).Sum }
    }
    $totalResources[$version] = $totals
}
$summary = [ordered]@{
    complete = $scoredRows.Count -eq $allCases.Count -and $reviewed.Count -eq $allCases.Count
    exportedPairs = @($rows | Where-Object { $_.exported }).Count
    comparable = $scoredRows.Count
    reviewed = $reviewed.Count
    newWins = $newWins
    medianIouGain = $iouGain
    medianColorErrorChange = $colorChange
    resources = $totalResources
    cases = $rows
}
$summary.passed = $summary.complete -and $newWins -ge 4 -and $iouGain -ge 0.05 -and $colorChange -le 0.02
$summaryFile = 'benchmark.json'
if ($Calibration) {
    $holdouts = @($allCases | Where-Object { !$_['rehearsal'] })
    $holdoutRows = @($rows | Where-Object { !$_.rehearsal })
    $summary.complete = $holdouts.Count -eq 3 -and @($holdoutRows | Where-Object { $_.scored -and $_.preference }).Count -eq 3
    $summary.holdoutComparable = @($holdoutRows | Where-Object scored).Count
    $summary.holdoutReviewed = @($holdoutRows | Where-Object { $_.scored -and $_.preference }).Count
    $summary.calibrationWins = @($holdoutRows | Where-Object calibrationWin).Count
    $summary.passed = $summary.complete -and $summary.calibrationWins -ge 2
    $summaryFile = 'calibration.json'
}
[void][IO.Directory]::CreateDirectory($results)
$summary | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $results $summaryFile)
[pscustomobject]$summary
