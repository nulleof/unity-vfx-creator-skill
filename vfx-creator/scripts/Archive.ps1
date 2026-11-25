function Open-VfxArchive([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
        return [System.Formats.Tar.TarReader]::new($gzip)
    } catch {
        $stream.Dispose()
        throw
    }
}

function Get-VfxSafePath([string]$Root, [string]$RelativePath) {
    $normalized = $RelativePath.Replace('\', '/')
    if (!$normalized -or [IO.Path]::IsPathRooted($normalized) -or $normalized.Contains(':')) {
        throw "Invalid relative path '$RelativePath'."
    }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('/', '\')
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($rootPath, $normalized))
    $comparison = [StringComparison]::Ordinal
    if ($IsWindows) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    if (!$path.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw "Path '$RelativePath' escapes '$Root'."
    }
    $cursor = $path
    while ($cursor.Length -gt $rootPath.Length) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Path '$RelativePath' traverses a symbolic link or junction."
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $path
}

function Get-VfxArchiveIndex([string]$Path, [switch]$Dependencies) {
    $rows = @{}
    $archive = Open-VfxArchive $Path
    try {
        while ($entry = $archive.GetNextEntry($false)) {
            if ($entry.EntryType -notin @('RegularFile', 'V7RegularFile') -or !$entry.DataStream) { continue }
            if ($entry.Name -notmatch '^(?:\./)?([0-9a-f]{32})/(pathname|asset|asset\.meta)$') { continue }
            $guid = $Matches[1]
            $part = $Matches[2]
            if (!$rows.ContainsKey($guid)) {
                $rows[$guid] = @{
                    guid = $guid
                    path = ''
                    hasAsset = $false
                    dependencies = [Collections.Generic.HashSet[string]]::new()
                }
            }
            $row = $rows[$guid]
            if ($part -eq 'asset') { $row.hasAsset = $true }
            if (($part -ne 'pathname' -and !$Dependencies) -or $entry.Length -gt 32MB) { continue }
            $reader = [IO.StreamReader]::new($entry.DataStream, [Text.Encoding]::UTF8, $true, 1024, $true)
            try {
                if ($part -eq 'pathname') {
                    $line = $reader.ReadLine()
                    if ($line) { $row.path = $line.Trim([char[]]@(0, 10, 13, 32)).Replace('\', '/') }
                    continue
                }
                $prefix = [char[]]::new(5)
                $read = $reader.ReadBlock($prefix, 0, $prefix.Length)
                if ($part -eq 'asset' -and ($read -lt 5 -or (-join $prefix) -ne '%YAML')) { continue }
                foreach ($reference in [regex]::Matches($reader.ReadToEnd(), '(?i)\bguid:\s*([0-9a-f]{32})')) {
                    [void]$row.dependencies.Add($reference.Groups[1].Value.ToLowerInvariant())
                }
            } finally {
                $reader.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
    return $rows
}

function Export-VfxNestedPackage([string]$ArchivePath, [string]$Guid, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { return }
    $archive = Open-VfxArchive $ArchivePath
    $partial = "$Destination.partial-$([guid]::NewGuid().ToString('N'))"
    try {
        while ($entry = $archive.GetNextEntry($false)) {
            if ($entry.Name -notin @("$Guid/asset", "./$Guid/asset") -or !$entry.DataStream) { continue }
            $output = [IO.File]::Create($partial)
            try { $entry.DataStream.CopyTo($output) } finally { $output.Dispose() }
            [IO.File]::Move($partial, $Destination, $true)
            return
        }
        throw "Nested package '$Guid' is missing from '$ArchivePath'."
    } finally {
        $archive.Dispose()
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
    }
}

function Resolve-VfxArchive([string]$Path, [string]$Work, [string]$Nested) {
    $index = Get-VfxArchiveIndex $Path
    $packages = @($index.Values | Where-Object { $_.hasAsset -and $_.path -like '*.unitypackage' })
    if (!$Nested -and @($index.Values | Where-Object path -like '*.prefab').Count) { return $Path }
    if (!$Nested -and !$packages.Count) { return $Path }
    $candidates = @(if ($Nested) { $packages | Where-Object path -like $Nested } else { $packages | Where-Object path -match '(?i)\bURP\b|_URP_' })
    if ($candidates.Count -ne 1) {
        throw "Choose -Nested from these package paths: $($packages.path -join ', ')"
    }
    $package = $candidates[0]
    $info = Get-Item -LiteralPath $Path
    $destination = Join-Path $Work "$($package.guid)-$($info.Length)-$($info.LastWriteTimeUtc.Ticks).unitypackage"
    Export-VfxNestedPackage $Path $package.guid $destination
    return $destination
}

function Get-VfxPrefabRow($Index, [string]$Prefab) {
    $matches = @($Index.Values | Where-Object {
        $_.path -like '*.prefab' -and ($_.path -eq $Prefab -or [IO.Path]::GetFileNameWithoutExtension($_.path) -eq $Prefab)
    })
    if ($matches.Count -ne 1) { throw "Expected one prefab for '$Prefab'; found $($matches.Count). Use Inventory for the asset path." }
    return $matches[0]
}

function Install-VfxPackagePrefab([string]$Path, [string]$Prefab, [string]$Project) {
    $index = Get-VfxArchiveIndex $Path -Dependencies
    $root = Get-VfxPrefabRow $index $Prefab
    $selected = [Collections.Generic.HashSet[string]]::new()
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($root.guid)
    while ($queue.Count) {
        $guid = $queue.Dequeue()
        if (!$index.ContainsKey($guid) -or !$selected.Add($guid)) { continue }
        $row = $index[$guid]
        foreach ($dependency in $row.dependencies) { $queue.Enqueue($dependency) }
        if ($row.path -like '*.cs') {
            foreach ($companion in $index.Values) {
                if (Test-VfxPartialScript $row.path $companion.path) { $queue.Enqueue($companion.guid) }
            }
        }
        if ($row.path -match '\.(?:[a-z0-9]*shader|hlsl|cginc)$') {
            $parent = [IO.Path]::GetDirectoryName($row.path).Replace('\', '/')
            foreach ($include in $index.Values) {
                if ($include.path -match '\.(hlsl|cginc)$' -and $include.path.StartsWith("$parent/")) {
                    $queue.Enqueue($include.guid)
                }
            }
        }
    }
    $pending = @{}
    foreach ($guid in $selected) {
        $row = $index[$guid]
        if (!$row.hasAsset -or !$row.path.StartsWith('Assets/', [StringComparison]::Ordinal)) { continue }
        $pending[$guid] = Get-VfxSafePath $Project $row.path
    }
    $archive = Open-VfxArchive $Path
    try {
        while ($entry = $archive.GetNextEntry($false)) {
            if ($entry.EntryType -notin @('RegularFile', 'V7RegularFile') -or !$entry.DataStream) { continue }
            if ($entry.Name -notmatch '^(?:\./)?([0-9a-f]{32})/(asset|asset\.meta)$') { continue }
            $guid = $Matches[1]
            $part = $Matches[2]
            if (!$pending.ContainsKey($guid)) { continue }
            $destination = $pending[$guid]
            if ($part -eq 'asset.meta') { $destination += '.meta' }
            if (Test-Path -LiteralPath $destination) {
                $meta = $pending[$guid] + '.meta'
                if (!(Test-Path -LiteralPath $meta) -or !(Select-String -LiteralPath $meta -Quiet -SimpleMatch "guid: $guid")) {
                    throw "Reference staging collided with '$destination'. Use a fresh disposable stand."
                }
                continue
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew)
            try { $entry.DataStream.CopyTo($output) } finally { $output.Dispose() }
        }
    } finally {
        $archive.Dispose()
    }
    return $root.path
}

function Test-VfxPartialScript([string]$Script, [string]$Companion) {
    if ($Companion -notlike '*.cs' -or $Script -ieq $Companion) { return $false }
    $stem = $Script.Substring(0, $Script.Length - 3)
    $companionStem = $Companion.Substring(0, $Companion.Length - 3)
    return $companionStem.StartsWith("$stem.", [StringComparison]::OrdinalIgnoreCase) -or
        $stem.StartsWith("$companionStem.", [StringComparison]::OrdinalIgnoreCase)
}

function Install-VfxProjectPrefab([string]$SourceProject, [string]$Prefab, [string]$Stand) {
    if (!$Prefab.StartsWith('Assets/', [StringComparison]::Ordinal) -or !$Prefab.EndsWith('.prefab', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Use a project-relative Assets/.../*.prefab path. Use Inventory to find it.'
    }
    $rootAsset = Get-VfxSafePath $SourceProject $Prefab
    if (!(Test-Path -LiteralPath $rootAsset -PathType Leaf)) { throw "Could not find prefab '$Prefab'." }
    $assets = Get-VfxSafePath $SourceProject 'Assets'
    $guidPattern = '(?i)\bguid:\s*([0-9a-f]{32})'
    $files = @{}
    Get-ChildItem -LiteralPath $assets -File -Recurse -Filter '*.meta' | ForEach-Object {
        $match = [regex]::Match(((Get-Content -LiteralPath $_.FullName -TotalCount 4) -join "`n"), $guidPattern)
        if ($match.Success) { $files[$match.Groups[1].Value] = $_.FullName.Substring(0, $_.FullName.Length - 5) }
    }

    $selected = [Collections.Generic.HashSet[string]]::new()
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($rootAsset)
    while ($pending.Count) {
        $file = $pending.Dequeue()
        if (!$selected.Add($file) -or !(Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $relative = [IO.Path]::GetRelativePath($SourceProject, $file)
        $sourceAsset = Get-VfxSafePath $SourceProject $relative
        $destination = Get-VfxSafePath $Stand $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        foreach ($suffix in @('', '.meta')) {
            if (Test-Path -LiteralPath ($sourceAsset + $suffix) -PathType Leaf) {
                if (Test-Path -LiteralPath ($destination + $suffix)) {
                    $sourceHash = (Get-FileHash -LiteralPath ($sourceAsset + $suffix)).Hash
                    $destinationHash = (Get-FileHash -LiteralPath ($destination + $suffix)).Hash
                    if ($sourceHash -ne $destinationHash) { throw "Reference staging collided with '$relative$suffix'. Use a fresh stand." }
                } else {
                    Copy-Item -LiteralPath ($sourceAsset + $suffix) -Destination ($destination + $suffix)
                }
            }
        }
        $metadata = if (Test-Path -LiteralPath ($sourceAsset + '.meta')) { Get-Content -LiteralPath ($sourceAsset + '.meta') -Raw } else { '' }
        if ((Get-Item -LiteralPath $sourceAsset).Length -le 32MB) {
            $reader = [IO.File]::OpenText($sourceAsset)
            try {
                $prefix = [char[]]::new(5)
                if ($reader.ReadBlock($prefix, 0, 5) -eq 5 -and (-join $prefix) -eq '%YAML') {
                    $metadata += $reader.ReadToEnd()
                }
            } finally { $reader.Dispose() }
        }
        foreach ($dependency in [regex]::Matches($metadata, $guidPattern)) {
            $guid = $dependency.Groups[1].Value
            if ($files.ContainsKey($guid)) { $pending.Enqueue($files[$guid]) }
        }
        if ($sourceAsset -like '*.cs') {
            Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($sourceAsset)) -File -Filter '*.cs' |
                Where-Object { Test-VfxPartialScript $sourceAsset $_.FullName } | ForEach-Object { $pending.Enqueue($_.FullName) }
        }
        if ($sourceAsset -match '\.(?:[a-z0-9]*shader|hlsl|cginc)$') {
            Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($sourceAsset)) -File -Recurse |
                Where-Object Extension -In @('.hlsl', '.cginc') | ForEach-Object { $pending.Enqueue($_.FullName) }
        }
    }
    return $Prefab
}
