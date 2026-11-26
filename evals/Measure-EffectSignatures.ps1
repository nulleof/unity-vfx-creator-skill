[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Labels,
    [Parameter(Mandatory)][string]$CaptureRoot,
    [Parameter(Mandatory)][string]$Output,
    [string]$CaptureSummary,
    [string]$TrialRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

function Initialize-PngMeasurement {
    if ('VfxSignaturePng' -as [type]) { return }
    Add-Type -AssemblyName System.Drawing.Common
    $references = @(
        [Drawing.Bitmap].Assembly.Location
        [Drawing.Color].Assembly.Location
        [Runtime.InteropServices.Marshal].Assembly.Location
        foreach ($name in @('System.Runtime.dll', 'System.Private.Windows.Core.dll', 'System.Private.Windows.GdiPlus.dll')) {
            $path = Join-Path $PSHOME $name
            if (Test-Path -LiteralPath $path -PathType Leaf) { $path }
        }
    )
    Add-Type -ReferencedAssemblies $references -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class VfxSignaturePng
{
    public sealed class Frame
    {
        public int area;
        public int xMin, xMax, yMin, yMax;
        public double centerX, centerY;
        public bool clipped;
    }

    public static byte[] Read(string path, int size)
    {
        using var bitmap = new Bitmap(path);
        if (bitmap.Width != size || bitmap.Height != size)
            throw new ArgumentException("PNG size does not match capture: " + path);
        var pixels = new byte[size * size * 4];
        var data = bitmap.LockBits(new Rectangle(0, 0, size, size), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            for (int y = 0; y < size; y++)
                Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), pixels, y * size * 4, size * 4);
        }
        finally { bitmap.UnlockBits(data); }
        return pixels;
    }

    public static Frame Measure(byte[] pixels, int size, byte[] backdrop)
    {
        var frame = new Frame { xMin = size, yMin = size };
        long totalX = 0, totalY = 0;
        for (int y = 0; y < size; y++)
        for (int x = 0; x < size; x++)
        {
            int pixel = 4 * (y * size + x);
            int background = backdrop.Length == 3 ? 0 : pixel;
            // Match Render.IsForeground on the captured RGB bytes.
            if (Math.Abs(pixels[pixel] - backdrop[background]) <= 15 &&
                Math.Abs(pixels[pixel + 1] - backdrop[background + 1]) <= 15 &&
                Math.Abs(pixels[pixel + 2] - backdrop[background + 2]) <= 15) continue;
            frame.area++;
            totalX += x;
            totalY += y;
            frame.xMin = Math.Min(frame.xMin, x);
            frame.xMax = Math.Max(frame.xMax, x);
            frame.yMin = Math.Min(frame.yMin, y);
            frame.yMax = Math.Max(frame.yMax, y);
        }
        if (frame.area > 0)
        {
            frame.centerX = (double)totalX / frame.area;
            frame.centerY = (double)totalY / frame.area;
            frame.clipped = frame.xMin == 0 || frame.xMax == size - 1 || frame.yMin == 0 || frame.yMax == size - 1;
        }
        return frame;
    }
}
'@
}

function Get-Timeline([string]$Directory, $Capture, [bool]$RequiresScene) {
    if ($Capture.Contains('timeline')) { return $Capture.timeline }
    Initialize-PngMeasurement
    $size = $Capture.settings.size
    if ($RequiresScene) {
        # This fallback needs a static scene whose final frame is its clean backdrop.
        $backdrop = [VfxSignaturePng]::Read((Join-Path $Directory ('frame-{0:0000}.png' -f ($Capture.frames - 1))), $size)
    } else {
        $background = $Capture.background
        $backdrop = [byte[]]@($background.b, $background.g, $background.r)
    }
    for ($index = 0; $index -lt $Capture.frames; $index++) {
        $path = Join-Path $Directory ('frame-{0:0000}.png' -f $index)
        [VfxSignaturePng]::Measure([VfxSignaturePng]::Read($path, $size), $size, $backdrop)
    }
}

function Get-FrameSignature($Timeline, [int]$Index, $Settings) {
    $frame = $Timeline[$Index]
    $width = $frame.xMax - $frame.xMin + 1
    $height = $frame.yMax - $frame.yMin + 1
    $unitsPerPixel = $Settings.framing / $Settings.size
    return [ordered]@{
        frame = $Index
        seconds = [Math]::Round($Index / $Settings.fps, 4)
        pixels = $frame.area
        widthPx = $width
        heightPx = $height
        projectedWidth = [Math]::Round($width * $unitsPerPixel, 4)
        projectedHeight = [Math]::Round($height * $unitsPerPixel, 4)
    }
}

$sources = @{}
if ($CaptureSummary) {
    $summary = Get-Content -LiteralPath $CaptureSummary -Raw | ConvertFrom-Json -AsHashtable
    foreach ($case in $summary.cases) { $sources[$case.id] = $case }
}
$trials = if ($TrialRoot) { Get-ChildItem -LiteralPath $TrialRoot -Directory | Sort-Object Name }
$ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$rows = @(foreach ($label in (Get-Content -LiteralPath $Labels -Raw | ConvertFrom-Json -AsHashtable)) {
    $id = $label.id
    if ($id -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or !$ids.Add($id)) { throw "Invalid or duplicate signature ID '$id'." }
    $source = $sources[$id] ?? @{}
    $directory = $source['capture'] ?? (Join-Path $CaptureRoot $id)
    $manifest = Join-Path $directory 'capture.json'
    $requiresScene = [bool]$label['requiresScene']
    $row = [ordered]@{ id = $id; status = 'missing'; requiresScene = $requiresScene; capture = $directory }
    if ($source['scene']) { $row.scene = $source.scene }
    if ($label['note']) { $row.note = $label.note }
    if ($TrialRoot) {
        $trialPattern = '^' + [regex]::Escape($id) + '-[0-9]+-'
        $row.failedTrials = @(foreach ($trial in $trials) {
            if ($trial.Name -cnotmatch $trialPattern) { continue }
            $trialManifest = Join-Path $trial.FullName 'capture.json'
            if (!(Test-Path -LiteralPath $trialManifest -PathType Leaf)) { continue }
            try {
                $attempt = Get-Content -LiteralPath $trialManifest -Raw | ConvertFrom-Json -AsHashtable
            } catch {
                [ordered]@{ status = 'error'; capture = $trial.FullName; error = $_.Exception.Message }
                continue
            }
            if (!$attempt.visibleFrames -or $attempt['clippedFrames']) {
                [ordered]@{
                    status = if (!$attempt.visibleFrames) { 'invisible' } else { 'clipped' }
                    visibleFrames = $attempt.visibleFrames
                    clippedFrames = $attempt['clippedFrames']
                    capture = $trial.FullName
                }
            }
        })
    }
    if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) {
        if ($source['status'] -in 'invisible', 'clipped', 'error') { $row.status = $source.status }
        $row
        continue
    }
    try {
        $capture = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable
        $settings = $capture.settings
        $timeline = @(Get-Timeline $directory $capture $requiresScene)
        if ($timeline.Count -ne $capture.frames) { throw 'Frame count does not match capture manifest.' }
        $visible = @(for ($index = 0; $index -lt $timeline.Count; $index++) {
            if ($timeline[$index].area -gt 0) { $index }
        })
        $clipped = @($timeline | Where-Object clipped).Count
        $row.visibleFrames = $visible.Count
        $row.clippedFrames = $clipped
        $row.settings = $settings
        $row.measurement = if ($capture['timeline']) { 'capture-timeline' } elseif ($requiresScene) { 'png-scene-difference' } else { 'png-background-difference' }
        if ($visible.Count -ne $capture.visibleFrames -or ($capture.Contains('clippedFrames') -and $clipped -ne $capture.clippedFrames)) {
            throw "Foreground counts disagree with the capture manifest ($($capture.visibleFrames) visible, $($capture['clippedFrames']) clipped)."
        }
        if (!$visible.Count) { $row.status = 'invisible' }
        elseif ($clipped) { $row.status = 'clipped' }
        else {
            $onset = $visible[0]
            $peak = $onset
            foreach ($frame in $visible) { if ($timeline[$frame].area -gt $timeline[$peak].area) { $peak = $frame } }
            $last = $visible[-1]
            $signature = [ordered]@{}
            foreach ($key in @('mode', 'silhouette', 'motion', 'beatCount')) {
                if ($label.Contains($key)) { $signature[$key] = $label[$key] }
            }
            if ($last -lt $timeline.Count - 1 -and $label['mode'] -ne 'loop') {
                $signature.visibleDurationSec = [Math]::Round(($last - $onset + 1) / $settings.fps, 4)
            }
            $row.status = if ($requiresScene) { 'requires-scene' } else { 'measured' }
            $row.signature = $signature
            $row.onset = Get-FrameSignature $timeline $onset $settings
            $row.peak = Get-FrameSignature $timeline $peak $settings
            $row.lastVisible = Get-FrameSignature $timeline $last $settings
            $row.visibleAtEnd = $last -eq $timeline.Count - 1
            $row.trajectory = @(
                foreach ($frame in $visible) {
                    [ordered]@{
                        frame = $frame
                        x = [Math]::Round(($timeline[$frame].centerX + 0.5) / $settings.size, 5)
                        y = [Math]::Round(($timeline[$frame].centerY + 0.5) / $settings.size, 5)
                    }
                }
            )
        }
    } catch {
        $row.status = 'error'
        $row.error = $_.Exception.Message
    }
    $row
})
$report = [ordered]@{
    schemaVersion = 1
    counts = [ordered]@{}
    effects = $rows
}
foreach ($group in ($rows | Group-Object { $_.status } | Sort-Object Name)) { $report.counts[$group.Name] = $group.Count }
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $destination
[pscustomobject]$report.counts
