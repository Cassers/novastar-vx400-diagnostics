#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='', [string]$SourceDataDirectory='', [switch]$EnableControl, [switch]$StartNow, [switch]$Update, [switch]$Remove)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath=Join-Path $PSScriptRoot 'plan.config.json' }
if ([string]::IsNullOrWhiteSpace($SourceDataDirectory)) { $SourceDataDirectory=Join-Path $PSScriptRoot 'plan-data' }

function Assert-RealPath([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are forbidden: $cursor"
            }
        }
        $parent=[IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }; $cursor=$parent
    }
}
function New-ControlAcl([bool]$Directory) {
    $acl=if ($Directory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    $inherit=if ($Directory) { [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($text in @('S-1-5-18','S-1-5-32-544')) {
        $sid=New-Object Security.Principal.SecurityIdentifier($text)
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $null=$acl.AddAccessRule($rule)
    }
    return $acl
}
function New-ControlDirectory([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path,(New-ControlAcl $true))
    Assert-RealPath $Path
    Set-Acl -LiteralPath $Path -AclObject (New-ControlAcl $true)
}
function Assert-ControlTask($Task,[string]$Exe,[string]$Arguments,[string]$Root) {
    $actions=@($Task.Actions)
    if ($actions.Count -ne 1 -or $actions[0].Execute -ine $Exe -or
        $actions[0].WorkingDirectory -ine $Root -or
        @($Arguments,($Arguments+' -EnableControl')) -notcontains $actions[0].Arguments) {
        throw 'Task ownership check failed. No task will be replaced or removed.'
    }
}
function Assert-OwnedControlDirectory([string]$Root,[string]$Data) {
    $marker=Join-Path $Root 'installation.json'
    Assert-RealPath $marker
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Retained installation has no ownership marker.' }
    $identity=Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($identity.application -cne 'NovaStar-VX400-Control' -or $identity.schemaVersion -ne 1) { throw 'Retained installation marker does not match this application.' }
    foreach ($path in @($Root,$Data,$marker)) {
        $acl=Get-Acl -LiteralPath $path
        if (-not $acl.AreAccessRulesProtected) { throw 'Retained installation ACL is not protected.' }
        foreach ($rule in $acl.Access) {
            $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($rule.AccessControlType -eq 'Allow' -and $sid -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Retained installation has unexpected access rules.' }
        }
    }
}
function Stop-ControlTask([string]$Name,[string]$Data) {
    Disable-ScheduledTask -TaskName $Name -TaskPath '\' | Out-Null
    if ((Get-ScheduledTask -TaskName $Name -TaskPath '\').State -eq 'Running') {
        [IO.File]::WriteAllText((Join-Path $Data 'stop.request'),'stop')
        $timer=[Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 300
            $running=(Get-ScheduledTask -TaskName $Name -TaskPath '\').State -eq 'Running'
        } while ($running -and $timer.Elapsed.TotalSeconds -lt 20)
        if ($running) { throw 'Controller has not stopped. Task remains disabled; no files replaced. Inspect the app and screen before continuing.' }
    }
}
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSVersion.Major -ne 5) {
        throw 'Use Windows PowerShell 5.1 as administrator.'
    }
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Ejecute la app como administrador para gestionar el inicio automatico.' }
    if ($Remove -and ($Update -or $StartNow -or $EnableControl)) { throw 'Remove cannot be combined with installation switches.' }
    Import-Module ScheduledTasks -ErrorAction Stop
    $taskName='NovaStar-VX400-Control'
    $installRoot=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) $taskName
    $dataRoot=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) $taskName
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $watcher=Join-Path $installRoot 'Watch-Vx400Plan.ps1'
    $installedConfig=Join-Path $installRoot 'plan.config.json'
    $baseArguments='-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}" -DataDirectory "{2}"' -f $watcher,$installedConfig,$dataRoot
    foreach ($path in @($installRoot,$dataRoot,$exe)) { Assert-RealPath $path }
    $task=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) { Assert-ControlTask $task $exe $baseArguments $installRoot }
    if ($Remove) {
        if ($task) {
            Stop-ControlTask $taskName $dataRoot
            Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
        }
        Write-Output "Tarea retirada. Configuracion y registros conservados: $installRoot ; $dataRoot"
        exit 0
    }
    if ($task -and -not $Update) { throw 'Installation exists. Use Update to modify the owned installation.' }
    if ($task -and (Test-Path -LiteralPath $SourceDataDirectory) -and
        [IO.Path]::GetFullPath($SourceDataDirectory) -ine [IO.Path]::GetFullPath($dataRoot)) {
        throw 'La instalacion usa otra carpeta de datos. Abra el contexto instalado antes de actualizar; no se descartaran decisiones ni solicitudes de la copia portatil.'
    }
    if (-not $task -and ((Test-Path -LiteralPath $installRoot) -or (Test-Path -LiteralPath $dataRoot))) {
        if (-not $Update) { throw 'Use Update to restore an owned retained installation. Unrecognized directories are never overwritten.' }
        Assert-OwnedControlDirectory $installRoot $dataRoot
    }
    $sourceConfig=[IO.Path]::GetFullPath($ConfigPath)
    $names=@('Watch-Vx400Plan.ps1','Vx400.Schedule.psm1','Vx400.Protocol.psm1','Vx.Connection.psm1','Vx.Usb.psm1','Vx.Usb.Native.cs','Test-VxConnection.ps1','Abrir-Control-NovaStar.bat','Control-Vx400.ps1','Set-Vx400Manual.ps1','Invoke-VxLayer.ps1','Vx.Layers.psm1','Recover-Vx400.ps1','Vx400.Ownership.psm1','Abrir-Control-VX400.bat','Install-Vx400Control.ps1','Abrir-Control-Pro.bat','Abrir-Control-Usuarios.bat','Control-VxUsuarios.ps1','Configurar-VxUsuarios.ps1','Vx.Operator.psm1','Watch-VxOperator.ps1','Play-VxOperatorMedia.ps1','Vx.Operator.Media.cs','Recover-VxOperatorUi.ps1','Vx.Operator.Deployment.psm1','Export-VxUsuarios.ps1','Install-VxUsuariosStartup.ps1')
    foreach ($name in $names) {
        $path=Join-Path $PSScriptRoot $name
        Assert-RealPath $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing required file: $path" }
    }
    Assert-RealPath $sourceConfig
    $validate=@('-NoLogo','-NoProfile','-ExecutionPolicy','RemoteSigned','-File',(Join-Path $PSScriptRoot 'Watch-Vx400Plan.ps1'),'-ConfigPath',$sourceConfig,'-ValidateOnly')
    if ($EnableControl) { $validate+='-EnableControl' }
    & $exe @validate
    if ($LASTEXITCODE -ne 0) { throw 'Invalid configuration; installation unchanged.' }
    # Capture the validated data before a source==destination update, never a partial rewrite.
    $configBytes=[IO.File]::ReadAllBytes($sourceConfig)
    if ($task) { Stop-ControlTask $taskName $dataRoot }
    else {
        New-ControlDirectory $installRoot; New-ControlDirectory $dataRoot
        # Preserve a pending operator decision when moving a stopped portable controller.
        if (-not [string]::IsNullOrWhiteSpace($SourceDataDirectory) -and
            [IO.Path]::GetFullPath($SourceDataDirectory) -ine [IO.Path]::GetFullPath($dataRoot)) {
            Assert-RealPath $SourceDataDirectory
            foreach ($dataName in @('operator-session.json','operator-state.json','solicitudes.json','estado.json','eventos.jsonl','eventos.jsonl.1','eventos.jsonl.2','eventos.jsonl.3','eventos.jsonl.4','eventos.jsonl.5')) {
                $sourceData=Join-Path $SourceDataDirectory $dataName
                if (Test-Path -LiteralPath $sourceData -PathType Leaf) {
                    Assert-RealPath $sourceData
                    $targetData=Join-Path $dataRoot $dataName
                    Copy-Item -LiteralPath $sourceData -Destination $targetData
                    Set-Acl -LiteralPath $targetData -AclObject (New-ControlAcl $false)
                }
            }
        }
    }
    foreach ($name in $names) {
        $source=Join-Path $PSScriptRoot $name; $target=Join-Path $installRoot $name
        if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($target)) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
        Set-Acl -LiteralPath $target -AclObject (New-ControlAcl $false)
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
            throw "Copy verification failed: $name"
        }
    }
    # The operator profile is separate and never overwritten during an advanced-Pro update.
    $operatorProfile=Join-Path $installRoot 'operator.config.json'
    if(-not [IO.File]::Exists($operatorProfile)){
        $profileSource=Join-Path (Split-Path $sourceConfig -Parent) 'operator.config.json'
        if(-not [IO.File]::Exists($profileSource)){$profileSource=Join-Path $PSScriptRoot 'operator.config.json'}
        Assert-RealPath $profileSource
        Copy-Item -LiteralPath $profileSource -Destination $operatorProfile
    }
    Set-Acl -LiteralPath $operatorProfile -AclObject (New-ControlAcl $false)
    $temporary=Join-Path $installRoot 'plan.config.json.tmp'
    [IO.File]::WriteAllBytes($temporary,$configBytes)
    if (Test-Path -LiteralPath $installedConfig) { [IO.File]::Replace($temporary,$installedConfig,[NullString]::Value) }
    else { [IO.File]::Move($temporary,$installedConfig) }
    Set-Acl -LiteralPath $installedConfig -AclObject (New-ControlAcl $false)
    $marker=Join-Path $installRoot 'installation.json'
    if (-not (Test-Path -LiteralPath $marker)) {
        $identity=[ordered]@{application='NovaStar-VX400-Control';schemaVersion=1;installedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        [IO.File]::WriteAllText($marker,($identity | ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))
        Set-Acl -LiteralPath $marker -AclObject (New-ControlAcl $false)
    }
    $arguments=$baseArguments
    if ($EnableControl) { $arguments+=' -EnableControl' }
    $action=New-ScheduledTaskAction -Execute $exe -Argument $arguments -WorkingDirectory $installRoot
    $startup=New-ScheduledTaskTrigger -AtStartup
    $watchdog=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $system=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $definition=New-ScheduledTask -Action $action -Trigger @($startup,$watchdog) -Settings $settings -Principal $system -Description 'Control local VX400. Perdidas de comunicacion requieren decision del operador; no controla alimentacion electrica.'
    if ($task) { Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $definition -Force | Out-Null }
    else { Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $definition | Out-Null }
    if ($StartNow) { Start-ScheduledTask -TaskName $taskName -TaskPath '\' }
    Write-Output "Instalado $taskName. Configuracion: $installedConfig ; datos: $dataRoot"
    if (-not $StartNow) { Write-Output 'Inicio al reiniciar Windows o dentro de cinco minutos.' }
} catch {
    Write-Error ($_.Exception.Message+' No se borran instalaciones parciales ni registros automaticamente.') -ErrorAction Continue
    exit 1
}
