#requires -Version 5.1
Set-StrictMode -Version Latest

function Get-VxChecksum([byte[]]$Bytes, [int]$EndExclusive) {
    [int]$sum = 0x5555
    for ($index=2; $index -lt $EndExclusive; $index++) { $sum += $Bytes[$index] }
    return [uint16]($sum -band 0xFFFF)
}
function ConvertTo-VxHex([byte[]]$Bytes) { return [BitConverter]::ToString($Bytes).Replace('-',' ').ToLowerInvariant() }
function Throw-VxProtocol([string]$Message, [byte[]]$Raw) {
    $exception = New-Object System.IO.InvalidDataException($Message)
    $exception.Data['RawHex'] = ConvertTo-VxHex $Raw
    throw $exception
}
function New-VxFrame {
    param([uint32]$Address,[uint16]$Length,[byte]$Sequence,[byte]$Destination=0,
        [byte]$Device=0,[byte]$Port=0,[uint16]$Board=0,[byte]$Command=0,
        [byte[]]$Payload=@())
    [byte[]]$frame = New-Object byte[] (20 + $Payload.Length)
    $frame[0]=0x55; $frame[1]=0xAA; $frame[3]=$Sequence
    $frame[4]=0xFE; $frame[5]=$Destination; $frame[6]=$Device; $frame[7]=$Port
    [Array]::Copy([BitConverter]::GetBytes($Board),0,$frame,8,2)
    $frame[10]=$Command
    [Array]::Copy([BitConverter]::GetBytes($Address),0,$frame,12,4)
    [Array]::Copy([BitConverter]::GetBytes($Length),0,$frame,16,2)
    if ($Payload.Length) { [Array]::Copy($Payload,0,$frame,18,$Payload.Length) }
    $checksum = Get-VxChecksum $frame ($frame.Length-2)
    [Array]::Copy([BitConverter]::GetBytes($checksum),0,$frame,($frame.Length-2),2)
    return ,$frame
}
function New-VxReadRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Address,
        [Parameter(Mandatory)][ValidateRange(1,4096)][int]$Length,
        [byte]$Sequence=0,[byte]$Device=0,[byte]$Port=0,[uint16]$Board=0)
    New-VxFrame -Address $Address -Length $Length -Sequence $Sequence -Device $Device -Port $Port -Board $Board
}
function New-VxBrightnessRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte]$Value,[byte]$Sequence=0)
    # VX400 protocol 3.2.1: broadcast. No explicit flash-save command is issued.
    New-VxFrame -Address 0x02000001 -Length 1 -Sequence $Sequence -Destination 0xFF -Device 1 -Port 0xFF -Board 0xFFFF -Command 1 -Payload @($Value)
}
function New-VxDisplayRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Normal','Blackout','White')][string]$Mode,[byte]$Sequence=0)
    [byte[]]$data = switch ($Mode) { 'Normal' { 3,0 }; 'Blackout' { 5,0 }; 'White' { 6,4 } }
    New-VxFrame -Address 0x13000004 -Length 2 -Sequence $Sequence -Command 1 -Payload $data
}
function ConvertFrom-VxResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Raw,[Parameter(Mandatory)][byte[]]$Request)
    if ($Request.Length -lt 20) { Throw-VxProtocol 'Invalid request length.' $Raw }
    if ($Raw.Length -lt 20 -or $Raw.Length -gt 4116) { Throw-VxProtocol 'Invalid response length.' $Raw }
    if ($Raw[0] -ne 0xAA -or $Raw[1] -ne 0x55) { Throw-VxProtocol 'Unexpected response header.' $Raw }
    $dataLength = [BitConverter]::ToUInt16($Raw,16)
    if ($dataLength -gt 4096 -or $Raw.Length -ne (20+$dataLength)) { Throw-VxProtocol 'Response payload length mismatch.' $Raw }
    $actualChecksum = [BitConverter]::ToUInt16($Raw,($Raw.Length-2))
    if ($actualChecksum -ne (Get-VxChecksum $Raw ($Raw.Length-2))) { Throw-VxProtocol 'Invalid response checksum; preserve raw packet for review.' $Raw }
    # Response bytes 4/5 reverse the sender/destination, including FF broadcast.
    if ($Raw[2] -ne 0) { Throw-VxProtocol ('Response status/reserved byte is nonzero: '+$Raw[2]) $Raw }
    if ($Raw[3] -ne $Request[3]) { Throw-VxProtocol 'Response sequence mismatch.' $Raw }
    if ($Raw[4] -ne $Request[5] -or $Raw[5] -ne $Request[4]) { Throw-VxProtocol 'Response routing mismatch.' $Raw }
    for ($index=6; $index -le 15; $index++) {
        if ($Raw[$index] -ne $Request[$index]) { Throw-VxProtocol ('Response correlation mismatch at byte '+$index) $Raw }
    }
    $expectedLength = if ($Request[10] -eq 0) { [BitConverter]::ToUInt16($Request,16) } else { 0 }
    if ($dataLength -ne $expectedLength) { Throw-VxProtocol 'Response length differs from requested read or write ACK.' $Raw }
    [byte[]]$payload = New-Object byte[] $dataLength
    if ($dataLength) { [Array]::Copy($Raw,18,$payload,0,$dataLength) }
    return [pscustomobject]@{
        RawHex=(ConvertTo-VxHex $Raw); RequestHex=(ConvertTo-VxHex $Request)
        Payload=$payload; Sequence=$Raw[3]; Address=[BitConverter]::ToUInt32($Raw,12)
        ResponseStatus=$Raw[2]; ChecksumValid=$true; CorrelationValid=$true
    }
}
function Invoke-VxExchange {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DeviceAddress,[ValidateRange(1,65535)][int]$TcpPort=5200,
        [Parameter(Mandatory)][byte[]]$Request,[ValidateRange(250,15000)][int]$TimeoutMs=3000)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $client = New-Object System.Net.Sockets.TcpClient
    $raw = New-Object 'System.Collections.Generic.List[byte]'
    $connection = $null
    try {
        $connection = $client.BeginConnect($DeviceAddress,$TcpPort,$null,$null)
        if (-not $connection.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw 'TCP connection timeout.' }
        $client.EndConnect($connection)
        $stream = $client.GetStream()
        $remaining = $TimeoutMs - [int]$timer.ElapsedMilliseconds
        if ($remaining -le 0) { throw 'TCP deadline expired before write.' }
        $stream.WriteTimeout = $remaining
        $stream.Write($Request,0,$Request.Length)
        $wanted = 18
        while ($raw.Count -lt $wanted) {
            $remaining = $TimeoutMs - [int]$timer.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'TCP response timeout.' }
            $stream.ReadTimeout = $remaining
            [byte[]]$buffer = New-Object byte[] ($wanted-$raw.Count)
            $read = $stream.Read($buffer,0,$buffer.Length)
            if ($read -eq 0) { throw 'TCP peer closed before the complete response.' }
            for ($index=0; $index -lt $read; $index++) { $raw.Add($buffer[$index]) }
            if ($raw.Count -eq 18 -and $wanted -eq 18) {
                $declared = [BitConverter]::ToUInt16($raw.ToArray(),16)
                if ($declared -gt 4096) { throw 'Response declares an excessive payload.' }
                $wanted = 20 + $declared
            }
        }
        return ConvertFrom-VxResponse -Raw $raw.ToArray() -Request $Request
    } catch {
        $_.Exception.Data['RawHex'] = ConvertTo-VxHex $raw.ToArray()
        $_.Exception.Data['RequestHex'] = ConvertTo-VxHex $Request
        throw
    } finally {
        if ($null -ne $connection) { $connection.AsyncWaitHandle.Close() }
        $client.Close()
        $timer.Stop()
    }
}
function ConvertFrom-VxInputPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Payload)
    if ($Payload.Length -ne 256) { throw 'Input-source read must contain exactly 256 bytes.' }
    # Protocol 3.3.2: eight 32-byte source records. Byte 0 is reserved in each.
    for ($source=0; $source -lt 8; $source++) {
        $offset = 32*$source
        $period = [BitConverter]::ToUInt16($Payload,($offset+7))
        $rate = if ($period -gt 0) { [Math]::Round(1000000.0/$period,3) } else { $null }
        [pscustomobject]@{
            SourceIndex=($source+1); SignalStateRaw=$Payload[$offset+2]
            SignalPresent=($Payload[$offset+2] -eq 1); InterlacedRaw=$Payload[$offset+1]
            Width=[BitConverter]::ToUInt16($Payload,($offset+3))
            Height=[BitConverter]::ToUInt16($Payload,($offset+5))
            FramePeriodMicroseconds=$period; FrameRateHz=$rate
            ConnectorName='not_assigned_by_this_read'
        }
    }
}
Export-ModuleMember -Function New-VxFrame,New-VxReadRequest,New-VxBrightnessRequest,New-VxDisplayRequest,ConvertFrom-VxResponse,Invoke-VxExchange,ConvertFrom-VxInputPayload
