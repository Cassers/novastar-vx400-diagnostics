#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
# Compile production state machine and fake together; no native library is loaded.
if($null -eq ('VxUsbFake' -as [type])){
    Add-Type -Path @((Join-Path $root 'Vx.Usb.Native.cs'),(Join-Path $PSScriptRoot 'Usb.Fake.cs'))
}
Import-Module (Join-Path $root 'Vx.Usb.psm1') -Force
$script:passed=0
function Assert-True($Value,[string]$Label){if(-not $Value){throw ('FAIL: '+$Label)};$script:passed++}
function Reject([scriptblock]$Action,[string]$Pattern,[string]$Label){
    $message='';try{& $Action | Out-Null}catch{$message=$_.Exception.ToString()}
    Assert-True ($message -match $Pattern) $Label
}
function Request([int]$Length=2,[switch]$Write){
    [byte[]]$request=New-Object byte[] $(if($Write){20+$Length}else{20})
    $request[0]=0x55;$request[1]=0xAA;$request[10]=[byte][bool]$Write
    $request[16]=[byte]($Length -band 255);$request[17]=[byte]($Length -shr 8)
    return ,$request
}
function Fake([int]$Length=22){
    $fake=New-Object VxUsbFake
    $fake.Reply=New-Object byte[] $Length;$fake.Reply[0]=0xAA;$fake.Reply[1]=0x55
    return $fake
}
function Exchange($Fake,[byte[]]$Request=(Request),[int]$Timeout=3000,[string]$Key='',[int]$ExpectedModelId=0){
    return ,([VxUsb.Transport]::Exchange($Fake,$Request,$Timeout,$Key,$ExpectedModelId))
}

$fake=Fake;$reply=Exchange $fake
Assert-True ($reply.Length -eq 22 -and $reply[0] -eq 0xAA) 'Direct AA55 response returned as raw bytes'
Assert-True ($fake.Writes.Count -eq 2 -and $fake.Writes[0].Length -eq 31 -and $fake.Writes[1].Length -eq 20) 'CBW and register payload are separate OUT transfers'
Assert-True ($fake.Disposed) 'Direct success closes USB handle'
$cbw=$fake.Writes[0]
Assert-True ([BitConverter]::ToString($cbw[0..3]) -eq '55-53-42-43' -and $cbw[14] -eq 0x10 -and $cbw[15] -eq 0xA2 -and $cbw[22] -eq 1) 'A2 CBW constants match UDiskMode framing'
Assert-True ([BitConverter]::ToUInt32($cbw,8) -eq 20 -and $cbw[12] -eq 0) 'A2 CBW length and write direction'
$allowed=@(0,1,2,3,4,5,6,7,8,9,10,11,14,15,22)
Assert-True (@(0..30 | Where-Object {$_ -notin $allowed -and $cbw[$_] -ne 0}).Count -eq 0) 'All reserved CBW fields zero'

$fake=Fake;$fake.Coalesce=$true;$reply=Exchange $fake
Assert-True ($reply.Length -eq 22 -and $fake.Writes.Count -eq 2 -and $fake.Disposed) 'Coalesced direct response plus matching optional CSW validated'
foreach($kind in @('CorruptTag','CorruptResidue','CorruptStatus')){
    $fake=Fake;$fake.Coalesce=$true;$fake.$kind=1
    Reject {Exchange $fake} 'status|residue' "Direct optional CSW $kind rejected"
    Assert-True $fake.Disposed 'Invalid optional direct CSW closes handle'
}
$fake=Fake;$fake.StatusRoute=$true;$reply=Exchange $fake
Assert-True ($reply.Length -eq 22 -and $fake.Writes.Count -eq 3) 'Valid write CSW triggers A3 response fetch'
$readCbw=$fake.Writes[2]
Assert-True ($readCbw[15] -eq 0xA3 -and $readCbw[12] -eq 0x80 -and [BitConverter]::ToUInt32($readCbw,8) -eq 22) 'A3 CBW has read direction and exact expected reply size'
Assert-True ([BitConverter]::ToUInt32($readCbw,4) -ne [BitConverter]::ToUInt32($fake.Writes[0],4)) 'A2 and A3 use distinct command tags'
Assert-True ($fake.Disposed) 'A3 success closes USB handle'
$fake=Fake;$fake.StatusRoute=$true;$fake.Fragment=$true;$reply=Exchange $fake
Assert-True ($reply.Length -eq 22 -and $fake.ReadCount -gt 10) 'Fragmented CSWs and response are assembled'
$fake=Fake;$fake.Fragment=$true;$reply=Exchange $fake
Assert-True ($reply.Length -eq 22) 'Fragmented direct response assembled'
$fake=Fake;$fake.StatusRoute=$true;$fake.Coalesce=$true;$reply=Exchange $fake
Assert-True ($reply.Length -eq 22) 'A3 response and CSW coalesced in one read are split and validated'

$request=Request -Length 44 -Write;$fake=Fake 20;$reply=Exchange $fake $request -ExpectedModelId 0x6211
Assert-True ($fake.Writes.Count -eq 5 -and $fake.Writes[4].Length -eq 0) '64-byte payload transfer gets terminating zero-length OUT'
Assert-True ($reply.Length -eq 20) 'Write reply is fixed 20-byte ACK'
$request=Request -Length 256;$fake=Fake 276;$fake.StatusRoute=$true;$reply=Exchange $fake $request
Assert-True ([BitConverter]::ToUInt32($fake.Writes[2],8) -eq 276) 'Read length uses UInt16 at request16, not vendor17/18 bug'

foreach($route in @(1,2)){
    foreach($kind in @('CorruptTag','CorruptResidue','CorruptStatus')){
        $fake=Fake;$fake.StatusRoute=$true;$fake.$kind=$route
        Reject {Exchange $fake} 'status|residue' "$kind route$route rejected"
        Assert-True $fake.Disposed "$kind route$route releases handle"
        if($route -eq 1){Assert-True ($fake.Writes.Count -eq 2) 'Invalid write CSW never sends A3'}
    }
}
$fake=Fake;$fake.StatusRoute=$true;$fake.BadSignature=$true
Reject {Exchange $fake} 'signature' 'Wrong USBS signature rejected'
foreach($at in @(1,2)){
    $fake=Fake;$fake.ShortWriteAt=$at
    Reject {Exchange $fake} 'short write' "Partial OUT$at safely rejected"
    Assert-True ($fake.Disposed -and $fake.Writes.Count -eq $at -and $fake.ReadCount -eq 0) 'Partial command is never retried and handle closes'
}
$fake=Fake;$fake.ThrowRead=$true
Reject {Exchange $fake} 'read fault' 'Read exception preserved'
Assert-True $fake.Disposed 'Read fault releases handle'
$fake=Fake;$fake.ThrowWrite=$true
Reject {Exchange $fake} 'write fault' 'Write exception preserved'
Assert-True $fake.Disposed 'Write fault releases handle'
$fake=Fake;$fake.NoReply=$true
Reject {Exchange $fake} 'timeout' 'Native timeout preserved'
Assert-True $fake.Disposed 'Timeout releases handle'
$fake=Fake;$fake.DelayMs=15
Reject {Exchange $fake (Request) 5} 'deadline' 'One total deadline applies across stages'
Assert-True ($fake.Disposed -and $fake.Writes.Count -eq 1) 'Expired deadline prevents subsequent writes'
$fake=Fake;$fake.Reply=[byte[]]@(0xAA,0x55)
Reject {Exchange $fake} 'empty' 'Truncated direct response rejected'
Assert-True $fake.Disposed 'Truncated response closes handle'
$fake=Fake;$fake.Reply[0]=0x12
Reject {Exchange $fake} 'empty|signature' 'Unknown response framing rejected'

$fake=Fake;$fake.Devices=@()
Reject {Exchange $fake} 'No compatible' 'No devices fails before open'
Assert-True ($fake.OpenCount -eq 0) 'Missing device never opened'
$fake=Fake;$fake.Devices=@($fake.Devices[0],(New-Object VxUsb.DeviceInfo('second','USB second',0x0483,0x5720,$null)))
Reject {Exchange $fake} 'Multiple compatible' 'Auto selection rejects ambiguity'
Assert-True ($fake.OpenCount -eq 0) 'Ambiguity causes no device access'
$reply=Exchange $fake (Request) 3000 'second'
Assert-True ($reply.Length -eq 22 -and $fake.OpenCount -eq 1) 'Explicit stable selector works with multiple devices'
$fake=Fake
Reject {Exchange $fake (Request) 3000 'missing'} 'missing' 'Pinned missing device never falls back to auto'
Assert-True ($fake.OpenCount -eq 0) 'Missing explicit selector never opens another device'
$fake=Fake;$fake.Devices=@($fake.Devices[0],$fake.Devices[0])
Reject {Exchange $fake} 'duplicate' 'Duplicate driver selectors fail closed'
$fake=Fake;$fake.ThrowOpen=$true
Reject {Exchange $fake} 'access denied' 'Open/access error preserved'
Assert-True ($fake.Writes.Count -eq 0) 'Failed open sends nothing'

foreach($length in @(0,4097)){
    $fake=Fake
    Reject {Exchange $fake (Request -Length $length)} 'length' "Out of bounds declared length$length rejected before access"
    Assert-True ($fake.OpenCount -eq 0) 'Invalid request never opens handle'
}
$fake=Fake;$request=Request;$request[10]=3
Reject {Exchange $fake $request} 'command' 'Unsupported register command rejected'
$fake=Fake;$request=Request;$request[0]=0
Reject {Exchange $fake $request} 'canonical' 'Raw TCP/unframed requests rejected'
Reject {[VxUsb.Transport]::CommandBlock(1,4117,$true)} 'payloadLength' 'CBW maximum length bounded'
Reject {Exchange (Fake) (Request) 0} 'timeoutMs' 'Zero timeout rejected'
Reject {Exchange (Fake) (Request) 15001} 'timeoutMs' 'Excessive timeout rejected'
$maximum=Request -Length 4096
Assert-True ([VxUsb.Transport]::ExpectedReplyLength($maximum) -eq 4116) 'Maximum canonical read bounded at4116'

# A runtime identity cached from an earlier device never authorizes a new opened handle.
$request=Request -Length 1 -Write
foreach($model in @(0,0x6212,0x620D)){
    $fake=Fake 20
    Reject {Exchange $fake $request -ExpectedModelId $model} 'ExpectedModelId' 'Writes require an explicitly supported expected model before discovery'
    Assert-True ($fake.EnumerateCount -eq 0 -and $fake.OpenCount -eq 0 -and $fake.Writes.Count -eq 0) 'Missing or unsupported write identity produces no driver access'
}
foreach($model in @(0x6211,0x620E)){
    $fake=Fake 20;$fake.ProbeModelId=$model
    $reply=Exchange $fake $request -ExpectedModelId $model
    Assert-True ($reply.Length -eq 20 -and $fake.OpenCount -eq 1 -and $fake.EnumerateCount -eq 1 -and $fake.Disposed) 'Matched identity probe and write use one discovered opened handle'
    $probe=$fake.Writes[1];$mutation=$fake.Writes[3]
    Assert-True ($probe.Length -eq 20 -and $probe[10] -eq 0 -and [BitConverter]::ToUInt32($probe,12) -eq 2 -and [BitConverter]::ToUInt16($probe,16) -eq 2) 'Canonical read-only ModelID probe precedes mutation'
    Assert-True ($mutation[10] -eq 1 -and $fake.Writes.Count -eq 4) 'One mutation follows a validated matching probe'
    [int]$sum=0x5555;for($i=2;$i -lt 18;$i++){$sum+=$probe[$i]}
    Assert-True ([BitConverter]::ToUInt16($probe,18) -eq ($sum -band 65535)) 'Generated ModelID probe checksum valid'
}
$fake=Fake 20;$fake.StatusRoute=$true;$fake.Fragment=$true
$reply=Exchange $fake $request -ExpectedModelId 0x6211
Assert-True ($reply.Length -eq 20 -and $fake.OpenCount -eq 1 -and $fake.Writes.Count -eq 6 -and $fake.Disposed) 'Model preflight and mutation both support fragmented A3 route on same handle'
$fake=Fake 20;$fake.ProbeModelId=0x620E
Reject {Exchange $fake $request -ExpectedModelId 0x6211} 'ModelID mismatch' 'Hot-swapped VX600 cannot inherit cached VX400 authorization'
Assert-True ($fake.Writes.Count -eq 2 -and $fake.Writes[1][10] -eq 0 -and $fake.Disposed) 'Mismatch sends only read-only identity probe and closes handle'
$fake=Fake 20;$fake.ProbeModelId=0x6211
Reject {Exchange $fake $request -ExpectedModelId 0x620E} 'ModelID mismatch' 'Hot-swapped VX400 cannot inherit cached VX600 authorization'
Assert-True ($fake.Writes.Count -eq 2 -and $fake.Disposed) 'Reverse model mismatch prevents mutation'
# Build independently valid probe response, then corrupt every gate while preserving
# checksum when testing a different field so checksum validation cannot mask omissions.
$probe=Request;$probe[3]=0x80;$probe[4]=0xFE;$probe[12]=2
foreach($field in @(0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,20)){
    $fake=Fake 20;$fake.ProbeReply=[VxUsbFake]::ModelResponse($probe,0x6211)
    $fake.ProbeReply[$field]=$fake.ProbeReply[$field] -bxor 1
    if($field -ne 20){[VxUsbFake]::Rechecksum($fake.ProbeReply)}
    Reject {Exchange $fake $request -ExpectedModelId 0x6211} 'probe|signature|empty' "Malformed ModelID probe field$field blocks mutation"
    Assert-True ($fake.Writes.Count -eq 2 -and $fake.Disposed) "Malformed probe field$field never transmits mutation and closes handle"
}
$fake=Fake 20;$fake.ProbeReply=New-Object byte[] 23;$fake.ProbeReply[0]=0xAA;$fake.ProbeReply[1]=0x55
Reject {Exchange $fake $request -ExpectedModelId 0x6211} 'empty|status|trailing|signature' 'Oversized ModelID response cannot authorize mutation'
Assert-True ($fake.Writes.Count -eq 2 -and $fake.Disposed) 'Oversized identity response closes without mutation'
$fake=Fake 20;$fake.DelayMs=15
Reject {Exchange $fake $request 40 '' 0x6211} 'deadline' 'Identity preflight consumes shared transaction deadline'
Assert-True ($fake.Writes.Count -le 2 -and $fake.Disposed -and @( $fake.Writes | Where-Object {$_.Length -ge 20 -and $_[0] -eq 0x55 -and $_[1] -eq 0xAA -and $_[10] -eq 1} ).Count -eq 0) 'Deadline exhausted by probe blocks every mutation packet'

$fake=Fake;$reply=[VxUsb.Transport]::Exchange($fake,(Request),3000,'')
Assert-True ($reply.Length -eq 22) 'Optional expected model remains omitted for existing read callers'
Reject {Invoke-VxUsbExchange -Request $request} 'ExpectedModelId' 'Exported write API rejects missing model before native driver initialization'
[byte[]]$brightness=@(0x55,0xAA,0,0,0xFE,0xFF,1,0xFF,0xFF,0xFF,1,0,1,0,0,2,1,0,25,0x6E,0x5A)
$fake=Fake 20;$fake.ProbeModelId=0x620E
Reject {Exchange $fake $brightness -ExpectedModelId 0x6211} 'ModelID mismatch' 'Real broadcast brightness blocked after target model changes'
Assert-True (@($fake.Writes | Where-Object {$_.Length -ge 20 -and $_[0] -eq 0x55 -and $_[1] -eq 0xAA -and $_[10] -eq 1}).Count -eq 0 -and $fake.Disposed) 'No broadcast brightness bytes reach mismatched target'
$fake=Fake 20;$reply=Exchange $fake $brightness -ExpectedModelId 0x6211
Assert-True ($fake.Writes[3][5] -eq 0xFF -and $fake.Writes[3][18] -eq 25 -and $fake.OpenCount -eq 1) 'Validated same-handle probe permits unchanged broadcast brightness frame'

# Verify native ABI against the public C header independently of the Windows driver.
$busOffset=[Runtime.InteropServices.Marshal]::OffsetOf([type][VxUsb.UsbBus],'Devices').ToInt32()
Assert-True ($busOffset -eq $(if([IntPtr]::Size -eq 8){528}else{520})) 'usb_bus devices pointer follows 512-byte path at correct packed offset'
Assert-True ([Runtime.InteropServices.Marshal]::SizeOf([type][VxUsb.UsbDeviceDescriptor]) -eq 18) 'Device descriptor is exactly18bytes'
$descOffset=[Runtime.InteropServices.Marshal]::OffsetOf([type][VxUsb.UsbDevice],'Descriptor').ToInt32()
Assert-True ($descOffset -eq (512+3*[IntPtr]::Size)) 'usb_device descriptor follows next/prev/filename/bus packed fields'
$locationOffset=[Runtime.InteropServices.Marshal]::OffsetOf([type][VxUsb.UsbBus],'RootDevice').ToInt32()-[Runtime.InteropServices.Marshal]::OffsetOf([type][VxUsb.UsbBus],'Location').ToInt32()
Assert-True ($locationOffset -eq 4) 'Windows unsigned long remains32bits on x64'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){Reject {Get-VxUsbDevices} 'Windows' 'Native discovery reports unsupported OS without bundling driver'}
Write-Host ("PASS: $script:passed USB transport assertions; Windows driver/hardware acceptance remains unverified.")
