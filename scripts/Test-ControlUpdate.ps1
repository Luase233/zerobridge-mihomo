#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\Update-Control.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw 'Updater syntax failed.' }
# Import helper definitions only. Never execute the installation or restart body.
$functionSource = @($ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst]}, $true) | ForEach-Object {$_.Extent.Text}) -join "`n"
. ([scriptblock]::Create($functionSource))
$fixtureParent = Join-Path $repo 'bin'
$fixture = [IO.Path]::GetFullPath((Join-Path $fixtureParent ('control-update-test-' + [Guid]::NewGuid().ToString('N'))))
Assert-NoReparse $fixture
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
try {
    $source = Join-Path $fixture 'source.bin'; $target = Join-Path $fixture 'target.bin'
    [IO.File]::WriteAllText($source, 'source'); [IO.File]::WriteAllText($target, 'original')
    $expected = Hash $source
    Copy-Verified $source $target $expected
    if ((Hash $target) -ne $expected) { throw 'Verified copy failed.' }
    [IO.File]::WriteAllText($source, 'changed')
    $rejected = $false
    try { Copy-Verified $source $target $expected } catch { $rejected = $true }
    if (-not $rejected -or (Hash $target) -ne $expected) { throw 'Changed-source rejection failed.' }

    # Heartbeat checks use UTF-8 fixtures and a process stub, never installed files.
    $expectedVersion = '0.3.2'; $files = @([pscustomobject]@{Target='fixture-mobile.exe'})
    $statePath = Join-Path $fixture 'status.json'
    # Keep this script ASCII so Windows PowerShell 5.1 can read its source safely.
    $unicodeGroup = -join @([char]0x901f, [char]0x4e91, [char]0x68af)
    function Exact-Processes([string]$Path) { return [pscustomobject]@{ProcessId=123; ExecutablePath=$Path} }
    function Set-State([string]$Version, [bool]$Online, [datetime]$Updated, [switch]$Nanoseconds) {
        $stamp = $Updated.ToUniversalTime().ToString('o')
        if ($Nanoseconds) { $stamp = $Updated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + '89Z' }
        $json = [ordered]@{version=$Version;online=$Online;updated=$stamp;groups=@(@{name=$unicodeGroup;type='Selector';now='fixture-node';selectable=$true})} | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText($statePath, $json, (New-Object Text.UTF8Encoding($false)))
    }
    $since = [DateTime]::UtcNow
    Set-State '0.3.2' $true $since
    if (-not (Mobile-Ready $since)) { throw 'Fresh UTF-8 heartbeat rejected.' }
    Set-State '0.3.2' $true $since -Nanoseconds
    if (-not (Mobile-Ready $since)) { throw 'Nanosecond UTF-8 heartbeat rejected.' }
    Set-State '0.3.0' $true $since
    if (Mobile-Ready $since) { throw 'Old version accepted.' }
    Set-State '0.3.2' $false $since
    if (Mobile-Ready $since) { throw 'Offline heartbeat accepted.' }
    Set-State '0.3.2' $true $since.AddSeconds(-30)
    if (Mobile-Ready $since) { throw 'Stale heartbeat accepted.' }

    # A reused PID must never reach Stop-Process. All process functions are mocks.
    $originalTime = [DateTime]::UtcNow
    function Exact-Processes([string]$Path) { return [pscustomobject]@{ProcessId=123;ExecutablePath=$Path;CreationDate=$originalTime} }
    function Get-Process { param($Id,$ErrorAction); return [pscustomobject]@{Path='fixture-mobile.exe'} }
    function Get-CimInstance { param($ClassName,$Filter); return [pscustomobject]@{ExecutablePath='fixture-mobile.exe';CreationDate=$originalTime.AddSeconds(1)} }
    $script:stopCalls = 0
    function Stop-Process { param($InputObject,[switch]$Force); $script:stopCalls++ }
    $rejected = $false
    try { Stop-ControlProcesses } catch { $rejected = $true }
    if (-not $rejected -or $script:stopCalls -ne 0) { throw 'Reused PID was not rejected before stopping.' }
    Write-Output 'Passed updater syntax and 8 isolated helper checks; no installed files, tasks or processes were touched.'
} finally {
    $allowedParent = [IO.Path]::GetFullPath($fixtureParent).TrimEnd('\') + '\'
    if (-not $fixture.StartsWith($allowedParent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fixture) -notmatch '^control-update-test-[0-9a-f]{32}$') { throw 'Refusing to remove an unexpected fixture path.' }
    Assert-NoReparse $fixture
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
