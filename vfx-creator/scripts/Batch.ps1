function Resolve-VfxBatchPath($Value, [string]$Base, [string]$Name) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "Each batch item needs a $Name path."
    }
    return [IO.Path]::GetFullPath($Value, $Base)
}

function Get-VfxKeyFrames($Capture) {
    $visible = @(for ($i = 0; $i -lt $Capture.timeline.Count; $i++) {
        if ($Capture.timeline[$i].area -gt 0) { $i }
    })
    if (!$visible.Count) { return }
    $largest = $brightest = $visible[0]
    foreach ($frame in $visible) {
        if ($Capture.timeline[$frame].area -gt $Capture.timeline[$largest].area) { $largest = $frame }
        if ($Capture.timeline[$frame].meanLuminance -gt $Capture.timeline[$brightest].meanLuminance) { $brightest = $frame }
    }
    foreach ($index in @($visible[0], $largest, $brightest, $visible[-1]) | Sort-Object -Unique) {
        $frame = $Capture.timeline[$index]
        [ordered]@{
            index = $index
            file = 'frame-{0:D4}.png' -f $index
            timeSec = [math]::Round($index / $Capture.settings.fps, 3)
            widthPx = $frame.xMax - $frame.xMin + 1
            heightPx = $frame.yMax - $frame.yMin + 1
            areaPx = $frame.area
            clipped = $frame.clipped
        }
    }
}

function Write-VfxBatchGallery($Batch, [string]$Output) {
    $cards = foreach ($row in $Batch.items) {
        $label = [Net.WebUtility]::HtmlEncode(($row.id ?? "Item $($row.index)"))
        $errorText = [Net.WebUtility]::HtmlEncode($row.error)
        $frames = foreach ($frame in $row.keyFrames) {
            $image = "captures/$($row.id)/$($frame.file)"
            "<figure><a href='$image'><img src='$image' loading='lazy' alt='Frame $($frame.index)'></a><figcaption>$($frame.timeSec) s · $($frame.widthPx) × $($frame.heightPx) px</figcaption></figure>"
        }
        $links = @(
            if ($null -ne $row.visibleFrames) {
                "<a href='captures/$($row.id)/capture.json'>Capture measurements</a>"
                "<a href='captures/$($row.id)/'>All frames</a>"
            }
            if ($row.effect) { "<a href='captures/$($row.id)/effect.json'>Playback manifest</a>" }
            if ($row.receipt) { "<a href='receipts/$($row.index).json'>Build receipt</a>" }
        )
        $warning = if ($row.visibleFrames -eq 0) { '<p class="warning">No visible frames</p>' }
                   elseif ($row.clippedFrames -gt 0) { "<p class='warning'>$($row.clippedFrames) clipped frames</p>" }
        $prefab = if ($row.prefab) { "<p><code>$([Net.WebUtility]::HtmlEncode($row.prefab))</code></p>" }
        "<article><h2>$label <small>$($row.status)</small></h2><p>$errorText</p>$warning<div class='frames'>$($frames -join '')</div>$prefab<nav>$($links -join ' · ')</nav></article>"
    }
    $lastError = [Net.WebUtility]::HtmlEncode($Batch.error)
    $gallery = Join-Path $Output 'index.html'
    @"
<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>VFX batch</title>
<style>
body{margin:2rem auto;max-width:72rem;padding:0 1rem;background:#151820;color:#e8ebf1;font:16px system-ui}
article{border-top:1px solid #434b5b;padding:1rem 0}h2{margin:0}small,figcaption{font-size:.85rem;color:#aebbd0}
a{color:#9ad9ff}.frames{display:flex;flex-wrap:wrap;gap:.75rem}figure{margin:0}img{width:min(13rem,75vw);display:block}.warning{color:#ffca82}
</style>
<h1>VFX batch</h1>
<p>$($Batch.succeeded) succeeded · $($Batch.failed) failed · $($Batch.interrupted) interrupted</p>
<p>$lastError</p>
<p><a href="batch.json">Batch report</a></p>
$($cards -join [Environment]::NewLine)
</html>
"@ | Set-Content -LiteralPath $gallery
}

function Invoke-VfxBuildBatch($Unity, [string]$ManifestPath, [string]$Output, [hashtable]$CaptureDefaults) {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($manifest -isnot [System.Collections.IDictionary] -or $manifest['version'] -isnot [long] -or
        $manifest['version'] -ne 1 -or $manifest['items'] -isnot [array] -or !$manifest['items'].Count) {
        throw 'A batch manifest needs version 1 and a nonempty items array.'
    }
    $base = Split-Path -Parent $ManifestPath
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = @(for ($i = 0; $i -lt $manifest.items.Count; $i++) {
        $entry = $manifest.items[$i]
        $row = [ordered]@{
            index = $i + 1; id = $null; mode = $null; recipe = $null; effectBrief = $null
            status = 'failed'; error = $null; prefab = $null; capture = $null; effect = $null; receipt = $null
            visibleFrames = $null; clippedFrames = $null; keyFrames = @()
        }
        $brief = $null
        $capture = $CaptureDefaults.Clone()
        try {
            if ($entry -isnot [System.Collections.IDictionary]) { throw 'A batch item must be an object.' }
            $row.effectBrief = Resolve-VfxBatchPath $entry['effectBrief'] $base 'effectBrief'
            $brief = Get-Content -LiteralPath $row.effectBrief -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
            if ($brief -is [System.Collections.IDictionary] -and $brief['id'] -is [string] -and
                $brief['id'] -cmatch '\A[a-z0-9][a-z0-9-]{0,63}\z') {
                $row.id = $brief['id']
            }
            $row.recipe = Resolve-VfxBatchPath $entry['recipe'] $base 'recipe'
            Test-VfxEffectBrief $brief $capture
            $row.mode = $brief.mode
        } catch {
            $row.error = $_.Exception.Message
        }
        if ($row.id -and !$ids.Add($row.id)) { throw "Duplicate batch effect ID '$($row.id)'." }
        @{ row = $row; entry = $entry; brief = $brief; capture = $capture }
    })
    if ((Test-Path -LiteralPath $Output -PathType Leaf) -or
        ((Test-Path -LiteralPath $Output -PathType Container) -and (Get-ChildItem -LiteralPath $Output -Force | Select-Object -First 1))) {
        throw 'BuildBatch requires a fresh or empty output directory.'
    }
    [void](New-VfxDirectory $Output)
    $reportPath = Join-Path $Output 'batch.json'
    $reservation = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew)
    $reservation.Dispose()

    $run = New-VfxDirectory (Join-Path (Get-VfxWork $Unity.path) ("buildbatch-" + [guid]::NewGuid().ToString('N').Substring(0, 12)))
    $requests = @(foreach ($item in $items) {
        $row = $item.row
        if ($row.error) { continue }
        try {
            $recipe = Join-Path $run "$($row.index).recipe.json"
            ConvertTo-VfxBuildRecipe $row.recipe $recipe
            $resources = Split-Path -Parent $row.recipe
            if ($item.entry.Contains('resourceRoot')) {
                $resources = Resolve-VfxBatchPath $item.entry['resourceRoot'] $base 'resourceRoot'
                if (!(Test-Path -LiteralPath $resources -PathType Container)) { throw "Resource directory '$resources' does not exist." }
            }
            @{
                action = 'build'; id = $row.id; capture = $item.capture; effectBrief = $item.brief
                stagingToken = [guid]::NewGuid().ToString('N')
                recipe = $recipe; sourceRecipe = $row.recipe; resourceRoot = $resources
                shader = Join-Path $skill 'unity/Layer.shader'
                output = Join-Path $Output "captures/$($row.id)"
                response = Join-Path $Output "receipts/$($row.index).json"
            }
            $row.status = 'interrupted'
        } catch {
            $row.error = $_.Exception.Message
        }
    })
    $unityError = $null
    $launches = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($requests.Count) {
            $launches = 1
            $null = Invoke-VfxUnity $Unity @{ action = 'buildbatch'; items = $requests } $run
        }
    } catch {
        $unityError = $_.Exception.Message
    } finally {
        $timer.Stop()
        $rows = @(foreach ($item in $items) {
            $row = $item.row
            if ($row.status -eq 'interrupted') {
                $receiptPath = Join-Path $Output "receipts/$($row.index).json"
                if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
                    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
                    $row.receipt = $receiptPath
                    $row.status = if ($receipt.ok) { 'succeeded' } else { 'failed' }
                    $row.error = $receipt.error
                    $row.capture = $receipt.capture
                    if ($receipt.ok) {
                        $row.prefab = $receipt.prefab
                        $row.effect = $receipt.effect
                    }
                } else {
                    $row.error = $unityError ?? 'Unity stopped before recording a result.'
                    $unconfirmedPrefab = "Assets/VfxCreatorGenerated/$($row.id)/Effect.prefab"
                    if (Test-Path -LiteralPath (Join-Path $Unity.path $unconfirmedPrefab) -PathType Leaf) {
                        $row.error += " A prefab exists at '$unconfirmedPrefab'. Inspect it before retrying."
                    }
                }
                if ($row.capture) {
                    $capture = Get-Content -LiteralPath (Join-Path $row.capture 'capture.json') -Raw | ConvertFrom-Json -AsHashtable
                    $row.visibleFrames = $capture.visibleFrames
                    $row.clippedFrames = $capture.clippedFrames
                    $row.keyFrames = @(Get-VfxKeyFrames $capture)
                }
            }
            $row
        })
        $batch = [ordered]@{
            version = 1; project = $Unity.path; manifest = $ManifestPath
            report = $reportPath; gallery = Join-Path $Output 'index.html'
            unityLog = if ($launches) { Join-Path $run 'unity.log' }
            unityLaunches = $launches; unitySeconds = $timer.Elapsed.TotalSeconds; error = $unityError
            succeeded = @($rows | Where-Object status -eq 'succeeded').Count
            failed = @($rows | Where-Object status -eq 'failed').Count
            interrupted = @($rows | Where-Object status -eq 'interrupted').Count
            items = $rows
        }
        $batch.ok = !$batch.error -and !$batch.failed -and !$batch.interrupted
        $batch | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath
        Write-VfxBatchGallery $batch $Output
    }
    return [pscustomobject]$batch
}
