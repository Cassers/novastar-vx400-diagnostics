#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Vx.Operator.Deployment.psm1') -Force
Import-Module (Join-Path $root 'Vx400.Ownership.psm1') -Force
$count=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:count++}
function Reject([scriptblock]$Body,[string]$Message){$bad=$false;try{$null=&$Body}catch{$bad=$true};Assert $bad $Message}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('vx-deploy-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temp)
try{
    $destination=Join-Path $temp 'Usuarios'
    $plan=Join-Path $root 'plan.config.json';$profile=Join-Path $root 'operator.config.json'
    $before=(Get-FileHash $plan).Hash;$beforeProfile=(Get-FileHash $profile).Hash
    & (Join-Path $root 'Export-VxUsuarios.ps1') -ConfigPath $plan -OperatorConfigPath $profile -Destination $destination
    foreach($file in @(Get-VxUserPackageFiles)){
        Assert ([IO.File]::Exists((Join-Path $destination $file))) ('Missing export file '+$file)
        Assert ((Get-FileHash (Join-Path $destination $file)).Hash -eq (Get-FileHash (Join-Path $root $file)).Hash) ('Export bytes '+$file)
    }
    Assert ((Get-FileHash (Join-Path $destination 'plan.config.json')).Hash -eq $before) 'Plan export exact'
    Assert ((Get-FileHash (Join-Path $destination 'operator.config.json')).Hash -eq $beforeProfile) 'Operator profile export exact'
    Assert (-not [IO.File]::Exists((Join-Path $destination 'Control-Vx400.ps1'))) 'Users omit expert GUI'
    Assert (-not [IO.File]::Exists((Join-Path $destination 'Configurar-VxUsuarios.ps1'))) 'Users omit profile editor'
    Assert (-not [IO.Directory]::Exists((Join-Path $destination 'plan-data'))) 'Export excludes runtime commands/session/data'
    Reject {& (Join-Path $root 'Export-VxUsuarios.ps1') -ConfigPath $plan -OperatorConfigPath $profile -Destination $destination} 'Never overwrite an existing user installation'
    Assert ((Get-FileHash $plan).Hash -eq $before -and (Get-FileHash $profile).Hash -eq $beforeProfile) 'Export preserves source configuration'
    $name=Get-VxOperatorTaskName (Join-Path $temp 'data')
    Assert ($name -cmatch '^NovaStar-Usuarios-[A-F0-9]{16}$') 'Stable scoped task name'
    Assert ((Get-VxOperatorTaskName (Join-Path $temp 'other')) -cne $name) 'Different data folders have separate startup identities'
    Assert ((Get-VxPrincipalSid 'S-1-5-18') -ceq 'S-1-5-18') 'SID stays invariant'
    Reject {Assert-VxDeploymentPath 'relative-folder'} 'Deployment requires absolute path'
    Reject {Assert-VxDeploymentPath ($temp+'"')} 'Deployment rejects command quoting injection'
    if($env:OS -ne 'Windows_NT'){$link=Join-Path $temp 'linked';$null=New-Item -ItemType SymbolicLink -Path $link -Target $destination;Reject {Assert-VxDeploymentPath $link} 'Deployment rejects reparse path'}
    # A genuine new motor is identified by source hash, plan, data and its own profile.
    $exe=Join-Path $temp 'powershell.exe';[IO.File]::WriteAllText($exe,'fixture; never executed')
    $controller=Join-Path $destination 'Watch-VxOperator.ps1';$data=Join-Path $destination 'plan-data';$null=[IO.Directory]::CreateDirectory($data)
    $copiedPlan=Join-Path $destination 'plan.config.json';$copiedProfile=Join-Path $destination 'operator.config.json'
    $command='"'+$exe+'" -NoProfile -STA -File "'+$controller+'" -ConfigPath "'+$copiedPlan+'" -OperatorConfigPath "'+$copiedProfile+'" -DataDirectory "'+$data+'" -EnableControl'
    $record=[pscustomobject]@{ProcessId=1234;CreationDate=[DateTime]::UtcNow.AddSeconds(1);ExecutablePath=$exe;CommandLine=$command}
    $base=Get-Content -LiteralPath $copiedPlan -Raw|ConvertFrom-Json
    $endpoint=if($base.connectionType -eq 'USB'){'USB:LOCAL'}else{$base.deviceAddress+':'+$base.tcpPort}
    $identity=Get-VxControllerIdentity $record $endpoint $exe
    Assert ($identity.gracefulSupported -and $identity.operatorConfigPath -ieq $copiedProfile) 'New motor owner binds the exact operator profile'
    Assert ($identity.operatorConfigHash.Length -eq 64) 'Operator profile hash captured'
    $record.CreationDate=(Get-Item -LiteralPath $copiedProfile).LastWriteTimeUtc.AddSeconds(-1)
    Reject {Get-VxControllerIdentity $record $endpoint $exe} 'Changed configuration cannot authorize owner termination'
    Write-Output "PASS $script:count operator deployment assertions"
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
