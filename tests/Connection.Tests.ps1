#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:count=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:count++}
function Throws([scriptblock]$Body,[string]$Message){$thrown=$false;try{&$Body}catch{$thrown=$true};Assert $thrown $Message}
function Hex([string]$Value){return ,[byte[]]@(for($i=0;$i -lt $Value.Length;$i+=2){[Convert]::ToByte($Value.Substring($i,2),16)})}
function Reply([byte[]]$Request,[byte[]]$Payload){
    [byte[]]$raw=New-Object byte[] (20+$Payload.Length)
    [Array]::Copy($Request,0,$raw,0,18)
    $raw[0]=0xAA;$raw[1]=0x55;$raw[4]=$Request[5];$raw[5]=$Request[4]
    [Array]::Copy([BitConverter]::GetBytes([uint16]$Payload.Length),0,$raw,16,2)
    if($Payload.Length){[Array]::Copy($Payload,0,$raw,18,$Payload.Length)}
    Fix-Checksum $raw
    return ,$raw
}
function Fix-Checksum([byte[]]$Raw){
    [int]$sum=0x5555;for($i=2;$i -lt ($Raw.Length-2);$i++){$sum+=$Raw[$i]}
    [Array]::Copy([BitConverter]::GetBytes([uint16]($sum -band 0xFFFF)),0,$Raw,($Raw.Length-2),2)
}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('vx-connection-tests-'+[Guid]::NewGuid().ToString())
$null=New-Item -ItemType Directory -Path $tmp
$utf8=New-Object Text.UTF8Encoding($false)
$global:VxTestUsbLoaded=$false;$global:VxTestUsbCalls=0;$global:VxTestTcpCalls=0;$global:VxTestUsbFailure=$false
$global:VxTestUsbDevices=@([pscustomobject]@{Key='device-one'})
$global:VxTestUsbDiscoveryCalls=0;$global:VxTestUsbWrites=0;$global:VxTestExpectedModelId=0
$global:VxTestRaw=[byte[]]@();$global:VxTestRequest=[byte[]]@();$global:VxTestTimeout=0;$global:VxTestKey=''
$module=$null
try{
    foreach($name in @('Vx.Connection.psm1','Vx400.Protocol.psm1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../'+$name)) -Destination (Join-Path $tmp $name)}
    # A disposable module fixture exercises dispatch without loading native code or touching USB.
    [IO.File]::WriteAllText((Join-Path $tmp 'Vx.Usb.psm1'),@'
$global:VxTestUsbLoaded=$true
function Get-VxUsbDevices{
    $global:VxTestUsbDiscoveryCalls++
    return $global:VxTestUsbDevices
}
function Invoke-VxUsbExchange([byte[]]$Request,[int]$TimeoutMs,[string]$DeviceKey,[int]$ExpectedModelId){
    $global:VxTestUsbCalls++;$global:VxTestRequest=$Request;$global:VxTestTimeout=$TimeoutMs;$global:VxTestKey=$DeviceKey;$global:VxTestExpectedModelId=$ExpectedModelId
    if(@($global:VxTestUsbDevices | Where-Object {$_.Key -ceq $DeviceKey}).Count -ne 1){throw 'Synthetic pinned USB device absent.'}
    if($global:VxTestUsbFailure){throw 'Synthetic USB adapter failure.'}
    if($Request[10] -eq 1){$global:VxTestUsbWrites++}
    return ,$global:VxTestRaw
}
Export-ModuleMember -Function Get-VxUsbDevices,Invoke-VxUsbExchange
'@,$utf8)
    Import-Module (Join-Path $tmp 'Vx400.Protocol.psm1') -Force
    $module=Import-Module (Join-Path $tmp 'Vx.Connection.psm1') -PassThru
    & $module {
        function script:Invoke-VxExchange([string]$DeviceAddress,[int]$TcpPort,[byte[]]$Request,[int]$TimeoutMs){
            $global:VxTestTcpCalls++;$global:VxTestRequest=$Request;$global:VxTestTimeout=$TimeoutMs;$global:VxTestKey=$DeviceAddress+':'+$TcpPort
            return ConvertFrom-VxResponse -Raw $global:VxTestRaw -Request $Request
        }
    }
    $legacy=[pscustomobject]@{deviceAddress='127.0.0.1';tcpPort=5200;timeoutMs=950}
    $c=Complete-VxConnectionConfig $legacy
    Assert ($c.deviceModel -ceq 'VX400' -and $c.connectionType -ceq 'Ethernet' -and $c.usbDeviceKey -ceq '') legacydefaults
    Assert ((Get-VxConnectionKey $c) -ceq '127.0.0.1:5200') legacykeyexact
    Assert ((Get-VxExpectedModelId $c) -eq 0x6211) vx400model
    $request=New-VxReadRequest -Address 2 -Length 2
    $global:VxTestRaw=Reply $request ([byte[]]@(0x11,0x62))
    $parsed=Invoke-VxConfiguredExchange $c $request
    Assert-VxDeviceIdentity $c $parsed
    Assert ($global:VxTestTcpCalls -eq 1 -and $global:VxTestUsbCalls -eq 0 -and -not $global:VxTestUsbLoaded) ethernetneverloadsusb
    Assert ($global:VxTestKey -ceq '127.0.0.1:5200' -and $global:VxTestTimeout -eq 950) ethernetarguments
    $c.deviceModel='VX600'
    Assert ((Get-VxExpectedModelId $c) -eq 0x620E) vx600model
    Assert ((Get-VxConnectionKey $c) -ceq '127.0.0.1:5200') modelsdonotsplitlock
    # NovaStar original VX600 Protocol V1.1 authored ModelID reply example.
    $raw=Hex 'aa55000000fe0000000000000200000002000e62c756'
    $reply=ConvertFrom-VxResponse -Raw $raw -Request $request
    Assert-VxDeviceIdentity $c $reply;Assert $true documentedvx600reply
    Throws {Assert-VxDeviceIdentity $legacy $parsed} selectedmodelmismatch
    foreach($payload in @([byte[]]@(0x11,0x62),[byte[]]@(0,0),[byte[]]@(0x0E))){Throws {Assert-VxDeviceIdentity $c ([pscustomobject]@{Payload=$payload})} invalididentity}
    $c.connectionType='USB';$c.usbDeviceKey='device-one'
    Assert ((Get-VxConnectionKey $c) -ceq 'USB:LOCAL') conservativeusbmutex
    [byte[]]$badRequest=$request.Clone();$badRequest[-1]=$badRequest[-1] -bxor 1
    Throws {Invoke-VxConfiguredExchange $c $badRequest} invalidrequestbeforedispatch
    Assert (-not $global:VxTestUsbLoaded -and $global:VxTestUsbCalls -eq 0) invalidrequestneverloadsusb
    $global:VxTestRaw=$raw
    $parsed=Invoke-VxConfiguredExchange $c $request
    Assert-VxDeviceIdentity $c $parsed
    Assert ($global:VxTestUsbLoaded -and $global:VxTestUsbCalls -eq 1 -and $global:VxTestTcpCalls -eq 1) selectedusbdispatch
    Assert ($global:VxTestTimeout -eq 950 -and $global:VxTestKey -ceq 'device-one' -and $global:VxTestExpectedModelId -eq 0x620E) usbarguments
    Assert ($global:VxTestUsbDiscoveryCalls -eq 0) explicitkeyskipsautodiscovery
    Assert ([BitConverter]::ToString($global:VxTestRequest) -ceq [BitConverter]::ToString($request)) usbrequestunchanged
    $c.usbDeviceKey='device-two';Assert ((Get-VxConnectionKey $c) -ceq 'USB:LOCAL') usbkeysneversplitlock
    $c.usbDeviceKey=''
    $beforeCalls=$global:VxTestUsbCalls;$beforeWrites=$global:VxTestUsbWrites
    $writePacket=New-VxBrightnessRequest -Value 25
    $global:VxTestRaw=Reply $writePacket ([byte[]]@())
    foreach($selection in @(
        [pscustomobject]@{devices=@()},
        [pscustomobject]@{devices=@([pscustomobject]@{Key='device-one'},[pscustomobject]@{Key='device-two'})},
        [pscustomobject]@{devices=@([pscustomobject]@{Key=''})},
        [pscustomobject]@{devices=@([pscustomobject]@{Key=$null})},
        [pscustomobject]@{devices=@([pscustomobject]@{Key=('a'*257)})},
        [pscustomobject]@{devices=@([pscustomobject]@{Key="bad`nkey"})}
    )){
        $global:VxTestUsbDevices=$selection.devices
        Throws {Invoke-VxConfiguredExchange $c $writePacket} unsafeautoselectionrejected
        Assert ($c.usbDeviceKey -ceq '' -and $global:VxTestUsbCalls -eq $beforeCalls -and $global:VxTestUsbWrites -eq $beforeWrites) unsafeautoselectionneverdispatches
    }
    $global:VxTestUsbDevices=@([pscustomobject]@{Key='device-one'})
    $global:VxTestRaw=$raw
    $beforeDiscovery=$global:VxTestUsbDiscoveryCalls
    $sameConfig=$c
    $null=Invoke-VxConfiguredExchange $c $request
    Assert ($c.usbDeviceKey -ceq 'device-one' -and $sameConfig.usbDeviceKey -ceq 'device-one' -and [object]::ReferenceEquals($c,$sameConfig)) autodiscoverypinsoriginalconfig
    Assert ($global:VxTestKey -ceq 'device-one' -and $global:VxTestUsbDiscoveryCalls -eq ($beforeDiscovery+1)) autodiscoveryrunsjustonce
    $global:VxTestUsbDevices=@([pscustomobject]@{Key='device-two'})
    $global:VxTestRaw=Reply $writePacket ([byte[]]@())
    $beforeWrites=$global:VxTestUsbWrites
    Throws {Invoke-VxConfiguredExchange $c $writePacket} missingpinneddevicefails
    Assert ($c.usbDeviceKey -ceq 'device-one' -and $global:VxTestKey -ceq 'device-one') missingspecifieddeviceneverswitches
    Assert ($global:VxTestUsbDiscoveryCalls -eq ($beforeDiscovery+1) -and $global:VxTestUsbWrites -eq $beforeWrites) missingpinneddeviceneverrediscoveredorwritten
    $global:VxTestUsbDevices=@([pscustomobject]@{Key='device-one'})
    foreach($model in @('VX400','VX600')){
        $c.deviceModel=$model
        $expected=if($model -ceq 'VX400'){0x6211}else{0x620E}
        $global:VxTestRaw=Reply $request ([BitConverter]::GetBytes([uint16]$expected))
        $null=Invoke-VxConfiguredExchange $c $request
        Assert ($global:VxTestExpectedModelId -eq $expected) selectedmodelpassedforusbread
        $global:VxTestRaw=Reply $writePacket ([byte[]]@())
        $null=Invoke-VxConfiguredExchange $c $writePacket
        Assert ($global:VxTestExpectedModelId -eq $expected) selectedmodelpassedforusbwrite
    }
    Assert ($global:VxTestUsbDiscoveryCalls -eq ($beforeDiscovery+1)) subsequentexchangeskeeporiginalbinding
    $c.deviceModel='VX600'
    foreach($index in @(2,3,4,6,12)){
        [byte[]]$global:VxTestRaw=$raw.Clone();$global:VxTestRaw[$index]=$global:VxTestRaw[$index] -bxor 1;Fix-Checksum $global:VxTestRaw
        Throws {Invoke-VxConfiguredExchange $c $request} invalidusbreplycorrelation
    }
    [byte[]]$global:VxTestRaw=$raw.Clone();$global:VxTestRaw[-1]=$global:VxTestRaw[-1] -bxor 1
    Throws {Invoke-VxConfiguredExchange $c $request} invalidusbreplychecksum
    $global:VxTestRaw=[byte[]]@(0xAA,0x55);Throws {Invoke-VxConfiguredExchange $c $request} invalidusbreplylength
    foreach($packet in @((New-VxBrightnessRequest -Value 25),(New-VxDisplayRequest -Mode White))){
        $global:VxTestRaw=Reply $packet ([byte[]]@());$null=Invoke-VxConfiguredExchange $c $packet;Assert $true usbwriteackvalidated
        $global:VxTestRaw=Reply $packet ([byte[]]@(1));Throws {Invoke-VxConfiguredExchange $c $packet} usbwritepayloadrejected
    }
    $global:VxTestUsbFailure=$true;Throws {Invoke-VxConfiguredExchange $c $request} usbfailureexplicit
    Assert ($global:VxTestTcpCalls -eq 1) neverfallbacktoethernet
    foreach($bad in @('Auto','WiFi','usb')){$c.connectionType=$bad;Throws {Invoke-VxConfiguredExchange $c $request} unsupportedtransport}
    Assert ($global:VxTestTcpCalls -eq 1) invalidtransportneverdispatches
    Write-Output "PASS $script:count connection assertions (mock adapters; no hardware)"
}finally{
    if($null -ne $module){Remove-Module -ModuleInfo $module -Force}
    Get-Module | Where-Object {$_.Path.StartsWith($tmp)} | Remove-Module -Force
    Remove-Item -LiteralPath $tmp -Recurse -Force
    Get-Variable -Name 'VxTest*' -Scope Global | Remove-Variable -Scope Global
}
