#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='', [switch]$ListUsb)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$mutex=$null;$owns=$false;$code=0
$result=[ordered]@{success=$false;readOnly=$true;message='';devices=@()}
try{
    Import-Module (Join-Path $PSScriptRoot 'Vx.Connection.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1') -Force
    if($ListUsb){
        Import-Module (Join-Path $PSScriptRoot 'Vx.Usb.psm1') -Force
        $result.devices=@(Get-VxUsbDevices)
        $result.success=$true
        $result.message=('USB compatibles detectados: {0}. Se verificara el modelo al probar la conexion.' -f $result.devices.Count)
        foreach($device in $result.devices){$result.message+=[Environment]::NewLine+([string]$device.DisplayName)+' | '+([string]$device.Key)}
    }else{
        Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force
        if([string]::IsNullOrWhiteSpace($ConfigPath)){$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
        $config=Read-VxPlanConfig -Path $ConfigPath
        $key=Get-VxConnectionKey -Config $config
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-','')}finally{$sha.Dispose()}
        $prefix=if($env:OS -eq 'Windows_NT'){'Global\'}else{''}
        $mutex=New-Object Threading.Mutex($false,($prefix+'NovaStarVX400-'+$hash))
        try{$owns=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
        if(-not $owns){throw 'Otro controlador usa esta conexion. Detengalo o use Recuperar control antes de probar.'}
        $reply=Invoke-VxConfiguredExchange -Config $config -Request (New-VxReadRequest -Address 2 -Length 2 -Sequence 1)
        Assert-VxDeviceIdentity -Config $config -Reply $reply
        $id=[BitConverter]::ToUInt16($reply.Payload,0)
        $result.success=$true;$result.model=$config.deviceModel;$result.connectionType=$config.connectionType;$result.modelId=[int]$id
        $result.message=('{0} confirmado por {1}. ModelID 0x{2:X4}; checksum y respuesta correlacionada validos. Solo lectura: no se cambio brillo ni contenido.' -f $config.deviceModel,$config.connectionType,$id)
    }
}catch{
    $code=2;$result.message=$_.Exception.GetBaseException().Message
    if($result.message -match '(?i)access.*denied|acceso.*denegado|unauthorized'){$result.message+=' Use Recuperar control y acepte elevacion si existe un bloqueo de otra instancia.'}
}finally{
    if($owns){$mutex.ReleaseMutex()};if($null -ne $mutex){$mutex.Dispose()}
}
if($ListUsb -and $env:OS -eq 'Windows_NT'){
    try{
        $devices=@(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE 'USB\\VID_0483%' OR Name LIKE '%Nova%'" -ErrorAction Stop)
        foreach($device in $devices){$result.message+=[Environment]::NewLine+('Windows USB: {0} | {1} | driver: {2}' -f $device.Name,$device.PNPDeviceID,$device.Service)}
    }catch{ $result.message+=[Environment]::NewLine+'No se pudo consultar el inventario USB de Windows.' }
}
Write-Output ($result|ConvertTo-Json -Depth 6 -Compress)
exit $code
