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
$cases += Get-Content -LiteralPath (Join-Path $repo 'evals/accuracy-cases.json') -Raw | ConvertFrom-Json -AsHashtable
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
    $expected = $case['catalogId'] ?? $case.id
    $result = & $pipeline Find -Brief $case.brief | Select-Object -First 1
    if (!$result -or $result.id -ne $expected) { throw "Brief did not select '$expected': $($case.brief)" }
    if ($SourceRoot) {
        $pack = Join-Path $SourceRoot $case.package
        $list = @(& $pipeline Inventory -Source $pack -ExpandNested -Work (Join-Path $repo '.vfx-work') |
            Where-Object { $_.path -eq $case.prefab -or [IO.Path]::GetFileNameWithoutExtension($_.path) -eq $case.prefab })
        if ($list.Count -ne 1) { throw "Expected one '$($case.prefab)' in '$pack'." }
    }
}
$profiles = Get-Content -LiteralPath (Join-Path $skill 'catalog-signatures.json') -Raw | ConvertFrom-Json -AsHashtable
if (!$recipes.SetEquals([string[]]$profiles.Keys)) { throw 'Catalog signatures must cover the catalog recipe IDs.' }
foreach ($id in $profiles.Keys) {
    $signature = ConvertTo-Json -InputObject $profiles[$id] -Compress
    $hits = @(& $pipeline Find -Brief 'zzznomatchingwords' -Signature $signature)
    if ($id -notin $hits.id) { throw "Catalog signature for '$id' cannot retrieve its recipe." }
}
$corpus = Get-Content -LiteralPath (Join-Path $repo 'evals/corpus-briefs.json') -Raw | ConvertFrom-Json -AsHashtable
$queries = Get-Content -LiteralPath (Join-Path $repo 'evals/corpus-signature-queries.json') -Raw | ConvertFrom-Json -AsHashtable
foreach ($fixture in @(@{ id = '03'; first = 'toon-star-hit' }, @{ id = '04'; first = 'warm-flash' })) {
    $brief = ($corpus | Where-Object id -eq $fixture.id).brief
    $query = ($queries | Where-Object id -eq $fixture.id).signature | ConvertTo-Json -Compress
    $legacy = & $pipeline Find -Brief $brief | Select-Object -First 1
    $ranked = & $pipeline Find -Brief $brief -Signature $query | Select-Object -First 1
    if ($legacy.id -ne 'blue-teal-teleport' -or $ranked.id -ne $fixture.first -or
        !(Test-Path -LiteralPath $ranked.path -PathType Leaf)) {
        throw "Unexpected text or signature ranking for '$($fixture.id)'."
    }
}
$partial = @(& $pipeline Find -Brief 'zzznomatchingwords' -Signature '{"silhouette":"crescent"}')
if ($partial.Count -ne 1 -or $partial[0].id -ne 'clean-sword-arc') {
    throw 'A partial signature must retrieve a match without shared keywords.'
}
$timed = & $pipeline Find -Brief 'zzznomatchingwords' -Signature '{"beatCount":2,"visibleDurationSec":0.4}' |
    Select-Object -First 1
if ($timed.id -ne 'gold-shockwave-burst') { throw 'Phase count must break a tie before visible duration.' }
foreach ($invalid in @('{}', '[]', '{"silhouette":"unknown"}', '{"Silhouette":"star"}', '{"beatCount":1.5}', '{"visibleDurationSec":0}')) {
    $rejected = $false
    try { & $pipeline Find -Brief 'flash' -Signature $invalid | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw "Accepted an invalid signature $invalid." }
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
    $installedHit = & $installedPipeline Find -Brief 'quick glint' -Signature '{"silhouette":"star","motion":"contract"}' |
        Select-Object -First 1
    if ($installedHit.id -ne 'warm-flash') { throw 'Installed signature search failed.' }
    $fixture = & $installedPipeline Find -Brief 'A compact lilac muzzle flash' | Select-Object -First 1
    $id = 'portable-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $receipt = & $installedPipeline Build -Project $target -Recipe $fixture.path -Id $id -RenderAfterBuild -Size 192 -Fps 20 -Duration 0.6
    if (!$receipt.ok -or !$receipt.visible -or !$receipt.dependencies.Count) { throw 'Portable build or capture failed.' }
    if (Test-Path -LiteralPath (Join-Path $receipt.capture 'effect.json')) { throw 'A legacy build exported an effect brief manifest.' }
    $receipt
}
Write-Output "VFX Creator smoke checks passed ($($cases.Count) reference briefs, $($recipes.Count) catalog recipes)."
