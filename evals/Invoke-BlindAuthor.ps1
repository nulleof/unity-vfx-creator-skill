[CmdletBinding()]
param(
    [ValidateSet('Run', 'Resume', 'Prepare', 'Draft', 'Finalize')][string]$Stage = 'Run',
    [Parameter(Mandatory)][string]$Output,
    [Alias('CleanProject')][string]$Project,
    [string]$SkillPath,
    [string]$Brief,
    [string]$SearchSignature,
    [string]$CaptureJson,
    [ValidateRange(32, 2048)][int]$Size = 256,
    [string]$Model,
    [ValidateSet('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$Effort,
    [ValidateSet('Legacy', 'Measured')][string]$DraftFeedback = 'Legacy',
    [ValidateRange(0, 2400)][int[]]$DraftSampleFrames = @(),
    [string]$AuthorUsageJson,
    [ValidateRange(0, [double]::MaxValue)][double]$AuthorElapsedSeconds
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'UnitySlot.ps1')
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
$stateFile = Join-Path $destination 'run.json'
$captureBounds = @{ size = 32, 2048; fps = 1, 120; duration = 0.05, 20; framing = 0.1, 100
    cameraPitch = -89, 89; travel = 0, 100; arc = 0, 100; seed = 1, 2147483647 }
$hasAuthorElapsedSeconds = $PSBoundParameters.ContainsKey('AuthorElapsedSeconds')
$hasDraftFeedback = $PSBoundParameters.ContainsKey('DraftFeedback')
$hasDraftSampleFrames = $PSBoundParameters.ContainsKey('DraftSampleFrames')
$feedbackProtocol = 1
$DraftFeedback = if ($DraftFeedback -eq 'Measured') { 'Measured' } else { 'Legacy' }
$sampleFrames = @($DraftSampleFrames | Sort-Object -Unique)
if ($sampleFrames.Count -ne $DraftSampleFrames.Count) { throw '-DraftSampleFrames must contain distinct indices.' }

function Save-Run($Run) {
    $temporary = "$stateFile.tmp"
    $Run | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary
    [IO.File]::Move($temporary, $stateFile, $true)
}

function Prepare-Run {
    if (!$Project -or !$SkillPath -or [string]::IsNullOrWhiteSpace($Brief) -or !$CaptureJson) {
        throw "$Stage needs -Project, -SkillPath, -Brief and -CaptureJson."
    }
    $projectPath = (Get-Item -LiteralPath $Project).FullName
    $version = Join-Path $projectPath 'ProjectSettings/ProjectVersion.txt'
    $manifest = Join-Path $projectPath 'Packages/manifest.json'
    if (!(Test-Path -LiteralPath $version -PathType Leaf) -or !(Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "'$projectPath' is not a Unity project."
    }
    $packages = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable
    if ((Test-Path -LiteralPath (Join-Path $projectPath '.vfx-reference')) -or
        !$packages['dependencies']['com.unity.render-pipelines.universal']) {
        throw 'Use a clean URP project separate from the reference stand.'
    }

    $settings = $CaptureJson | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($settings -isnot [System.Collections.IDictionary]) { throw '-CaptureJson must be a JSON object.' }
    $capture = [ordered]@{ size = $Size; fps = 30; duration = 1.2; framing = 3; cameraPitch = 0; travel = 0; arc = 0; seed = 1729 }
    foreach ($key in $settings.Keys) {
        $value = $settings[$key]
        if (!$captureBounds.ContainsKey($key) -or ($value -isnot [long] -and $value -isnot [double])) {
            throw 'Capture settings accept only numeric size, fps, duration, framing, cameraPitch, travel, arc and seed.'
        }
        $minimum, $maximum = $captureBounds[$key]
        if ($value -lt $minimum -or $value -gt $maximum -or
            ($key -in @('size', 'fps', 'seed') -and $value -ne [Math]::Truncate($value))) {
            throw "Invalid capture value for '$key': $value. See the pipeline parameter range."
        }
        $capture[$key] = $value
    }
    if ($DraftFeedback -eq 'Measured' -and !$sampleFrames.Count) {
        throw 'Measured draft feedback requires -DraftSampleFrames.'
    }
    $lastFrame = [Math]::Ceiling([single]([single]$capture.duration * $capture.fps))
    if ($sampleFrames.Count -and $sampleFrames[-1] -gt $lastFrame) {
        throw "Draft sample frames must be within the capture range (0 to $lastFrame)."
    }

    $sourceSkill = (Get-Item -LiteralPath $SkillPath).FullName
    $documents = @('SKILL.md', 'roles/author.md', 'roles/review.md', 'references/recipes.md')
    foreach ($entry in ($documents + 'scripts/vfx.ps1')) {
        if (!(Test-Path -LiteralPath (Join-Path $sourceSkill $entry) -PathType Leaf)) { throw "The skill is missing '$entry'." }
    }
    if ((Test-Path -LiteralPath $destination) -and @(Get-ChildItem -LiteralPath $destination -Force).Count) {
        throw "Prepare needs a new or empty output directory. Existing output: '$destination'."
    }
    [void][IO.Directory]::CreateDirectory($destination)

    # Use a fresh work directory with no inherited project or evaluation tree.
    $author = Join-Path ([IO.Path]::GetTempPath()) ('vfx-author-' + [guid]::NewGuid().ToString('N'))
    $skill = Join-Path $author '.agents/skills/vfx-creator'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $skill))
    Copy-Item -LiteralPath $sourceSkill -Destination $skill -Recurse

    $handbook = foreach ($document in $documents) {
        "## $document`n" + (Get-Content -LiteralPath (Join-Path $skill $document) -Raw)
    }
    $entries = @(Get-ChildItem -LiteralPath (Join-Path $skill 'catalog') -File -Filter '*.json' | Sort-Object Name)
    $pipeline = Join-Path $skill 'scripts/vfx.ps1'
    $searchArguments = @{ Brief = $Brief }
    if ($SearchSignature) { $searchArguments.Signature = $SearchSignature }
    $closest = @(& $pipeline Find @searchArguments | Select-Object -First 3)
    $cards = foreach ($file in $entries) {
        $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        "$($entry.id) | $($entry.title) | $($entry.description) | $($entry['tags'] -join ', ')"
    }
    $catalog = foreach ($hit in $closest) {
        $entry = Get-Content -LiteralPath $hit.path -Raw | ConvertFrom-Json -AsHashtable
        "## catalog/$($hit.id).json`n" + ($entry | ConvertTo-Json -Compress -Depth 100)
    }
    $settingsText = $capture | ConvertTo-Json -Compress
    $contextFile = Join-Path $author 'context.md'
    @"
# Brief

$Brief

Preview settings for a clean Unity URP project:
$settingsText

# VFX Creator authoring documentation

$($handbook -join "`n")

# VFX Creator catalog index

$($cards -join "`n")

# Closest catalog recipes

$($catalog -join "`n")
"@ | Set-Content -LiteralPath $contextFile

    $draftPrompt = Join-Path $author 'draft-prompt.md'
    @"
Create the complete draft VFX Creator version 1 recipe for this brief. Use the supplied skill and catalog. Use built-in procedural textures and set layer timing from the brief. The harness will build and capture your draft in Unity and supply the preview before revision. Submit a JSON object in draft.json. Use only this supplied context and work directory.

$(Get-Content -LiteralPath $contextFile -Raw)
"@ | Set-Content -LiteralPath $draftPrompt

    $prepared = [ordered]@{
        status = 'prepared'; startedAt = [DateTimeOffset]::UtcNow.ToString('o'); project = $projectPath
        pipeline = $pipeline; captureSettings = $capture
        closestRecipeIds = @($closest | ForEach-Object id)
        draftFeedback = $DraftFeedback; draftFeedbackProtocol = $feedbackProtocol; draftSampleFrames = $sampleFrames
        requestedModel = $Model; requestedEffort = $Effort; authorDirectory = $author; draftPrompt = $draftPrompt
        draftRecipe = (Join-Path $author 'draft.json'); finalRecipe = (Join-Path $author 'final.json')
        revisionPrompt = (Join-Path $author 'revision-prompt.md'); publishedRecipe = $null; prefab = $null; capture = $null
        draft = $null; final = $null; cliAttempts = @()
    }
    Save-Run $prepared
    return $prepared
}

function Read-Run {
    $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $savedMode = $saved['draftFeedback'] ?? 'Legacy'
    $savedFrames = $saved['draftSampleFrames'] ?? @()
    if (($savedMode -eq 'Measured' -and $saved['draftFeedbackProtocol'] -ne $feedbackProtocol) -or
        ($hasDraftFeedback -and $savedMode -ne $DraftFeedback) -or
        ($hasDraftSampleFrames -and ($savedFrames -join ',') -ne ($sampleFrames -join ','))) {
        throw 'The draft feedback protocol or sample frames changed. Use a new output directory.'
    }
    return $saved
}

function Invoke-CodexAuthor($Run, [string]$Phase, [string]$Prompt, [string]$Recipe, [string[]]$Frames) {
    $codex = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$codex) { throw 'Codex CLI is unavailable. Use the prepared author directory and resume with Draft or Finalize.' }

    $attemptNumber = 1 + @($Run.cliAttempts | Where-Object phase -eq $Phase).Count
    $attemptName = if ($attemptNumber -eq 1) { $Phase } else { "$Phase-$attemptNumber" }
    $schema = Join-Path $Run.authorDirectory 'response-schema.json'
    $reply = Join-Path $Run.authorDirectory "$attemptName-reply.json"
    '{"type":"object","properties":{"recipeJson":{"type":"string"}},"required":["recipeJson"],"additionalProperties":false}' |
        Set-Content -LiteralPath $schema
    $arguments = @('exec', '--ephemeral', '--skip-git-repo-check', '--ignore-user-config', '--ignore-rules',
        '--json', '--sandbox', 'read-only', '-c', 'approval_policy="never"', '-c', 'web_search="disabled"',
        '--disable', 'shell_tool', '--disable', 'apps', '--disable', 'plugins', '--disable', 'memories',
        '--disable', 'hooks', '--disable', 'browser_use', '--disable', 'computer_use', '--disable', 'shell_snapshot',
        '--enable', 'skip_host_skill_discovery',
        '-C', $Run.authorDirectory, '--output-schema', $schema, '--output-last-message', $reply)
    if ($Run.requestedModel) { $arguments += @('-m', $Run.requestedModel) }
    if ($Run.requestedEffort) { $arguments += @('-c', ('model_reasoning_effort="{0}"' -f $Run.requestedEffort)) }
    if ($Frames.Count) { $arguments += @('--image', ($Frames -join ',')) }
    $arguments += '-'
    $promptText = "The harness writes the requested JSON file. Return the complete recipe object serialized as the recipeJson string in the structured response, with no Markdown fences.`n`n" +
        (Get-Content -LiteralPath $Prompt -Raw)
    $eventsFile = Join-Path $destination "$attemptName-events.jsonl"
    $errorsFile = Join-Path $destination "$attemptName-codex.log"
    $PSNativeCommandUseErrorActionPreference = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $promptText | & $codex.Source @arguments 2> $errorsFile | Set-Content -LiteralPath $eventsFile
    $exitCode = $LASTEXITCODE
    $timer.Stop()

    $usage = $null
    $threadId = $null
    $events = if (Test-Path -LiteralPath $eventsFile -PathType Leaf) { Get-Content -LiteralPath $eventsFile }
    foreach ($line in $events) {
        $event = $line | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
        if ($event -isnot [System.Collections.IDictionary]) { continue }
        if ($event['type'] -eq 'turn.completed') { $usage = $event['usage'] }
        if ($event['type'] -eq 'thread.started') { $threadId = $event['thread_id'] }
    }
    $attempt = [ordered]@{
        phase = $Phase; mode = 'codex-cli'; seconds = $timer.Elapsed.TotalSeconds; exitCode = $exitCode
        threadId = $threadId; usage = $usage; events = $eventsFile; log = $errorsFile
    }
    $Run.cliAttempts += $attempt
    Save-Run $Run
    if ($exitCode -ne 0 -or !(Test-Path -LiteralPath $reply -PathType Leaf)) {
        throw "Codex failed during $Phase (exit $exitCode). See '$errorsFile'. Use the prepared author directory and resume with Draft or Finalize."
    }
    $encoded = Get-Content -LiteralPath $reply -Raw | ConvertFrom-Json -AsHashtable
    $encoded['recipeJson'] | Set-Content -LiteralPath $Recipe
    return $attempt
}

function Get-ManualAuthor([DateTimeOffset]$StartedAt) {
    $seconds = ([DateTimeOffset]::UtcNow - $StartedAt).TotalSeconds
    $timing = 'stage-window'
    if ($hasAuthorElapsedSeconds) {
        $seconds = $AuthorElapsedSeconds
        $timing = 'supplied'
    }
    $usage = if ($AuthorUsageJson) { $AuthorUsageJson | ConvertFrom-Json -AsHashtable }
    return [ordered]@{ mode = 'external'; seconds = $seconds; timing = $timing; usage = $usage }
}

function Get-AutomatedAuthor($Run, [string]$Phase, [string]$Prompt, [string]$Recipe, [string[]]$Frames) {
    $completed = $Run.cliAttempts | Where-Object { $_.phase -eq $Phase -and $_.exitCode -eq 0 } | Select-Object -Last 1
    if ($completed -and (Test-Path -LiteralPath $Recipe -PathType Leaf)) { return $completed }
    return Invoke-CodexAuthor $Run $Phase $Prompt $Recipe $Frames
}

function Build-Phase($Run, [string]$Name, [string]$AuthorRecipe, $AuthorMetadata) {
    if (!(Test-Path -LiteralPath $AuthorRecipe -PathType Leaf)) { throw "The author must submit '$AuthorRecipe'." }
    $data = Get-Content -LiteralPath $AuthorRecipe -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($data -isnot [System.Collections.IDictionary] -or $data['version'] -ne 1 -or !$data['id'] -or !$data['layers']) {
        throw "The $Name recipe must be a complete version 1 recipe with an id and layers."
    }
    $phase = Join-Path $destination $Name
    [void][IO.Directory]::CreateDirectory($phase)
    $recipe = Join-Path $phase 'recipe.json'
    $capture = Join-Path $phase 'capture'
    Copy-Item -LiteralPath $AuthorRecipe -Destination $recipe -Force
    $id = "blind-$Name-" + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $settings = $Run.captureSettings
    $manifestPath = Join-Path $capture 'capture.json'
    $queueTimer = [Diagnostics.Stopwatch]::StartNew()
    $lock = Wait-VfxUnitySlot
    $queueTimer.Stop()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $receipt = & $Run.pipeline Build -Project $Run.project -Recipe $recipe -Id $id -Work (Join-Path $destination 'unity') `
            -Output $capture -RenderAfterBuild @settings
    } catch {
        if ($_.Exception.Message -notlike '*The capture contains no visible frames*' -or
            !(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw }
        # Retain the exported prefab and record a blank capture for review.
        $receipt = [ordered]@{
            prefab = "Assets/VfxCreatorGenerated/$id/Effect.prefab"; capture = $capture
            visible = $false; notes = @($_.Exception.Message)
        }
    } finally {
        $timer.Stop()
        $lock.Dispose()
    }
    $prefab = Join-Path $Run.project $receipt.prefab
    if (!(Test-Path -LiteralPath $prefab -PathType Leaf) -or !(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Unity did not produce a $Name prefab and capture."
    }
    return [ordered]@{
        recipe = $recipe; prefab = $prefab; capture = $capture; captureManifest = $manifestPath
        buildSeconds = $timer.Elapsed.TotalSeconds; unityWaitSeconds = $queueTimer.Elapsed.TotalSeconds
        author = $AuthorMetadata; receipt = $receipt
    }
}

function Get-MeasuredPreviewIndices([int[]]$Samples, $Timeline) {
    $limit = [Math]::Min(8, $Timeline.Count)
    if ($Samples.Count -ge $limit) {
        if ($limit -eq 1) { return $Samples[0] }
        return 0..($limit - 1) | ForEach-Object {
            $Samples[[int][Math]::Round($_ * ($Samples.Count - 1) / ($limit - 1))]
        }
    }

    $indices = [System.Collections.Generic.List[int]]::new()
    $indices.AddRange($Samples)
    $peak = 0
    for ($frame = 1; $frame -lt $Timeline.Count; $frame++) {
        if ($Timeline[$frame].area -gt $Timeline[$peak].area) { $peak = $frame }
    }
    foreach ($frame in @($peak, 0, ($Timeline.Count - 1))) {
        if ($indices.Count -lt $limit -and !$indices.Contains($frame)) { $indices.Add($frame) }
    }
    # Fill remaining preview slots with frames furthest from any selected frame.
    while ($indices.Count -lt $limit) {
        $bestFrame = 0
        $maxDistance = 0
        for ($frame = 0; $frame -lt $Timeline.Count; $frame++) {
            $distance = $Timeline.Count
            foreach ($index in $indices) { $distance = [Math]::Min($distance, [Math]::Abs($index - $frame)) }
            if ($distance -gt $maxDistance) { $bestFrame = $frame; $maxDistance = $distance }
        }
        $indices.Add($bestFrame)
    }
    return $indices
}

function Format-DraftMeasurements([int[]]$Samples, $Manifest) {
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $rows = foreach ($index in $Samples) {
        $frame = $Manifest.timeline[$index]
        $time = ($index / $Manifest.settings.fps).ToString('0.000', $culture)
        $bounds = $center = $luminance = '—'
        if ($frame.area -gt 0) {
            $bounds = "$($frame.xMin), $($frame.yMin), $($frame.xMax), $($frame.yMax)"
            $center = [string]::Format($culture, '{0:0.0}, {1:0.0}', $frame.centerX, $frame.centerY)
            $luminance = $frame.meanLuminance.ToString('0.0000', $culture)
        }
        "| $index | $time | $($frame.area) | $bounds | $center | $luminance | $($frame.clipped) |"
    }
    return @"


## Draft measurements

These rows measure your own draft at the brief's sample beats. Area counts foreground pixels. Bounds are inclusive xMin, yMin, xMax, yMax and centers are x, y, in pixels from the top left of the $($Manifest.settings.size) × $($Manifest.settings.size) frame. Mean foreground luminance uses normalized Rec. 709 weights (0–1). Clipped means foreground reaches a frame edge.

| Frame | Time (s) | Area (pixels) | Bounds | Center | Mean luminance | Clipped |
| --- | --- | --- | --- | --- | --- | --- |
$($rows -join "`n")
"@
}

function Prepare-Revision($Run) {
    $draft = $Run.draft
    $manifest = Get-Content -LiteralPath $draft.captureManifest -Raw | ConvertFrom-Json -AsHashtable
    $files = @(Get-ChildItem -LiteralPath $draft.capture -File -Filter 'frame-*.png' | Sort-Object Name)
    if (!$files.Count) { throw 'The draft capture contains no preview frames.' }
    $measurements = ''
    if ($Run['draftFeedback'] -eq 'Measured') {
        $timeline = $manifest['timeline']
        $samples = $Run.draftSampleFrames
        if (!$timeline -or $timeline.Count -ne $manifest.frames -or $files.Count -ne $manifest.frames) {
            throw 'Measured draft feedback requires a complete draft capture with one timeline entry per frame.'
        }
        if ($samples[-1] -ge $timeline.Count) { throw 'A draft sample frame is outside the rendered capture.' }
        $indices = Get-MeasuredPreviewIndices $samples $timeline
        $measurements = Format-DraftMeasurements $samples $manifest
    } else {
        $indices = (0..10 | ForEach-Object { [int][Math]::Round($_ * ($files.Count - 1) / 10) }) +
            (0.1, 0.25, 0.5, 0.75 | ForEach-Object { [int][Math]::Min($files.Count - 1, [Math]::Round($_ * $manifest.settings.fps)) })
    }
    $preview = Join-Path $Run.authorDirectory 'draft-preview'
    [void][IO.Directory]::CreateDirectory($preview)
    $attachments = foreach ($index in ($indices | Sort-Object -Unique)) {
        $name = $files[$index].Name
        $target = Join-Path $preview $name
        Copy-Item -LiteralPath $files[$index].FullName -Destination $target -Force
        $target
    }
    $frameNames = $attachments | ForEach-Object { Split-Path -Leaf $_ }
    $previewSummary = "Visible frames $($manifest.visibleFrames) of $($manifest.frames), clipped frames $($manifest.clippedFrames), peak particles $($manifest.peakParticles)."
    $contextFile = Join-Path $Run.authorDirectory 'context.md'
    @"
Inspect the draft capture in draft-preview or the attached frames. This is your draft preview in chronological order ($($frameNames -join ', ')). $previewSummary$measurements

Refine the recipe based on how the draft matches the brief, including silhouette, motion, layer timing and fade. Submit the complete version 1 recipe in final.json using built-in procedural textures. The harness will export and render your final prefab. Use only this supplied context and work directory.

$(Get-Content -LiteralPath $contextFile -Raw)

# Draft recipe

$(Get-Content -LiteralPath $draft.recipe -Raw)
"@ | Set-Content -LiteralPath $Run.revisionPrompt
    $Run['draftPreview'] = @($attachments)
    $Run['draftedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
    $Run.status = 'drafted'
    Save-Run $Run
}

[void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
try { $executionSlot = [IO.File]::Open("$destination.execution.lock", 'OpenOrCreate', 'ReadWrite', 'None') }
catch [IO.IOException] { throw "An authoring stage is already running for '$destination'." }
try {
    $prepare = $Stage -in @('Run', 'Prepare')
    $run = if ($prepare) { Prepare-Run } else { Read-Run }
    $automated = $Stage -in @('Run', 'Resume')
    if ($Stage -eq 'Draft' -or ($automated -and $run.status -eq 'prepared')) {
        if ($run.status -ne 'prepared') { throw "Draft requires a prepared run. Current status is '$($run.status)'." }
        $authorMetadata = if ($automated) { Get-AutomatedAuthor $run 'draft' $run.draftPrompt $run.draftRecipe @() }
                          else { Get-ManualAuthor $run.startedAt }
        $run.draft = Build-Phase $run 'draft' $run.draftRecipe $authorMetadata
        Prepare-Revision $run
    }
    if ($Stage -eq 'Finalize' -or ($automated -and $run.status -eq 'drafted')) {
        if ($run.status -ne 'drafted') { throw "Finalize requires a completed draft. Current status is '$($run.status)'." }
        $authorMetadata = if ($automated) { Get-AutomatedAuthor $run 'final' $run.revisionPrompt $run.finalRecipe $run.draftPreview }
                          else { Get-ManualAuthor $run.draftedAt }
        $run.final = Build-Phase $run 'final' $run.finalRecipe $authorMetadata
        $run.publishedRecipe = $run.final.recipe
        $run.prefab = $run.final.prefab
        $run.capture = $run.final.capture
        $run['finishedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
        $run['elapsedSeconds'] = ([DateTimeOffset]$run.finishedAt - [DateTimeOffset]$run.startedAt).TotalSeconds
        $run.status = 'complete'
        Save-Run $run
    }
    $run | ConvertTo-Json -Depth 30
} finally { $executionSlot.Dispose() }
