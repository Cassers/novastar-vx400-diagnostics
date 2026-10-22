#requires -Version 5.1
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1')

function Complete-VxConnectionConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    if($Config -isnot [pscustomobject]){throw 'Connection config must be a JSON object.'}
    foreach($entry in @(@('deviceModel','VX400'),@('connectionType','Ethernet'),@('usbDeviceKey',''))){
        if($null -eq $Config.PSObject.Properties[$entry[0]]){$Config | Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1]}
    }
    if($Config.deviceModel -isnot [string] -or $Config.deviceModel -cnotin @('VX400','VX600')){throw 'deviceModel must be VX400 or VX600 (original models only).'}
    if($Config.connectionType -isnot [string] -or $Config.connectionType -cnotin @('Ethernet','USB')){throw 'connectionType must be Ethernet or USB.'}
    if($Config.usbDeviceKey -isnot [string] -or $Config.usbDeviceKey.Length -gt 256 -or $Config.usbDeviceKey -match '[\p{Cc}]'){throw 'usbDeviceKey must be a string of at most 256 characters without controls.'}
    return $Config
}
function Get-VxConnectionKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $Config=Complete-VxConnectionConfig $Config
    # Keep the exact old Ethernet lock key; USB discovery keys cannot split local ownership.
    if($Config.connectionType -eq 'USB'){return 'USB:LOCAL'}
    return "$($Config.deviceAddress):$($Config.tcpPort)"
}
function Get-VxExpectedModelId {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $Config=Complete-VxConnectionConfig $Config
    if($Config.deviceModel -eq 'VX600'){return [uint16]0x620E}
    return [uint16]0x6211
}
function Assert-VxDeviceIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)]$Reply)
    $expected=Get-VxExpectedModelId $Config
    if($null -eq $Reply -or $null -eq $Reply.PSObject.Properties['Payload'] -or $Reply.Payload -isnot [byte[]] -or
       $Reply.Payload.Length -ne 2 -or [BitConverter]::ToUInt16($Reply.Payload,0) -ne $expected){
        throw ('Wrong ModelID: expected original {0} 0x{1:X4}.' -f $Config.deviceModel,$expected)
    }
}
function Assert-VxConnectionRequest([byte[]]$Request){
    if($Request.Length -lt 20 -or $Request.Length -gt 4116 -or $Request[0] -ne 0x55 -or $Request[1] -ne 0xAA){throw 'Invalid configured request frame.'}
    $length=[BitConverter]::ToUInt16($Request,16)
    if($Request[10] -notin @(0,1) -or $length -lt 1 -or $length -gt 4096 -or
       ($Request[10] -eq 0 -and $Request.Length -ne 20) -or ($Request[10] -eq 1 -and $Request.Length -ne (20+$length))){throw 'Invalid configured request payload length or command.'}
    [int]$sum=0x5555
    for($i=2;$i -lt ($Request.Length-2);$i++){$sum+=$Request[$i]}
    if([BitConverter]::ToUInt16($Request,($Request.Length-2)) -ne ($sum -band 0xFFFF)){throw 'Invalid configured request checksum.'}
}
function Invoke-VxConfiguredExchange {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][byte[]]$Request)
    $Config=Complete-VxConnectionConfig $Config
    Assert-VxConnectionRequest $Request
    if($Config.connectionType -eq 'Ethernet'){
        return Invoke-VxExchange -DeviceAddress $Config.deviceAddress -TcpPort $Config.tcpPort -Request $Request -TimeoutMs $Config.timeoutMs
    }
    # Native USB code stays unloaded during Ethernet, validation and offline preview.
    Import-Module (Join-Path $PSScriptRoot 'Vx.Usb.psm1') -ErrorAction Stop
    try{
        if($Config.usbDeviceKey -ceq ''){
            $devices=@(Get-VxUsbDevices)
            if($devices.Count -ne 1){throw 'Automatic USB selection requires exactly one supported attached device; select a device explicitly.'}
            $device=$devices[0]
            if($null -eq $device -or $null -eq $device.PSObject.Properties['Key'] -or $device.Key -isnot [string] -or
               [string]::IsNullOrWhiteSpace($device.Key) -or $device.Key.Length -gt 256 -or $device.Key -match '[\p{Cc}]'){
                throw 'Automatic USB selection returned an invalid device key.'
            }
            # Bind this runtime config in memory; a disconnect must never select another controller.
            $Config.usbDeviceKey=$device.Key
        }
        [byte[]]$raw=Invoke-VxUsbExchange -Request $Request -TimeoutMs $Config.timeoutMs -DeviceKey $Config.usbDeviceKey -ExpectedModelId (Get-VxExpectedModelId $Config)
        return ConvertFrom-VxResponse -Raw $raw -Request $Request
    }catch{
        $_.Exception.Data['RequestHex']=[BitConverter]::ToString($Request).Replace('-',' ').ToLowerInvariant()
        throw
    }
}
Export-ModuleMember -Function Complete-VxConnectionConfig,Get-VxConnectionKey,Get-VxExpectedModelId,Assert-VxDeviceIdentity,Invoke-VxConfiguredExchange
