#requires -Version 5.1
# Disposable Windows CI runner only. Registers/removes a monitor task, never starts it.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This smoke test is restricted to a disposable GitHub Actions Windows runner.' }
$root = Split-Path $PSScriptRoot -Parent
$taskName = 'NovaStar-VX400-Watcher'
$installRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) $taskName
$dataRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) $taskName
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$configFile = Join-Path $env:RUNNER_TEMP 'vx400-installer-fixture.json'
$config = Get-Content (Join-Path $root 'watcher.config.json') -Raw | ConvertFrom-Json
$config.deviceAddress='127.0.0.1'; $config.tcpPort=9
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configFile -Encoding UTF8
$installer = Join-Path $root 'Install-Vx400Watcher.ps1'
try {
    & $powershell -NoProfile -File $installer -ConfigPath $configFile -EnableSequence
    if ($LASTEXITCODE -eq 0 -or (Test-Path $installRoot) -or (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw 'Invalid live profile must fail before installation.'
    }
    & $powershell -NoProfile -File $installer -ConfigPath $configFile
    if ($LASTEXITCODE -ne 0) { throw 'Monitor installation failed.' }
    $task = Get-ScheduledTask -TaskName $taskName
    if ($task.Principal.UserId -notin @('SYSTEM','S-1-5-18')) { throw 'Task must run as SYSTEM.' }
    if ($task.Actions[0].Arguments -match 'EnableSequence') { throw 'Default task must be read-only.' }
    if (@($task.Triggers).Count -ne 2) { throw 'Missing startup/watchdog trigger.' }
    if ($task.Settings.ExecutionTimeLimit -ne 'PT0S') { throw 'Unexpected task runtime limit.' }
    if ($task.Settings.MultipleInstances -ne 'IgnoreNew') { throw 'Parallel task instances permitted.' }
    foreach ($path in @($installRoot,$dataRoot,(Join-Path $installRoot 'Watch-Vx400.ps1'),(Join-Path $installRoot 'watcher.config.json'))) {
        $acl = Get-Acl -LiteralPath $path
        if (-not $acl.AreAccessRulesProtected) { throw "ACL inheritance not disabled: $path" }
        foreach ($rule in $acl.Access) {
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($rule.AccessControlType -eq 'Allow' -and $sid -notin @('S-1-5-18','S-1-5-32-544')) {
                throw "Unexpected access rule on $path : $sid"
            }
        }
    }
    & $powershell -NoProfile -File $installer -ConfigPath $configFile
    if ($LASTEXITCODE -eq 0) { throw 'Implicit overwrite must be refused.' }
    Write-Output 'Installer configuration, protected ACLs, SYSTEM task and collision checks passed.'
} finally {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        & $powershell -NoProfile -File $installer -Remove
        if ($LASTEXITCODE -ne 0) { throw 'Owned task removal failed.' }
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Task still registered.' }
        if (-not (Test-Path $dataRoot)) { throw 'Removal must retain audit directory.' }
    }
}
