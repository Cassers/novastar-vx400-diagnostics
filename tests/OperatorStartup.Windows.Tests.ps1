#requires -Version 5.1
# Disposable CI runner only. Registers/removes an at-logon task; never starts it.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:OS -ne 'Windows_NT'){throw 'Restricted to a disposable Windows CI runner.'}
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Vx.Operator.Deployment.psm1') -Force
Import-Module (Join-Path $root 'Vx400.Ownership.psm1') -Force
$temp=Join-Path $env:RUNNER_TEMP ('vx-startup-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($temp)
$application=Join-Path $temp 'Usuarios';$null=& (Join-Path $root 'Export-VxUsuarios.ps1') -Destination $application
$data=Join-Path $temp 'data';$planPath=Join-Path $temp 'plan.config.json';$profilePath=Join-Path $temp 'operator.config.json'
$name=Get-VxOperatorTaskName $data
$plan=Get-Content (Join-Path $root 'plan.config.json') -Raw|ConvertFrom-Json
$plan.deviceAddress='127.0.0.1';$plan.tcpPort=9;$plan.connectionType='Ethernet';$plan.profileAccepted=$true;$plan.panelPowerCouplingVerified=$true;$plan.startupProtectionVerified=$true
$plan|ConvertTo-Json -Depth 20|Set-Content $planPath -Encoding UTF8
$profile=Get-Content (Join-Path $root 'operator.config.json') -Raw|ConvertFrom-Json
$profile.configured=$true;$profile.mediaEnabled=$false
$profile|ConvertTo-Json -Depth 10|Set-Content $profilePath -Encoding UTF8
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$installer=Join-Path $root 'Install-VxUsuariosStartup.ps1'
try{
    & $exe -NoProfile -File $installer -ConfigPath $planPath -OperatorConfigPath $profilePath -DataDirectory $data -ApplicationDirectory $application
    if($LASTEXITCODE -ne 0){throw 'Interactive user startup registration failed.'}
    $task=Get-ScheduledTask -TaskName $name -TaskPath '\'
    if($task.Principal.LogonType -ne 'Interactive' -or $task.Principal.RunLevel -ne 'Limited' -or $task.State -eq 'Running'){throw 'Startup must be limited, interactive and not launched by installation.'}
    if(@($task.Triggers).Count -ne 1 -or $task.Triggers[0].CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger'){throw 'Only at-logon trigger is permitted.'}
    if(-not (Test-VxOwnedControllerTask $task '127.0.0.1:9' $exe)){throw 'Recovery did not recognize the genuine interactive user task.'}
    & $exe -NoProfile -File $installer -ConfigPath $planPath -OperatorConfigPath $profilePath -DataDirectory $data -ApplicationDirectory $application
    if($LASTEXITCODE -ne 0){throw 'Idempotent owned task update failed.'}
    & $exe -NoProfile -File $installer -ConfigPath $planPath -OperatorConfigPath $profilePath -DataDirectory $data -ApplicationDirectory $application -Remove
    if($LASTEXITCODE -ne 0 -or $null -ne (Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue)){throw 'Owned startup removal failed.'}
    if(-not [IO.File]::Exists($planPath) -or -not [IO.File]::Exists($profilePath)){throw 'Removing startup discarded configuration.'}
    Write-Output 'PASS interactive user startup registration, identity, idempotence and removal; no task or hardware launched.'
}finally{Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $temp -Recurse -Force}
