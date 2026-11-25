[CmdletBinding()]
param(
    [ValidateSet('Compare', 'Summarize')][string]$Stage = 'Summarize',
    [Parameter(Mandatory)][string]$ResultsRoot,
    [string]$Manifest = (Join-Path $PSScriptRoot 'corpus-holdouts.json'),
    [string]$Project,
    [string[]]$CaseId
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
    $attempts = @($Run['cliAttempts'] | Where-Object { $_ })
    $usage = @($attempts | ForEach-Object { $_['usage'] } | Where-Object { $_ })
    $tokens = [ordered]@{}
    foreach ($key in @('input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens')) {
        $values = @($usage | ForEach-Object { $_[$key] } | Where-Object { $null -ne $_ })
        $tokens[$key] = if ($values.Count) { ($values | Measure-Object -Sum).Sum }
    }
    [ordered]@{
        wallSeconds = $Run['elapsedSeconds']
        authorSeconds = if ($attempts.Count) { ($attempts | ForEach-Object { $_.seconds } | Measure-Object -Sum).Sum }
        measuredTurns = $usage.Count
        tokens = $tokens
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
    $versions = if ($caseIndex % 2 -eq 0) { [ordered]@{ A = 'old'; B = 'new' } } else { [ordered]@{ A = 'new'; B = 'old' } }
    $reference = Join-Path $results "references/$id"
    $refStatus = Get-CaptureStatus (Read-Json (Join-Path $reference 'capture.json'))
    $captures = @{}
    foreach ($label in $versions.Keys) {
        $version = $versions[$label]
        $run = Read-Json (Join-Path $results "runs/$id/$version/run.json")
        $directory = if ($run -and $run['final'] -and $run['final']['receipt']) { $run['final']['receipt']['capture'] }
        $manifestData = if ($directory) { Read-Json (Join-Path $directory 'capture.json') }
        $captures[$label] = [ordered]@{ directory = $directory; status = (Get-CaptureStatus $manifestData); run = $run }
    }
    $reviewRoot = Join-Path $results "review/$id"
    $valid = $refStatus -eq 'valid' -and $captures.A.status -eq 'valid' -and $captures.B.status -eq 'valid'
    $metrics = @{}
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
        }
    }
    if ($Stage -eq 'Compare' -and $metrics.Count -eq 2) {
        $reviewFrames = @(0, 0.05, 0.15, 0.35, 0.65, 0.9 | ForEach-Object {
            [int][Math]::Round($_ * ($comparison.frames - 1))
        })
        $reviewFrames += @($metrics.old.referenceTiming.peak, $metrics.old.candidateTiming.peak, $metrics.new.candidateTiming.peak)
        $reviewFrames = @($reviewFrames | Where-Object { $_ -ge 0 } | Sort-Object -Unique)
        & (Join-Path $PSScriptRoot 'New-CorpusContactSheet.ps1') `
            -Capture @($reference, $captures.A.directory, $captures.B.directory) -Label @('Reference', 'A', 'B') `
            -Frame $reviewFrames -Output (Join-Path $reviewRoot 'contact-sheet.png') | Out-Null
    }
    $review = Read-Json (Join-Path $reviewRoot 'verdict.json')
    if ($review -and $review['preference'] -cnotin @('A', 'B', 'tie')) { throw "Invalid visual preference for '$id'." }
    $vote = if ($review) { $review['preference'] }
    $preference = if ($vote -eq 'tie') { 'tie' } elseif ($vote) { $versions[$vote] }
    $scored = $valid -and $metrics.Count -eq 2
    $oldLabel = if ($versions.A -eq 'old') { 'A' } else { 'B' }
    $newLabel = if ($oldLabel -eq 'A') { 'B' } else { 'A' }
    [ordered]@{
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
    foreach ($key in @('input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens')) {
        $values = @($runs | ForEach-Object { $_.tokens[$key] } | Where-Object { $null -ne $_ })
        $totals[$key] = if ($values.Count) { ($values | Measure-Object -Sum).Sum }
    }
    $totals.medianAuthorSeconds = Get-Median @($runs | ForEach-Object authorSeconds | Where-Object { $null -ne $_ })
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
[void][IO.Directory]::CreateDirectory($results)
$summary | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $results 'benchmark.json')
[pscustomobject]$summary
