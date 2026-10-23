#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='',[string]$OperatorConfigPath='',[string]$AccessPolicyPath='',[Parameter(Mandatory)][string]$Destination)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.Deployment.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1')
Import-Module (Join-Path $PSScriptRoot 'Vx.ProAccess.psm1') -Force
if(-not $ConfigPath){$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
if(-not $OperatorConfigPath){$OperatorConfigPath=Join-Path $PSScriptRoot 'operator.config.json'}
$ConfigPath=Assert-VxDeploymentPath ([IO.Path]::GetFullPath($ConfigPath))
$OperatorConfigPath=Assert-VxDeploymentPath ([IO.Path]::GetFullPath($OperatorConfigPath))
if(-not $AccessPolicyPath){$AccessPolicyPath=Join-Path (Split-Path $ConfigPath -Parent) 'pro-access.json'}
$AccessPolicyPath=Assert-VxDeploymentPath ([IO.Path]::GetFullPath($AccessPolicyPath))
$null=Read-VxPlanConfig -Path $ConfigPath
$null=Read-VxOperatorConfig -Path $OperatorConfigPath
# Capture validated bytes before creating any destination or staging files.
$null=Read-VxProAccessPolicy -Path $AccessPolicyPath
$policyBytes=[IO.File]::ReadAllBytes($AccessPolicyPath)
$Destination=Assert-VxDeploymentPath $Destination
if((Test-Path -LiteralPath $Destination) -and @((Get-ChildItem -LiteralPath $Destination -Force)).Count){throw 'El destino debe ser una carpeta vacía nueva. No se sobrescriben perfiles ni datos.'}
$files=@(Get-VxUserPackageFiles)
foreach($name in $files){
    $source=Assert-VxDeploymentPath (Join-Path $PSScriptRoot $name)
    if(-not [IO.File]::Exists($source)){throw "Falta archivo del paquete unificado: $name"}
}
$staging=$Destination+'.export-'+[guid]::NewGuid().ToString('N')
try{
    $null=[IO.Directory]::CreateDirectory($staging)
    foreach($name in $files){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $staging $name)}
    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $staging 'plan.config.json')
    Copy-Item -LiteralPath $OperatorConfigPath -Destination (Join-Path $staging 'operator.config.json')
    [IO.File]::WriteAllBytes((Join-Path $staging 'pro-access.json'),$policyBytes)
    foreach($document in @('README.md','VALIDACION.md')){
        if([IO.File]::Exists((Join-Path $PSScriptRoot $document))){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $document) -Destination (Join-Path $staging $document)}
    }
    $docsSource=Join-Path $PSScriptRoot 'docs'
    if([IO.Directory]::Exists($docsSource)){
        $docsTarget=Join-Path $staging 'docs';$null=[IO.Directory]::CreateDirectory($docsTarget)
        foreach($document in @(Get-ChildItem -LiteralPath $docsSource -File -Filter '*.md')){Copy-Item -LiteralPath $document.FullName -Destination (Join-Path $docsTarget $document.Name)}
    }
    if([IO.File]::Exists((Join-Path $PSScriptRoot 'docs/usuarios.md'))){Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs/usuarios.md') -Destination (Join-Path $staging 'LEEME.md')}
    # Local media paths are preserved. Files may be large/private: do not silently bundle them.
    [IO.File]::WriteAllText((Join-Path $staging 'edition.json'),'{"schemaVersion":1,"edition":"Unified","version":"0.8.1"}',(New-Object Text.UTF8Encoding($false)))
    if([IO.Directory]::Exists($Destination)){
        if(@(Get-ChildItem -LiteralPath $Destination -Force).Count){throw 'El destino cambió durante la exportación.'}
        [IO.Directory]::Delete($Destination)
    }
    [IO.Directory]::Move($staging,$Destination)
    Write-Output ('Paquete unificado Usuarios + Pro exportado: '+$Destination+'. Copie/configure los medios en el PC de destino desde Pro antes de activar el motor.')
}finally{if([IO.Directory]::Exists($staging)){Remove-Item -LiteralPath $staging -Recurse -Force}}
