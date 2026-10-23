#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='',[string]$OperatorConfigPath='',[Parameter(Mandatory)][string]$Destination)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.Deployment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1')
if(-not $ConfigPath){$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
if(-not $OperatorConfigPath){$OperatorConfigPath=Join-Path $PSScriptRoot 'operator.config.json'}
$null=Read-VxPlanConfig -Path $ConfigPath
$null=Read-VxOperatorConfig -Path $OperatorConfigPath
$Destination=Assert-VxDeploymentPath $Destination
if((Test-Path -LiteralPath $Destination) -and @((Get-ChildItem -LiteralPath $Destination -Force)).Count){throw 'El destino debe ser una carpeta vacía nueva. No se sobrescriben perfiles ni datos.'}
foreach($name in @(Get-VxUserPackageFiles)){
    $source=Assert-VxDeploymentPath (Join-Path $PSScriptRoot $name)
    if(-not [IO.File]::Exists($source)){throw "Falta archivo de Usuarios: $name"}
}
$staging=$Destination+'.export-'+[guid]::NewGuid().ToString('N')
try{
    $null=[IO.Directory]::CreateDirectory($staging)
    foreach($name in @(Get-VxUserPackageFiles)){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $staging $name)}
    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $staging 'plan.config.json')
    Copy-Item -LiteralPath $OperatorConfigPath -Destination (Join-Path $staging 'operator.config.json')
    if([IO.File]::Exists((Join-Path $PSScriptRoot 'docs/usuarios.md'))){Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs/usuarios.md') -Destination (Join-Path $staging 'LEEME.md')}
    # Local media paths are preserved. Files may be large/private: do not silently bundle them.
    [IO.File]::WriteAllText((Join-Path $staging 'edition.json'),'{"schemaVersion":1,"edition":"Usuarios","version":"0.8.0"}',(New-Object Text.UTF8Encoding($false)))
    if([IO.Directory]::Exists($Destination)){
        if(@(Get-ChildItem -LiteralPath $Destination -Force).Count){throw 'El destino cambió durante la exportación.'}
        [IO.Directory]::Delete($Destination)
    }
    [IO.Directory]::Move($staging,$Destination)
    Write-Output ('Usuarios exportado: '+$Destination+'. Copie/configure los medios en el PC de destino desde Pro antes de activar el motor.')
}finally{if([IO.Directory]::Exists($staging)){Remove-Item -LiteralPath $staging -Recurse -Force}}
