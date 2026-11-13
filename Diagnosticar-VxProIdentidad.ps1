#requires -Version 5.1
[CmdletBinding()]
param([string]$DeviceAddress='', [ValidateRange(1,65535)][int]$TcpPort=15200,
    [ValidateRange(250,15000)][int]$TimeoutMs=3000, [string]$OutputPath='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$code=2
$result=[ordered]@{
    schemaVersion=1;softwareVersion='0.8.3+vx-pro-identity.1';timestampUtc=[DateTime]::UtcNow.ToString('o')
    readOnly=$true;success=$false;status='diagnostic_failed';deviceAddress='';tcpPort=$TcpPort
    modelIdRaw=$null;modelIdHex=$null;requestHex='';replyHex='';checksumValid=$false;correlationValid=$false
    identityMappingVerified=$false;controlEnabled=$false;firmwareQueried=$false
    message='';error='';reportPath=''
}
try {
    if([string]::IsNullOrWhiteSpace($DeviceAddress)){$DeviceAddress=Read-Host 'IPv4 del controlador (sin buscar otros equipos)'}
    $ip=$null
    if($DeviceAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse($DeviceAddress,[ref]$ip) -or
        $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Introduzca una direccion IPv4 valida; no se admiten nombres ni comandos.'}
    $result.deviceAddress=$ip.ToString()
    Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1') -Force
    # Only one identity READ. No model mapping, discovery, retries, settings or control writes.
    $request=New-VxReadRequest -Address 2 -Length 2 -Sequence 1
    $result.requestHex=[BitConverter]::ToString($request).Replace('-',' ').ToLowerInvariant()
    $reply=Invoke-VxExchange -DeviceAddress $result.deviceAddress -TcpPort $TcpPort -TimeoutMs $TimeoutMs -Request $request
    $result.replyHex=$reply.RawHex;$result.checksumValid=$reply.ChecksumValid;$result.correlationValid=$reply.CorrelationValid
    $result.modelIdRaw=[int][BitConverter]::ToUInt16($reply.Payload,0)
    $result.modelIdHex=('0x{0:X4}' -f $result.modelIdRaw)
    $result.success=$true;$result.status='protocol_valid_identity_unmapped';$code=0
    $result.message='Lectura valida. Identidad sin correspondencia de modelo verificada; control NO habilitado.'
} catch {
    $result.error=$_.Exception.GetBaseException().Message
    $result.message='No se obtuvo una lectura de identidad validada. Control NO habilitado.'
    # Protocol errors may be wrapped by PowerShell. Export only bounded packet evidence.
    $exception=$_.Exception
    for($depth=0;$depth -lt 8 -and $null -ne $exception;$depth++){
        if($exception.Data.Contains('RawHex')){$result.replyHex=([string]$exception.Data['RawHex']).Substring(0,[Math]::Min(12347,([string]$exception.Data['RawHex']).Length))}
        $exception=$exception.InnerException
    }
}
try {
    if([string]::IsNullOrWhiteSpace($OutputPath)){
        $base=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if([string]::IsNullOrWhiteSpace($base)){throw 'No hay directorio local de usuario. Use -OutputPath con un archivo nuevo.'}
        $directory=Join-Path $base 'NovaStar\diagnostics'
        $null=[IO.Directory]::CreateDirectory($directory)
        $OutputPath=Join-Path $directory ('vx-pro-identity-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N')+'.json')
    }
    $OutputPath=[IO.Path]::GetFullPath($OutputPath)
    $result.reportPath=$OutputPath
    $json=$result|ConvertTo-Json -Depth 4
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
    # CreateNew refuses overwriting any existing configuration or previous report.
    $file=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
} catch {
    $code=2;$result.reportPath='';$result.error='No se pudo guardar el informe sin sobrescribir archivos: '+$_.Exception.GetBaseException().Message
}
Write-Output ($result|ConvertTo-Json -Depth 4)
exit $code
