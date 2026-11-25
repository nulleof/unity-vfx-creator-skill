[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Inventory,
    [string]$HoldoutManifest = (Join-Path $PSScriptRoot 'corpus-holdouts.json'),
    [string]$LearningManifest = (Join-Path $PSScriptRoot 'corpus-learning.json')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$catalog = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json -AsHashtable
$eligible = @($catalog.assets | Where-Object { $_.kind -eq 'prefab' -and $_.status -in @('candidate', 'variant') })

function Resolve-Case($Case) {
    $matches = @($eligible | Where-Object {
        $_.package -eq $Case.package -and $_.nestedPackage -eq $Case['nested'] -and
        ($_.path -eq $Case.prefab -or [IO.Path]::GetFileNameWithoutExtension($_.path) -eq $Case.prefab)
    })
    if ($matches.Count -ne 1) { throw "Expected one eligible prefab for '$($Case.id)', found $($matches.Count)." }
    return $matches[0]
}

$holdouts = @(Get-Content -LiteralPath $HoldoutManifest -Raw | ConvertFrom-Json -AsHashtable)
$learning = @(Get-Content -LiteralPath $LearningManifest -Raw | ConvertFrom-Json -AsHashtable)
$packCount = @($holdouts | ForEach-Object package | Sort-Object -Unique).Count
if ($packCount -ne $catalog.summary.topLevelPackages -or $holdouts.Count -ne $packCount) {
    throw 'Holdouts must contain one prefab from each package.'
}
$reserved = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($case in $holdouts) {
    $asset = Resolve-Case $case
    [void]$reserved.Add("$($asset.package)|$($asset.variantGroup)")
}
$families = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($case in $learning) {
    $asset = Resolve-Case $case
    if ($reserved.Contains("$($asset.package)|$($asset.variantGroup)")) { throw "Training case '$($case.id)' shares a holdout group." }
    if ($asset.primaryFamily -ne $case.id -or !$families.Add($asset.primaryFamily)) {
        throw "Learning case '$($case.id)' must represent one distinct family."
    }
}
$expected = @($eligible | ForEach-Object primaryFamily | Where-Object { $_ -ne 'unknown' } | Sort-Object -Unique)
if (!$families.SetEquals([string[]]$expected)) { throw "Learning manifest must cover: $($expected -join ', ')." }
Write-Output "Corpus split checks passed ($packCount holdouts, $($families.Count) learning families)."
