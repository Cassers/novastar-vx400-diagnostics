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
    $destination=Join-Path $temp 'Unified'
    # The selected install owns its policy; never inherit the editor checkout's policy.
    $selected=Join-Path $temp 'selected';$null=[IO.Directory]::CreateDirectory($selected)
    $plan=Join-Path $selected 'chosen-plan.json';$profile=Join-Path $selected 'chosen-profile.json'
    [IO.File]::WriteAllText($plan,([IO.File]::ReadAllText((Join-Path $root 'plan.config.json'))+"`n "))
    [IO.File]::WriteAllText($profile,([IO.File]::ReadAllText((Join-Path $root 'operator.config.json'))+"`n "))
    $policy=Join-Path $selected 'pro-access.json'
    $fixture=[ordered]@{schemaVersion=1;kdf='PBKDF2-SHA256';iterations=600000;salt=[Convert]::ToBase64String([byte[]](1..32));hash=[Convert]::ToBase64String([byte[]](33..64));requireChange=$true}
    [IO.File]::WriteAllText($policy,($fixture|ConvertTo-Json))
    $policyHash=(Get-FileHash $policy).Hash
    [IO.File]::WriteAllText((Join-Path $selected 'private-media.mp4'),'fixture; must not be bundled')
    $before=(Get-FileHash $plan).Hash;$beforeProfile=(Get-FileHash $profile).Hash
    & (Join-Path $root 'Export-VxUsuarios.ps1') -ConfigPath $plan -OperatorConfigPath $profile -Destination $destination
    foreach($file in @(Get-VxUserPackageFiles)){
        Assert ([IO.File]::Exists((Join-Path $destination $file))) ('Missing export file '+$file)
        Assert ((Get-FileHash (Join-Path $destination $file)).Hash -eq (Get-FileHash (Join-Path $root $file)).Hash) ('Export bytes '+$file)
    }
    Assert ((Get-FileHash (Join-Path $destination 'plan.config.json')).Hash -eq $before) 'Plan export exact'
    Assert ((Get-FileHash (Join-Path $destination 'operator.config.json')).Hash -eq $beforeProfile) 'Operator profile export exact'
    foreach($file in @('Control-Vx400.ps1','Configurar-VxUsuarios.ps1','Vx.ProAccess.psm1','Abrir-NovaStar.bat','Export-VxUsuarios.ps1','Install-Vx400Control.ps1','Watch-Vx400.ps1','Vx400.Automation.psm1','watcher.config.json','README.md','VALIDACION.md')){
        Assert ([IO.File]::Exists((Join-Path $destination $file))) ('Unified package includes '+$file)
    }
    Assert ((Get-FileHash (Join-Path $destination 'pro-access.json')).Hash -eq $policyHash) 'Policy belongs to selected installation, byte exact'
    $edition=Get-Content (Join-Path $destination 'edition.json') -Raw|ConvertFrom-Json
    Assert ($edition.edition -ceq 'Unified' -and $edition.version -ceq '0.8.1') 'Unified edition metadata'
    Assert ([IO.File]::Exists((Join-Path $destination 'docs/usuarios.md'))) 'Documentation preserves relative paths'
    Assert (-not [IO.File]::Exists((Join-Path $destination 'private-media.mp4'))) 'Export never bundles selected media'
    Assert (-not [IO.Directory]::Exists((Join-Path $destination 'plan-data'))) 'Export excludes runtime commands/session/data'
    Reject {& (Join-Path $root 'Export-VxUsuarios.ps1') -ConfigPath $plan -OperatorConfigPath $profile -Destination $destination} 'Never overwrite an existing user installation'
    Assert ((Get-FileHash (Join-Path $destination 'pro-access.json')).Hash -eq $policyHash) 'Rejected export preserves destination policy'
    $fixture.hash=[Convert]::ToBase64String([byte[]](65..96));$fixture.requireChange=$false
    $replacement=Join-Path $temp 'replacement-policy.json';[IO.File]::WriteAllText($replacement,($fixture|ConvertTo-Json))
    $otherDestination=Join-Path $temp 'other-unified'
    & (Join-Path $root 'Export-VxUsuarios.ps1') -ConfigPath $plan -OperatorConfigPath $profile -AccessPolicyPath $replacement -Destination $otherDestination
    Assert ((Get-FileHash (Join-Path $otherDestination 'pro-access.json')).Hash -eq (Get-FileHash $replacement).Hash) 'Explicit alternate policy used exactly'
    Assert ((Get-FileHash $policy).Hash -eq $policyHash) 'Export never changes source verifier'
    $reexport=Join-Path $temp 'from-unified'
    & (Join-Path $destination 'Export-VxUsuarios.ps1') -Destination $reexport
    Assert ((Get-FileHash (Join-Path $reexport 'pro-access.json')).Hash -eq $policyHash) 'Exported package can re-export its own complete installation'
    Assert ((Get-FileHash (Join-Path $reexport 'operator.config.json')).Hash -eq $beforeProfile) 'Re-export preserves selected profile'
    foreach($badKind in @('missing','malformed','plaintext')){
        $badPolicy=Join-Path $temp ($badKind+'.json');$badDestination=Join-Path $temp ('rejected-'+$badKind)
        if($badKind -eq 'malformed'){[IO.File]::WriteAllText($badPolicy,'{}')}
        if($badKind -eq 'plaintext'){[IO.File]::WriteAllText($badPolicy,'{"schemaVersion":1,"password":"fixture-not-a-secret"}')}
        Reject {& (Join-Path $root 'Export-VxUsuarios.ps1') -ConfigPath $plan -OperatorConfigPath $profile -AccessPolicyPath $badPolicy -Destination $badDestination} ('Reject '+$badKind+' policy')
        Assert (-not [IO.Directory]::Exists($badDestination)) ('No partial export on '+$badKind+' policy')
        Assert (@(Get-ChildItem -LiteralPath $temp -Directory | Where-Object {$_.Name -like ('rejected-'+$badKind+'.export-*')}).Count -eq 0) ('No staging remains on '+$badKind+' policy')
    }
    $emptyTarget=Join-Path $temp 'existing-empty';$null=[IO.Directory]::CreateDirectory($emptyTarget)
    Reject {& (Join-Path $root 'Export-VxUsuarios.ps1') -ConfigPath $plan -OperatorConfigPath $profile -AccessPolicyPath (Join-Path $temp 'malformed.json') -Destination $emptyTarget} 'Invalid policy leaves existing empty destination untouched'
    Assert ([IO.Directory]::Exists($emptyTarget) -and @(Get-ChildItem -LiteralPath $emptyTarget -Force).Count -eq 0) 'No failed export files in existing destination'
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
