#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='', [string]$DataDirectory='', [switch]$EnableControl,
      [switch]$ValidateOnly, [ValidateRange(0,1000000)][int]$MaxPolls=0)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
if ([string]::IsNullOrWhiteSpace($DataDirectory)) {$DataDirectory=Join-Path $PSScriptRoot 'plan-data'}
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force
try {$config=Read-VxPlanConfig -Path $ConfigPath -EnableControl:$EnableControl}
catch {Write-Error $_ -ErrorAction Continue; exit 2}
if ($ValidateOnly) {Write-Output ('Plan valid. '+$(if($EnableControl){'CONTROL'}else{'MONITOR (read only)'}));exit 0}
Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1') -Force
$utf8=New-Object Text.UTF8Encoding($false)
$script:status=[ordered]@{
    schemaVersion=1;mode=$(if($EnableControl){'control'}else{'monitor'});state='BOOT';communication='unknown'
    brightnessRequested=$null;phase=$null;progressPercent=0;remainingSeconds=0;profileKey='';updatedUtc=$null
    lastSuccessfulReadUtc=$null;lastEvent=$null;operatorPending=$false;operatorGateId=$null;operatorMessage='';operatorLastCommandId=$null;operatorConsumedCommandIds=@()
    deviceAddress=$config.deviceAddress;tcpPort=$config.tcpPort
}
$mutex=$null;$ownsMutex=$false;$fileLock=$null;$exitCode=0
$clock=[Diagnostics.Stopwatch]::StartNew()
$script:seq=0;$script:trusted=$false;$script:wrote=$false;$script:fault=$false
$script:lastReadStamp=0L;$script:lastReadUtc=[DateTimeOffset]::MinValue
$script:brightnessByte=-1;$script:pattern='unknown'
$script:activeMode='';$script:activeKey='';$script:profile=@();$script:profileStart=0.0
$script:activeRequest=$null;$script:operatorForced=$false;$script:ready=$false
$script:completed=@();$script:needInitialDry=$false

function Save-PlanState {
    $script:status.updatedUtc=[DateTimeOffset]::UtcNow.ToString('o')
    $tmp=Join-Path $DataDirectory 'estado.json.tmp';$path=Join-Path $DataDirectory 'estado.json'
    [IO.File]::WriteAllText($tmp,($script:status|ConvertTo-Json -Depth 8),$utf8)
    if([IO.File]::Exists($path)){[IO.File]::Replace($tmp,$path,[NullString]::Value)}else{[IO.File]::Move($tmp,$path)}
}
function Write-PlanEvent([string]$Name,[string]$Detail) {
    $path=Join-Path $DataDirectory 'eventos.jsonl'
    if([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -ge 1048576){
        for($i=4;$i -ge 1;$i--){if([IO.File]::Exists("$path.$i")){Move-Item -LiteralPath "$path.$i" -Destination "$path.$($i+1)" -Force}}
        Move-Item -LiteralPath $path -Destination "$path.1" -Force
    }
    $entry=[ordered]@{utc=[DateTimeOffset]::UtcNow.ToString('o');event=$Name;detail=$Detail;state=$script:status.state}
    [IO.File]::AppendAllText($path,(($entry|ConvertTo-Json -Compress)+[Environment]::NewLine),$utf8)
    $script:status.lastEvent=$entry;Save-PlanState
    Write-Host ($entry.utc+' '+$Name+' '+$Detail)
}
function Next-Sequence {$script:seq=($script:seq+1)%256;return [byte]$script:seq}
function Exchange-Plan([byte[]]$Packet) {
    $watch=[Diagnostics.Stopwatch]::StartNew();$utc=[DateTimeOffset]::UtcNow
    $reply=Invoke-VxExchange -DeviceAddress $config.deviceAddress -TcpPort $config.tcpPort -Request $Packet -TimeoutMs $config.timeoutMs
    if($watch.Elapsed.TotalSeconds -gt $config.maximumObservationGapSeconds -or [Math]::Abs(([DateTimeOffset]::UtcNow-$utc).TotalSeconds-$watch.Elapsed.TotalSeconds) -gt $config.maximumObservationGapSeconds){throw 'Observation gap during exchange; response no longer fresh.'}
    return $reply
}
function Assert-PlanFresh {
    $age=([Diagnostics.Stopwatch]::GetTimestamp()-$script:lastReadStamp)/[double][Diagnostics.Stopwatch]::Frequency
    if($age -gt $config.maximumObservationGapSeconds -or [Math]::Abs(([DateTimeOffset]::UtcNow-$script:lastReadUtc).TotalSeconds-$age) -gt $config.maximumObservationGapSeconds){throw 'Stale successful ModelID read; refusing display advancement.'}
}
function Send-PlanDisplay([string]$Mode,[switch]$Recovery) {
    if(-not $Recovery){Assert-PlanFresh}
    $script:wrote=$true
    try{$null=Exchange-Plan (New-VxDisplayRequest -Mode $Mode -Sequence (Next-Sequence));$script:pattern=$Mode}
    catch{if(-not $Recovery){$script:fault=$true};$script:pattern='unknown';throw}
}
function Send-PlanBrightness([double]$Percent,[switch]$Force,[switch]$Recovery) {
    $value=[int][Math]::Floor([Math]::Max([double]0,[Math]::Min([double]100,$Percent))*255/100)
    if(-not $Recovery){Assert-PlanFresh}
    if(-not $Force -and $value -eq $script:brightnessByte){return}
    $script:wrote=$true
    try{
        $null=Exchange-Plan (New-VxBrightnessRequest -Value ([byte]$value) -Sequence (Next-Sequence))
        $script:brightnessByte=$value;$script:status.brightnessRequested=$value*100.0/255
    }catch{if(-not $Recovery){$script:fault=$true};$script:brightnessByte=-1;throw}
}
function Try-PlanDark {
    if($EnableControl -and $script:trusted){
        try{Send-PlanDisplay 'Blackout' -Recovery}catch{Write-Warning ('Blackout unconfirmed: '+$_.Exception.Message)}
        try{Send-PlanBrightness 0 -Force -Recovery}catch{Write-Warning ('Zero unconfirmed: '+$_.Exception.Message)}
    }
}
function Set-PlanContent([string]$Content,[double]$Brightness) {
    $mode=if($Content -eq 'White'){'White'}else{'Normal'}
    if($script:pattern -ne $mode){
        Send-PlanDisplay 'Blackout'
        # Acknowledged low/current level always precedes enabling any pattern/input.
        Send-PlanBrightness $Brightness -Force
        Send-PlanDisplay $mode
    }else{Send-PlanBrightness $Brightness}
}
function Set-PlanBlack {
    if($script:pattern -ne 'Blackout'){Send-PlanDisplay 'Blackout'}
    Send-PlanBrightness $config.idleBrightnessPercent
    if($script:status.state -ne 'BLACK'){ $script:status.state='BLACK';Write-PlanEvent 'black' 'Blackout and idle brightness requested.' }
    $script:activeMode='';$script:activeKey='';$script:status.phase=$null;$script:status.profileKey='';$script:status.progressPercent=0;$script:status.remainingSeconds=0
}
function Start-PlanProfile([string]$Mode,[string]$Key,[object[]]$Profile,$Request,[switch]$OperatorRestart) {
    # Persist planned transition before the first live command.
    $script:status.state=$Mode;$script:status.profileKey=$Key;$script:status.phase=$Profile[0].name
    $script:status.progressPercent=0;$script:status.remainingSeconds=Get-VxProfileSeconds $Profile
    Write-PlanEvent 'profile_started' ($Mode+' '+$Key)
    Send-PlanDisplay 'Blackout';Send-PlanBrightness $Profile[0].from -Force
    $first=Get-VxPlanLevel -Profile $Profile -ElapsedSeconds 0 -DefaultContent $config.conditioningPattern
    $firstMode=if($first.content -eq 'White'){'White'}else{'Normal'}
    Send-PlanDisplay $firstMode
    $script:activeMode=$Mode;$script:activeKey=$Key;$script:profile=$Profile;$script:activeRequest=$Request
    $script:operatorForced=[bool]$OperatorRestart;$script:ready=$false;$script:profileStart=$clock.Elapsed.TotalSeconds
}
function Reset-PlanProgress {
    $script:activeMode='';$script:activeKey='';$script:activeRequest=$null;$script:operatorForced=$false;$script:ready=$false
    $script:status.phase=$null;$script:status.profileKey='';$script:status.progressPercent=0;$script:status.remainingSeconds=0
}
function Open-OperatorGate([string]$Reason) {
    Reset-PlanProgress
    if($EnableControl){
        $script:status.operatorPending=$true;$script:status.operatorGateId=[Guid]::NewGuid().ToString()
        $script:status.operatorMessage='Comunicacion interrumpida. Elija reiniciar precalentamiento completo o mantener negro.'
        $script:status.operatorLastCommandId=$null;$script:status.operatorConsumedCommandIds=@();$script:status.state='WAIT_OPERATOR'
    }else{$script:status.state='WAITING'}
    # The gate must survive even if the process dies during subsequent blackout attempts.
    Write-PlanEvent 'observation_lost' $Reason
    Try-PlanDark
}
function Read-OperatorChoice {
    $path=Join-Path $DataDirectory 'operador.json'
    if(-not [IO.File]::Exists($path)){return ''}
    if((Get-Item -LiteralPath $path).Length -gt 8192){throw 'Operator command too large.'}
    $json=Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {$command=ConvertFrom-Json -InputObject $json -DateKind String}else{$command=ConvertFrom-Json -InputObject $json}
    $fields=@($command.PSObject.Properties.Name)
    if($command -isnot [pscustomobject] -or $fields.Count -ne 4 -or @('id','gateId','action','utc'|Where-Object{$fields -notcontains $_}).Count -gt 0){throw 'Invalid operator command shape.'}
    $id=[Guid]::Empty;$gate=[Guid]::Empty;$utc=[DateTimeOffset]::MinValue
    if($command.id -isnot [string] -or -not [Guid]::TryParseExact($command.id,'D',[ref]$id) -or $id -eq [Guid]::Empty -or
       $command.gateId -isnot [string] -or -not [Guid]::TryParseExact($command.gateId,'D',[ref]$gate) -or
       $command.action -cnotin @('restart','hold') -or $command.utc -isnot [string] -or
       $command.utc -notmatch '(Z|[+-]\d{2}:\d{2})$' -or -not [DateTimeOffset]::TryParse($command.utc,[ref]$utc)){throw 'Invalid operator command values.'}
    if($command.gateId -ne $script:status.operatorGateId -or $script:status.operatorConsumedCommandIds -contains $command.id){return ''}
    if($script:status.operatorConsumedCommandIds.Count -ge 1024){throw 'Too many operator commands for one gate; explicit process inspection required.'}
    $script:status.operatorConsumedCommandIds+= $command.id
    $script:status.operatorLastCommandId=$command.id
    if($command.action -eq 'hold'){
        $script:status.operatorMessage='Operador eligio mantener negro. Reiniciar sigue disponible.'
        Write-PlanEvent 'operator_hold' $command.id;return 'hold'
    }
    $script:status.operatorPending=$false;$script:status.operatorMessage='Reinicio completo autorizado por operador.'
    Write-PlanEvent 'operator_restart' $command.id
    return 'restart'
}

try {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$endpoint=[BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes("$($config.deviceAddress):$($config.tcpPort)"))).Replace('-','')}finally{$sha.Dispose()}
    $prefix=if($env:OS -eq 'Windows_NT'){'Global\'}else{''}
    $mutex=New-Object Threading.Mutex($false,($prefix+'NovaStarVX400-'+$endpoint))
    try{$ownsMutex=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$ownsMutex=$true}
    if(-not $ownsMutex){throw 'Another watcher owns this endpoint.'}
    $null=New-Item -ItemType Directory -Path $DataDirectory -Force
    $fileLock=[IO.File]::Open((Join-Path $DataDirectory 'watcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $previousPath=Join-Path $DataDirectory 'estado.json'
    if([IO.File]::Exists($previousPath)){
        if((Get-Item -LiteralPath $previousPath).Length -gt 1048576){throw 'Previous state too large.'}
        $previous=Get-Content -LiteralPath $previousPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($null -ne $previous.PSObject.Properties['operatorPending'] -and $previous.operatorPending){
            $gate=[Guid]::Empty
            if($previous.operatorPending -isnot [bool] -or $previous.operatorGateId -isnot [string] -or -not [Guid]::TryParseExact($previous.operatorGateId,'D',[ref]$gate)){throw 'Invalid persisted operator gate.'}
            $script:status.operatorPending=$true;$script:status.operatorGateId=$gate.ToString();$script:status.operatorMessage='Decision del operador pendiente tras interrupcion previa.'
            if($null -ne $previous.PSObject.Properties['operatorLastCommandId']){$script:status.operatorLastCommandId=$previous.operatorLastCommandId}
            if($null -ne $previous.PSObject.Properties['operatorConsumedCommandIds']){
                $ids=$previous.operatorConsumedCommandIds
                if($ids -isnot [array] -or $ids.Count -gt 1024){throw 'Invalid persisted consumed operator commands.'}
                foreach($commandId in $ids){$parsedId=[Guid]::Empty;if($commandId -isnot [string] -or -not [Guid]::TryParseExact($commandId,'D',[ref]$parsedId)){throw 'Invalid persisted command id.'}}
                $script:status.operatorConsumedCommandIds=@($ids)
            }elseif($null -ne $script:status.operatorLastCommandId){$script:status.operatorConsumedCommandIds=@($script:status.operatorLastCommandId)}
        }
    }
    Write-PlanEvent 'started' 'Read-only unless -EnableControl; protocol reachability does not establish panel power.'
    $connected=$false;$everConnected=$false;$lossEpisode=$false;$offlineMarked=$false
    $failures=0;$successes=0;$polls=0;$lastLoop=0.0;$lastUtc=[DateTimeOffset]::UtcNow
    while($MaxPolls -eq 0 -or $polls -lt $MaxPolls){
        if([IO.File]::Exists((Join-Path $DataDirectory 'stop.request'))){Write-PlanEvent 'stop_requested' 'Operator requested graceful stop.';Remove-Item -LiteralPath (Join-Path $DataDirectory 'stop.request') -ErrorAction Stop;break}
        $polls++
        $delta=$clock.Elapsed.TotalSeconds-$lastLoop;$wall=([DateTimeOffset]::UtcNow-$lastUtc).TotalSeconds
        if($delta -gt $config.maximumObservationGapSeconds -or [Math]::Abs($wall-$delta) -gt $config.maximumObservationGapSeconds){
            $connected=$false;$successes=0;$failures=0;$offlineMarked=$false
            $script:status.communication='unknown'
            Open-OperatorGate 'Process suspension/clock gap: elapsed progress discarded.';$lossEpisode=$true
        }
        # Invalid/missing-after-creation files fail closed; only absence of requests is empty.
        $requests=Read-VxRequests -Path (Join-Path $DataDirectory 'solicitudes.json')
        $decision=Get-VxPlanDecision -Config $config -Requests $requests -NowUtc ([DateTimeOffset]::UtcNow) -CompletedDryKeys $script:completed
        $readError=$null
        try{
            $reply=Exchange-Plan (New-VxReadRequest -Address 2 -Length 2 -Sequence (Next-Sequence))
            if($reply.Payload.Length -ne 2 -or [BitConverter]::ToUInt16($reply.Payload,0) -ne 0x6211){$script:trusted=$false;throw 'Wrong ModelID: expected original VX400 0x6211.'}
            $script:trusted=$true;$script:lastReadStamp=[Diagnostics.Stopwatch]::GetTimestamp();$script:lastReadUtc=[DateTimeOffset]::UtcNow
            $script:status.lastSuccessfulReadUtc=$script:lastReadUtc.ToString('o')
        }catch{$readError=$_.Exception.Message}
        if($null -ne $readError){
            $successes=0;$failures++;$connected=$false
            if(-not $lossEpisode){
                $lossEpisode=$true;$script:status.communication='uncertain'
                if($everConnected){Open-OperatorGate $readError}else{Reset-PlanProgress;$script:status.state='WAITING';Write-PlanEvent 'read_failed' $readError}
            }
            if($failures -ge $config.offlineFailures -and -not $offlineMarked){$offlineMarked=$true;$script:status.communication='unreachable';Write-PlanEvent 'unreachable' 'Consecutive protocol failures; electrical state unknown.'}
        }else{
            $failures=0;$successes++
            if(-not $connected -and $successes -ge $config.onlineSuccesses){
                $connected=$true;$lossEpisode=$false;$offlineMarked=$false;$script:status.communication='reachable'
                $event=if($everConnected){'reconnected'}else{'connected'};$everConnected=$true
                $script:needInitialDry=$false
                Write-PlanEvent $event 'Stable valid ModelID reads.'
                if($EnableControl -and $script:status.operatorPending){Try-PlanDark}
            }
            if($connected){
                if(-not $EnableControl){
                    if($script:status.state -ne $decision.mode -or $script:status.profileKey -ne $decision.key){$script:status.state=$decision.mode;$script:status.profileKey=$decision.key;Write-PlanEvent 'desired_plan' ('Monitor only: '+$decision.mode+' '+$decision.key)}
                }elseif($script:fault){
                    if($script:status.state -ne 'FAULT'){$script:status.state='FAULT';Write-PlanEvent 'write_fault' 'Uncertain write. Process restart and operator inspection required.'}
                }else{
                    try{
                        if($script:status.operatorPending){
                            $script:status.state='WAIT_OPERATOR';$script:status.phase='Esperando operador';$script:status.remainingSeconds=0
                            $choice=Read-OperatorChoice
                            if($choice -eq 'restart'){
                                $request=if($decision.mode -in @('PREHEAT','OPERATING')){$decision.request}else{$null}
                                $key=if($null -ne $request){$decision.key}else{'operator:'+$script:status.operatorGateId}
                                $script:needInitialDry=$false
                                Start-PlanProfile 'PREHEAT' $key $config.profiles.preheat $request -OperatorRestart
                            }
                        }else{
                            $booking=($decision.mode -in @('PREHEAT','OPERATING'))
                            $sameBooking=$booking -and $decision.key -eq $script:activeKey
                            if($script:activeMode -in @('PREHEAT','OPERATING') -and $null -ne $script:activeRequest -and -not $sameBooking -and -not $booking){
                                $current=if($script:brightnessByte -ge 0){$script:brightnessByte*100.0/255}else{0}
                                $cool=Get-VxCooldownProfile -Profile $config.profiles.cooldown -CurrentBrightness $current
                                Start-PlanProfile 'COOLDOWN' ('cooldown:'+$script:activeKey) $cool $null
                            }
                            if($booking -and -not $sameBooking){
                                $script:needInitialDry=$false
                                Start-PlanProfile 'PREHEAT' $decision.key $config.profiles.preheat $decision.request
                            }elseif(-not $script:activeMode){
                                if($decision.mode -eq 'DRY'){$script:needInitialDry=$false;Start-PlanProfile 'DRY' $decision.key $config.profiles.dry $null}
                                else{Set-PlanBlack}
                            }
                            if($script:activeMode -in @('PREHEAT','DRY','COOLDOWN')){
                                $elapsed=$clock.Elapsed.TotalSeconds-$script:profileStart
                                $level=Get-VxPlanLevel -Profile $script:profile -ElapsedSeconds $elapsed -DefaultContent $config.conditioningPattern
                                Set-PlanContent $level.content $level.brightnessPercent
                                if($script:status.phase -ne $level.phase){$script:status.phase=$level.phase;Write-PlanEvent 'phase' $level.phase}
                                $total=Get-VxProfileSeconds $script:profile
                                $script:status.progressPercent=[Math]::Min([double]100,100*$elapsed/$total);$script:status.remainingSeconds=[Math]::Max([double]0,$total-$elapsed)
                                if($level.done){
                                    if($script:activeMode -eq 'PREHEAT'){
                                        $script:ready=$true
                                        if($booking -and $decision.key -eq $script:activeKey -and [DateTimeOffset]::UtcNow -ge [DateTimeOffset]$decision.request.startUtc){
                                            $script:activeMode='OPERATING';$script:status.state='OPERATING';$script:status.phase='Operacion';Set-PlanContent 'FromInput' $config.operatingBrightnessPercent
                                            Write-PlanEvent 'operating' $script:activeKey
                                        }elseif($null -eq $script:activeRequest){Set-PlanBlack}
                                    }elseif($script:activeMode -eq 'DRY'){
                                        $script:completed+= $script:activeKey
                                        # Bounded keys; old dates need not remain in memory indefinitely.
                                        if($script:completed.Count -gt 256){$script:completed=@($script:completed|Select-Object -Last 256)}
                                        Write-PlanEvent 'dry_completed' $script:activeKey;Set-PlanBlack
                                    }else{Write-PlanEvent 'cooldown_completed' $script:activeKey;Set-PlanBlack}
                                }
                            }elseif($script:activeMode -eq 'OPERATING'){Set-PlanContent 'FromInput' $config.operatingBrightnessPercent}
                        }
                    }catch{
                        $faultMessage=$_.Exception.Message
                        $script:fault=$true;Open-OperatorGate ('Uncertain control write: '+$faultMessage);$script:status.state='FAULT'
                        Write-PlanEvent 'control_fault' ($faultMessage+'; no automatic Normal or high brightness retry.')
                    }
                }
            }
        }
        Save-PlanState
        $lastLoop=$clock.Elapsed.TotalSeconds;$lastUtc=[DateTimeOffset]::UtcNow
        if($MaxPolls -eq 0 -or $polls -lt $MaxPolls){
            $sleep=[Diagnostics.Stopwatch]::StartNew()
            while($sleep.Elapsed.TotalSeconds -lt $config.pollIntervalSeconds){
                if([IO.File]::Exists((Join-Path $DataDirectory 'stop.request'))){break}
                $remaining=$config.pollIntervalSeconds-$sleep.Elapsed.TotalSeconds
                Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(1000,$remaining*1000)))
                Save-PlanState
            }
        }
    }
    if($script:fault){$exitCode=2}
}catch{
    $exitCode=2;Try-PlanDark;$script:status.state='FAULT'
    if($null -ne $fileLock){try{Write-PlanEvent 'process_fault' $_.Exception.Message}catch{Write-Warning ('Cannot persist fault: '+$_.Exception.Message)}}
    Write-Error $_ -ErrorAction Continue
}finally{
    # Forced process/PC termination can bypass finally. Physical startup blackout is essential.
    if($ownsMutex -and $null -ne $fileLock){
        if($script:wrote){Try-PlanDark}
        if($script:fault){$exitCode=2}
        if($exitCode -eq 0){$script:status.state='STOPPED'}
        try{Write-PlanEvent 'stopped' 'Best-effort Blackout/zero on normal exit; progress is never resumed.'}catch{$exitCode=2}
        $fileLock.Dispose()
    }
    if($ownsMutex){$mutex.ReleaseMutex()};if($null -ne $mutex){$mutex.Dispose()}
}
exit $exitCode
