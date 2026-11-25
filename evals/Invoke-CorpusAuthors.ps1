[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResultsRoot,
    [Parameter(Mandatory)][string]$BaselineSkill,
    [string]$UpdatedSkill = (Join-Path (Split-Path -Parent $PSScriptRoot) 'vfx-creator'),
    [string]$Manifest = (Join-Path $PSScriptRoot 'corpus-holdouts.json'),
    [string]$BriefManifest = (Join-Path $PSScriptRoot 'corpus-briefs.json'),
    [string[]]$CaseId,
    [ValidateSet('old', 'new')][string[]]$Version = @('old', 'new'),
    [string]$Model = 'gpt-6.2-sol',
    [ValidateSet('low', 'medium', 'high')][string]$Effort = 'medium',
    [ValidateRange(1, 3)][int]$Throttle = 3
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$results = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsRoot)
$skills = @{ old = (Get-Item -LiteralPath $BaselineSkill).FullName; new = (Get-Item -LiteralPath $UpdatedSkill).FullName }
$runner = Join-Path $PSScriptRoot 'Invoke-BlindAuthor.ps1'
$cases = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json -AsHashtable)
$fingerprints = @{}
foreach ($name in $Version) {
    $root = $skills[$name]
    $entries = @(Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName | ForEach-Object {
        [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') + ' ' + (Get-FileHash -LiteralPath $_.FullName).Hash
    })
    $fingerprints[$name] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($entries -join "`n")))
}
$briefs = @{}
foreach ($entry in (Get-Content -LiteralPath $BriefManifest -Raw | ConvertFrom-Json -AsHashtable)) {
    if ($briefs.ContainsKey($entry.id) -or [string]::IsNullOrWhiteSpace($entry.brief)) { throw 'Briefs must have unique IDs and nonempty text.' }
    $briefs[$entry.id] = $entry.brief.Trim()
}
if ($CaseId) { $cases = @($cases | Where-Object id -In ($CaseId -split ',')) }
if (!$cases.Count) { throw 'No cases were selected.' }

$jobs = @(foreach ($case in $cases) {
    $id = $case.id
    $reference = Join-Path $results "references/$id/capture.json"
    if (!(Test-Path -LiteralPath $reference -PathType Leaf) -or !$briefs.ContainsKey($id)) {
        throw "Case '$id' needs a reference capture and a source-free brief."
    }
    $capture = Get-Content -LiteralPath $reference -Raw | ConvertFrom-Json -AsHashtable
    if (!$capture.visibleFrames -or $capture.clippedFrames) { throw "Unusable reference for '$id'." }
    foreach ($name in $Version) {
        @{
            id = $id; name = $name; skill = $skills[$name]; fingerprint = $fingerprints[$name]; model = $Model; effort = $Effort; runner = $runner
            project = Join-Path $results "author-projects/$id/$name"
            output = Join-Path $results "runs/$id/$name"
            brief = $briefs[$id]
            capture = $capture.settings | ConvertTo-Json -Compress
        }
    }
})

$outcomes = @($jobs | ForEach-Object -Parallel {
    $ErrorActionPreference = 'Stop'
    $run = $_
    $statePath = Join-Path $run.output 'run.json'
    $slot = $null
    try {
        $parent = Split-Path -Parent $run.output
        [void][IO.Directory]::CreateDirectory($parent)
        $slot = [IO.File]::Open((Join-Path $parent "$($run.name).lock"), 'OpenOrCreate', 'ReadWrite', 'None')
        $inputPath = Join-Path $parent "$($run.name)-inputs.json"
        $inputs = [ordered]@{
            skillSha256 = $run.fingerprint; brief = $run.brief; capture = $run.capture
            model = $run.model; effort = $run.effort
        } | ConvertTo-Json -Compress
        if (Test-Path -LiteralPath $inputPath -PathType Leaf) {
            if ((Get-Content -LiteralPath $inputPath -Raw).Trim() -cne $inputs) {
                throw 'The benchmark inputs changed. Use a new results directory.'
            }
        } else { $inputs | Set-Content -LiteralPath $inputPath }
        if (!(Test-Path -LiteralPath (Join-Path $run.project 'ProjectSettings/ProjectVersion.txt'))) {
            & (Join-Path $run.skill 'scripts/vfx.ps1') Init -Project $run.project -Version '6000.6.8f1' | Out-Null
        }
        if (Test-Path -LiteralPath $statePath) {
            & $run.runner Resume -Output $run.output | Out-Null
        } else {
            & $run.runner Run -Output $run.output -Project $run.project -SkillPath $run.skill `
                -Brief $run.brief -CaptureJson $run.capture -Model $run.model -Effort $run.effort | Out-Null
        }
        [pscustomobject]@{ id = $run.id; version = $run.name; ok = $true; error = '' }
    } catch {
        [pscustomobject]@{ id = $run.id; version = $run.name; ok = $false; error = $_.Exception.Message }
    } finally {
        if ($slot) { $slot.Dispose() }
    }
} -ThrottleLimit $Throttle)
$outcomes | Sort-Object id, version
if ($outcomes | Where-Object { !$_.ok }) { throw 'Some blind author runs failed. See the run directories to retry.' }
