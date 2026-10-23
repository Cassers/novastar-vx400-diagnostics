#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='',[string]$OperatorConfigPath='',[string]$DataDirectory='',[switch]$Remove)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Use Windows PowerShell 5.1 en la sesión del usuario de la pantalla.'}
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.Deployment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1')
Import-Module (Join-Path $PSScriptRoot 'Vx.Connection.psm1')
Import-Module ScheduledTasks -ErrorAction Stop
if(-not $ConfigPath){$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
if(-not $OperatorConfigPath){$OperatorConfigPath=Join-Path $PSScriptRoot 'operator.config.json'}
if(-not $DataDirectory){$DataDirectory=Join-Path $PSScriptRoot 'plan-data'}
foreach($name in @('ConfigPath','OperatorConfigPath','DataDirectory')){Set-Variable -Name $name -Value (Assert-VxDeploymentPath (Get-Variable -Name $name -ValueOnly))}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if($sid -eq 'S-1-5-18' -or -not [Environment]::UserInteractive){throw 'Multimedia requiere la sesión interactiva del usuario; no instale esta tarea como SYSTEM.'}
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$engine=Assert-VxDeploymentPath (Join-Path $PSScriptRoot 'Watch-VxOperator.ps1')
$arguments='-NoLogo -NoProfile -STA -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}" -OperatorConfigPath "{2}" -DataDirectory "{3}" -EnableControl' -f $engine,$ConfigPath,$OperatorConfigPath,$DataDirectory
$name=Get-VxOperatorTaskName $DataDirectory
$task=Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
if($task){
    $actions=@($task.Actions)
    if($actions.Count -ne 1 -or $actions[0].Execute -ine $exe -or $actions[0].Arguments -cne $arguments -or $actions[0].WorkingDirectory -ine $PSScriptRoot -or (Get-VxPrincipalSid $task.Principal.UserId) -ine $sid -or $task.Principal.LogonType -ne 'Interactive'){throw 'La tarea existente no coincide con esta instalación/usuario. No se reemplazó.'}
}
if($Remove){
    if($task){Unregister-ScheduledTask -TaskName $name -TaskPath '\' -Confirm:$false}
    Write-Output 'Inicio de Usuarios retirado. El motor actual continúa hasta solicitar parada desde Soporte; perfiles y datos conservados.'
    exit 0
}
$null=Read-VxPlanConfig -Path $ConfigPath -EnableControl
$null=Read-VxOperatorConfig -Path $OperatorConfigPath -ForControl
$protectedCode=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'NovaStar-VX400-Control'
$protectedData=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'NovaStar-VX400-Control'
foreach($path in @($engine,$ConfigPath,$OperatorConfigPath,$DataDirectory)){
    foreach($protected in @($protectedCode,$protectedData)){
        if($path -ieq $protected -or $path.StartsWith($protected+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'La instalación Pro está protegida para administradores. Exporte Usuarios a una carpeta accesible del usuario y ábrala desde Pro → Otra instalación Usuarios antes de activar este inicio limitado.'}
    }
}
Import-Module (Join-Path $PSScriptRoot 'Vx400.Ownership.psm1') -Force
$plan=Read-VxPlanConfig -Path $ConfigPath
foreach($legacyName in @('NovaStar-VX400-Control','NovaStar-VX400-Watcher')){
    $legacy=Get-ScheduledTask -TaskName $legacyName -TaskPath '\' -ErrorAction SilentlyContinue
    if($null -ne $legacy -and $legacy.State -ne 'Disabled' -and (Test-VxOwnedControllerTask -Task $legacy -Endpoint (Get-VxConnectionKey $plan) -ExpectedPowerShell $exe)){throw 'Hay un inicio automático avanzado Pro para esta conexión. Quítelo desde Pro antes de activar el de Usuarios.'}
}
$null=[IO.Directory]::CreateDirectory($DataDirectory)
$lock=$null
try{
    $lock=[IO.File]::Open((Join-Path $DataDirectory 'watcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $marker=[ordered]@{schemaVersion=1;application='NovaStar-Usuarios';taskName=$name;userSid=$sid;scriptRoot=$PSScriptRoot;configPath=$ConfigPath;operatorConfigPath=$OperatorConfigPath;dataDirectory=$DataDirectory}
    $markerPath=Join-Path $DataDirectory 'operator-startup.json';$temporary=$markerPath+'.tmp'
    [IO.File]::WriteAllText($temporary,($marker|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    Move-VxAtomicFile -Source $temporary -Destination $markerPath
    $action=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $PSScriptRoot
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $sid
    $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
    # No restart-on-failure or periodic triggers: a failed sequence needs operator review.
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $name -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'NovaStar Usuarios: motor y multimedia en la sesión de pantalla, perfil configurado desde Pro.' -Force | Out-Null
    Write-Output ('Inicio de Usuarios activado al iniciar sesión: '+$name+'. Mantenga esta carpeta y la sesión de Windows abiertas. Cerrar la interfaz no detiene el motor.')
}finally{if($null -ne $lock){$lock.Dispose()}}
