[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResultsRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$reports = Join-Path $ResultsRoot 'reports'
$cases = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'accuracy-cases.json') -Raw | ConvertFrom-Json

function Get-AreaPeak([int[]]$Areas, [int]$Start, [int]$End) {
    $peak = -1
    $largest = 0
    for ($frame = $Start; $frame -le $End; $frame++) {
        if ($Areas[$frame] -le $largest) { continue }
        $largest = $Areas[$frame]
        $peak = $frame
    }
    return $peak
}

function Get-Median([int[]]$Values) {
    $sorted = @($Values | Sort-Object)
    $left = [int][math]::Floor(($sorted.Count - 1) / 2)
    $right = [int][math]::Floor($sorted.Count / 2)
    return ($sorted[$left] + $sorted[$right]) / 2
}

function Read-Comparison($Case, [string]$Version) {
    $path = Join-Path $reports "$Version-$($Case.id)/comparison.json"
    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $refAreas = @($data.timeline.reference.area)
    $areas = @($data.timeline.candidate.area)
    $metrics = [ordered]@{
        iou = [double]$data.foregroundIoU
        colorError = [double]$data.meanColorError
    }
    if ($Case.id -eq 'teleport') {
        $split = $Case.events[1].frame
        $refPeaks = @((Get-AreaPeak $refAreas 0 ($split - 1)), (Get-AreaPeak $refAreas $split ($data.frames - 1)))
        $peaks = @((Get-AreaPeak $areas 0 ($split - 1)), (Get-AreaPeak $areas $split ($data.frames - 1)))
        $deltas = @(for ($beat = 0; $beat -lt $refPeaks.Count; $beat++) {
            if ($refPeaks[$beat] -lt 0 -or $peaks[$beat] -lt 0) { $null }
            else { [math]::Abs($refPeaks[$beat] - $peaks[$beat]) }
        })
        $gap = $peaks[0] -ge 0 -and $peaks[1] -gt $peaks[0] -and 0 -in $areas[$peaks[0]..$peaks[1]]
        $metrics.referencePeaks = $refPeaks
        $metrics.peaks = $peaks
        $metrics.peakDeltas = $deltas
        $metrics.quietGap = $gap
        $metrics.behaviorPassed = $gap -and $null -notin $deltas -and $deltas[0] -le 3 -and $deltas[1] -le 3
    } else {
        $afterBuildup = $data.fps..($data.frames - 1)
        $steady = $areas[$afterBuildup]
        $steadyReference = Get-Median $refAreas[$afterBuildup]
        $steadyMedian = Get-Median $steady
        $coverage = @($steady | Where-Object { $_ -gt 0 }).Count / $steady.Count
        $relativeError = if ($steadyReference -gt 0) { [math]::Abs($steadyMedian - $steadyReference) / $steadyReference }
        $metrics.visibleCoverage = $coverage
        $metrics.referenceMedianArea = $steadyReference
        $metrics.medianArea = $steadyMedian
        $metrics.medianAreaError = $relativeError
        $metrics.behaviorPassed = $coverage -ge 0.95 -and $null -ne $relativeError -and $relativeError -le 0.20
    }
    return $metrics
}

function Format-Behavior($Metrics, [string]$Id) {
    if ($Id -eq 'teleport') {
        $deltas = @($Metrics.peakDeltas | ForEach-Object { if ($null -eq $_) { 'missing' } else { $_ } })
        return "Peak frame errors $($deltas -join ' / ') · quiet gap $($Metrics.quietGap)"
    }
    $errorText = if ($null -eq $Metrics.medianAreaError) { 'unavailable' } else { '{0:P1}' -f $Metrics.medianAreaError }
    return 'Visible after startup {0:P1} · median area {1} px vs {2} px · area error {3}' -f
        $Metrics.visibleCoverage, $Metrics.medianArea, $Metrics.referenceMedianArea, $errorText
}

$results = @(foreach ($case in $cases) {
    $old = Read-Comparison $case 'old'
    $new = Read-Comparison $case 'new'
    $guidedPath = Join-Path $reports "guided-$($case.id)/comparison.json"
    $guided = if (Test-Path -LiteralPath $guidedPath) { Read-Comparison $case 'guided' }
    $gain = $new.iou - $old.iou
    $colorChange = $new.colorError - $old.colorError
    [ordered]@{
        id = $case.id
        title = $case.title
        old = $old
        new = $new
        guided = $guided
        iouGain = $gain
        colorErrorChange = $colorChange
        passed = $gain -ge 0.05 -and $colorChange -le 0.02 -and $new.behaviorPassed
    }
})
$results | ConvertTo-Json -Depth 6 -AsArray | Set-Content -LiteralPath (Join-Path $reports 'accuracy.json')
$rows = foreach ($result in $results) {
    $id = $result.id
    $title = [System.Net.WebUtility]::HtmlEncode($result.title)
    $status = if ($result.passed) { 'Met numeric targets' } else { 'Missed numeric targets' }
    foreach ($version in @('old', 'new', 'guided')) {
        $data = $result[$version]
        if ($null -eq $data) { continue }
        $label = switch ($version) {
            'old' { 'Baseline' }
            'new' { 'Updated skill' }
            'guided' { 'After visual review' }
        }
        $iou = '{0:P1}' -f $data.iou
        $color = '{0:P1}' -f $data.colorError
        $behavior = Format-Behavior $data $id
        "<tr><th>$title</th><td><a href='$version-$id/index.html'>$label</a></td><td>$iou</td><td>$color</td><td>$behavior</td><td>$(if ($version -eq 'new') { $status })</td></tr>"
    }
}
@"
<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>VFX Creator accuracy comparison</title>
<style>
body{margin:3rem auto;max-width:1150px;padding:0 1rem;background:#141722;color:#ebeef6;font:16px system-ui}
table{width:100%;border-collapse:collapse} th,td{padding:.75rem;text-align:left;border-bottom:1px solid #394052}
a{color:#88ddf4} thead th{border-bottom:2px solid #687084}
</style>
<h1>VFX Creator accuracy comparison</h1>
<table><thead><tr><th>Effect</th><th>Skill</th><th>Foreground IoU</th><th>Color error</th><th>Timing and coverage</th><th>Target</th></tr></thead>
<tbody>$($rows -join [Environment]::NewLine)</tbody></table>
</html>
"@ | Set-Content -LiteralPath (Join-Path $reports 'index.html')
$results
