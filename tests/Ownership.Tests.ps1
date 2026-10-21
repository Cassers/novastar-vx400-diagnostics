#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../Vx400.Ownership.psm1') -Force
$script:count=0
function Assert($Condition,[string]$Name){if(-not $Condition){throw $Name};$script:count++}
function Throws([scriptblock]$Body,[string]$Name){$bad=$false;try{$null=&$Body}catch{$bad=$true};Assert $bad $Name}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('vx-ownership-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temporary)
$oldProgramFiles=$env:ProgramFiles;$oldProgramData=$env:ProgramData
try{
    $exe=Join-Path $temporary 'powershell.exe';[IO.File]::WriteAllText($exe,'pure fixture; never executed')
    $root=Join-Path $temporary 'copy';$data=Join-Path $root 'plan-data';$null=[IO.Directory]::CreateDirectory($data)
    $source=Join-Path $PSScriptRoot '../Watch-Vx400Plan.ps1';$scriptPath=Join-Path $root 'Watch-Vx400Plan.ps1'
    Copy-Item -LiteralPath $source -Destination $scriptPath
    $configPath=Join-Path $root 'plan.config.json';[IO.File]::WriteAllText($configPath,'{"deviceAddress":"127.0.0.1","tcpPort":5200}')
    $command='"'+$exe+'" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "'+$scriptPath+'" -ConfigPath "'+$configPath+'" -DataDirectory "'+$data+'" -EnableControl'
    $parsed=ConvertFrom-VxControllerCommandLine $command
    Assert ($parsed.scriptName -eq 'Watch-Vx400Plan.ps1') genuineparse
    Assert ($parsed.parameters['-enablecontrol'] -eq $true) controllerswitch
    $manual=ConvertFrom-VxControllerCommandLine ($command+' -ManualDry')
    Assert ($manual.parameters['-manualdry'] -eq $true) manualdryrecognized
    $windows=ConvertFrom-VxControllerCommandLine 'powershell.exe -NoProfile -File "C:\Real Copy\Watch-Vx400Plan.ps1" -EnableControl'
    Assert ($windows.scriptName -eq 'Watch-Vx400Plan.ps1') windowspathparse
    foreach($bad in @(
        'powershell.exe -Command "Watch-Vx400Plan.ps1"',
        'powershell.exe -EncodedCommand dGVzdA==',
        'powershell.exe -File other.ps1',
        'powershell.exe -File Watch-Vx400Plan.ps1 -Command x',
        'powershell.exe -File Watch-Vx400Plan.ps1 -ValidateOnly',
        'powershell.exe -File Watch-Vx400Plan.ps1 -EnableControl:$false',
        'powershell.exe -File Watch-Vx400Plan.ps1 -ConfigPath a -ConfigPath b',
        'powershell.exe -File "C:\bad\Watch-Vx400Plan.ps1',
        'powershell.exe -File Watch-Vx400Plan.ps1 -ConfigPath "C:\trailing\"',
        'powershell.exe -File Watch-Vx400Plan.ps1 -MaxPolls -1',
        'powershell.exe -File Set-Vx400Manual.ps1 -BrightnessPercent 101 -Display Normal',
        'powershell.exe -Unknown -File Watch-Vx400Plan.ps1'
    )){Throws {ConvertFrom-VxControllerCommandLine $bad} ('reject '+$bad)}
    $record=[pscustomobject]@{ProcessId=1245;CreationDate=[DateTime]::UtcNow;ExecutablePath=$exe;CommandLine=$command}
    $identity=Get-VxControllerIdentity $record '127.0.0.1:5200' $exe
    Assert ($identity.processId -eq 1245 -and $identity.gracefulSupported) genuineidentity
    Assert ($identity.dataDirectory -eq $data) datadir
    Throws {Get-VxControllerIdentity $record '127.0.0.1:5300' $exe} endpointmismatch
    $record.ExecutablePath=$scriptPath;Throws {Get-VxControllerIdentity $record '127.0.0.1:5200' $exe} fakeexecutable
    $record.ExecutablePath=$exe
    $record.CommandLine='powershell.exe -File "'+$scriptPath+'"'
    $identity=Get-VxControllerIdentity $record '127.0.0.1:5200' $exe
    Assert ($identity.configPath -eq $configPath -and $identity.dataDirectory -eq $data) safedefaults
    $record.CommandLine=$command
    [IO.File]::AppendAllText($scriptPath,"`n# spoof content")
    Throws {Get-VxControllerIdentity $record '127.0.0.1:5200' $exe} hashspoof
    Copy-Item -LiteralPath $source -Destination $scriptPath -Force
    [IO.File]::WriteAllText($configPath,'{"deviceAddress":"127.1","tcpPort":5200}')
    Throws {Get-VxControllerIdentity $record '127.0.0.1:5200' $exe} abbreviatedip
    [IO.File]::WriteAllText($configPath,'{"deviceAddress":"127.0.0.1","tcpPort":"5200"}')
    Throws {Get-VxControllerIdentity $record '127.0.0.1:5200' $exe} stringport
    [IO.File]::WriteAllText($configPath,'{"deviceAddress":"127.0.0.1","tcpPort":5200}')
    $env:ProgramFiles=Join-Path $temporary 'program';$env:ProgramData=Join-Path $temporary 'data'
    $taskRoot=Join-Path $env:ProgramFiles 'NovaStar-VX400-Control';$taskData=Join-Path $env:ProgramData 'NovaStar-VX400-Control'
    $null=[IO.Directory]::CreateDirectory($taskRoot);$null=[IO.Directory]::CreateDirectory($taskData)
    Copy-Item -LiteralPath $source -Destination (Join-Path $taskRoot 'Watch-Vx400Plan.ps1')
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $taskRoot 'plan.config.json')
    $args='-NoProfile -File "'+(Join-Path $taskRoot 'Watch-Vx400Plan.ps1')+'" -ConfigPath "'+(Join-Path $taskRoot 'plan.config.json')+'" -DataDirectory "'+$taskData+'"'
    $task=[pscustomobject]@{TaskName='NovaStar-VX400-Control';TaskPath='\';Actions=@([pscustomobject]@{Execute=$exe;Arguments=$args;WorkingDirectory=$taskRoot})}
    Assert (Test-VxOwnedControllerTask $task '127.0.0.1:5200' $exe) ownedtask
    $task.TaskPath='\Unrelated\';Assert (-not (Test-VxOwnedControllerTask $task '127.0.0.1:5200' $exe)) nestedspoof
    $task.TaskPath='\';$task.TaskName='OtherTask';Assert (-not (Test-VxOwnedControllerTask $task '127.0.0.1:5200' $exe)) namespoof
    $task.TaskName='NovaStar-VX400-Control';$task.Actions[0].Arguments='-Command "Write-Host hi"';Assert (-not (Test-VxOwnedControllerTask $task '127.0.0.1:5200' $exe)) actionspoof
    $task.Actions[0].Arguments=$args
    Assert (-not (Test-VxOwnedControllerTask $task '127.0.0.1:5300' $exe)) taskendpoint
    $stopData=Join-Path $temporary 'stop-data';$null=[IO.Directory]::CreateDirectory($stopData)
    $module=Get-Module Vx400.Ownership
    & $module {param($folder) Request-VxOwnershipStop $folder} $stopData
    Assert ([IO.File]::ReadAllText((Join-Path $stopData 'stop.request')) -match 'Explicit local ownership recovery') createsstop
    [IO.File]::WriteAllText((Join-Path $stopData 'stop.request'),'preserve existing request')
    & $module {param($folder) Request-VxOwnershipStop $folder} $stopData
    Assert ([IO.File]::ReadAllText((Join-Path $stopData 'stop.request')) -ceq 'preserve existing request') preservesexistingstop
    Remove-Item -LiteralPath (Join-Path $stopData 'stop.request')
    $target=Join-Path $temporary 'unrelated.txt';[IO.File]::WriteAllText($target,'unrelated contents')
    $null=New-Item -ItemType HardLink -Path (Join-Path $stopData 'stop.request') -Target $target
    & $module {param($folder) Request-VxOwnershipStop $folder} $stopData
    Assert ([IO.File]::ReadAllText($target) -ceq 'unrelated contents') preservesstopHardlinkTarget
    Write-Output "PASS $script:count ownership pure assertions"
}finally{
    $env:ProgramFiles=$oldProgramFiles;$env:ProgramData=$oldProgramData
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
