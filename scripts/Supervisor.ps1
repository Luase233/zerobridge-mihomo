#requires -Version 5.1
# Boot supervisor: never removes/restores NAT, changes routes, or asserts phone OFF.
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Elevated
$mutex = Enter-GatewayLock
$supervisorLog = Join-Path $gatewayState 'supervisor.log'
function Write-SupervisorLog([string]$Message) {
    if ((Test-Path -LiteralPath $supervisorLog) -and (Get-Item -LiteralPath $supervisorLog).Length -gt 5MB) {
        $oldLog = $supervisorLog + '.previous'
        if (Test-Path -LiteralPath $oldLog) { Remove-Item -LiteralPath $oldLog -Force }
        Move-Item -LiteralPath $supervisorLog -Destination $oldLog
    }
    Add-Content -LiteralPath $supervisorLog -Encoding UTF8 -Value (([DateTime]::UtcNow.ToString('o')) + ' ' + $Message)
}
function Set-GatewayHigh($Identity) {
    $owned = Get-OwnedProcess $Identity
    if ($null -eq $owned) { throw 'Owned gateway process exited before priority assignment.' }
    $owned.PriorityClass = [Diagnostics.ProcessPriorityClass]::High
}
function New-ProxyHealthState([bool]$Ready, [string]$Reason, $Health = $null) {
    return [pscustomobject]@{Ready=$Ready;Reason=$Reason;Health=$Health}
}
function Convert-HealthUTC($Stamp) {
    # PowerShell 7 may deserialize ISO JSON dates into typed values. Preserve
    # their UTC kind/offset instead of stringifying them with a local format.
    if ($Stamp -is [DateTime]) { return $Stamp.ToUniversalTime() }
    if ($Stamp -is [DateTimeOffset]) { return $Stamp.UtcDateTime }
    $Stamp = [string]$Stamp
    if ([string]::IsNullOrWhiteSpace($Stamp)) { throw 'Missing health timestamp.' }
    # Go emits nanoseconds; .NET accepts at most seven fractional digits.
    $Stamp = $Stamp -replace '(\.\d{7})\d+(Z|[+-]\d{2}:\d{2})$','$1$2'
    return [DateTime]::Parse($Stamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Test-ProxyHealth($Health, $Identity, [string]$ConfigHash, [string]$Source, [DateTime]$Now = [DateTime]::UtcNow) {
    if ($null -eq $Health) { return New-ProxyHealthState $false 'Proxy health heartbeat is missing or unreadable.' }
    foreach ($property in @('pid','mode','version','source','config_sha256','process_start_filetime','updated_utc','interface_index','interface_available','guard_available','upstream_status','last_upstream_check_utc','last_error')) {
        if ($null -eq $Health.PSObject.Properties[$property]) { return New-ProxyHealthState $false ('Proxy health heartbeat is incomplete: ' + $property) }
    }
    try {
        $expectedStart = [DateTime]::new([long]$Identity.StartUtcTicks,[DateTimeKind]::Utc).ToFileTimeUtc().ToString()
        if ([int]$Health.pid -ne [int]$Identity.Pid -or [string]$Health.mode -cne 'proxy' -or [string]$Health.version -cne '0.3.2' -or [string]$Health.source -cne $Source -or [string]$Health.config_sha256 -cne $ConfigHash -or [string]$Health.process_start_filetime -cne $expectedStart) {
            return New-ProxyHealthState $false 'Proxy health identity/configuration does not match the owned process.'
        }
        $age = ($Now.ToUniversalTime() - (Convert-HealthUTC $Health.updated_utc)).TotalSeconds
        if ($age -lt -5 -or $age -gt 20) { return New-ProxyHealthState $false 'Proxy health heartbeat is stale or has an invalid future timestamp.' }
        if ($Health.interface_available -isnot [bool] -or $Health.guard_available -isnot [bool]) { return New-ProxyHealthState $false 'Proxy health availability fields must be booleans.' }
        if (-not $Health.guard_available) { return New-ProxyHealthState $false 'Independent guard is unavailable; proxy interception remains in drop mode.' $Health }
        if (-not $Health.interface_available -or [uint32]$Health.interface_index -eq 0) { return New-ProxyHealthState $false ([string]$Health.last_error) $Health }
        if ([string]$Health.upstream_status -cne 'ready') {
            $reason = [string]$Health.last_error
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'SOCKS/DNS health check is not ready.' }
            return New-ProxyHealthState $false $reason $Health
        }
        $checkAge = ($Now.ToUniversalTime() - (Convert-HealthUTC $Health.last_upstream_check_utc)).TotalSeconds
        if ($checkAge -lt -5 -or $checkAge -gt 60) { return New-ProxyHealthState $false 'SOCKS/DNS health check is stale or has an invalid future timestamp.' $Health }
        return New-ProxyHealthState $true '' $Health
    } catch { return New-ProxyHealthState $false ('Invalid proxy health heartbeat: ' + $_.Exception.Message) }
}
function Get-ProxyHealthState($Identity, [string]$HealthPath) {
    if ($null -eq (Get-OwnedProcess $Identity)) { return New-ProxyHealthState $false 'Owned proxy process is no longer running.' }
    try {
        $health = Get-Content -LiteralPath $HealthPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $config = Get-Content -LiteralPath $gatewayConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $hash = (Get-FileHash -LiteralPath $gatewayConfig -Algorithm SHA256).Hash.ToLowerInvariant()
        return Test-ProxyHealth $health $Identity $hash ([string]$config.source_ip)
    } catch { return New-ProxyHealthState $false ('Proxy health heartbeat unavailable: ' + $_.Exception.Message) }
}
try {
    [IO.Directory]::CreateDirectory($gatewayState) | Out-Null
    (Get-Process -Id $PID).PriorityClass = [Diagnostics.ProcessPriorityClass]::High
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $manifest = Read-GatewayManifest
    if ($null -ne $manifest -and (Convert-HealthUTC $manifest.StartedUtc) -lt $boot) {
        # A previous boot cannot own any current PID, even if Windows reused it.
        Assert-NoUnrecordedGateway
        Write-GatewayJson (Join-Path $gatewayState ('previous-boot-' + $manifest.RunId + '.json')) $manifest
        Remove-Item -LiteralPath $gatewayManifest -Force
        $manifest = $null
    }
    if ($null -eq $manifest) {
        Assert-NoUnrecordedGateway
        $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
        $runDirectory = Join-Path $gatewayState ('runs\' + $runId)
        [IO.Directory]::CreateDirectory($runDirectory) | Out-Null
        $manifest = [pscustomobject]@{SchemaVersion=1;Task='zt-socks-gateway';RunId=$runId;StartedUtc=[DateTime]::UtcNow.ToString('o');Status='waiting';RunDirectory=$runDirectory;Guard=$null;Proxy=$null}
        Write-GatewayJson $gatewayManifest $manifest
    }
    foreach ($property in @('GuardReadyPath','GuardDirectory','ProxyDirectory','SupervisorPid','LastError','ProxyGuardPid','ProxyHealthPath','ProxyHealthStatus','ProxyHealth')) {
        if ($null -eq $manifest.PSObject.Properties[$property]) { $manifest | Add-Member -NotePropertyName $property -NotePropertyValue $null }
    }
    if ([string]::IsNullOrWhiteSpace($manifest.GuardReadyPath) -and $null -ne $manifest.Guard) {
        $manifest.GuardReadyPath = Join-Path $manifest.RunDirectory 'guard.ready.json'
    }
    if ($null -eq $manifest.ProxyGuardPid -and $null -ne $manifest.Guard -and $null -ne $manifest.Proxy) { $manifest.ProxyGuardPid = $manifest.Guard.Pid }
    $manifest.SupervisorPid = $PID
    Write-SupervisorLog 'Supervisor started. High priority; NAT/route configuration is never changed here.'
    $lastProbeUtc = [DateTime]::MinValue
    while ($true) {
        try {
            $recorded = @()
            foreach ($identity in @($manifest.Guard,$manifest.Proxy)) { if ($null -ne $identity) { $recorded += [int]$identity.Pid } }
            Assert-NoUnrecordedGateway -RecordedPids $recorded
            $guardProcess = Get-OwnedProcess $manifest.Guard
            $proxyProcess = Get-OwnedProcess $manifest.Proxy
            if ($null -eq $guardProcess) {
                # An old proxy may already be in DROP mode. Keep its handle until
                # the replacement guard has independently reported readiness.
                $childDirectory = Join-Path $manifest.RunDirectory ('guard-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
                [IO.Directory]::CreateDirectory($childDirectory) | Out-Null
                $child = Start-GatewayChild -Mode guard -RunDirectory $childDirectory
                $manifest.Guard = $child.Identity
                $manifest.GuardReadyPath = $child.ReadyPath
                $manifest.GuardDirectory = $childDirectory
                $manifest.Status = 'guard-starting'
                Write-GatewayJson $gatewayManifest $manifest
                Set-GatewayHigh $manifest.Guard
                Wait-GatewayReady $manifest.Guard $manifest.GuardReadyPath
                Stop-OwnedProcess $manifest.Proxy
                $manifest.Proxy = $null
                $proxyProcess = $null
                $manifest.Status = 'guard-ready'
                Write-GatewayJson $gatewayManifest $manifest
                Write-SupervisorLog 'Guard ready. Waiting for working Mihomo SOCKS before proxy startup.'
            }
            Wait-GatewayReady $manifest.Guard $manifest.GuardReadyPath
            if ($null -ne $proxyProcess -and $manifest.ProxyGuardPid -ne $manifest.Guard.Pid) {
                Stop-OwnedProcess $manifest.Proxy
                $manifest.Proxy = $null
                $proxyProcess = $null
                Write-GatewayJson $gatewayManifest $manifest
            }
            if ($null -eq $proxyProcess) {
                if (([DateTime]::UtcNow - $lastProbeUtc).TotalSeconds -lt 30) { Start-Sleep -Seconds 5; continue }
                $lastProbeUtc = [DateTime]::UtcNow
                $childDirectory = Join-Path $manifest.RunDirectory ('proxy-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
                [IO.Directory]::CreateDirectory($childDirectory) | Out-Null
                $check = Invoke-BoundedGatewayProcess -Arguments "check -config `"$gatewayConfig`"" -RunDirectory $childDirectory -LogName 'check' -TimeoutMilliseconds 45000
                if ($check.ExitCode -ne 0) { throw "Mihomo/system check failed; guard retained. Logs: $childDirectory" }
                # Start-GatewayChild expects guard readiness beside the proxy.
                # Copy only the verified live guard's proof; Go verifies its PID,
                # executable, creation time, configuration hash and source again.
                $null = Get-OwnedProcess $manifest.Guard
                Copy-Item -LiteralPath $manifest.GuardReadyPath -Destination (Join-Path $childDirectory 'guard.ready.json')
                $child = Start-GatewayChild -Mode proxy -RunDirectory $childDirectory -GuardPid $manifest.Guard.Pid
                $manifest.Proxy = $child.Identity
                $manifest.ProxyGuardPid = $manifest.Guard.Pid
                $manifest.ProxyDirectory = $childDirectory
                $manifest.Status = 'proxy-starting'
                Write-GatewayJson $gatewayManifest $manifest
                Set-GatewayHigh $manifest.Proxy
                Wait-GatewayReady $manifest.Proxy $child.ReadyPath
                Write-SupervisorLog 'Proxy ready. Both children use High process priority.'
            }
            $proxyReadyDirectory = $manifest.ProxyDirectory
            if ([string]::IsNullOrWhiteSpace($proxyReadyDirectory)) { $proxyReadyDirectory = $manifest.RunDirectory }
            Wait-GatewayReady $manifest.Proxy (Join-Path $proxyReadyDirectory 'proxy.ready.json')
            Set-GatewayHigh $manifest.Guard
            Set-GatewayHigh $manifest.Proxy
            $manifest.ProxyHealthPath = Join-Path $proxyReadyDirectory 'proxy.health.json'
            $healthState = Get-ProxyHealthState $manifest.Proxy $manifest.ProxyHealthPath
            $oldHealthStatus = $manifest.ProxyHealthStatus
            $manifest.ProxyHealth = $healthState.Health
            if ($healthState.Ready) {
                $manifest.ProxyHealthStatus = 'ready'
                $manifest.Status = 'ready'
                $manifest.LastError = $null
            } else {
                # Retain both children and their handles. An upstream or interface
                # outage is recoverable in place; restart would break healthy flows.
                $manifest.ProxyHealthStatus = 'degraded'
                $manifest.Status = 'degraded'
                $manifest.LastError = $healthState.Reason
            }
            if ($oldHealthStatus -cne $manifest.ProxyHealthStatus) { Write-SupervisorLog ('Proxy health: ' + $manifest.ProxyHealthStatus + ' ' + $manifest.LastError) }
            Write-GatewayJson $gatewayManifest $manifest
            Start-Sleep -Seconds 5
        }
        catch {
            $manifest.Status = 'waiting-or-recovering'
            $manifest.LastError = $_.Exception.Message
            Write-GatewayJson $gatewayManifest $manifest
            Write-SupervisorLog $manifest.LastError
            # Keep surviving handles; never restore NAT or release protection as
            # a side effect of a failed upstream check or startup attempt.
            Start-Sleep -Seconds 30
        }
    }
}
finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
