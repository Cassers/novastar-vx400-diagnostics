#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')][string]$ConfigPath = '',
    [Parameter(ParameterSetName = 'Install')][switch]$EnableSequence,
    [Parameter(ParameterSetName = 'Install')][switch]$StartNow,
    [Parameter(Mandatory = $true, ParameterSetName = 'Remove')][switch]$Remove
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Remove -and [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'watcher.config.json'
}

function Assert-NoReparsePoint([string]$Path) {
    $cursor = [System.IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are forbidden: $cursor"
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function New-PrivateAcl([bool]$IsDirectory) {
    if ($IsDirectory) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetAccessRuleProtection($true, $false)
    $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($administrators)
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidText)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    return $acl
}

function Set-PrivateAcl([string]$Path, [bool]$IsDirectory) {
    Set-Acl -LiteralPath $Path -AclObject (New-PrivateAcl $IsDirectory)
}

function New-PrivateDirectory([string]$Path) {
    # Windows PowerShell/.NET Framework applies this ACL during creation,
    # without an ordinary-user write window before Set-Acl.
    [void][System.IO.Directory]::CreateDirectory($Path, (New-PrivateAcl $true))
    Assert-NoReparsePoint $Path
    Set-PrivateAcl $Path $true
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This installer requires Windows PowerShell 5.1 and administrator privileges.'
    }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open Windows PowerShell as administrator, then run this installer again.'
    }
    if ($PSVersionTable.PSVersion.Major -ne 5) {
        throw 'Use Windows PowerShell 5.1 (powershell.exe), as provided by the BAT launchers.'
    }
    Import-Module ScheduledTasks -ErrorAction Stop
    $taskName = 'NovaStar-VX400-Watcher'
    $installRoot = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) $taskName
    $dataRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) $taskName
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $installedWatcher = Join-Path $installRoot 'Watch-Vx400.ps1'
    $installedConfig = Join-Path $installRoot 'watcher.config.json'
    $baseArguments = '-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}" -DataDirectory "{2}"' -f $installedWatcher, $installedConfig, $dataRoot
    foreach ($path in @($installRoot, $dataRoot, $powerShell)) { Assert-NoReparsePoint $path }
    $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue

    if ($Remove) {
        if (-not $existingTask) { Write-Output 'Task absent. Files and audit data retained.'; exit 0 }
        $actions = @($existingTask.Actions)
        if ($actions.Count -ne 1 -or $actions[0].Execute -ine $powerShell -or
            $actions[0].WorkingDirectory -ine $installRoot -or
            @($baseArguments, ($baseArguments + ' -EnableSequence')) -notcontains $actions[0].Arguments) {
            throw 'Task ownership check failed: action does not match this installer. Nothing removed.'
        }
        Stop-ScheduledTask -TaskName $taskName -TaskPath '\'
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
        Write-Output "Task removed. Code retained: $installRoot . Audit data retained: $dataRoot"
        exit 0
    }

    if ($existingTask -or (Test-Path -LiteralPath $installRoot) -or (Test-Path -LiteralPath $dataRoot)) {
        throw 'Existing task or installation/data directory detected. Refusing implicit update; retained audit files require operator review.'
    }
    $sourceConfig = [System.IO.Path]::GetFullPath($ConfigPath)
    $sourceFiles = @(
        (Join-Path $PSScriptRoot 'Watch-Vx400.ps1'),
        (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1'),
        (Join-Path $PSScriptRoot 'Vx400.Automation.psm1'),
        $sourceConfig
    )
    foreach ($file in $sourceFiles) {
        Assert-NoReparsePoint $file
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required source missing: $file" }
    }
    # Validation executes only the watcher's no-network configuration path, before disk/task mutations.
    $validationArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'RemoteSigned',
        '-File', $sourceFiles[0], '-ConfigPath', $sourceConfig, '-DataDirectory', $dataRoot, '-ValidateOnly')
    if ($EnableSequence) { $validationArguments += '-EnableSequence' }
    & $powerShell @validationArguments
    if ($LASTEXITCODE -ne 0) { throw "Configuration validation failed (exit $LASTEXITCODE); nothing installed." }

    # Protect roots before copying executable code or creating any runtime data.
    New-PrivateDirectory $installRoot
    New-PrivateDirectory $dataRoot
    $destinationNames = @('Watch-Vx400.ps1', 'Vx400.Protocol.psm1', 'Vx400.Automation.psm1', 'watcher.config.json')
    for ($index = 0; $index -lt $sourceFiles.Count; $index++) {
        $destination = Join-Path $installRoot $destinationNames[$index]
        Copy-Item -LiteralPath $sourceFiles[$index] -Destination $destination -ErrorAction Stop
        Set-PrivateAcl $destination $false
        if ((Get-FileHash -LiteralPath $sourceFiles[$index] -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash) {
            throw "Copy verification failed: $destination"
        }
    }
    $arguments = $baseArguments
    if ($EnableSequence) { $arguments += ' -EnableSequence' }
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $installRoot
    $startup = New-ScheduledTaskTrigger -AtStartup
    # No RepetitionDuration: repeat indefinitely, even when the process exits successfully.
    $watchdog = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $definition = New-ScheduledTask -Action $action -Trigger @($startup, $watchdog) -Settings $settings -Principal $taskPrincipal `
        -Description 'NovaStar VX400 communication watcher. Sequence writes require explicit installer opt-in and a validated live profile.'
    # No -Force: another task appearing after preflight must fail instead of being overwritten.
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -InputObject $definition -ErrorAction Stop | Out-Null
    if ($StartNow) { Start-ScheduledTask -TaskName $taskName -TaskPath '\' }
    $mode = 'MONITOR (read-only)'
    if ($EnableSequence) { $mode = 'SEQUENCE (writes explicitly enabled)' }
    Write-Output "Installed $taskName : $mode. Code: $installRoot . Audit data: $dataRoot"
    if (-not $StartNow) { Write-Output 'No immediate start requested. Starts at reboot or the next five-minute watchdog trigger; operator may start it from Task Scheduler.' }
} catch {
    Write-Error -Message ($_.Exception.Message + ' Any partial protected installation is retained for operator review; no files are automatically deleted.') -ErrorAction Continue
    exit 1
}
