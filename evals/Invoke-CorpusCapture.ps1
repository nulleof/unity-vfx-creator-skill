[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$SourceRoot,
    [string]$ResultsRoot,
    [string]$Manifest = (Join-Path $PSScriptRoot 'corpus-holdouts.json'),
    [string[]]$CaseId,
    [ValidateRange(32, 2048)][int]$Size = 256,
    [ValidateRange(1, 180)][int]$TimeoutMinutes = 6
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'UnitySlot.ps1')
$repo = Split-Path -Parent $PSScriptRoot
if (!$ResultsRoot) { $ResultsRoot = Join-Path $repo '.vfx-work/corpus-iteration' }
$results = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsRoot)
$pipeline = Join-Path $repo 'vfx-creator/scripts/vfx.ps1'
. (Join-Path $repo 'vfx-creator/scripts/Archive.ps1')
$sources = (Get-Item -LiteralPath $SourceRoot).FullName
$relativeWork = [IO.Path]::GetRelativePath($sources, $results)
if (![IO.Path]::IsPathRooted($relativeWork) -and $relativeWork -ne '..' -and
    !$relativeWork.StartsWith("..$([IO.Path]::DirectorySeparatorChar)")) {
    throw 'Place reference capture output outside the source package directory.'
}
$stand = (Get-Item -LiteralPath $Project).FullName
$unityVersion = Get-Content -LiteralPath (Join-Path $stand 'ProjectSettings/ProjectVersion.txt') -Raw
$packages = Get-Content -LiteralPath (Join-Path $stand 'Packages/manifest.json') -Raw | ConvertFrom-Json -AsHashtable
if ($unityVersion -notmatch '(?m)^m_EditorVersion: 6000\.6\.8f1\s*$' -or
    !$packages['dependencies']['com.unity.render-pipelines.universal'] -or
    !(Test-Path -LiteralPath (Join-Path $stand '.vfx-reference') -PathType Leaf)) {
    throw 'Corpus captures need a disposable Unity 6000.6.8f1 URP reference stand.'
}
$cases = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json -AsHashtable)
if ($CaseId) { $cases = @($cases | Where-Object id -In ($CaseId -split ',')) }
if (!$cases.Count) { throw 'No cases were selected.' }

$failures = [Collections.Generic.List[string]]::new()
function Write-CaptureStatus([string]$Id, [string]$Status, [string]$Directory, [string]$Message) {
    $path = Get-VfxSafePath $results "reference-status/$Id.json"
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [ordered]@{ id = $Id; status = $Status; directory = $Directory; message = $Message } |
        ConvertTo-Json | Set-Content -LiteralPath $path
}

foreach ($case in $cases) {
    $id = $case.id
    if ($id -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw "Invalid case ID '$id'." }
    $final = Get-VfxSafePath $results "references/$id"
    $settings = @{ size = $Size; fps = 30; seed = 1729; CameraPitch = 0; Travel = 0; Arc = 0 }
    foreach ($key in $case.capture.Keys) { $settings[$key] = $case.capture[$key] }
    $source = Get-VfxSafePath $sources $case.package
    $trial = ''
    try {
        $previous = Join-Path $final 'capture.json'
        if (Test-Path -LiteralPath $previous) {
            $capture = Get-Content -LiteralPath $previous -Raw | ConvertFrom-Json
            if ($capture.visibleFrames -gt 0 -and $capture.clippedFrames -eq 0) {
                Write-CaptureStatus $id 'valid' $final ''
                Write-Host "$id already captured in $final. Use a new results directory to recapture."
                continue
            }
            throw "An incomplete capture already exists in '$final'. Use a new results directory."
        }
        $extra = @{}
        if ($case['nested']) { $extra.Nested = $case['nested'] }
        $learned = Join-Path $results "learned/$id.json"
        if ($case['events']) {
            $events = Join-Path $results "events/$id.json"
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $events))
            ConvertTo-Json -InputObject @($case['events']) -Depth 4 | Set-Content -LiteralPath $events
            $extra.GraphEvents = $events
        }
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $trial = Get-VfxSafePath $results "reference-trials/$id-$attempt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $lock = Wait-VfxUnitySlot
            try {
                & $pipeline Learn -Project $stand -Source $source -Prefab $case.prefab -Id "reference-$id" `
                    -Title 'Reference capture' -Brief 'Reference capture' -Output $trial -Recipe $learned `
                    -Work (Join-Path $results 'capture-runs') -TimeoutMinutes $TimeoutMinutes @settings @extra | Out-Null
            } catch {
                if ($case.prefab -cnotlike 'Assets/*.prefab' -or
                    $_.Exception.Message -notlike '*No active Particle Systems, Trail Renderers or VFX Graph components were found.*') { throw }
                # Learn has already staged the prefab. Mesh-only references can still be rendered.
                & $pipeline Render -Project $stand -Prefab $case.prefab -Output $trial `
                    -Work (Join-Path $results 'capture-runs') -TimeoutMinutes $TimeoutMinutes @settings | Out-Null
            } finally {
                $lock.Dispose()
                # Allow waiting draft builds to acquire the editor between catalogue captures.
                Start-Sleep -Milliseconds 550
            }
            $capture = Get-Content -LiteralPath (Join-Path $trial 'capture.json') -Raw | ConvertFrom-Json
            Write-Host "$id at framing $($settings.Framing): $($capture.visibleFrames) visible / $($capture.clippedFrames) clipped frames."
            if (!$capture.visibleFrames) { throw "Reference is invisible. $($capture.notes -join ' ') See '$trial'." }
            if (!$capture.clippedFrames) {
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $final))
                [IO.Directory]::Move($trial, $final)
                Write-CaptureStatus $id 'valid' $final ''
                break
            }
            if ($attempt -eq 2 -or $settings.Framing -ge 100) { throw "Reference is clipped. See '$trial'." }
            $settings.Framing = [Math]::Min(100, 2 * $settings.Framing)
        }
    } catch {
        $failures.Add($id)
        $message = $_.Exception.Message
        $status = 'error'
        if ($trial -and (Test-Path -LiteralPath (Join-Path $trial 'capture.json') -PathType Leaf)) {
            $attemptCapture = Get-Content -LiteralPath (Join-Path $trial 'capture.json') -Raw | ConvertFrom-Json
            if ($attemptCapture.visibleFrames -eq 0) { $status = 'invisible' }
            elseif ($attemptCapture.clippedFrames -gt 0) { $status = 'clipped' }
        }
        Write-CaptureStatus $id $status $trial $message
        Write-Warning "$id - $message"
    }
}
if ($failures.Count) { throw "Reference capture failed for $($failures -join ', ')." }
