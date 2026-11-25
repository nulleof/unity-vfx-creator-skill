[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Capture,
    [Parameter(Mandatory)][string[]]$Label,
    [Parameter(Mandatory)][string]$Output,
    [int[]]$Frame,
    [ValidateRange(64, 384)][int]$Cell = 160
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
if ($Capture.Count -ne $Label.Count) { throw 'Provide one label per capture.' }
$manifests = @($Capture | ForEach-Object {
    Get-Content -LiteralPath (Join-Path $_ 'capture.json') -Raw | ConvertFrom-Json
})
$manifest = $manifests[0]
if ($manifests | Where-Object { $_.frames -ne $manifest.frames -or $_.settings.fps -ne $manifest.settings.fps }) {
    throw 'Contact sheets need the same frame count and FPS in all captures.'
}
if (!$Frame) {
    $Frame = @(0, 0.045, 0.1, 0.18, 0.3, 0.5, 0.74, 0.95 | ForEach-Object {
        [int][Math]::Round($_ * ($manifest.frames - 1))
    } | Select-Object -Unique)
}
if ($Frame | Where-Object { $_ -lt 0 -or $_ -ge $manifest.frames }) { throw 'A requested frame is outside the capture.' }

Add-Type -AssemblyName System.Drawing.Common
$gutter = 4
$caption = 26
$width = $Capture.Count * ($Cell + $gutter) + $gutter
$height = $caption + $Frame.Count * ($Cell + $caption) + $gutter
$bitmap = [Drawing.Bitmap]::new($width, $height)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$font = [Drawing.Font]::new('Segoe UI', 10)
try {
    $graphics.Clear([Drawing.Color]::FromArgb(20, 24, 34))
    for ($column = 0; $column -lt $Capture.Count; $column++) {
        $x = $gutter + $column * ($Cell + $gutter)
        $graphics.DrawString($Label[$column], $font, [Drawing.Brushes]::White, $x, $gutter)
        for ($row = 0; $row -lt $Frame.Count; $row++) {
            $y = $caption + $row * ($Cell + $caption)
            $number = $Frame[$row]
            $path = Join-Path $Capture[$column] ('frame-{0:0000}.png' -f $number)
            $image = [Drawing.Image]::FromFile((Get-Item -LiteralPath $path).FullName)
            try { $graphics.DrawImage($image, $x, $y, $Cell, $Cell) } finally { $image.Dispose() }
            $seconds = ($number / $manifest.settings.fps).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
            $graphics.DrawString("$seconds s  ·  $number", $font, [Drawing.Brushes]::White, $x, $y + $Cell + 2)
        }
    }
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    $bitmap.Save($destination, [Drawing.Imaging.ImageFormat]::Png)
    $destination
} finally {
    $font.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
}
