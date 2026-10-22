#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='', [string]$DataDirectory='',
      [Parameter(Mandatory)][ValidateSet('Read','Apply')][string]$Action,
      [ValidateSet('Main','PIP1','PIP2')][string]$Layer,
      [string]$ChangesPath='',[switch]$EnableControl)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ConfigPath)){$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
if([string]::IsNullOrWhiteSpace($DataDirectory)){$DataDirectory=Join-Path $PSScriptRoot 'plan-data'}
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx.Connection.psm1')
Import-Module (Join-Path $PSScriptRoot 'Vx.Layers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1')
$mutex=$null;$owns=$false;$lock=$null;$code=0;$script:sequence=0;$uncertain=$false
$utf8=New-Object Text.UTF8Encoding($false)
$script:identity=$null;$script:identityStamp=0L;$script:identityUtc=[DateTimeOffset]::MinValue
function Next-LayerSequence {$script:sequence=($script:sequence+1)%256;return [byte]$script:sequence}
function Assert-LayerFreshness {
    Assert-VxDeviceIdentity -Config $config -Reply $script:identity
    $age=([Diagnostics.Stopwatch]::GetTimestamp()-$script:identityStamp)/[double][Diagnostics.Stopwatch]::Frequency
    if($age -gt $config.maximumObservationGapSeconds -or [Math]::Abs(([DateTimeOffset]::UtcNow-$script:identityUtc).TotalSeconds-$age) -gt $config.maximumObservationGapSeconds){throw 'Stale ModelID or observation gap; layer operation cancelled.'}
}
function Exchange-LayerPacket([byte[]]$Packet,[switch]$Identity){
    if(-not $Identity){Assert-LayerFreshness}
    $timer=[Diagnostics.Stopwatch]::StartNew();$utc=[DateTimeOffset]::UtcNow
    $reply=Invoke-VxConfiguredExchange -Config $config -Request $Packet
    if($timer.Elapsed.TotalSeconds -gt $config.maximumObservationGapSeconds -or [Math]::Abs(([DateTimeOffset]::UtcNow-$utc).TotalSeconds-$timer.Elapsed.TotalSeconds) -gt $config.maximumObservationGapSeconds){throw 'Observation gap during layer exchange; reply rejected.'}
    if(-not $Identity){Assert-LayerFreshness}
    return $reply
}
function Read-LayerSnapshot {
    $snapshot=@()
    foreach($name in @('Main','PIP1','PIP2')){
        $reply=Exchange-LayerPacket (New-VxLayerReadRequest -Layer $name -Sequence (Next-LayerSequence))
        $decoded=ConvertFrom-VxLayerBlock -Block $reply.Payload -Layer $name
        $snapshot+=[pscustomobject]@{layer=$name;block=$reply.Payload;view=$decoded}
    }
    return ,$snapshot
}
function Write-LayerEvent([string]$Event,$Detail){
    $entry=[ordered]@{utc=[DateTimeOffset]::UtcNow.ToString('o');event=$Event;detail=($Detail|ConvertTo-Json -Depth 8 -Compress);state='MANUAL'}
    [IO.File]::AppendAllText((Join-Path $DataDirectory 'eventos.jsonl'),(($entry|ConvertTo-Json -Compress)+[Environment]::NewLine),$utf8)
}
try{
    # Validate intent before endpoint access. Only Switch is user-writable.
    $changes=$null
    if($Action -eq 'Apply'){
        if(-not $EnableControl){throw 'Layer Apply requires explicit EnableControl.'}
        if([string]::IsNullOrWhiteSpace($Layer) -or [string]::IsNullOrWhiteSpace($ChangesPath)){throw 'Layer Apply requires Layer and ChangesPath.'}
        if((Get-Item -LiteralPath $ChangesPath).Length -gt 1024){throw 'Layer changes exceed 1 KiB.'}
        $changeJson=[IO.File]::ReadAllText($ChangesPath)
        if($changeJson -cnotmatch '\A\s*\{\s*"enabled"\s*:\s*(?:true|false)\s*\}\s*\z'){throw 'Layer changes require strict JSON containing only enabled boolean.'}
        $changes=$changeJson|ConvertFrom-Json
        Assert-VxLayerChanges $changes
    }
    $config=Read-VxPlanConfig -Path $ConfigPath
    if($config.deviceModel -cne 'VX600'){throw 'Layer controls require original VX600.'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes((Get-VxConnectionKey $config)))).Replace('-','')}finally{$sha.Dispose()}
    $prefix=if($env:OS -eq 'Windows_NT'){'Global\'}else{''}
    $mutex=New-Object Threading.Mutex($false,($prefix+'NovaStarVX400-'+$key))
    try{$owns=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
    if(-not $owns){throw 'Another controller owns this endpoint. Stop it before reading or applying layers.'}
    $null=[IO.Directory]::CreateDirectory($DataDirectory)
    $lock=[IO.File]::Open((Join-Path $DataDirectory 'watcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $reply=Exchange-LayerPacket (New-VxReadRequest -Address 2 -Length 2 -Sequence (Next-LayerSequence)) -Identity
    Assert-VxDeviceIdentity -Config $config -Reply $reply
    $script:identity=$reply;$script:identityStamp=[Diagnostics.Stopwatch]::GetTimestamp();$script:identityUtc=[DateTimeOffset]::UtcNow
    $snapshot=Read-LayerSnapshot
    if($Action -eq 'Apply'){
        $target=@($snapshot | Where-Object {$_.layer -ceq $Layer})[0]
        [byte[]]$patched=New-VxLayerPatch -Block $target.block -Layer $Layer -Changes $changes -Layers @($snapshot | ForEach-Object {$_.view})
        $expected=@{};foreach($item in $snapshot){$expected[$item.layer]=$item.block}
        $expected[$Layer]=$patched
        Assert-LayerFreshness
        # Any failure after this boundary leaves state uncertain; never write compensating global commands.
        $uncertain=$true
        $null=Exchange-LayerPacket (New-VxLayerWriteRequest -Layer $Layer -Block $patched -Sequence (Next-LayerSequence))
        $snapshot=Read-LayerSnapshot
        foreach($item in $snapshot){
            if([Convert]::ToBase64String($item.block) -cne [Convert]::ToBase64String($expected[$item.layer])){throw ('Layer readback mismatch after ACK for '+$item.layer+'; device state uncertain.')}
        }
        $uncertain=$false
    }
    $result=[ordered]@{success=$true;deviceModel='VX600';connectionType=$config.connectionType;layers=@($snapshot | ForEach-Object {$_.view});utc=[DateTimeOffset]::UtcNow.ToString('o')}
    Write-LayerEvent ('layers_'+$Action.ToLowerInvariant()) $result
    Write-Output ($result|ConvertTo-Json -Depth 8 -Compress)
}catch{
    $code=2
    $failure=[ordered]@{success=$false;error=$_.Exception.Message;uncertain=$uncertain;utc=[DateTimeOffset]::UtcNow.ToString('o')}
    # Failed contenders cannot modify another owner's persisted evidence.
    if($owns -and $null -ne $lock){try{Write-LayerEvent 'layers_failed' $failure}catch{}}
    Write-Output ($failure|ConvertTo-Json -Compress)
    Write-Error $failure.error -ErrorAction Continue
}finally{
    if($null -ne $lock){$lock.Dispose()}
    if($owns){$mutex.ReleaseMutex()};if($null -ne $mutex){$mutex.Dispose()}
}
exit $code
