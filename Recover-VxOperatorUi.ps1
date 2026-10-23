#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$DataDirectory,[Parameter(Mandatory)][string]$OutputPath,[switch]$Force,[string]$ExpectedOwnersPath='',[switch]$Elevated)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.Deployment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force
$result=$null
try{
    foreach($name in @('ConfigPath','DataDirectory','OutputPath')){Set-Variable -Name $name -Value (Assert-VxDeploymentPath (Get-Variable -Name $name -ValueOnly))}
    if($ExpectedOwnersPath){$ExpectedOwnersPath=Assert-VxDeploymentPath $ExpectedOwnersPath}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        if($Elevated){throw 'La recuperación requiere el permiso de administrador solicitado por Windows.'}
        $args='-NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}" -DataDirectory "{2}" -OutputPath "{3}" -Elevated' -f $PSCommandPath,$ConfigPath,$DataDirectory,$OutputPath
        if($Force){$args+=' -Force -ExpectedOwnersPath "'+$ExpectedOwnersPath+'"'}
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $child=Start-Process -FilePath $exe -ArgumentList $args -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        try{if($child.ExitCode -ne 0 -or -not [IO.File]::Exists($OutputPath)){throw 'El proceso de recuperación no devolvió un resultado. Revise el permiso de Windows.'}}finally{$child.Dispose()}
        exit 0
    }
    Import-Module (Join-Path $PSScriptRoot 'Vx400.Ownership.psm1') -Force
    $result=Invoke-VxOwnershipRecovery -ConfigPath $ConfigPath -DataDirectory $DataDirectory -Force:$Force -ExpectedOwnersPath $ExpectedOwnersPath
}catch{$result=[pscustomobject]@{schemaVersion=1;endpoint='';success=$false;needsForce=$false;message=$_.Exception.Message;controllers=@();pausedTasks=@();mutexAvailable=$false}}
$temporary=$OutputPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
try{
    [IO.File]::WriteAllText($temporary,($result|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
    Move-VxAtomicFile -Source $temporary -Destination $OutputPath
}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
# The caller inspects success/needsForce; a written negative result is still a completed worker.
exit 0
