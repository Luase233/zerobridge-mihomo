#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([string]$GatewayRoot = 'C:\ZeroTierGateway')

$ErrorActionPreference = 'Stop'
$expectedVersion = '0.3.2'
$repoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$GatewayRoot = [IO.Path]::GetFullPath($GatewayRoot).TrimEnd('\')
if ($GatewayRoot.Contains('"') -or $GatewayRoot.Contains("`n") -or $GatewayRoot.Contains("`r")) { throw 'Invalid gateway path.' }
if ($GatewayRoot.Length -le [IO.Path]::GetPathRoot($GatewayRoot).TrimEnd('\').Length) { throw 'Use a gateway installation directory, not a drive root.' }
if ($repoRoot -eq $GatewayRoot) { throw 'Run the updater from a separate built source checkout.' }

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Update paths must not contain links or junctions.' }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
}
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Copy-Verified([string]$Source, [string]$Destination, [string]$ExpectedHash) {
    Assert-NoReparse $Source
    Assert-NoReparse $Destination
    if ((Hash $Source) -ne $ExpectedHash) { throw 'An update or backup file changed before copying.' }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    if ((Hash $Destination) -ne $ExpectedHash) { throw 'A copied file did not match its recorded SHA-256 hash.' }
}
function Exact-Processes([string]$Path) {
    $name = [IO.Path]::GetFileName($Path)
    $items = @(Get-CimInstance Win32_Process -Filter ("Name='" + $name + "'"))
    foreach ($item in $items) {
        if (-not $item.ExecutablePath) { throw 'Cannot verify the executable path of a control process.' }
        if ([string]::Equals([IO.Path]::GetFullPath($item.ExecutablePath), $Path, [StringComparison]::OrdinalIgnoreCase)) { $item }
    }
}
function Stop-ControlProcesses {
    foreach ($file in $files) {
        foreach ($item in @(Exact-Processes $file.Target)) {
            $process = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
            if ($null -eq $process) { continue }
            if (-not [string]::Equals($process.Path, $file.Target, [StringComparison]::OrdinalIgnoreCase)) { throw 'A control process changed identity before stopping.' }
            # Re-read creation time as well as path to avoid acting on a reused PID.
            $current = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $item.ProcessId)
            if ($null -eq $current) { continue }
            if ($current.CreationDate -ne $item.CreationDate -or $current.ExecutablePath -ne $item.ExecutablePath) { throw 'A control process changed identity before stopping.' }
            Stop-Process -InputObject $process -Force
            if (-not $process.WaitForExit(5000)) { throw 'A control process did not stop.' }
        }
    }
}
function Stop-ControlTasks {
    foreach ($name in $taskNames) { Stop-ScheduledTask -TaskName $name -TaskPath '\' }
    Stop-ControlProcesses
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $running = @($taskNames | ForEach-Object { Get-ScheduledTask -TaskName $_ -TaskPath '\' } | Where-Object {$_.State -eq 'Running'})
        if ($running.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'A control task did not stop before the restart deadline.'
}
function Mobile-Ready([datetime]$Since) {
    try {
        $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
        if ($state.updated -is [DateTime]) { $updated = $state.updated.ToUniversalTime() }
        elseif ($state.updated -is [DateTimeOffset]) { $updated = $state.updated.UtcDateTime }
        else {
            $updatedText = [regex]::Replace([string]$state.updated, '(\.\d{7})\d+(?=Z|[+-])', '$1')
            $updated = [DateTimeOffset]::Parse($updatedText, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        }
        $age = ([DateTime]::UtcNow - $updated).TotalSeconds
        return $state.version -eq $expectedVersion -and $state.online -eq $true -and $updated -ge $Since.AddSeconds(-1) -and $age -ge -5 -and $age -lt 15 -and @(Exact-Processes $files[0].Target).Count -eq 1
    } catch { return $false }
}

$configPath = Join-Path $GatewayRoot 'mobile.json'
$gatewayConfigPath = Join-Path $GatewayRoot 'gateway.json'
$qrPath = Join-Path $GatewayRoot 'state\mobile\pairing.png'
$files = @(
    [pscustomobject]@{Name='zerobridge-mobile.exe'; Source=(Join-Path $repoRoot 'bin\zerobridge-mobile.exe'); Target=(Join-Path $GatewayRoot 'bin\zerobridge-mobile.exe'); SourceHash=''; OriginalHash=''; Backup=''},
    [pscustomobject]@{Name='zerobridge-desktop.exe'; Source=(Join-Path $repoRoot 'bin\zerobridge-desktop.exe'); Target=(Join-Path $GatewayRoot 'bin\zerobridge-desktop.exe'); SourceHash=''; OriginalHash=''; Backup=''}
)
foreach ($path in @($configPath, $gatewayConfigPath, (Join-Path $GatewayRoot 'scripts\Run-Mobile.ps1')) + @($files | ForEach-Object {$_.Source; $_.Target})) {
    Assert-NoReparse $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The configured installation and both built control binaries are required.' }
}
try { $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json } catch { throw 'Cannot read the existing mobile configuration.' }
$statePath = [IO.Path]::GetFullPath([string]$config.state_file)
if (-not [string]::Equals($statePath, (Join-Path $GatewayRoot 'state\mobile\status.json'), [StringComparison]::OrdinalIgnoreCase)) { throw 'The mobile status path must belong to this installation.' }
Assert-NoReparse $statePath
Assert-NoReparse $qrPath
$configHash = Hash $configPath
$gatewayConfigHash = Hash $gatewayConfigPath
$qrHash = if (Test-Path -LiteralPath $qrPath -PathType Leaf) { Hash $qrPath } else { '' }
foreach ($file in $files) { $file.SourceHash = Hash $file.Source; $file.OriginalHash = Hash $file.Target }
if ((Get-Item -LiteralPath $files[1].Source).VersionInfo.FileVersion -ne ($expectedVersion + '.0')) { throw 'Build the v0.3.2 desktop before updating.' }
# Capture output: --check may contain private proxy-group names. Never print it.
try { $checkOutput = @(& ($files[0].Source) --config $configPath --check 2>&1) } catch { throw 'The v0.3.2 mobile binary did not pass its read-only Clash controller check.' }
if ($LASTEXITCODE -ne 0 -or ($checkOutput -join "`n") -notmatch 'version=0\.3\.2(?:;|\s|$)') { throw 'The v0.3.2 mobile binary did not pass its read-only Clash controller check.' }

$taskNames = @('ZeroBridgeMihomoMobile', 'ZeroBridgeMihomoTray')
$tasks = @($taskNames | ForEach-Object { Get-ScheduledTask -TaskName $_ -TaskPath '\' })
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$mobileArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $GatewayRoot 'scripts\Run-Mobile.ps1') + '"'
$trayArguments = '--root "' + $GatewayRoot + '" --minimized'
$expectedActions = @(@($powershell, $mobileArguments), @($files[1].Target, $trayArguments))
$taskXml = @()
$wasRunning = @()
for ($i = 0; $i -lt $tasks.Count; $i++) {
    if ($tasks[$i].State -eq 'Disabled' -or @($tasks[$i].Actions).Count -ne 1) { throw 'Both existing control tasks must be enabled and have exactly one action.' }
    $action = @($tasks[$i].Actions)[0]
    if (-not [string]::Equals($action.Execute, $expectedActions[$i][0], [StringComparison]::OrdinalIgnoreCase) -or $action.Arguments -ne $expectedActions[$i][1]) { throw 'An existing control task does not match this installation; no tasks were changed.' }
    $taskXml += Export-ScheduledTask -TaskName $taskNames[$i] -TaskPath '\'
    $wasRunning += ($tasks[$i].State -eq 'Running' -or @(Exact-Processes $files[$i].Target).Count -gt 0)
}

$backupParent = Join-Path $GatewayRoot 'state\control-update-backups'
$backupDirectory = Join-Path $backupParent ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
Assert-NoReparse $backupDirectory
New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
& icacls.exe $backupDirectory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect the control backup directory.' }
foreach ($file in $files) { $file.Backup = Join-Path $backupDirectory $file.Name; Copy-Verified $file.Target $file.Backup $file.OriginalHash }
$qrBackup = Join-Path $backupDirectory 'pairing.png'
if ($qrHash) { Copy-Verified $qrPath $qrBackup $qrHash }
$changed = $false
try {
    $changed = $true
    Stop-ControlTasks
    foreach ($file in $files) { Copy-Verified $file.Source $file.Target $file.SourceHash }
    $restartTime = [DateTime]::UtcNow
    Start-ScheduledTask -TaskName $taskNames[0] -TaskPath '\'
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        if (Mobile-Ready $restartTime) { break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not (Mobile-Ready $restartTime)) { throw 'The new mobile service did not report a fresh v0.3.2 online heartbeat.' }
    # Keep the original pairing image even if startup regenerated an equivalent QR.
    if ($qrHash) { Copy-Verified $qrBackup $qrPath $qrHash }
    Start-ScheduledTask -TaskName $taskNames[1] -TaskPath '\'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (@(Exact-Processes $files[1].Target).Count -eq 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 1 }
    if (@(Exact-Processes $files[1].Target).Count -ne 1) { throw 'The new desktop did not start in the task user session.' }
    if ((Hash $configPath) -ne $configHash -or (Hash $gatewayConfigPath) -ne $gatewayConfigHash) { throw 'Configuration changed during the update; inspect it before retrying.' }
    for ($i = 0; $i -lt $taskNames.Count; $i++) {
        if ((Export-ScheduledTask -TaskName $taskNames[$i] -TaskPath '\') -ne $taskXml[$i]) { throw 'A control task changed during the update.' }
    }
    Write-Output 'Updated mobile control and desktop to v0.3.2; fresh online heartbeat verified.'
    Write-Output ('Previous control binaries and pairing QR retained at: ' + $backupDirectory)
    Write-Output 'Gateway, NAT, configurations, task settings and firewall rules were not changed. Reload the iPhone page or reopen its Home Screen app.'
} catch {
    $failure = $_.Exception.Message
    if ($changed) {
        try {
            Stop-ControlTasks
            foreach ($file in $files) { Copy-Verified $file.Backup $file.Target $file.OriginalHash }
            if ($qrHash) { Copy-Verified $qrBackup $qrPath $qrHash }
            for ($i = 0; $i -lt $taskNames.Count; $i++) { if ($wasRunning[$i]) { Start-ScheduledTask -TaskName $taskNames[$i] -TaskPath '\' } }
        } catch { throw ('Control update failed and automatic rollback was incomplete. Keep the backup at ' + $backupDirectory + ' and inspect the control tasks. The gateway was not stopped.') }
    }
    throw ('Control update failed; original control binaries restored. ' + $failure)
}
