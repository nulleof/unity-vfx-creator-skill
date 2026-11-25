[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Reference', 'Candidate', 'Review', 'Variant')][string]$Stage,
    [string]$ReferenceProject,
    [string]$CleanProject,
    [string]$SourceRoot,
    [string]$ResultsRoot,
    [string[]]$CaseId,
    [switch]$FreshCodex,
    [int]$Size = 256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$repo = Split-Path -Parent $PSScriptRoot
$skill = Join-Path $repo 'vfx-creator'
$pipeline = Join-Path $skill 'scripts/vfx.ps1'
if (!$ResultsRoot) { $ResultsRoot = Join-Path $repo '.vfx-work/eval' }
$results = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsRoot)
$cases = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'cases.json') -Raw | ConvertFrom-Json -AsHashtable
if ($CaseId) { $cases = @($cases | Where-Object id -In $CaseId) }
if (!$cases.Count) { throw 'No cases were selected.' }
if ($Stage -eq 'Reference' -and (!$SourceRoot -or !$ReferenceProject)) { throw 'Reference needs -ReferenceProject and -SourceRoot.' }
if ($Stage -eq 'Review' -and !$ReferenceProject) { throw 'Review needs -ReferenceProject.' }
if ($Stage -in @('Candidate', 'Variant') -and !$CleanProject) { throw "$Stage needs -CleanProject." }

if ($Stage -in @('Candidate', 'Variant')) {
    $project = (Get-Item -LiteralPath $CleanProject).FullName
    $installed = Join-Path $project '.agents/skills/vfx-creator'
    if (!(Test-Path -LiteralPath $installed)) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $installed))
        Copy-Item -LiteralPath $skill -Destination $installed -Recurse
    }
    $installedPipeline = Join-Path $installed 'scripts/vfx.ps1'
}
if ($Stage -eq 'Variant') {
    foreach ($name in @('frost-bolt-draft', 'frost-bolt')) {
        $outputId = $name + '-eval-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        & $installedPipeline Build -Project $project -Recipe (Join-Path $PSScriptRoot "variants/$name.json") -Size $Size `
            -Id $outputId -Framing 4 -Duration 1.2 -RenderAfterBuild -Output (Join-Path $results "variant/$name")
    }
    & $installedPipeline Compare -Project $project -Reference (Join-Path $results 'variant/frost-bolt-draft') `
        -Candidate (Join-Path $results 'variant/frost-bolt') -Output (Join-Path $results 'reports/frost-bolt')
    return
}

$failures = [Collections.Generic.List[string]]::new()
foreach ($case in $cases) {
    $capture = $case.capture
    $id = $case.id
    try {
        if ($Stage -eq 'Reference') {
            $stand = $ReferenceProject
            if ($cases.Count -gt 1) {
                $stand = Join-Path $results "reference-projects/$id"
                if (!(Test-Path -LiteralPath (Join-Path $stand '.vfx-reference'))) {
                    & $pipeline Init -Version '6000.6.8f1' -Project $stand -ReferenceStand | Out-Null
                    $cache = Join-Path $ReferenceProject 'Library/PackageCache'
                    if (Test-Path -LiteralPath $cache -PathType Container) {
                        [void][IO.Directory]::CreateDirectory((Join-Path $stand 'Library'))
                        Copy-Item -LiteralPath $cache -Destination (Join-Path $stand 'Library/PackageCache') -Recurse
                    }
                }
            }
            & $pipeline Learn -Source (Join-Path $SourceRoot $case.package) -Project $stand -Prefab $case.prefab `
                -Brief $case.brief -Title $case.title -Id $id -Work $results -Size $Size @capture `
                -Recipe (Join-Path $results "learned/$id.json") -Output (Join-Path $results "refs/$id")
        }
        elseif ($Stage -eq 'Candidate') {
            # The new authoring process receives the description, installed skill and project only.
            $worker = Join-Path $PSScriptRoot 'Invoke-TextBuild.ps1'
            $agentMode = @()
            if ($FreshCodex) { $agentMode = @('-FreshCodex') }
            $result = & pwsh -NoProfile -NonInteractive -File $worker -Project $project -Pipeline $installedPipeline `
                -Brief $case.brief -Output (Join-Path $results "candidates/$id") -CaptureJson ($capture | ConvertTo-Json -Compress) -Size $Size @agentMode
            $result
            if ($LASTEXITCODE -ne 0) { throw "The isolated text build exited with code $LASTEXITCODE." }
        }
        else {
            $limitFile = Join-Path $PSScriptRoot "limits/$id.json"
            $comparisonArgs = if (Test-Path -LiteralPath $limitFile) { @{ Limits = $limitFile } } else { @{} }
            $result = & $pipeline Compare -Project $ReferenceProject -Reference (Join-Path $results "refs/$id") `
                -Candidate (Join-Path $results "candidates/$id") -Output (Join-Path $results "reports/$id") @comparisonArgs
            $result
            if ($result.hasLimits -and !$result.passedLimits) { throw 'The comparison exceeded approved limits.' }
        }
    }
    catch {
        $failures.Add($id)
        Write-Warning "$id - $($_.Exception.Message)"
    }
}
if ($Stage -eq 'Review') {
    $reportDirectory = Join-Path $results 'reports'
    [void][IO.Directory]::CreateDirectory($reportDirectory)
    $rows = foreach ($case in $cases) {
        $name = [System.Net.WebUtility]::HtmlEncode($case.title)
        if (Test-Path -LiteralPath (Join-Path $reportDirectory "$($case.id)/index.html")) {
            "<li><a href='$($case.id)/index.html'>$name</a></li>"
        } else { "<li>$name (capture pending)</li>" }
    }
    if (Test-Path -LiteralPath (Join-Path $reportDirectory 'frost-bolt/index.html')) {
        $rows += '<li><a href="frost-bolt/index.html">Frost bolt · draft and final</a></li>'
    }
    "<!doctype html><html lang='en'><meta charset='utf-8'><title>VFX Creator</title><h1>VFX Creator comparisons</h1><ul>$($rows -join '')</ul></html>" |
        Set-Content -LiteralPath (Join-Path $reportDirectory 'index.html')
}
if ($failures.Count) { throw "$Stage failed for $($failures -join ', ')." }
