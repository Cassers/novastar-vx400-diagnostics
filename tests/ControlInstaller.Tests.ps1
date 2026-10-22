#requires -Version 5.1
# Disposable Windows CI runner only; registers tasks, never starts live control.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Restricted to a disposable GitHub Actions runner.' }
$root=Split-Path $PSScriptRoot -Parent
$name='NovaStar-VX400-Control'
$installRoot=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) $name
$dataRoot=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) $name
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$installer=Join-Path $root 'Install-Vx400Control.ps1'
$configFile=Join-Path $env:RUNNER_TEMP 'vx400-control-installer.json'
$config=Get-Content (Join-Path $root 'plan.config.json') -Raw | ConvertFrom-Json
$config.deviceAddress='127.0.0.1'; $config.tcpPort=9
$portableData=Join-Path $env:RUNNER_TEMP 'vx400-portable-source'
$null=New-Item -ItemType Directory -Path $portableData -Force
'{"schemaVersion":1,"operatorPending":true,"operatorGateId":"test-pending"}' | Set-Content -LiteralPath (Join-Path $portableData 'estado.json') -Encoding UTF8
function Save-Fixture { $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configFile -Encoding UTF8 }
Save-Fixture
try {
    & $exe -NoProfile -File $installer -ConfigPath $configFile -EnableControl
    if ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $installRoot)) { throw 'Control must reject missing physical startup verification before installation.' }
    & $exe -NoProfile -File $installer -ConfigPath $configFile -SourceDataDirectory $portableData
    if ($LASTEXITCODE -ne 0) { throw 'Monitor installation failed.' }
    $migrated=Get-Content (Join-Path $dataRoot 'estado.json') -Raw | ConvertFrom-Json
    if (-not $migrated.operatorPending -or $migrated.operatorGateId -ne 'test-pending') { throw 'Portable pending operator decision was lost.' }
    & $exe -NoProfile -File $installer -ConfigPath $configFile -Update -SourceDataDirectory $portableData
    if ($LASTEXITCODE -eq 0) { throw 'Cross-data update must not discard a portable operator decision.' }
    foreach($layerFile in @('Invoke-VxLayer.ps1','Vx.Layers.psm1')){if(-not (Test-Path -LiteralPath (Join-Path $installRoot $layerFile))){throw ('Missing installed layer control: '+$layerFile)}}
    $task=Get-ScheduledTask -TaskName $name -TaskPath '\'
    if ($task.Actions[0].Arguments -match 'EnableControl') { throw 'Default installation must be monitor.' }
    if ($task.Principal.UserId -notin @('SYSTEM','S-1-5-18') -or $task.Settings.MultipleInstances -ne 'IgnoreNew') { throw 'Invalid task identity/settings.' }
    foreach ($path in @($installRoot,$dataRoot,(Join-Path $installRoot 'plan.config.json'),(Join-Path $installRoot 'Watch-Vx400Plan.ps1'))) {
        $acl=Get-Acl -LiteralPath $path
        if (-not $acl.AreAccessRulesProtected) { throw "Unprotected ACL: $path" }
        foreach ($rule in $acl.Access) {
            $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($rule.AccessControlType -eq 'Allow' -and $sid -notin @('S-1-5-18','S-1-5-32-544')) { throw "Unexpected principal $sid" }
        }
    }
    # Update preserves pending operator metadata and audit data.
    $sentinel=Join-Path $dataRoot 'pending-test.txt'
    'keep operator pending' | Set-Content -LiteralPath $sentinel -Encoding UTF8
    $config.panelPowerCouplingVerified=$true; $config.startupProtectionVerified=$true
    Save-Fixture
    & $exe -NoProfile -File $installer -ConfigPath $configFile -Update -EnableControl
    if ($LASTEXITCODE -ne 0) { throw 'Explicit owned update failed.' }
    $task=Get-ScheduledTask -TaskName $name -TaskPath '\'
    if ($task.Actions[0].Arguments -notmatch 'EnableControl') { throw 'Updated task mode incorrect.' }
    if (-not (Test-Path -LiteralPath $sentinel)) { throw 'Update lost operator/audit data.' }
    # The installed copy can update its own configuration without copying a file over itself.
    & $exe -NoProfile -File (Join-Path $installRoot 'Install-Vx400Control.ps1') -ConfigPath (Join-Path $installRoot 'plan.config.json') -Update
    if ($LASTEXITCODE -ne 0) { throw 'Installed self-update failed.' }
    & $exe -NoProfile -File $installer -Remove
    if ($LASTEXITCODE -ne 0) { throw 'First removal failed.' }
    & $exe -NoProfile -File $installer -ConfigPath $configFile -Update -SourceDataDirectory $dataRoot
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $sentinel)) { throw 'Owned reinstall lost retained data or failed.' }
    Write-Output 'PASS: control installer monitor/control modes, ACLs, owned updates and retained data.'
} finally {
    if (Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue) {
        & $exe -NoProfile -File $installer -Remove
        if ($LASTEXITCODE -ne 0) { throw 'Control task removal failed.' }
        if (Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'Control task still registered.' }
        if (-not (Test-Path -LiteralPath $dataRoot)) { throw 'Removal discarded audit data.' }
    }
}
