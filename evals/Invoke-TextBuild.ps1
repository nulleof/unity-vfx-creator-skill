[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$Pipeline,
    [Parameter(Mandatory)][string]$Brief,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][string]$CaptureJson,
    [Parameter(Mandatory)][int]$Size,
    [switch]$FreshCodex,
    [switch]$SelectionOnly
)
$ErrorActionPreference = 'Stop'
$matches = @(& $Pipeline Find -Brief $Brief)
$match = $matches | Select-Object -First 1
if ($FreshCodex) {
    $session = Join-Path ([IO.Path]::GetTempPath()) ('vfx-text-' + [guid]::NewGuid().ToString('N'))
    $installDirectory = Join-Path $session '.agents/skills/vfx-creator'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $installDirectory))
    $skill = Split-Path -Parent (Split-Path -Parent $Pipeline)
    Copy-Item -LiteralPath $skill -Destination $installDirectory -Recurse
    $schema = Join-Path $session 'response.schema.json'
    $reply = Join-Path $session 'response.json'
    '{"type":"object","properties":{"recipeId":{"type":"string"}},"required":["recipeId"],"additionalProperties":false}' |
        Set-Content -LiteralPath $schema
    $cards = Get-ChildItem -LiteralPath (Join-Path $installDirectory 'catalog') -Filter '*.json' -File | ForEach-Object {
        $card = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        "$($card.id) | $($card.title) | $($card.description) | $($card.tags -join ', ')"
    }
    $prompt = "Act as the recipe selection step of the vfx-creator skill. Pick the single best recipe for the text brief. The supplied catalog is complete for this test. Return its recipe ID using the response schema.`n`nBrief: $Brief`n`nCatalog:`n$($cards -join "`n")"
    $prompt | & codex exec --ephemeral --skip-git-repo-check --sandbox read-only -c 'model_reasoning_effort="low"' -C $session --output-schema $schema -o $reply - | Out-Host
    if ($LASTEXITCODE -or !(Test-Path -LiteralPath $reply)) { throw 'The fresh Codex session did not return a recipe.' }
    $selection = Get-Content -LiteralPath $reply -Raw | ConvertFrom-Json
    if ($selection.recipeId -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Invalid recipe ID returned by Codex.' }
    $path = Join-Path $skill "catalog/$($selection.recipeId).json"
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Unknown recipe '$($selection.recipeId)'." }
    $match = [pscustomobject]@{ id = $selection.recipeId; path = $path }
}
if (!$match) { throw "No recipe matched '$Brief'." }
if ($SelectionOnly) {
    @{ recipeId = $match.id } | ConvertTo-Json -Compress
    return
}
$capture = ConvertFrom-Json -InputObject $CaptureJson -AsHashtable
$id = $match.id + '-eval-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$receipt = & $Pipeline Build -Project $Project -Recipe $match.path -Id $id -RenderAfterBuild -Output $Output -Size $Size @capture
$receipt | ConvertTo-Json -Depth 6
