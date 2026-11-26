[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Apk,
    [string]$Serial
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$apkPath = (Get-Item -LiteralPath $Apk).FullName
$adbPath = (Get-Command adb -CommandType Application).Source
$package = 'org.vfxcreator.overlayreview'
$output = Join-Path (Split-Path -Parent (Split-Path -Parent $apkPath)) ('android-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($output)

if (!$Serial) {
    $devices = @(& $adbPath devices | ForEach-Object {
        if ($_ -match '^(\S+)\s+device\s*$') { $Matches[1] }
    })
    if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) {
        throw 'Connect exactly one authorized Android device, or specify -Serial from adb devices.'
    }
    $Serial = $devices[0]
}

function Invoke-Adb([string[]]$Arguments) {
    $result = & $adbPath -s $Serial @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ADB exited with code ${LASTEXITCODE}: $($Arguments[0]) $result" }
    $result
}

$userId = (Invoke-Adb @('shell', 'am', 'get-current-user')).Trim()
if ($userId -notmatch '^\d+$') { throw "Could not resolve the active Android user: '$userId'." }
$deviceFiles = "/storage/emulated/$userId/Android/data/$package/files/ui-review"

Invoke-Adb @('install', '-r', $apkPath) | Out-Host
$resolution = Invoke-Adb @('shell', 'cmd', 'package', 'resolve-activity', '--brief', '--user', $userId,
    '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER', '-p', $package)
$activity = $resolution | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith("$package/") } | Select-Object -First 1
if (!$activity) { throw "Could not resolve the Android fixture's launcher activity: $resolution" }
$frames = @('dark-standard-peak.png', 'dark-reduced-peak.png', 'light-standard-peak.png', 'light-reduced-peak.png')
$files = @('profile.json', 'review.json', 'playback.json', 'failure.txt') + $frames
$devicePaths = @($files | ForEach-Object { "$deviceFiles/$_" })
Invoke-Adb @('shell', 'am', 'force-stop', '--user', $userId, $package)
Invoke-Adb (@('shell', 'rm', '-f') + $devicePaths)
$launch = Invoke-Adb @('shell', 'am', 'start', '-W', '--user', $userId, '-n', $activity)
if (!($launch -match '^Status: ok\s*$')) { throw "Android fixture did not launch: $launch" }
Write-Host "Collecting six device runs. Local results: $output"

$deadline = [DateTime]::UtcNow.AddMinutes(4)
while ($true) {
    & $adbPath -s $Serial shell test -s "$deviceFiles/failure.txt"
    if ($LASTEXITCODE -eq 0) {
        Invoke-Adb @('pull', "$deviceFiles/failure.txt", $output) | Out-Host
        throw "Android fixture failed. See '$output/failure.txt'."
    }
    & $adbPath -s $Serial shell test -s "$deviceFiles/playback.json"
    if ($LASTEXITCODE -eq 0) { break }
    if ([DateTime]::UtcNow -ge $deadline) { throw "Android fixture timed out. Keep the phone unlocked and in the foreground. Results: '$output'." }
    Start-Sleep -Seconds 2
}
$resultPaths = @((@('profile.json', 'review.json', 'playback.json') + $frames) | ForEach-Object { "$deviceFiles/$_" })
Invoke-Adb (@('pull') + $resultPaths + $output) | Out-Host
$review = Get-Content -LiteralPath (Join-Path $output 'review.json') -Raw | ConvertFrom-Json -AsHashtable
$profile = Get-Content -LiteralPath (Join-Path $output 'profile.json') -Raw | ConvertFrom-Json -AsHashtable
$playback = Get-Content -LiteralPath (Join-Path $output 'playback.json') -Raw | ConvertFrom-Json -AsHashtable
if (!$playback.passed -or !$review.deviceSafeArea -or $review.width -ne $profile.width -or $review.height -ne $profile.height -or
    $profile.pairs.Count -ne 3 -or $profile.targetFps -ne 60 -or (Compare-Object $frames $review.captures)) {
    throw "Unexpected Android review output in '$output'."
}

$budgets = [ordered]@{ cpu = 1.0; gpu = 1.0; canvas = 0.5 }
$acceptance = [ordered]@{}
foreach ($metric in $budgets.Keys) {
    $deltas = @($profile.pairs | ForEach-Object {
        if ($_.off[$metric].samples -ge 432 -and $_.on[$metric].samples -ge 432) {
            $_.on[$metric].p95Ms - $_.off[$metric].p95Ms
        }
    })
    $status = if (@($deltas | Where-Object { $_ -gt $budgets[$metric] }).Count) { 'overBudget' }
        elseif ($deltas.Count -eq 3) { 'pass' }
        else { 'unavailable' }
    $acceptance[$metric] = @{ budgetMs = $budgets[$metric]; status = $status; pairDeltasMs = $deltas }
}
$acceptance | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'acceptance.json')
Write-Output "Android review results: $output"
$acceptance | ConvertTo-Json -Depth 5
if ($acceptance.Values.status -contains 'overBudget') { throw "An Android frame-time budget was exceeded. See '$output/acceptance.json'." }
