#requires -Version 5.1
Set-StrictMode -Version Latest

function Initialize-VxUsbTypes {
    # Compilation is lazy; importing the module does not load a native driver.
    if ($null -eq ('VxUsb.Transport' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'Vx.Usb.Native.cs') -ErrorAction Stop
    }
}
function Get-VxUsbDevices {
    [CmdletBinding()]
    param()
    Initialize-VxUsbTypes
    [VxUsb.Driver]::GetDevices()
}
function Invoke-VxUsbExchange {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Request,
        [ValidateRange(1,15000)][int]$TimeoutMs=3000,
        [AllowEmptyString()][string]$DeviceKey='',
        [int]$ExpectedModelId=0)
    Initialize-VxUsbTypes
    return ,([VxUsb.Driver]::Exchange($Request,$TimeoutMs,$DeviceKey,$ExpectedModelId))
}
Export-ModuleMember -Function Get-VxUsbDevices,Invoke-VxUsbExchange
