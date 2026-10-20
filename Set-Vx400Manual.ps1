#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='', [string]$DataDirectory='',
      [Parameter(Mandatory)][ValidateRange(0,100)][double]$BrightnessPercent,
      [Parameter(Mandatory)][ValidateSet('Normal','Blackout','White')][string]$Display,
      [switch]$EnableControl)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $EnableControl){Write-Error 'Manual commands require explicit EnableControl.' -ErrorAction Continue;exit 2}
if([string]::IsNullOrWhiteSpace($ConfigPath)){$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
if([string]::IsNullOrWhiteSpace($DataDirectory)){$DataDirectory=Join-Path $PSScriptRoot 'plan-data'}
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1') -Force
$mutex=$null;$owns=$false;$lock=$null;$trusted=$false;$code=0;$script:sequence=0
$utf8=New-Object Text.UTF8Encoding($false)
$script:readStamp=0L;$script:readUtc=[DateTimeOffset]::MinValue
function Exchange-ManualPacket([byte[]]$Packet){
    $timer=[Diagnostics.Stopwatch]::StartNew();$utc=[DateTimeOffset]::UtcNow
    $reply=Invoke-VxExchange -DeviceAddress $config.deviceAddress -TcpPort $config.tcpPort -Request $Packet -TimeoutMs $config.timeoutMs
    if($timer.Elapsed.TotalSeconds -gt $config.maximumObservationGapSeconds -or [Math]::Abs(([DateTimeOffset]::UtcNow-$utc).TotalSeconds-$timer.Elapsed.TotalSeconds) -gt $config.maximumObservationGapSeconds){throw 'Observation gap during manual exchange; refusing stale reply.'}
    return $reply
}
function Send-ManualPacket([byte[]]$Packet,[switch]$Recovery){
    if(-not $Recovery){
        $age=([Diagnostics.Stopwatch]::GetTimestamp()-$script:readStamp)/[double][Diagnostics.Stopwatch]::Frequency
        if($age -gt $config.maximumObservationGapSeconds -or [Math]::Abs(([DateTimeOffset]::UtcNow-$script:readUtc).TotalSeconds-$age) -gt $config.maximumObservationGapSeconds){throw 'Stale ModelID; manual command cancelled.'}
    }
    $null=Exchange-ManualPacket $Packet
}
function Next-ManualSequence {$script:sequence=($script:sequence+1)%256;return [byte]$script:sequence}
try{
    $config=Read-VxPlanConfig -Path $ConfigPath
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes("$($config.deviceAddress):$($config.tcpPort)"))).Replace('-','')}finally{$sha.Dispose()}
    $prefix=if($env:OS -eq 'Windows_NT'){'Global\'}else{''}
    $mutex=New-Object Threading.Mutex($false,($prefix+'NovaStarVX400-'+$key))
    try{$owns=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
    if(-not $owns){throw 'Another controller owns this endpoint. Stop it before manual commands.'}
    $null=[IO.Directory]::CreateDirectory($DataDirectory)
    $lock=[IO.File]::Open((Join-Path $DataDirectory 'watcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $reply=Exchange-ManualPacket (New-VxReadRequest -Address 2 -Length 2 -Sequence (Next-ManualSequence))
    if($reply.Payload.Length -ne 2 -or [BitConverter]::ToUInt16($reply.Payload,0) -ne 0x6211){throw 'Wrong ModelID: expected original VX400 0x6211.'}
    $trusted=$true;$script:readStamp=[Diagnostics.Stopwatch]::GetTimestamp();$script:readUtc=[DateTimeOffset]::UtcNow
    # No unknown brightness is exposed: acknowledged Blackout, then brightness, then chosen content.
    Send-ManualPacket (New-VxDisplayRequest -Mode Blackout -Sequence (Next-ManualSequence))
    $value=[byte][Math]::Floor($BrightnessPercent*255.0/100)
    Send-ManualPacket (New-VxBrightnessRequest -Value $value -Sequence (Next-ManualSequence))
    if($Display -ne 'Blackout'){Send-ManualPacket (New-VxDisplayRequest -Mode $Display -Sequence (Next-ManualSequence))}
    $result=[ordered]@{success=$true;utc=[DateTimeOffset]::UtcNow.ToString('o');display=$Display;brightnessRequestedPercent=$value*100.0/255;measured=$false}
    $entry=[ordered]@{utc=$result.utc;event='manual_applied';detail=($result|ConvertTo-Json -Compress);state='MANUAL'}
    [IO.File]::AppendAllText((Join-Path $DataDirectory 'eventos.jsonl'),(($entry|ConvertTo-Json -Compress)+[Environment]::NewLine),$utf8)
    # Successful output stays as explicitly chosen; this one-shot process never auto-restarts.
    Write-Output ($result|ConvertTo-Json -Compress)
}catch{
    $code=2
    if($owns -and $null -ne $lock -and $trusted){
        try{Send-ManualPacket (New-VxDisplayRequest -Mode Blackout -Sequence (Next-ManualSequence)) -Recovery}catch{}
        try{Send-ManualPacket (New-VxBrightnessRequest -Value 0 -Sequence (Next-ManualSequence)) -Recovery}catch{}
    }
    Write-Error $_ -ErrorAction Continue
}finally{
    if($null -ne $lock){$lock.Dispose()}
    if($owns){$mutex.ReleaseMutex()};if($null -ne $mutex){$mutex.Dispose()}
}
exit $code
