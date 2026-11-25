function Wait-VfxUnitySlot {
    $repositoryWork = Join-Path (Split-Path -Parent $PSScriptRoot) '.vfx-work'
    [void][IO.Directory]::CreateDirectory($repositoryWork)
    $path = Join-Path $repositoryWork 'blind-author-unity.lock'
    $identity = if ($IsWindows) { $path.ToUpperInvariant() } else { $path }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
    $mutex = [Threading.Mutex]::new($false, "VfxCreator-$hash")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(12)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (!$acquired) { throw 'Timed out waiting for the Unity evaluation queue.' }

        # The file also arbitrates Unity workers launched in another OS session.
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes(12)
        while ($true) {
            try { $file = [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None'); break }
            catch [IO.IOException] {
                if ([DateTimeOffset]::UtcNow -ge $deadline) { throw }
                Start-Sleep -Milliseconds 400
            }
        }
        return ([pscustomobject]@{ File = $file; Mutex = $mutex } | Add-Member -PassThru -MemberType ScriptMethod -Name Dispose -Value {
            try { $this.File.Dispose() } finally {
                try { $this.Mutex.ReleaseMutex() } finally { $this.Mutex.Dispose() }
            }
        })
    } catch {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        throw
    }
}
