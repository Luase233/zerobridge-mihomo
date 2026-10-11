#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\Update-Gateway.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'Gateway updater syntax failed.' }
# Import definitions only; installation, elevation and restart bodies never run.
$functionSource = @($ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst]}, $true) | ForEach-Object {$_.Extent.Text}) -join "`n"
. ([scriptblock]::Create($functionSource))
$fixtureParent = Join-Path $repo 'bin'
$fixture = [IO.Path]::GetFullPath((Join-Path $fixtureParent ('gateway-update-test-' + [Guid]::NewGuid().ToString('N'))))
Assert-GatewayUpdatePath $fixture
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$script:checks = 0
function Assert-UpdateTest([bool]$Passed, [string]$Message) {
    if (-not $Passed) { throw $Message }
    $script:checks++
}
function Assert-UpdateThrows([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Assert-UpdateTest $rejected $Message
}
function Write-UpdateFixture([string]$Path, $Value) {
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
}
try {
    $source = Join-Path $fixture 'source.bin'; $target = Join-Path $fixture 'target.bin'
    [IO.File]::WriteAllText($source, 'source'); [IO.File]::WriteAllText($target, 'original')
    $expected = Gateway-Hash $source
    Copy-GatewayVerified $source $target $expected
    Assert-UpdateTest ((Gateway-Hash $target) -eq $expected) 'Verified copy failed.'
    [IO.File]::WriteAllText($source, 'changed')
    Assert-UpdateThrows { Copy-GatewayVerified $source $target $expected } 'Changed source was accepted.'
    Assert-UpdateTest ((Gateway-Hash $target) -eq $expected) 'Changed-source rejection altered the target.'
    [IO.File]::WriteAllText($source, 'source')
    # A copying fault is simulated, without replacing any installation file.
    function Copy-Item { param($LiteralPath,$Destination,[switch]$Force); [IO.File]::WriteAllText($Destination, 'corrupt') }
    try { Assert-UpdateThrows { Copy-GatewayVerified $source $target $expected } 'Corrupt copied target was accepted.' }
    finally { Remove-Item Function:\Copy-Item -Force }

    # A real Go-style UTC JSON timestamp stays a string on PS 5 and may become
    # DateTime on PS 7. Neither path may shift it to the local time zone.
    $utcTime = [DateTime]::UtcNow
    $jsonStamp = $utcTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + '89Z'
    $parsedStamp = ('{"updated_utc":"' + $jsonStamp + '"}') | ConvertFrom-Json
    $converted = Gateway-Time $parsedStamp.updated_utc
    Assert-UpdateTest ($converted.Kind -eq [DateTimeKind]::Utc -and $converted.Ticks -eq $utcTime.Ticks) 'JSON-roundtripped UTC nanoseconds lost their UTC instant.'
    $offsetTime = [DateTimeOffset]::new($utcTime).ToOffset([TimeSpan]::FromHours(8))
    $converted = Gateway-Time $offsetTime
    Assert-UpdateTest ($converted.Kind -eq [DateTimeKind]::Utc -and $converted.Ticks -eq $utcTime.Ticks) 'Typed DateTimeOffset lost its offset during freshness conversion.'

    $expectedVersion = '0.3.2'
    $gatewayState = Join-Path $fixture 'state'
    $gatewayManifest = Join-Path $gatewayState 'runtime.json'
    $gatewayConfig = Join-Path $fixture 'gateway.json'
    $guardPath = Join-Path $gatewayState 'runs\20261011T120000Z-1234abcd\guard\guard.ready.json'
    $proxyDirectory = Join-Path $gatewayState 'runs\20261011T120000Z-1234abcd\proxy'
    $proxyPath = Join-Path $proxyDirectory 'proxy.ready.json'
    $since = [DateTime]::UtcNow
    $processTime = $since.AddSeconds(-2)
    $script:ownedTimes = @{101=$processTime;102=$processTime}
    function Read-GatewayManifest { return Get-Content -Raw -Encoding UTF8 -LiteralPath $gatewayManifest | ConvertFrom-Json }
    function Get-OwnedProcess($Identity) {
        if ($null -eq $Identity -or -not $script:ownedTimes.ContainsKey([int]$Identity.Pid)) { return $null }
        $start = $script:ownedTimes[[int]$Identity.Pid]
        if ([string]$Identity.StartUtcTicks -cne $start.ToUniversalTime().Ticks.ToString()) { throw 'Fixture PID was reused.' }
        return [pscustomobject]@{StartTime=$start}
    }
    function Reset-ReadyFixture([string]$Version = '0.3.2') {
        # The source remains ASCII so PS 5.1 can parse it; fixture JSON is UTF-8.
        $unicodeLabel = -join @([char]0x901f,[char]0x4e91,[char]0x68af)
        Write-UpdateFixture $gatewayConfig @{source_ip='192.0.2.10';label=$unicodeLabel}
        $hash = Gateway-Hash $gatewayConfig
        foreach ($entry in @(@{Path=$guardPath;Mode='guard';Pid=101},@{Path=$proxyPath;Mode='proxy';Pid=102})) {
            Write-UpdateFixture $entry.Path @{pid=$entry.Pid;mode=$entry.Mode;source='192.0.2.10';version=$Version;config_sha256=$hash;process_start_filetime=$processTime.ToFileTimeUtc().ToString()}
        }
        $health = @{pid=102;mode='proxy';source='192.0.2.10';version=$Version;config_sha256=$hash;process_start_filetime=$processTime.ToFileTimeUtc().ToString();updated_utc=[DateTime]::UtcNow.ToString('o');upstream_status='ready';interface_available=$true;guard_available=$true;interface_index=18;last_upstream_check_utc=[DateTime]::UtcNow.ToString('o');last_error=''}
        $guard = @{Pid=101;Executable='fixture.exe';StartUtcTicks=$processTime.Ticks.ToString()}
        $proxy = @{Pid=102;Executable='fixture.exe';StartUtcTicks=$processTime.Ticks.ToString()}
        Write-UpdateFixture $gatewayManifest @{SchemaVersion=1;Task='zt-socks-gateway';RunId='20261011T120000Z-1234abcd';Status='ready';StartedUtc=$since.ToString('o');Guard=$guard;Proxy=$proxy;GuardReadyPath=$guardPath;ProxyDirectory=$proxyDirectory;ProxyHealthStatus='ready';ProxyHealth=$health}
        $script:ownedTimes = @{101=$processTime;102=$processTime}
    }
    function Change-FixtureJSON([string]$Path,[scriptblock]$Change) {
        $value = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
        & $Change $value
        Write-UpdateFixture $Path $value
    }
    function Assert-ReadyRejected([string]$Reason,[scriptblock]$Change) {
        Reset-ReadyFixture
        & $Change
        Assert-UpdateTest (-not (Gateway-UpdateReady $since $expectedVersion)) ($Reason + ' was accepted.')
    }
    Reset-ReadyFixture
    Assert-UpdateTest (Gateway-UpdateReady $since $expectedVersion) 'Fresh owned UTF-8 readiness rejected.'
    Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.updated_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + '89Z'}
    Assert-UpdateTest (Gateway-UpdateReady $since $expectedVersion) 'Nanosecond heartbeat rejected.'
    Assert-ReadyRejected 'Old binary version' { Change-FixtureJSON $proxyPath {param($p) $p.version='0.3.1'} }
    Assert-ReadyRejected 'Guard proof with proxy mode' { Change-FixtureJSON $guardPath {param($p) $p.mode='proxy';$p.pid=102} }
    Assert-ReadyRejected 'Proxy proof with guard mode' { Change-FixtureJSON $proxyPath {param($p) $p.mode='guard';$p.pid=101} }
    Assert-ReadyRejected 'Wrong ready source' { Change-FixtureJSON $proxyPath {param($p) $p.source='192.0.2.11'} }
    Assert-ReadyRejected 'Wrong ready configuration hash' { Change-FixtureJSON $guardPath {param($p) $p.config_sha256='bad'} }
    Assert-ReadyRejected 'Wrong ready creation time' { Change-FixtureJSON $proxyPath {param($p) $p.process_start_filetime=$processTime.AddSeconds(1).ToFileTimeUtc().ToString()} }
    Assert-ReadyRejected 'Reused proxy PID' { $script:ownedTimes[102]=$processTime.AddSeconds(1) }
    Assert-ReadyRejected 'Missing owned guard' { $script:ownedTimes.Remove(101) }
    Assert-ReadyRejected 'Malformed ready JSON' { [IO.File]::WriteAllText($proxyPath, '{') }
    Assert-ReadyRejected 'Malformed current config' { [IO.File]::WriteAllText($gatewayConfig, '{') }
    Assert-ReadyRejected 'Changed current config' { [IO.File]::AppendAllText($gatewayConfig, ' ') }
    Assert-ReadyRejected 'Stale manifest' { [IO.File]::SetLastWriteTimeUtc($gatewayManifest,[DateTime]::UtcNow.AddSeconds(-30)) }
    Assert-ReadyRejected 'Pre-update run' { Change-FixtureJSON $gatewayManifest {param($m) $m.StartedUtc=$since.AddMinutes(-1).ToString('o')} }
    Assert-ReadyRejected 'Degraded manifest' { Change-FixtureJSON $gatewayManifest {param($m) $m.Status='degraded'} }
    Assert-ReadyRejected 'Proof outside state runs' {
        $outside = Join-Path $fixture 'outside.ready.json'
        Copy-Item -LiteralPath $guardPath -Destination $outside
        Change-FixtureJSON $gatewayManifest {param($m) $m.GuardReadyPath=$outside}
    }
    Assert-ReadyRejected 'Missing health' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth=$null} }
    Assert-ReadyRejected 'Wrong health mode' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.mode='guard'} }
    Assert-ReadyRejected 'Wrong health source' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.source='192.0.2.11'} }
    Assert-ReadyRejected 'Wrong health PID' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.pid=101} }
    Assert-ReadyRejected 'Wrong health creation time' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.process_start_filetime=$processTime.AddSeconds(1).ToFileTimeUtc().ToString()} }
    Assert-ReadyRejected 'Wrong health hash' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.config_sha256='bad'} }
    Assert-ReadyRejected 'Stale health' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.updated_utc=[DateTime]::UtcNow.AddSeconds(-30).ToString('o')} }
    Assert-ReadyRejected 'Future health' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.updated_utc=[DateTime]::UtcNow.AddMinutes(1).ToString('o')} }
    Assert-ReadyRejected 'Invalid health timestamp' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.updated_utc='invalid'} }
    Assert-ReadyRejected 'Unavailable interface' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.interface_available=$false} }
    Assert-ReadyRejected 'Unavailable guard' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.guard_available=$false} }
    Assert-ReadyRejected 'Failed SOCKS health' { Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth.upstream_status='unavailable'} }
    Reset-ReadyFixture '0.3.1'
    Change-FixtureJSON $gatewayManifest {param($m) $m.ProxyHealth=$null;$m.ProxyHealthStatus=$null}
    Assert-UpdateTest (Gateway-UpdateReady $since '0.3.1') 'Rollback readiness rejected the previous version without new health fields.'

    # Every task/process/lock function below is a mock. Assert stop ordering and
    # ownership rejection without touching Windows tasks or actual processes.
    $script:trace = New-Object 'Collections.Generic.List[string]'
    function Disable-ScheduledTask { param($TaskName,$TaskPath); $script:trace.Add('disable') }
    function Stop-ScheduledTask { param($TaskName,$TaskPath); $script:trace.Add('stop-task') }
    function Get-ScheduledTask { param($TaskName,$TaskPath); return [pscustomobject]@{State='Ready'} }
    function Enter-GatewayLock {
        $script:trace.Add('lock')
        $lock = New-Object psobject
        $lock | Add-Member ScriptMethod ReleaseMutex {$script:trace.Add('release')}
        $lock | Add-Member ScriptMethod Dispose {$script:trace.Add('dispose')}
        return $lock
    }
    function Get-OwnedProcess($Identity) {
        $script:trace.Add('verify:' + $Identity.Pid)
        if ([int]$Identity.Pid -eq $script:rejectPid) { throw 'Fixture identity mismatch.' }
        return [pscustomobject]@{StartTime=$processTime}
    }
    function Assert-NoUnrecordedGateway { param([int[]]$RecordedPids=@()); $script:trace.Add('unrecorded:' + ($RecordedPids -join ',')) }
    function Stop-OwnedProcess($Identity) { $script:trace.Add('stop:' + $Identity.Pid) }
    function Write-GatewayJson { param($Path,$Value); $script:trace.Add('backup-runtime') }
    $taskName = 'fixture-task'; $backupDirectory = Join-Path $fixture 'backups'; $script:rejectPid = 0
    Reset-ReadyFixture
    Stop-GatewayForUpdate
    $expectedTrace = 'disable,stop-task,lock,verify:102,verify:101,unrecorded:102,101,stop:102,stop:101,unrecorded:,backup-runtime,release,dispose'
    Assert-UpdateTest (($script:trace -join ',') -ceq $expectedTrace) ('Stop ordering differed: ' + ($script:trace -join ','))
    Assert-UpdateTest (-not (Test-Path -LiteralPath $gatewayManifest)) 'Stopped runtime manifest was not retired.'
    Reset-ReadyFixture
    $script:trace.Clear(); $script:rejectPid = 101
    Assert-UpdateThrows { Stop-GatewayForUpdate } 'Wrong guard identity did not abort the stop.'
    Assert-UpdateTest (-not (@($script:trace | Where-Object {$_ -like 'stop:*'}).Count)) 'A child was stopped before both identities were verified.'
    Assert-UpdateTest ((Test-Path -LiteralPath $gatewayManifest) -and ($script:trace -contains 'release') -and ($script:trace -contains 'dispose')) 'Failed ownership check did not preserve manifest/release mock lock.'

    # Exercise the updater's exact outer transaction with fixture-only copies
    # and mock lifecycle functions, including a failed new-version startup.
    $transaction = @($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.CatchClauses.Count -gt 0})
    Assert-UpdateTest ($transaction.Count -eq 1) 'Cannot identify the updater transaction for isolated rollback testing.'
    $rollbackFixture = Join-Path $fixture 'rollback'
    [IO.Directory]::CreateDirectory($rollbackFixture) | Out-Null
    $files = @()
    foreach ($name in @('gateway.exe','supervisor.ps1')) {
        $s = Join-Path $rollbackFixture ('new-' + $name)
        $b = Join-Path $rollbackFixture ('old-' + $name)
        $t = Join-Path $rollbackFixture ('installed-' + $name)
        [IO.File]::WriteAllText($s, 'new ' + $name)
        [IO.File]::WriteAllText($b, 'old ' + $name)
        [IO.File]::WriteAllText($t, 'old ' + $name)
        $files += [pscustomobject]@{Source=$s;Target=$t;Backup=$b;SourceHash=(Gateway-Hash $s);OriginalHash=(Gateway-Hash $b)}
    }
    $verifiedCopy = (Get-Command Copy-GatewayVerified).ScriptBlock
    function Copy-GatewayVerified([string]$Source,[string]$Target,[string]$ExpectedHash) {
        $script:trace.Add('copy:' + [IO.Path]::GetFileName($Source))
        & $verifiedCopy $Source $Target $ExpectedHash
    }
    function Stop-GatewayForUpdate { $script:trace.Add('stop-gateway') }
    function Start-UpdatedGateway([string]$Version) {
        $script:trace.Add('start:' + $Version)
        if ($Version -eq $expectedVersion) { throw 'Fixture new version failed readiness.' }
    }
    function Get-NetNat { return @() }
    function Export-ScheduledTask { param($TaskName,$TaskPath); return 'fixture-task-xml' }
    $configHash = Gateway-Hash $gatewayConfig
    $taskXml = 'fixture-task-xml'; $originalVersion='0.3.1'; $changed=$false
    $script:trace.Clear()
    $transactionFailure = ''
    try { . ([scriptblock]::Create($transaction[0].Extent.Text)) } catch { $transactionFailure=$_.Exception.Message }
    Assert-UpdateTest ($transactionFailure -like 'Gateway update failed; previous gateway restored.*') 'Failed update did not report completed rollback.'
    $expectedTrace = 'stop-gateway,copy:new-gateway.exe,copy:new-supervisor.ps1,start:0.3.2,stop-gateway,copy:old-gateway.exe,copy:old-supervisor.ps1,start:0.3.1'
    Assert-UpdateTest (($script:trace -join ',') -ceq $expectedTrace) ('Rollback ordering differed: ' + ($script:trace -join ','))
    foreach ($file in $files) { Assert-UpdateTest ((Gateway-Hash $file.Target) -eq $file.OriginalHash) 'Rollback did not restore the original fixture bytes.' }
    Write-Output ('Passed gateway updater syntax and ' + $script:checks + ' isolated checks; no installed files, tasks or processes were touched.')
} finally {
    $allowedParent = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\') + '\'
    if (-not $fixture.StartsWith($allowedParent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fixture) -notmatch '^gateway-update-test-[0-9a-f]{32}$') { throw 'Refusing to remove an unexpected fixture path.' }
    Assert-GatewayUpdatePath $fixture
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
