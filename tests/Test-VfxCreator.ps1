[CmdletBinding()]
param(
    [string]$UnityProject,
    [string]$SourceRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$repo = Split-Path -Parent $PSScriptRoot
$skill = Join-Path $repo 'vfx-creator'
$pipeline = Join-Path $skill 'scripts/vfx.ps1'
$cases = Get-Content -LiteralPath (Join-Path $repo 'evals/cases.json') -Raw | ConvertFrom-Json -AsHashtable
$recipes = [Collections.Generic.HashSet[string]]::new()
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $skill 'catalog') -Filter '*.json' -File) {
    $recipe = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    if ($recipe.version -ne 1 -or $recipe.id -ne $file.BaseName -or !$recipes.Add($recipe.id) -or !$recipe.layers.Count) {
        throw "Invalid catalog recipe '$($file.Name)'."
    }
    if (Select-String -LiteralPath $file.FullName -Pattern '\.unitypackage|C:\\WORK\\Effects|"guid"|"base64"' -Quiet) {
        throw "Found source references or payloads in '$($file.Name)'."
    }
}
foreach ($case in $cases) {
    $result = & $pipeline Find -Brief $case.brief | Select-Object -First 1
    if (!$result -or $result.id -ne $case.id) { throw "Brief did not select '$($case.id)': $($case.brief)" }
    if ($SourceRoot) {
        $pack = Join-Path $SourceRoot $case.package
        $list = @(& $pipeline Inventory -Source $pack -ExpandNested -Work (Join-Path $repo '.vfx-work') |
            Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.path) -eq $case.prefab })
        if ($list.Count -ne 1) { throw "Expected one '$($case.prefab)' in '$pack'." }
    }
}
if ($UnityProject) {
    $target = (Get-Item -LiteralPath $UnityProject).FullName
    $skillDirectory = Join-Path $target '.agents/skills'
    $installed = Join-Path $skillDirectory 'vfx-creator'
    if (!(Test-Path -LiteralPath $installed)) {
        [void][IO.Directory]::CreateDirectory($skillDirectory)
        Copy-Item -LiteralPath $skill -Destination $installed -Recurse
    }
    $installedPipeline = Join-Path $installed 'scripts/vfx.ps1'
    $fixture = & $installedPipeline Find -Brief 'A compact lilac muzzle flash' | Select-Object -First 1
    $id = 'portable-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $receipt = & $installedPipeline Build -Project $target -Recipe $fixture.path -Id $id -RenderAfterBuild -Size 192 -Fps 20 -Duration 0.6
    if (!$receipt.ok -or !$receipt.visible -or !$receipt.dependencies.Count) { throw 'Portable build or capture failed.' }
    $receipt
}
Write-Output "VFX Creator smoke checks passed ($($cases.Count) reference briefs, $($recipes.Count) catalog recipes)."
