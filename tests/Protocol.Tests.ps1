#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Vx400.Protocol.psm1') -Force
$script:passed = 0
function Assert-True($Value,[string]$Label) {
    if (-not $Value) { throw ('FAIL: '+$Label) }
    $script:passed++
}
function Hex([byte[]]$Value) { [BitConverter]::ToString($Value).Replace('-',' ').ToLowerInvariant() }
function Response([byte[]]$Request,[byte[]]$Payload=@()) {
    [byte[]]$raw = New-Object byte[] (20+$Payload.Length)
    [Array]::Copy($Request,0,$raw,0,18)
    $raw[0]=0xAA; $raw[1]=0x55; $raw[4]=$Request[5]; $raw[5]=$Request[4]
    [Array]::Copy([BitConverter]::GetBytes([uint16]$Payload.Length),0,$raw,16,2)
    if ($Payload.Length) { [Array]::Copy($Payload,0,$raw,18,$Payload.Length) }
    [int]$sum=0x5555
    for ($index=2; $index -lt ($raw.Length-2); $index++) { $sum += $raw[$index] }
    [Array]::Copy([BitConverter]::GetBytes([uint16]($sum -band 0xFFFF)),0,$raw,($raw.Length-2),2)
    return ,$raw
}
function Assert-Rejected([byte[]]$Raw,[byte[]]$Request,[string]$Label) {
    $rejected=$false
    try { $null=ConvertFrom-VxResponse -Raw $Raw -Request $Request } catch { $rejected=$true }
    Assert-True $rejected $Label
}
$request=New-VxReadRequest -Address 2 -Length 2
Assert-True ((Hex $request) -eq '55 aa 00 00 fe 00 00 00 00 00 00 00 02 00 00 00 02 00 57 56') 'ModelID golden request'
$inputRequest=New-VxReadRequest -Address 0x13010001 -Length 256
Assert-True ((Hex $inputRequest) -eq '55 aa 00 00 fe 00 00 00 00 00 00 00 01 00 01 13 00 01 69 56') 'Inputs golden request'
Assert-True ((Hex (New-VxBrightnessRequest -Value 25)) -eq '55 aa 00 00 fe ff 01 ff ff ff 01 00 01 00 00 02 01 00 19 6e 5a') 'Brightness10 golden request'
Assert-True ((Hex (New-VxBrightnessRequest -Value 255)) -eq '55 aa 00 00 fe ff 01 ff ff ff 01 00 01 00 00 02 01 00 ff 54 5b') '100 percent checksum calculated; doc typo not copied'
Assert-True ((Hex (New-VxDisplayRequest -Mode Normal)) -eq '55 aa 00 00 fe 00 00 00 00 00 01 00 04 00 00 13 02 00 03 00 70 56') 'Normal golden request'
Assert-True ((Hex (New-VxDisplayRequest -Mode Blackout)) -eq '55 aa 00 00 fe 00 00 00 00 00 01 00 04 00 00 13 02 00 05 00 72 56') 'Blackout golden request'
Assert-True ((Hex (New-VxDisplayRequest -Mode White)) -eq '55 aa 00 00 fe 00 00 00 00 00 01 00 04 00 00 13 02 00 06 04 77 56') 'White pattern0x04'
$raw=Response $request @(0x11,0x62)
$parsed=ConvertFrom-VxResponse -Raw $raw -Request $request
Assert-True ([BitConverter]::ToUInt16($parsed.Payload,0) -eq 0x6211) 'ModelID payload parsed separately from firmware'
$bad=[byte[]]$raw.Clone(); $bad[-1]=$bad[-1] -bxor 1
Assert-Rejected $bad $request 'Bad checksum rejected'
$different=New-VxReadRequest -Address 2 -Length 2 -Sequence 4
Assert-Rejected $raw $different 'Sequence mismatch rejected'
Assert-Rejected $raw $inputRequest 'Wrong address rejected'
Assert-Rejected $raw[0..19] $request 'Truncated payload rejected'
$unknownStatus=[byte[]]$raw.Clone(); $unknownStatus[2]=3
Assert-Rejected $unknownStatus $request 'Unknown response rejected'
$brightness=New-VxBrightnessRequest -Value 25
$ack=Response $brightness
$parsedAck=ConvertFrom-VxResponse -Raw $ack -Request $brightness
Assert-True ($parsedAck.Payload.Length -eq 0 -and $parsedAck.CorrelationValid) 'Broadcast write response FF source accepted'
Assert-True ((Hex $ack) -eq 'aa 55 00 00 ff fe 01 ff ff ff 01 00 01 00 00 02 00 00 54 5a') 'Official brightness ACK matches frame checksum'
[byte[]]$inputs=New-Object byte[] 256
$inputs[2]=1
[Array]::Copy([BitConverter]::GetBytes([uint16]1920),0,$inputs,3,2)
[Array]::Copy([BitConverter]::GetBytes([uint16]1080),0,$inputs,5,2)
[Array]::Copy([BitConverter]::GetBytes([uint16]16667),0,$inputs,7,2)
$decoded=@(ConvertFrom-VxInputPayload $inputs)
Assert-True ($decoded.Count -eq 8 -and $decoded[0].Width -eq 1920 -and $decoded[0].Height -eq 1080) 'Eight records decoded'
Assert-True ($decoded[0].FrameRateHz -gt 59.9 -and $decoded[0].FrameRateHz -lt 60.1) 'Microsecond period converted to Hz'
Assert-True ($null -eq $decoded[1].FrameRateHz) 'No divide by zero for unavailable signal'
Write-Host ("PASS: $script:passed protocol assertions")
