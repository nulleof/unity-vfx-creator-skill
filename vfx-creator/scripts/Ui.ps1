function Assert-VfxUiObject($Value, [string]$Field, [string[]]$Required, [string[]]$Optional = @()) {
    if ($Value -isnot [System.Collections.IDictionary]) { throw "$Field must be an object." }
    foreach ($key in $Required) {
        if ($key -cnotin $Value.psbase.Keys) { throw "$Field.$key is required." }
    }
    foreach ($key in $Value.psbase.Keys) {
        if ($key -cnotin ($Required + $Optional)) { throw "$Field.$key is unknown." }
    }
}

function Assert-VfxUiVersion($Value, [string]$Field) {
    if ($Value -isnot [long] -or $Value -ne 1) { throw "$Field must be 1." }
}

function Assert-VfxUiNumber($Value, [string]$Field, [double]$Min, [double]$Max) {
    if (($Value -isnot [long] -and $Value -isnot [double]) -or
        ![double]::IsFinite($Value) -or $Value -lt $Min -or $Value -gt $Max) {
        throw "$Field must be a number between $Min and $Max."
    }
}

function Assert-VfxUiPoint($Value, [string]$Field, [double]$Min, [double]$Max) {
    Assert-VfxUiObject $Value $Field @('x', 'y')
    foreach ($axis in 'x', 'y') { Assert-VfxUiNumber $Value[$axis] "$Field.$axis" $Min $Max }
}

function Read-VfxUiJson([string]$Path) {
    $options = @{ AsHashtable = $true; NoEnumerate = $true }
    if ($PSVersionTable.PSVersion -ge [version]'7.5') { $options.DateKind = 'String' }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json @options
}

function Read-VfxUiBrief([string]$Path) {
    $data = Read-VfxUiJson $Path
    $fields = @('version', 'id', 'description', 'trigger', 'target', 'anchor', 'footprint', 'order', 'clipping', 'retrigger', 'reducedMotion')
    Assert-VfxUiObject $data 'UI brief' $fields
    Assert-VfxUiVersion $data.version 'UI brief.version'
    if ($data.id -isnot [string] -or $data.id -cnotmatch '\A[a-z0-9][a-z0-9-]{0,63}\z') {
        throw 'UI brief.id must contain 1–64 lowercase letters, digits or hyphens and start with a letter or digit.'
    }
    foreach ($name in 'description', 'trigger', 'target', 'reducedMotion') {
        if ($data[$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($data[$name])) {
            throw "UI brief.$name must be a nonempty string."
        }
    }
    Assert-VfxUiPoint $data.anchor 'UI brief.anchor' 0 1
    Assert-VfxUiPoint $data.footprint 'UI brief.footprint' 0.01 4
    if ($data.order -isnot [string] -or $data.order -cnotin @('aboveContent', 'belowContent')) {
        throw 'UI brief.order must be aboveContent or belowContent.'
    }
    if ($data.clipping -isnot [string] -or $data.clipping -cnotin @('target', 'inherit')) {
        throw 'UI brief.clipping must be target or inherit.'
    }
    if ($data.retrigger -isnot [string] -or $data.retrigger -cnotin @('restart', 'ignoreWhilePlaying')) {
        throw 'UI brief.retrigger must be restart or ignoreWhilePlaying.'
    }
    return $data
}

function Test-VfxUiKeys($Keys, [string]$Field, [switch]$Standard) {
    if ($Keys -isnot [array] -or $Keys.Count -lt 2) { throw "$Field needs at least two keys." }
    $fields = @('time', 'opacity')
    if ($Standard) { $fields += @('position', 'scale') }
    $previous = [single]-1
    $visible = $false
    for ($index = 0; $index -lt $Keys.Count; $index++) {
        $key = $Keys[$index]
        $label = "$Field[$index]"
        Assert-VfxUiObject $key $label $fields
        Assert-VfxUiNumber $key.time "$label.time" 0 10
        Assert-VfxUiNumber $key.opacity "$label.opacity" 0 1
        if (($index -eq 0 -and $key.time -ne 0) -or [single]$key.time -le $previous) {
            throw "$label.time must start at zero and strictly increase."
        }
        if ($Standard) {
            Assert-VfxUiPoint $key.position "$label.position" -2 3
            Assert-VfxUiNumber $key.scale "$label.scale" 0 4
        }
        if ($key.opacity -gt 0 -and (!$Standard -or $key.scale -gt 0)) { $visible = $true }
        $previous = [single]$key.time
    }
    if ($Keys[-1].opacity -ne 0) { throw "$Field must end with opacity 0." }
    if ($Keys[-1].time -lt (1.0 / 60)) { throw "$Field must last at least 1/60 second." }
    return $visible
}

function Read-VfxUiRecipe([string]$Path) {
    $data = Read-VfxUiJson $Path
    Assert-VfxUiObject $data 'UI recipe' @('version', 'layers')
    Assert-VfxUiVersion $data.version 'UI recipe.version'
    if ($data.layers -isnot [array] -or !$data.layers.Count) { throw 'UI recipe.layers must be a nonempty array.' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $standardVisible = $false
    $reducedVisible = $false
    for ($index = 0; $index -lt $data.layers.Count; $index++) {
        $layer = $data.layers[$index]
        $field = "UI recipe.layers[$index]"
        Assert-VfxUiObject $layer $field @('name', 'shape', 'color', 'size', 'standard') @('reduced')
        if ($layer.name -isnot [string] -or $layer.name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 _-]{0,63}\z' -or !$names.Add($layer.name)) {
            throw "$field.name must be a unique 1–64 character layer name using letters, digits, spaces, underscores or hyphens."
        }
        if ($layer.shape -isnot [string] -or $layer.shape -cnotin @('ring', 'star', 'spark', 'glow')) {
            throw "$field.shape must be ring, star, spark or glow."
        }
        if ($layer.color -isnot [string] -or $layer.color -notmatch '\A#[0-9a-f]{6}\z') {
            throw "$field.color must be #RRGGBB."
        }
        Assert-VfxUiPoint $layer.size "$field.size" 0.01 4
        if (Test-VfxUiKeys $layer.standard "$field.standard" -Standard) { $standardVisible = $true }
        if ('reduced' -cin $layer.Keys) {
            Assert-VfxUiObject $layer.reduced "$field.reduced" @('position', 'scale', 'keys')
            Assert-VfxUiPoint $layer.reduced.position "$field.reduced.position" -2 3
            Assert-VfxUiNumber $layer.reduced.scale "$field.reduced.scale" 0.01 4
            if (Test-VfxUiKeys $layer.reduced.keys "$field.reduced.keys") { $reducedVisible = $true }
        }
    }
    if (!$standardVisible -or !$reducedVisible) { throw 'UI recipe needs at least one visible layer in both standard and reduced motion.' }
    return $data
}

function Assert-VfxUgui([string]$ProjectPath) {
    foreach ($name in 'manifest.json', 'packages-lock.json') {
        $path = Join-Path $ProjectPath "Packages/$name"
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $packages = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        if ($packages['dependencies'] -and $packages['dependencies'].Contains('com.unity.ugui')) { return }
    }
    throw 'BuildUi requires the com.unity.ugui package in the target Unity project.'
}
