#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Supervisor.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors) { throw 'Supervisor syntax failed.' }
# Import only pure health validation helpers, never the operational loop.
$names = @('New-ProxyHealthState','Convert-HealthUTC','Test-ProxyHealth','Get-ProxyHealthState')
$source = @($ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $item.Name},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"
. ([scriptblock]::Create($source))
Set-StrictMode -Version 2
$now = [DateTime]::UtcNow
$identity = [pscustomobject]@{Pid=123;StartUtcTicks=$now.AddMinutes(-1).Ticks.ToString()}
$expectedStart = [DateTime]::new([long]$identity.StartUtcTicks,[DateTimeKind]::Utc).ToFileTimeUtc().ToString()
$hash = 'a' * 64
function New-HealthFixture {
    return [pscustomobject]@{pid=123;mode='proxy';version='0.3.2';source='10.147.20.2';config_sha256=$hash;process_start_filetime=$expectedStart;updated_utc=$now.ToString('o');interface_index=34;interface_available=$true;guard_available=$true;upstream_status='ready';last_upstream_check_utc=$now.ToString('o');last_error=''}
}
function Assert-Degraded($Health,[string]$Label) {
    $result = Test-ProxyHealth $Health $identity $hash '10.147.20.2' $now
    if ($result.Ready -or [string]::IsNullOrWhiteSpace($result.Reason)) { throw ('Invalid state accepted or lacked reason: ' + $Label) }
}
$valid = New-HealthFixture
if (-not (Test-ProxyHealth $valid $identity $hash '10.147.20.2' $now).Ready) { throw 'Fresh owned healthy heartbeat rejected.' }
$valid.updated_utc = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + '89Z'
if (-not (Test-ProxyHealth $valid $identity $hash '10.147.20.2' $now).Ready) { throw 'Nanosecond heartbeat rejected.' }
$checks = 2
# Exercise actual JSON deserialization: PS 5 keeps strings while PS 7 may
# create DateTime values. Both must preserve the same UTC freshness.
$roundtrip = $valid | ConvertTo-Json -Depth 5 | ConvertFrom-Json
if (-not (Test-ProxyHealth $roundtrip $identity $hash '10.147.20.2' $now).Ready) { throw 'JSON-roundtripped nanosecond heartbeat rejected.' }
$typed = New-HealthFixture
$typed.updated_utc = $now
$typed.last_upstream_check_utc = $now
if (-not (Test-ProxyHealth $typed $identity $hash '10.147.20.2' $now).Ready) { throw 'UTC DateTime heartbeat lost its time kind.' }
$offset = [DateTimeOffset]::new($now).ToOffset([TimeSpan]::FromHours(8))
$typed.updated_utc = $offset
$typed.last_upstream_check_utc = $offset
if (-not (Test-ProxyHealth $typed $identity $hash '10.147.20.2' $now).Ready) { throw 'DateTimeOffset heartbeat lost its offset.' }
$typed.updated_utc = $offset.ToString('o')
$typed.last_upstream_check_utc = $offset.ToString('o')
if (-not (Test-ProxyHealth $typed $identity $hash '10.147.20.2' $now).Ready) { throw 'Offset string heartbeat was not converted to UTC.' }
$parsedStale = New-HealthFixture
$parsedStale.updated_utc = $now.AddSeconds(-21).ToString('o')
$parsedStale = $parsedStale | ConvertTo-Json -Depth 5 | ConvertFrom-Json
Assert-Degraded $parsedStale 'JSON-roundtripped stale heartbeat'
$parsedStale = New-HealthFixture
$parsedStale.last_upstream_check_utc = $now.AddSeconds(-61).ToString('o')
$parsedStale = $parsedStale | ConvertTo-Json -Depth 5 | ConvertFrom-Json
Assert-Degraded $parsedStale 'JSON-roundtripped stale probe'
$checks += 6
foreach ($case in @('missing','stale','future','reused-pid','wrong-start','wrong-hash','wrong-source','old-version','wrong-mode','interface-lost','interface-zero','guard-lost','checking','upstream-failed','probe-stale','bad-boolean')) {
    $health = New-HealthFixture
    switch ($case) {
        'missing' {$health=$null}
        'stale' {$health.updated_utc=$now.AddSeconds(-21).ToString('o')}
        'future' {$health.updated_utc=$now.AddSeconds(6).ToString('o')}
        'reused-pid' {$health.pid=124}
        'wrong-start' {$health.process_start_filetime='1'}
        'wrong-hash' {$health.config_sha256='b' * 64}
        'wrong-source' {$health.source='192.168.196.185'}
        'old-version' {$health.version='0.3.1'}
        'wrong-mode' {$health.mode='guard'}
        'interface-lost' {$health.interface_available=$false;$health.last_error='ZeroTier return interface unavailable.'}
        'interface-zero' {$health.interface_index=0;$health.last_error='ZeroTier return interface unavailable.'}
        'guard-lost' {$health.guard_available=$false}
        'checking' {$health.upstream_status='checking';$health.last_error='Initial SOCKS/DNS check pending.'}
        'upstream-failed' {$health.upstream_status='unavailable';$health.last_error='SOCKS/DNS probe unavailable.'}
        'probe-stale' {$health.last_upstream_check_utc=$now.AddSeconds(-61).ToString('o')}
        'bad-boolean' {$health.interface_available='true'}
    }
    Assert-Degraded $health $case
    $checks++
}
# An interface outage and its later new index remain owned by the same process.
$health = New-HealthFixture
$health.interface_available=$false; $health.interface_index=0; $health.last_error='Adapter unavailable.'
Assert-Degraded $health 'recovery-start'
$health.interface_available=$true; $health.interface_index=44; $health.last_error=''
if (-not (Test-ProxyHealth $health $identity $hash '10.147.20.2' $now).Ready) { throw 'Recovered interface heartbeat was not accepted in place.' }
$checks+=2
Write-Output "Passed supervisor syntax and $checks isolated health checks; no tasks, gateway processes, routes or installed files were touched."
