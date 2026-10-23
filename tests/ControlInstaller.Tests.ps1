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
$fixtureRoot=Join-Path $env:RUNNER_TEMP ('vx400-control-installer-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixtureRoot)
$configFile=Join-Path $fixtureRoot 'plan.config.json'
$sourcePolicy=Join-Path $fixtureRoot 'pro-access.json'
$installedPolicy=Join-Path $installRoot 'pro-access.json'
Import-Module (Join-Path $root 'Vx.Operator.Deployment.psm1') -Force
Import-Module (Join-Path $root 'Vx.ProAccess.psm1') -Force
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
    '{}' | Set-Content -LiteralPath $sourcePolicy -Encoding UTF8
    & $exe -NoProfile -File $installer -ConfigPath $configFile -SourceDataDirectory $portableData
    if ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $installRoot)) { throw 'Invalid source verifier must fail before runtime installation.' }
    Remove-Item -LiteralPath $sourcePolicy
    & $exe -NoProfile -File $installer -ConfigPath $configFile -SourceDataDirectory $portableData
    if ($LASTEXITCODE -ne 0) { throw 'Monitor installation failed.' }
    if ([IO.File]::Exists($installedPolicy)) { throw 'A checkout without policy must not create an unlocked fallback.' }
    $locked=$false;try {$null=Read-VxProAccessPolicy -Path $installedPolicy} catch {$locked=$true}
    if (-not $locked) { throw 'Missing installed policy must keep Pro locked.' }
    foreach($runtimeFile in @(Get-VxUserPackageFiles)){
        if(-not [IO.File]::Exists((Join-Path $installRoot $runtimeFile))){throw ('Missing unified runtime: '+$runtimeFile)}
    }
    $migrated=Get-Content (Join-Path $dataRoot 'estado.json') -Raw | ConvertFrom-Json
    if (-not $migrated.operatorPending -or $migrated.operatorGateId -ne 'test-pending') { throw 'Portable pending operator decision was lost.' }
    & $exe -NoProfile -File $installer -ConfigPath $configFile -Update -SourceDataDirectory $portableData
    if ($LASTEXITCODE -eq 0) { throw 'Cross-data update must not discard a portable operator decision.' }
    foreach($layerFile in @('Invoke-VxLayer.ps1','Vx.Layers.psm1')){if(-not (Test-Path -LiteralPath (Join-Path $installRoot $layerFile))){throw ('Missing installed layer control: '+$layerFile)}}
    $task=Get-ScheduledTask -TaskName $name -TaskPath '\'
    if ($task.State -eq 'Running') { throw 'Installation without StartNow must not launch the scheduled task.' }
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
    # A later verified policy can populate an installation created from a source checkout.
    $fixturePolicy=[ordered]@{schemaVersion=1;kdf='PBKDF2-SHA256';iterations=600000;salt=[Convert]::ToBase64String([byte[]](1..32));hash=[Convert]::ToBase64String([byte[]](33..64));requireChange=$true}
    $fixturePolicy|ConvertTo-Json|Set-Content -LiteralPath $sourcePolicy -Encoding UTF8
    & $exe -NoProfile -File $installer -ConfigPath $configFile -Update
    if ($LASTEXITCODE -ne 0 -or (Get-FileHash $sourcePolicy).Hash -cne (Get-FileHash $installedPolicy).Hash) { throw 'Validated source verifier was not installed byte exactly.' }
    $retainedPolicyHash=(Get-FileHash $installedPolicy).Hash
    $fixturePolicy.hash=[Convert]::ToBase64String([byte[]](65..96));$fixturePolicy.requireChange=$false
    $fixturePolicy|ConvertTo-Json|Set-Content -LiteralPath $sourcePolicy -Encoding UTF8
    $installedProfile=Join-Path $installRoot 'operator.config.json'
    [IO.File]::AppendAllText($installedProfile,"`r`n " )
    $retainedProfileHash=(Get-FileHash $installedProfile).Hash
    # Update preserves pending operator metadata, selected verifier, profile and audit data.
    $sentinel=Join-Path $dataRoot 'pending-test.txt'
    'keep operator pending' | Set-Content -LiteralPath $sentinel -Encoding UTF8
    $config.panelPowerCouplingVerified=$true; $config.startupProtectionVerified=$true
    Save-Fixture
    & $exe -NoProfile -File $installer -ConfigPath $configFile -Update -EnableControl
    if ($LASTEXITCODE -ne 0) { throw 'Explicit owned update failed.' }
    if ((Get-FileHash $installedPolicy).Hash -cne $retainedPolicyHash) { throw 'Update replaced an existing Pro verifier from another installation.' }
    if ((Get-FileHash $installedProfile).Hash -cne $retainedProfileHash) { throw 'Update replaced an existing operator profile.' }
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
    if ((Get-FileHash $installedPolicy).Hash -cne $retainedPolicyHash) { throw 'Self-update or retained reinstall replaced the Pro verifier.' }
    Write-Output 'PASS: unified runtime, fail-closed missing/invalid verifier, preserved verifier/profile, monitor/control modes, no StartNow, ACLs, owned updates and retained data.'
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    if (Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue) {
        & $exe -NoProfile -File $installer -Remove
        if ($LASTEXITCODE -ne 0) { throw 'Control task removal failed.' }
        if (Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'Control task still registered.' }
        if (-not (Test-Path -LiteralPath $dataRoot)) { throw 'Removal discarded audit data.' }
    }
}
