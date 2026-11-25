[CmdletBinding()]
param(
    [Alias('SourceRoot')][string]$EffectsRoot = 'C:/WORK/Effects',
    [Alias('Work')][string]$WorkRoot = (Join-Path $PSScriptRoot '../.vfx-work/corpus'),
    [switch]$Refresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$archiveReader = Join-Path $PSScriptRoot '../vfx-creator/scripts/Archive.ps1'
. $archiveReader

$archiveNamePattern = '^(?:\./)?([0-9a-f]{32})/asset$'
$classPattern = [regex]::new('(?m)^--- !u!(\d+)\s*&', 'Compiled')
$guidPattern = [regex]::new('(?i)\bguid:\s*([0-9a-f]{32})', 'Compiled')
$prefabPattern = [regex]::new('(?im)^\s*m_SourcePrefab:\s*\{[^}\r\n]*\bguid:\s*([0-9a-f]{32})', 'Compiled')

function Write-CorpusJson($Value, [string]$Path) {
    $partial = "$Path.partial-$([guid]::NewGuid().ToString('N'))"
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 24
        [IO.File]::WriteAllText($partial, ($json -replace '\r?\n', "`n") + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($partial, $Path, $true)
    } finally {
        if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
    }
}

function Get-CorpusArchiveScan([string]$ArchivePath, [string]$Sha256) {
    $cachePath = Get-VfxSafePath $cacheDirectory "$scannerKey-$Sha256.json"
    if (!$Refresh -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        Write-Verbose "Cache hit: $Sha256"
        return (Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -AsHashtable)
    }
    Write-Verbose "Scanning: $ArchivePath"
    $index = Get-VfxArchiveIndex $ArchivePath
    $paths = @{}
    $nested = [Collections.Generic.List[object]]::new()
    $assets = [Collections.Generic.List[object]]::new()
    $hints = [Collections.Generic.List[string]]::new()
    $pending = @{}
    foreach ($row in $index.Values) {
        if (!$row.path) { continue }
        $paths[$row.guid] = $row.path
        if ($row.hasAsset -and $row.path -match '(^|/)(ScenesURP|ScenesHDRP)(/|$)|(^|/)[^/]+_(URP|HDRP)\.(?:cginc|shader)$') {
            $hints.Add($row.path)
        }
        if ($row.path -match '\.(prefab|vfx|vfxoperator|vfxblock|unity|unitypackage)$') { $pending[$row.guid] = $row }
    }

    $archive = Open-VfxArchive $ArchivePath
    try {
        while ($entry = $archive.GetNextEntry($false)) {
            if ($entry.EntryType -notin @('RegularFile', 'V7RegularFile') -or !$entry.DataStream) { continue }
            if ($entry.Name -notmatch $archiveNamePattern -or !$pending.ContainsKey($Matches[1])) { continue }
            $guid = $Matches[1]
            $path = $paths[$guid]
            $pending.Remove($guid)
            $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
            if ($extension -eq '.unitypackage') {
                $partial = Get-VfxSafePath $archiveDirectory ("nested-$([guid]::NewGuid().ToString('N')).partial")
                try {
                    $stream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew)
                    try { $entry.DataStream.CopyTo($stream) } finally { $stream.Dispose() }
                    $nestedSha = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
                    $destination = Get-VfxSafePath $archiveDirectory "$nestedSha.unitypackage"
                    [IO.File]::Move($partial, $destination, $true)
                    $nested.Add([ordered]@{ path = $path; guid = $guid; sha256 = $nestedSha; bytes = $entry.Length })
                } finally {
                    if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
                }
                continue
            }

            $row = [ordered]@{
                path = $path
                guid = $guid
                kind = switch ($extension) {
                    '.unity' { 'scene' }
                    '.vfxoperator' { 'vfx-subgraph' }
                    '.vfxblock' { 'vfx-subgraph' }
                    default { $extension.Substring(1) }
                }
                serialized = 'empty'
                componentIds = @()
                referencedGuids = @()
                prefabSourceGuids = @()
            }
            if ($entry.Length -gt 64MB) {
                $row.serialized = 'over-inspection-limit'
            } elseif ($entry.Length -gt 0) {
                $reader = [IO.StreamReader]::new($entry.DataStream, [Text.Encoding]::UTF8, $true, 4096, $true)
                try {
                    $prefix = [char[]]::new(5)
                    if ($reader.ReadBlock($prefix, 0, $prefix.Length) -eq 5 -and (-join $prefix) -ceq '%YAML') {
                        $serialized = $reader.ReadToEnd()
                        $row.serialized = 'unity-yaml'
                        $row.componentIds = @($classPattern.Matches($serialized) | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
                        $row.referencedGuids = @($guidPattern.Matches($serialized) | ForEach-Object {
                            $reference = $_.Groups[1].Value.ToLowerInvariant()
                            if ($reference -ne $guid) { $reference }
                        } | Sort-Object -Unique)
                        $row.prefabSourceGuids = @($prefabPattern.Matches($serialized) | ForEach-Object {
                            $_.Groups[1].Value.ToLowerInvariant()
                        } | Sort-Object -Unique)
                    } else {
                        $row.serialized = 'non-yaml'
                    }
                } finally {
                    $reader.Dispose()
                }
            }
            $assets.Add($row)
        }
    } finally {
        $archive.Dispose()
    }

    foreach ($remaining in $pending.Values | Where-Object { $_.path -notlike '*.unitypackage' }) {
        $assets.Add([ordered]@{
            path = $remaining.path
            guid = $remaining.guid
            kind = switch ([IO.Path]::GetExtension($remaining.path).ToLowerInvariant()) {
                '.unity' { 'scene' }
                '.vfxoperator' { 'vfx-subgraph' }
                '.vfxblock' { 'vfx-subgraph' }
                default { [IO.Path]::GetExtension($remaining.path).Substring(1).ToLowerInvariant() }
            }
            serialized = 'missing-asset'
            componentIds = @()
            referencedGuids = @()
            prefabSourceGuids = @()
        })
    }
    $scan = [ordered]@{
        archiveAssetCount = @($index.Values | Where-Object hasAsset).Count
        assets = @($assets | Sort-Object { $_.path }, { $_.guid } -CaseSensitive)
        nested = @($nested | Sort-Object { $_.path }, { $_.guid } -CaseSensitive)
        pipelineHints = @($hints | Sort-Object -Unique)
    }
    Write-CorpusJson $scan $cachePath
    return $scan
}

function Get-CorpusTokens([string]$Name) {
    $words = $Name -creplace '([a-z0-9])([A-Z])', '$1 $2'
    return ($words.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim()
}

$families = [ordered]@{
    'muzzle-flash' = '\b(muzzle(?: ?(?:flash|flare))?|flash(?: \d+)?$)\b'
    'teleport' = '\b(teleport\w*|warp(?: in| out)?)\b'
    'portal' = '\b(portal\w*|gateway\w*|wormhole\w*)\b'
    'dissolve' = '\b(dissolv\w*|disintegrat\w*|dm)\b'
    'shield' = '\b(shield\w*|barrier\w*|block(?:ing)?|protection|defen[cs]\w*|deflect\w*)\b'
    'healing' = '\b(heal\w*|regeneration)\b'
    'aura' = '\b(aura\w*|halo)\b'
    'summon' = '\b(summon\w*|spawn)\b'
    'text' = '\b(text\w*|font)\b'
    'impact' = '\b(impact\w*|hit\w*|contact|punch|pow|splat|splash(?:es)?)\b'
    'explosion' = '\b(explos\w*|firework\w*|shockwave\w*|detonation|blast)\b'
    'slash' = '\b(slash\w*|swipe\w*|sword ?arc|melee)\b'
    'trail' = '\b(trail\w*|streak\w*|thruster\w*)\b'
    'projectile' = '\b(projectile\w*|missile\w*|bullet\w*|rocket\w*|arrow\w*|fireball\w*|shot\w*|shoot\w*|comet\w*)\b'
    'beam' = '\b(beam\w*|laser\w*|ray(?:s)?)\b'
    'lightning' = '\b(lightning\w*|electric\w*|thunder\w*|zap\w*)\b'
    'fire' = '\b(fire\w*|flame\w*|burn\w*|torch\w*)\b'
    'smoke' = '\b(smoke\w*|cloud\w*|steam\w*|fog|mist)\b'
    'buff' = '\b(buff\w*|blessing|energiz\w*|empower\w*|encouragement|rage|level ?up|enchant\w*)\b'
    'debuff' = '\b(debuff\w*|decay|malediction|touch of the dead|poison\w*|curse\w*)\b'
    'orb' = '\b(orb\w*|sphere\w*|bubble\w*|ball\w*)\b'
    'ground' = '\b(earth\w*|ground\w*|crater\w*|rock\w*|rune\w*|circle\w*)\b'
    'environment' = '\b(environment\w*|star\w*|dust\w*|wind\w*|tornado\w*|snow\w*|rain\w*|leaf\w*|leaves|ambient\w*|debris|flies)\b'
    'loot' = '\b(loot\w*|pick ?up\w*|treasure\w*)\b'
    'ice' = '\b(ice\w*|frost\w*|freez\w*)\b'
    'liquid' = '\b(liquid\w*|water\w*|blood\w*|radioactive waste)\b'
    'distortion' = '\bdistortion\w*\b'
    'weapon' = '\b(weapon\w*|sword\w*|axe\w*)\b'
    'movement' = '\b(leap\w*|sprint\w*|dash\w*|jump\w*)\b'
    'sparks' = '\b(spark\w*|glow\w*|embers)\b'
    'burst' = '\b((?:out)?burst\w*|pulse\w*|waves?|ring\w*|flash\w*)\b'
}

function Get-CorpusFamily([string]$Name, [string]$Path) {
    $tokens = $Name
    foreach ($source in @('asset-name', 'collection-folder')) {
        if ($source -eq 'collection-folder') {
            # Recognize effect categories under asset folders without treating publisher or package names as categories.
            $collection = [regex]::Match($Path, '(?i)/(?:[^/]*prefabs|visual effects|scenes)/(.*)/[^/]+$')
            if (!$collection.Success) { break }
            $tokens = Get-CorpusTokens $collection.Groups[1].Value
        }
        foreach ($key in $families.Keys) {
            if ($tokens -match $families[$key]) { return @{ name = $key; basis = $source } }
        }
    }
    return @{ name = 'unknown'; basis = 'no-family-name-match' }
}

function Get-CorpusPipeline([string]$Package, [string[]]$Chain, $Scan) {
    if ($Chain.Count) {
        $qualifier = $Chain[-1]
        if ($qualifier -match '(?i)(?:\b|_)HDRP(?:\b|_)') {
            return @{ name = 'hdrp'; disposition = 'alternate'; basis = 'nested-archive-label' }
        }
        if ($qualifier -match '(?i)(?:\b|_)(?:URP|LWRP)(?:\b|_)') {
            return @{ name = 'urp'; disposition = 'native'; basis = 'nested-archive-label' }
        }
        if ($qualifier -match '(?i)\blegacy\b') {
            return @{ name = 'built-in'; disposition = 'alternate'; basis = 'legacy-nested-edition' }
        }
    }
    if ($Package -match '^Cartoon FX 4 Remaster' -and $Scan.pipelineHints.Count) {
        return @{ name = 'urp'; disposition = 'compatible'; basis = 'packaged-urp-shader-and-remaster-documentation' }
    }
    if (@($Scan.pipelineHints | Where-Object { $_ -match '/ScenesURP/' }).Count) {
        return @{ name = 'urp'; disposition = 'compatible'; basis = 'packaged-urp-demo-scenes' }
    }
    if ($Package -match '^(AAA Stylized Projectiles|Toon_Projectiles_2)') {
        return @{ name = 'built-in'; disposition = 'requires-urp-check'; basis = 'packaged-readme-documents-standard-rendering-distortion' }
    }
    return @{ name = 'unknown'; disposition = 'requires-urp-check'; basis = 'no-pipeline-evidence' }
}

function Get-CorpusRenderers($Row, $Index, [Collections.Generic.HashSet[string]]$Visited) {
    if (!$Visited.Add($Row.guid)) { return }
    $classes = $Row.componentIds
    # Unity YAML IDs: https://docs.unity3d.com/6000.0/Documentation/Manual/ClassIDReference.html
    if ($Row.kind -in @('vfx', 'vfx-subgraph') -or 2083052967 -in $classes -or 73398921 -in $classes) { 'vfx-graph' }
    if (198 -in $classes -or 199 -in $classes -or 12 -in $classes -or 15 -in $classes -or 26 -in $classes) { 'particle-system' }
    if (96 -in $classes) { 'trail' }
    if (120 -in $classes) { 'line' }
    if (23 -in $classes -or 137 -in $classes) { 'mesh' }
    if (212 -in $classes) { 'sprite' }
    foreach ($dependency in $Row.prefabSourceGuids) {
        if ($Index.ContainsKey($dependency)) { Get-CorpusRenderers $Index[$dependency] $Index $Visited }
    }
}

function Get-CorpusVariantKey($Row, [string]$Package, $Index) {
    $name = [IO.Path]::GetFileNameWithoutExtension($Row.path)
    $source = $Row
    $visited = [Collections.Generic.HashSet[string]]::new()
    while ($source.prefabSourceGuids.Count -eq 1 -and $visited.Add($source.guid) -and $source.componentIds.Count -le 3) {
        $baseGuid = $source.prefabSourceGuids[0]
        if (!$Index.ContainsKey($baseGuid)) { break }
        $source = $Index[$baseGuid]
        $name = [IO.Path]::GetFileNameWithoutExtension($source.path)
    }

    $name = Get-CorpusTokens $name
    $name = $name -replace '^(?:vfxgraph|vfx graph|vfx|cfxr\d*|cfx\d*)\s+', ''
    $name = $name -replace '\bv\d+\b.*$', ''
    $name = $name -replace '\b(?:red|orange|yellow|green|blue|purple|violet|pink|teal|cyan|white|black|gold(?:en)?|emerald|magenta|silver|indigo|turquoise|lime|brown|gray|grey|azure|bronze|crimson|khaki|sepia|hdr)\b', ''
    $name = $name -replace '\b(?:skinned mesh(?:es)?|simple meshes|simple|with light|2 ?d|template|small|medium|big|large)\b', ''
    $name = $name -replace '\bvfx\b', ''
    if ($Package -match '^Stylized Projectile Pack') {
        $parts = $name.Trim().Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Count -ge 2 -and $parts[0] -in @('bullet', 'laser', 'plasma')) { $name = "$($parts[0]) $($parts[-1])" }
    }
    $name = ($name -replace '\s+', '-').Trim('-')
    if (!$name) { return $Row.guid }
    return $name
}

function Add-CorpusArchive(
    [string]$ArchivePath, [string]$ArchiveSha, [long]$Bytes, [string]$Package, [string]$PackageSha,
    [string[]]$Chain, [string[]]$AncestorHashes
) {
    if ($ArchiveSha -in $AncestorHashes) { throw "Repeated archive contents within nested chain '$($Chain -join ' -> ')'." }
    if ($Chain.Count -gt 12) { throw "Nested archive limit exceeded for '$Package'." }
    $scan = Get-CorpusArchiveScan $ArchivePath $ArchiveSha
    $pipeline = Get-CorpusPipeline $Package $Chain $scan
    $nestedPackage = if ($Chain.Count) { $Chain[-1] } else { $null }
    $archiveRows.Add([ordered]@{
        package = $Package
        packageSha256 = $PackageSha
        archiveSha256 = $ArchiveSha
        archiveChain = $Chain
        nestedPackage = $nestedPackage
        bytes = $Bytes
        pipeline = $pipeline.name
        pipelineDisposition = $pipeline.disposition
        pipelineEvidence = $pipeline.basis
        pipelineHintPaths = $scan.pipelineHints
        archiveAssetCount = $scan.archiveAssetCount
        inventoriedAssets = $scan.assets.Count
    })

    $index = @{}
    $referencedBy = @{}
    foreach ($row in $scan.assets) {
        $index[$row.guid] = $row
        foreach ($reference in $row.referencedGuids) {
            if (!$referencedBy.ContainsKey($reference)) { $referencedBy[$reference] = [Collections.Generic.List[string]]::new() }
            $referencedBy[$reference].Add($row.path)
        }
    }
    foreach ($row in $scan.assets) {
        $name = Get-CorpusTokens ([IO.Path]::GetFileNameWithoutExtension($row.path))
        $family = Get-CorpusFamily $name $row.path
        $visited = [Collections.Generic.HashSet[string]]::new()
        $renderers = @(Get-CorpusRenderers $row $index $visited | Sort-Object -Unique)
        $renderer = switch ($renderers.Count) {
            0 { 'unknown' }
            1 { $renderers[0] }
            default { 'mixed' }
        }
        $role = 'effect'
        $reason = 'effect-prefab-with-renderer-evidence'
        if ($row.serialized -in @('missing-asset', 'empty')) {
            $role = 'unknown'
            $reason = 'no-asset-payload'
        } elseif ($row.kind -eq 'scene') {
            $role = 'helper'
            $reason = 'scene-context-requires-scene-specific-extraction'
        } elseif ($row.kind -in @('vfx', 'vfx-subgraph')) {
            $role = 'dependency'
            $reason = if ($referencedBy.ContainsKey($row.guid)) {
                'graph-source-referenced-by-inventoried-assets'
            } else {
                'standalone-graph-source-requires-capture-wrapper'
            }
        } elseif ($row.path -match '(?i)/(?:Demo(?: Assets| Scene| Scenes)?|Samples?|Helpers?|Example(?:s)?)/' -or
            $name -match '^(?:camera(?: rig)?|demo(?: manager| controller)?|ground plane|dummy(?: target)?|scene controller|fps ?character|canvas)$') {
            $role = 'helper'
            $reason = 'demo-or-helper-prefab-path'
        } elseif ($renderer -eq 'unknown' -or $family.name -eq 'unknown') {
            $role = 'unknown'
            $reason = if ($renderer -eq 'unknown') { 'no-supported-renderer-evidence' } else { 'family-requires-review' }
        }

        $status = $role
        if ($pipeline.disposition -eq 'alternate' -and $role -in @('effect', 'unknown')) {
            $status = 'alternate-pipeline'
            $reason = 'archive-is-an-alternate-pipeline-or-legacy-edition'
        } elseif ($role -eq 'effect') {
            $status = 'candidate'
        }
        $variantKey = Get-CorpusVariantKey $row $Package $index
        $packageKey = (Get-CorpusTokens ([IO.Path]::GetFileNameWithoutExtension($Package))) -replace ' ', '-'
        $identity = "$Package`n$($Chain -join "`n")`n$($row.path)`n$($row.guid)"
        $id = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
        $usedBy = if ($referencedBy.ContainsKey($row.guid)) { @($referencedBy[$row.guid] | Sort-Object -Unique) }
        $assetRows.Add([ordered]@{
            id = $id
            package = $Package
            packageSha256 = $PackageSha
            archiveSha256 = $ArchiveSha
            archiveChain = $Chain
            nestedPackage = $nestedPackage
            path = $row.path
            guid = $row.guid
            kind = $row.kind
            pipeline = $pipeline.name
            pipelineDisposition = $pipeline.disposition
            renderer = $renderer
            primaryFamily = $family.name
            variantGroup = "$packageKey/$($row.kind)/$variantKey"
            representativeId = $null
            status = $status
            role = $role
            reason = $reason
            evidence = [ordered]@{
                serialization = $row.serialized
                unityClassIds = $row.componentIds
                rendererKinds = $renderers
                inheritedPrefabGuids = @($visited | Where-Object { $_ -ne $row.guid } | Sort-Object)
                graphGuids = @($row.referencedGuids | Where-Object { $index.ContainsKey($_) -and $index[$_].kind -like 'vfx*' })
                referencedBy = @($usedBy | Where-Object { $_ })
                primaryFamilyBasis = $family.basis
                pipelineBasis = $pipeline.basis
            }
        })
    }

    foreach ($nested in $scan.nested) {
        $nestedPath = Get-VfxSafePath $archiveDirectory "$($nested.sha256).unitypackage"
        if (!(Test-Path -LiteralPath $nestedPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $nestedPath -Algorithm SHA256).Hash -ne $nested.sha256) {
            $staged = Get-VfxSafePath $archiveDirectory ("restore-$([guid]::NewGuid().ToString('N')).partial")
            try {
                Export-VfxNestedPackage $ArchivePath $nested.guid $staged
                if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $nested.sha256) {
                    throw "Nested archive '$($nested.path)' changed during inventory."
                }
                [IO.File]::Move($staged, $nestedPath, $true)
            } finally {
                if ([IO.File]::Exists($staged)) { [IO.File]::Delete($staged) }
            }
        }
        Add-CorpusArchive $nestedPath $nested.sha256 $nested.bytes $Package $PackageSha (@($Chain) + $nested.path) (@($AncestorHashes) + $ArchiveSha)
    }
}

function Get-CorpusCounts($Rows, [string]$Property) {
    $counts = [ordered]@{}
    foreach ($group in $Rows | Group-Object -Property { $_[$Property] } | Sort-Object Name -CaseSensitive) {
        $counts[$group.Name] = $group.Count
    }
    return $counts
}

$source = Get-Item -LiteralPath $EffectsRoot
if (!$source.PSIsContainer) { throw "Expected an effects directory: '$EffectsRoot'." }
$workPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkRoot)
$directory = $workPath
while ($directory) {
    $item = Get-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Inventory work path traverses a symbolic link or junction: '$directory'."
    }
    $directory = [IO.Path]::GetDirectoryName($directory)
}
$relativeWork = [IO.Path]::GetRelativePath($source.FullName, $workPath)
if ($relativeWork -ne '..' -and !$relativeWork.StartsWith("..$([IO.Path]::DirectorySeparatorChar)") -and
    ![IO.Path]::IsPathRooted($relativeWork)) {
    throw 'The inventory work directory must be outside the read-only effects directory.'
}
$files = @(Get-ChildItem -LiteralPath $source.FullName -File -Recurse -Filter '*.unitypackage' |
    Where-Object { !($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | Sort-Object FullName -CaseSensitive)
if (!$files.Count) { throw "No .unitypackage archives found in '$EffectsRoot'." }

$cacheDirectory = Get-VfxSafePath $workPath 'cache'
$archiveDirectory = Get-VfxSafePath $workPath 'archives'
[void][IO.Directory]::CreateDirectory($cacheDirectory)
[void][IO.Directory]::CreateDirectory($archiveDirectory)
$readerHash = (Get-FileHash -LiteralPath $archiveReader -Algorithm SHA256).Hash
$scannerDefinition = (Get-Command Get-CorpusArchiveScan).Definition
$scannerKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(
    "$readerHash`n$archiveNamePattern`n$classPattern`n$guidPattern`n$prefabPattern`n$scannerDefinition"
))).ToLowerInvariant()
$archiveRows = [Collections.Generic.List[object]]::new()
$assetRows = [Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    $package = [IO.Path]::GetRelativePath($source.FullName, $file.FullName).Replace('\', '/')
    $sha = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-CorpusArchive $file.FullName $sha $file.Length $package $sha @() @()
}

foreach ($group in $assetRows | Group-Object { $_.variantGroup }) {
    # Prefer authored base prefabs and the transform-driven projectile where available.
    $members = @($group.Group | Where-Object { $_.status -eq 'candidate' } | Sort-Object @{ Expression = {
        if ($_.path -match '(?i)/variants[^/]*/|\(particle collision\)|projectiles 2d') { 2 }
        elseif ($_.evidence.inheritedPrefabGuids.Count) { 1 }
        else { 0 }
    } }, { $_.path.Length }, { $_.path }, { $_.id } -CaseSensitive)
    if (!$members.Count) { continue }
    foreach ($member in $group.Group) { $member.representativeId = $members[0].id }
    foreach ($member in $members | Select-Object -Skip 1) {
        $member.status = 'variant'
        $member.reason = 'related-variant-of-candidate-in-same-group'
    }
}

$output = [ordered]@{
    schemaVersion = 1
    packages = $archiveRows.ToArray()
    assets = $assetRows.ToArray()
    summary = [ordered]@{
        topLevelPackages = $files.Count
        archives = $archiveRows.Count
        assets = $assetRows.Count
        byStatus = Get-CorpusCounts $assetRows 'status'
        byKind = Get-CorpusCounts $assetRows 'kind'
        byPipeline = Get-CorpusCounts $assetRows 'pipeline'
        byRenderer = Get-CorpusCounts $assetRows 'renderer'
        byPrimaryFamily = Get-CorpusCounts $assetRows 'primaryFamily'
    }
}
$inventoryPath = Get-VfxSafePath $workPath 'inventory.json'
Write-CorpusJson $output $inventoryPath
Write-Host "Inventoried $($assetRows.Count) assets in $($archiveRows.Count) archives across $($files.Count) packages."
Write-Output $inventoryPath
