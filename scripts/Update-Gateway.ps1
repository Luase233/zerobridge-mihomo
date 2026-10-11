#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$GatewayRoot = 'C:\ZeroTierGateway', [switch]$PhoneDefaultRouteIsOff)

$ErrorActionPreference = 'Stop'
if (-not $PhoneDefaultRouteIsOff) { throw 'Turn OFF the phone Enable Default Route and keep it OFF until the update and checks complete.' }
$expectedVersion = '0.3.2'
$repoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$GatewayRoot = [IO.Path]::GetFullPath($GatewayRoot).TrimEnd('\')
if ($GatewayRoot.Contains('"') -or $GatewayRoot.Contains("`n") -or $GatewayRoot.Contains("`r") -or $GatewayRoot -eq $repoRoot -or $GatewayRoot.Length -le [IO.Path]::GetPathRoot($GatewayRoot).TrimEnd('\').Length) { throw 'Use a separate installation directory with a valid path.' }

function Assert-GatewayUpdatePath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Update paths must not contain links or junctions.' }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
function Gateway-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Copy-GatewayVerified([string]$Source, [string]$Target, [string]$ExpectedHash) {
    Assert-GatewayUpdatePath $Source; Assert-GatewayUpdatePath $Target
    if ((Gateway-Hash $Source) -ne $ExpectedHash) { throw 'An update or backup file changed before copying.' }
    Copy-Item -LiteralPath $Source -Destination $Target -Force
    if ((Gateway-Hash $Target) -ne $ExpectedHash) { throw 'Copied gateway file did not match its recorded SHA-256.' }
}
function Gateway-Time($Value) {
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    $text = [regex]::Replace([string]$Value, '(\.\d{7})\d+(?=Z|[+-])', '$1')
    return [DateTimeOffset]::Parse($text, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}
function Gateway-UpdateReady([datetime]$Since, [string]$Version) {
    try {
        $m = Read-GatewayManifest
        if ($null -eq $m -or $m.Status -ne 'ready' -or $null -eq (Get-OwnedProcess $m.Guard) -or $null -eq (Get-OwnedProcess $m.Proxy)) { return $false }
        $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $gatewayManifest).LastWriteTimeUtc).TotalSeconds
        if ($age -lt -5 -or $age -ge 20 -or (Gateway-Time $m.StartedUtc) -lt $Since.AddSeconds(-1)) { return $false }
        $proofs = @(@{Path=$m.GuardReadyPath;Mode='guard';Identity=$m.Guard}, @{Path=(Join-Path $m.ProxyDirectory 'proxy.ready.json');Mode='proxy';Identity=$m.Proxy})
        $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $gatewayConfig | ConvertFrom-Json
        foreach ($entry in $proofs) {
            $proofPath = $entry.Path
            Assert-GatewayUpdatePath $proofPath
            if (-not ([IO.Path]::GetFullPath($proofPath).StartsWith($gatewayState.TrimEnd('\') + '\runs\', [StringComparison]::OrdinalIgnoreCase))) { return $false }
            $proof = Get-Content -Raw -Encoding UTF8 -LiteralPath $proofPath | ConvertFrom-Json
            $identity = $entry.Identity
            $proc = Get-OwnedProcess $identity
            if ($proof.mode -cne $entry.Mode -or $proof.source -cne $config.source_ip -or $proof.version -ne $Version -or [int]$proof.pid -ne [int]$identity.Pid -or $proof.config_sha256 -ine (Gateway-Hash $gatewayConfig) -or [string]$proof.process_start_filetime -cne $proc.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()) { return $false }
        }
        if ($Version -eq $expectedVersion) {
            $health = $m.ProxyHealth
            $proxy = Get-OwnedProcess $m.Proxy
            if ($null -eq $health -or $m.ProxyHealthStatus -ne 'ready' -or $health.mode -cne 'proxy' -or $health.source -cne $config.source_ip -or $health.version -ne $Version -or $health.upstream_status -ne 'ready' -or $health.interface_available -ne $true -or $health.guard_available -ne $true -or [int]$health.pid -ne [int]$m.Proxy.Pid -or $health.config_sha256 -ine (Gateway-Hash $gatewayConfig) -or [string]$health.process_start_filetime -cne $proxy.StartTime.ToUniversalTime().ToFileTimeUtc().ToString()) { return $false }
            $age = ([DateTime]::UtcNow - (Gateway-Time $health.updated_utc)).TotalSeconds
            if ($age -lt -5 -or $age -ge 20) { return $false }
        }
        return $true
    } catch { return $false }
}
function Stop-GatewayForUpdate {
    Disable-ScheduledTask -TaskName $taskName -TaskPath '\' | Out-Null
    Stop-ScheduledTask -TaskName $taskName -TaskPath '\'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running') {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'The supervisor task did not stop; gateway files were not replaced.' }
        Start-Sleep -Milliseconds 250
    }
    $lock = Enter-GatewayLock
    try {
        $m = Read-GatewayManifest
        if ($null -eq $m) { Assert-NoUnrecordedGateway; return }
        # Verify both children before stopping either. The independent guard is last.
        $null = Get-OwnedProcess $m.Proxy; $null = Get-OwnedProcess $m.Guard
        $recorded = @($m.Proxy, $m.Guard | Where-Object {$null -ne $_} | ForEach-Object {[int]$_.Pid})
        Assert-NoUnrecordedGateway -RecordedPids $recorded
        Stop-OwnedProcess $m.Proxy; Stop-OwnedProcess $m.Guard
        Assert-NoUnrecordedGateway
        Write-GatewayJson (Join-Path $backupDirectory ('runtime-' + $m.RunId + '.json')) $m
        Remove-Item -LiteralPath $gatewayManifest -Force
    } finally { $lock.ReleaseMutex(); $lock.Dispose() }
}
function Start-UpdatedGateway([string]$Version) {
    $since = [DateTime]::UtcNow
    Enable-ScheduledTask -TaskName $taskName -TaskPath '\' | Out-Null
    Start-ScheduledTask -TaskName $taskName -TaskPath '\'
    $deadline = [DateTime]::UtcNow.AddSeconds(150)
    do {
        if (Gateway-UpdateReady $since $Version) { return }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The gateway did not reach fresh, versioned readiness within the update deadline. Keep the phone route OFF.'
}

foreach ($path in @($GatewayRoot, (Join-Path $GatewayRoot 'scripts\Common.ps1'), (Join-Path $GatewayRoot 'gateway.json'))) { Assert-GatewayUpdatePath $path }
. (Join-Path $GatewayRoot 'scripts\Common.ps1')
Assert-Elevated
$taskName = 'ZeroTierGateway'
$task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$expectedArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $GatewayRoot 'scripts\Supervisor.ps1') + '"'
$actions = @($task.Actions)
if ($task.State -eq 'Disabled' -or $actions.Count -ne 1 -or $actions[0].Execute -ine $powershell -or $actions[0].Arguments -cne $expectedArguments -or $task.Principal.UserId -notin @('SYSTEM','S-1-5-18')) { throw 'The existing enabled SYSTEM task must match this gateway installation.' }
$taskXml = Export-ScheduledTask -TaskName $taskName -TaskPath '\'
$original = Read-GatewayManifest
if ($null -eq $original -or $null -eq (Get-OwnedProcess $original.Guard) -or $null -eq (Get-OwnedProcess $original.Proxy)) { throw 'Both recorded gateway children must be alive before this update.' }
Assert-NoUnrecordedGateway -RecordedPids @($original.Guard.Pid, $original.Proxy.Pid)
if (@(Get-NetNat).Count -ne 0) { throw 'An unexpected WinNAT exists; the updater will not alter it.' }
$originalProof = Get-Content -Raw -Encoding UTF8 -LiteralPath $original.GuardReadyPath | ConvertFrom-Json
$originalVersion = [string]$originalProof.version
$configHash = Gateway-Hash $gatewayConfig
$files = @(
    [pscustomobject]@{Relative='bin\zt-gateway.exe';SourceHash='';OriginalHash='';Backup=''},
    [pscustomobject]@{Relative='scripts\Supervisor.ps1';SourceHash='';OriginalHash='';Backup=''}
)
foreach ($file in $files) {
    $file | Add-Member -NotePropertyName Source -NotePropertyValue (Join-Path $repoRoot $file.Relative)
    $file | Add-Member -NotePropertyName Target -NotePropertyValue (Join-Path $GatewayRoot $file.Relative)
    Assert-GatewayUpdatePath $file.Source; Assert-GatewayUpdatePath $file.Target
    $file.SourceHash = Gateway-Hash $file.Source; $file.OriginalHash = Gateway-Hash $file.Target
}
$backupDirectory = Join-Path $gatewayState ('gateway-update-backups\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
Assert-GatewayUpdatePath $backupDirectory
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
& icacls.exe $backupDirectory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect the gateway backup directory.' }
foreach ($file in $files) { $file.Backup = Join-Path $backupDirectory ([IO.Path]::GetFileName($file.Relative)); Copy-GatewayVerified $file.Target $file.Backup $file.OriginalHash }
Write-GatewayJson (Join-Path $backupDirectory 'before.json') $original
[IO.File]::WriteAllText((Join-Path $backupDirectory 'task.xml'), $taskXml, (New-Object Text.UTF8Encoding($false)))
$oldExe = $gatewayExe
try {
    # Read-only system/SOCKS preflight with the new binary before any interruption.
    $gatewayExe = $files[0].Source
    $check = Invoke-BoundedGatewayProcess -Arguments ('check -config "' + $gatewayConfig + '"') -RunDirectory $backupDirectory -LogName 'preflight' -TimeoutMilliseconds 45000
    $checkState = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $backupDirectory 'preflight.stdout.log') | ConvertFrom-Json
    if ($check.ExitCode -ne 0 -or $checkState.version -ne $expectedVersion) { throw 'The new gateway did not pass its versioned read-only preflight.' }
} finally { $gatewayExe = $oldExe }
$changed = $false
try {
    $changed = $true
    Stop-GatewayForUpdate
    foreach ($file in $files) { Copy-GatewayVerified $file.Source $file.Target $file.SourceHash }
    Start-UpdatedGateway $expectedVersion
    if ((Gateway-Hash $gatewayConfig) -ne $configHash -or @(Get-NetNat).Count -ne 0 -or (Export-ScheduledTask -TaskName $taskName -TaskPath '\') -cne $taskXml) { throw 'Configuration, NAT or task settings changed during the update.' }
    Write-Output ('Updated gateway to v' + $expectedVersion + '; versioned readiness and fresh health checks passed.')
    Write-Output ('Previous binary, supervisor and task snapshot: ' + $backupDirectory)
} catch {
    $failure = $_.Exception.Message
    if ($changed) {
        try {
            Stop-GatewayForUpdate
            foreach ($file in $files) { Copy-GatewayVerified $file.Backup $file.Target $file.OriginalHash }
            Start-UpdatedGateway $originalVersion
        } catch { throw ('Gateway update failed and rollback needs inspection. Keep the phone route OFF. Retain backup: ' + $backupDirectory + '. ' + $_.Exception.Message) }
    }
    throw ('Gateway update failed; previous gateway restored. ' + $failure)
}
