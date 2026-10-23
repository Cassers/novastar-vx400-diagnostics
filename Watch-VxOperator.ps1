#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigPath='',[string]$OperatorConfigPath='',[string]$DataDirectory='',[switch]$EnableControl,[switch]$ValidateOnly,[ValidateRange(0,1000000)][int]$MaxPolls=0)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $ConfigPath){$ConfigPath=Join-Path $PSScriptRoot 'plan.config.json'}
if(-not $OperatorConfigPath){$OperatorConfigPath=Join-Path $PSScriptRoot 'operator.config.json'}
if(-not $DataDirectory){$DataDirectory=Join-Path $PSScriptRoot 'plan-data'}
Import-Module (Join-Path $PSScriptRoot 'Vx.Operator.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1')
Import-Module (Join-Path $PSScriptRoot 'Vx.Connection.psm1')
Import-Module (Join-Path $PSScriptRoot 'Vx.Layers.psm1')
Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1')
try{
    $config=Read-VxPlanConfig -Path $ConfigPath -EnableControl:$EnableControl
    $operator=Read-VxOperatorConfig -Path $OperatorConfigPath -ForControl:$EnableControl
}catch{Write-Error $_ -ErrorAction Continue;exit 2}
# Validation reads configuration/assets only; no directory creation, locks, transport or UI.
if($ValidateOnly){Write-Output 'Operator configuration valid.';exit 0}
$utf8=New-Object Text.UTF8Encoding($false)
$script:state=[ordered]@{schemaVersion=1;ownerProcessId=$PID;sessionId=[Guid]::NewGuid().ToString();updatedUtc='';communication='unknown';outputBlackoutConfirmed=$false;state='BLACK';phase='';brightnessRequestedPercent=$null;remainingSeconds=0;preheatReady=$false;layers=@();lastCommandId=$null;lastCommandResult='';operatorPending=$false;message='Starting'}
$script:persist=[ordered]@{schemaVersion=1;sessionId=$script:state.sessionId;lastConsumedDay='';consumedCommandIds=@();operatorPending=$false;active=$false;legacyStateHash=''}
$script:sequence=0;$script:identity=$null;$script:identityStamp=0L;$script:identityUtc=[DateTimeOffset]::MinValue
$script:brightness=-1;$script:pattern='unknown';$script:mode='';$script:contentReady=$false;$script:mediaRequest=$null;$script:mediaStart=0.0
$script:modeStart=0.0;$script:coolFrom=0.0;$script:drySeconds=0.0;$script:lastRejected=''
$operatorPollSeconds=[Math]::Min([double]1,[double]$config.pollIntervalSeconds)
$clock=[Diagnostics.Stopwatch]::StartNew();$mutex=$null;$owns=$false;$lock=$null;$exitCode=0;$helper=$null
function Save-OperatorJson([string]$Name,$Value){
    $path=Join-Path $DataDirectory $Name;$tmp=$path+'.tmp'
    [IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth 10),$utf8)
    Move-VxAtomicFile -Source $tmp -Destination $path
}
function Save-OperatorPersistent {Save-OperatorJson 'operator-session.json' $script:persist}
function Save-OperatorState {$script:state.updatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Save-OperatorJson 'operator-state.json' $script:state}
function Read-OperatorJson([string]$Name,[int]$Limit=32768){
    $path=Join-Path $DataDirectory $Name
    if(-not [IO.File]::Exists($path)){return $null}
    if((Get-Item -LiteralPath $path).Length -gt $Limit){throw "$Name too large."}
    $json=Read-VxSharedText $path
    if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){return ConvertFrom-Json -InputObject $json -DateKind String}
    return $json|ConvertFrom-Json
}
function Next-OperatorSequence {$script:sequence=($script:sequence+1)%256;return [byte]$script:sequence}
function Assert-OperatorFresh {
    if($null -eq $script:identity){throw 'Unverified identity.'}
    Assert-VxDeviceIdentity -Config $config -Reply $script:identity
    $age=([Diagnostics.Stopwatch]::GetTimestamp()-$script:identityStamp)/[double][Diagnostics.Stopwatch]::Frequency
    if($age -gt $config.maximumObservationGapSeconds -or [Math]::Abs(([DateTimeOffset]::UtcNow-$script:identityUtc).TotalSeconds-$age) -gt $config.maximumObservationGapSeconds){throw 'Stale ModelID/observation gap.'}
}
function Exchange-Operator([byte[]]$Packet,[switch]$Identity,[switch]$Recovery){
    if(-not $Identity){if($Recovery){if($null -eq $script:identity){throw 'No trusted identity for dark recovery.'};Assert-VxDeviceIdentity -Config $config -Reply $script:identity}else{Assert-OperatorFresh}}
    $timer=[Diagnostics.Stopwatch]::StartNew();$utc=[DateTimeOffset]::UtcNow
    $reply=Invoke-VxConfiguredExchange -Config $config -Request $Packet
    if($timer.Elapsed.TotalSeconds -gt $config.maximumObservationGapSeconds -or [Math]::Abs(([DateTimeOffset]::UtcNow-$utc).TotalSeconds-$timer.Elapsed.TotalSeconds) -gt $config.maximumObservationGapSeconds){throw 'Observation gap during exchange.'}
    if(-not $Identity -and -not $Recovery){Assert-OperatorFresh}
    return $reply
}
function Send-OperatorDisplay([string]$Mode,[switch]$Recovery){
    if(-not $EnableControl){return}
    # Publish invalidation before sending Normal/White, so a failed media helper cannot
    # trust a cached blackout ACK while display output is transitioning.
    $script:state.outputBlackoutConfirmed=$false;Save-OperatorState
    $null=Exchange-Operator (New-VxDisplayRequest -Mode $Mode -Sequence (Next-OperatorSequence)) -Recovery:$Recovery
    $script:pattern=$Mode
    if($Mode -eq 'Blackout'){$script:state.outputBlackoutConfirmed=$true}
    Save-OperatorState
}
function Send-OperatorBrightness([double]$Percent,[switch]$Recovery){
    if(-not $EnableControl){return}
    $value=[int][Math]::Floor([Math]::Max([double]0,[Math]::Min([double]100,$Percent))*255/100)
    if($value -eq $script:brightness -and -not $Recovery){return}
    $null=Exchange-Operator (New-VxBrightnessRequest -Value ([byte]$value) -Sequence (Next-OperatorSequence)) -Recovery:$Recovery
    $script:brightness=$value;$script:state.brightnessRequestedPercent=$value*100.0/255
}
function Request-OperatorMedia([string]$Mode){
    if(-not $EnableControl -or -not $operator.mediaEnabled){$script:mediaRequest=$null;return}
    $script:mediaRequest=[pscustomobject]@{schemaVersion=1;id=[Guid]::NewGuid().ToString();sessionId=$script:state.sessionId;utc=[DateTimeOffset]::UtcNow.ToString('o');mode=$Mode}
    $script:mediaStart=$clock.Elapsed.TotalSeconds
    Save-OperatorJson 'operator-media.json' $script:mediaRequest
}
function Start-OperatorMediaHelper([switch]$Restart){
    if($EnableControl -and $operator.mediaEnabled){
        if($Restart -and $null -ne $script:helper -and -not $script:helper.HasExited){
            Request-OperatorMedia 'Stop'
            if(-not $script:helper.WaitForExit(2000)){$script:helper.Kill();$null=$script:helper.WaitForExit(500)}
        }
        if($null -ne $script:helper -and -not $script:helper.HasExited){return}
        # Replace leftover prior-session commands before the helper can observe them.
        Request-OperatorMedia 'Input'
        if($env:OS -ne 'Windows_NT' -or -not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0){throw 'Media requires interactive Windows session.'}
        $exe=Join-Path $PSHOME 'powershell.exe'
        $mediaScript=Join-Path $PSScriptRoot 'Play-VxOperatorMedia.ps1'
        $arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$mediaScript+'" -OperatorConfigPath "'+[IO.Path]::GetFullPath($OperatorConfigPath)+'" -DataDirectory "'+[IO.Path]::GetFullPath($DataDirectory)+'" -SessionId '+$script:state.sessionId
        $script:helper=Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    }
}
function Test-OperatorMedia {
    if(-not $operator.mediaEnabled){return $true}
    if($null -eq $script:mediaRequest){throw 'No pending media request.'}
    $ack=Read-OperatorJson 'operator-media-state.json'
    if($null -ne $ack -and $ack.id -ceq $script:mediaRequest.id -and $ack.sessionId -ceq $script:state.sessionId){
        $updated=[DateTimeOffset]::MinValue
        if($ack.schemaVersion -ne 1 -or $ack.success -isnot [bool] -or $ack.mode -cne $script:mediaRequest.mode -or $ack.updatedUtc -isnot [string] -or -not [DateTimeOffset]::TryParse($ack.updatedUtc,[ref]$updated)){throw 'Invalid media ACK.'}
        $age=([DateTimeOffset]::UtcNow-$updated).TotalSeconds
        if($age -lt -2 -or $age -gt 10){throw 'Stale media ACK.'}
        if(-not $ack.success){throw ('Media failed: '+$ack.message)}
        return $true
    }
    if(($clock.Elapsed.TotalSeconds-$script:mediaStart) -gt 10){throw 'Media ACK timeout.'}
    return $false
}
function Try-OperatorDark {
    if($EnableControl -and $null -ne $script:identity){
        try{Send-OperatorDisplay 'Blackout' -Recovery}catch{Write-Warning 'Blackout unconfirmed.'}
        try{Send-OperatorBrightness 0 -Recovery}catch{Write-Warning 'Zero unconfirmed.'}
    }
}
function Open-OperatorWait([string]$Reason){
    $script:persist.operatorPending=$true;$script:persist.active=$false
    $script:state.operatorPending=$true;$script:state.state='WAIT_OPERATOR';$script:state.phase='';$script:state.preheatReady=$false;$script:state.remainingSeconds=0;$script:state.message=$Reason
    $script:mode='';$script:contentReady=$false
    Save-OperatorPersistent;Save-OperatorState
    Try-OperatorDark
    try{Request-OperatorMedia 'Black'}catch{}
}
function Set-OperatorBlack {
    if($script:pattern -ne 'Blackout'){Send-OperatorDisplay 'Blackout'}
    $idle=[double]$operator.idlePercent
    if($script:mode -eq 'COOLDOWN' -and $script:brightness -ge 0){$idle=[Math]::Min($idle,$script:brightness*100.0/255)}
    Send-OperatorBrightness $idle
    $script:mode='';$script:state.state='BLACK';$script:state.phase='Black';$script:state.preheatReady=$false;$script:state.remainingSeconds=0
    $script:persist.active=$false;Save-OperatorPersistent
    Request-OperatorMedia 'Black'
}
function Start-OperatorMode([string]$Mode){
    $wasPending=[bool]$script:state.operatorPending
    $script:state.state=$Mode;$script:state.phase='Media pending';$script:state.preheatReady=$false;$script:state.operatorPending=$false
    $script:persist.operatorPending=$false;$script:persist.active=$true;Save-OperatorPersistent
    $script:mode=$Mode;$script:contentReady=$false
    Send-OperatorDisplay 'Blackout'
    if($Mode -eq 'COOLDOWN'){$script:coolFrom=if($script:brightness -ge 0){$script:brightness*100.0/255}else{0};Send-OperatorBrightness $script:coolFrom}
    else{Send-OperatorBrightness $operator.idlePercent}
    # Explicit restart after a gate recreates only this owner's media child.
    Start-OperatorMediaHelper -Restart:$wasPending
    Request-OperatorMedia $(if($Mode -eq 'DRY'){'Video'}else{'Input'})
    $script:modeStart=$clock.Elapsed.TotalSeconds
}
function Read-OperatorLayers {
    if($config.deviceModel -cne 'VX600'){throw 'Layer controls require original VX600.'}
    $snapshot=@()
    foreach($name in @('Main','PIP1','PIP2')){
        $reply=Exchange-Operator (New-VxLayerReadRequest -Layer $name -Sequence (Next-OperatorSequence))
        $view=ConvertFrom-VxLayerBlock -Block $reply.Payload -Layer $name
        $snapshot+=[pscustomobject]@{layer=$name;block=$reply.Payload;view=$view}
    }
    return ,$snapshot
}
function Apply-OperatorLayer($Command){
    $snapshot=Read-OperatorLayers
    try{
    if($Command.action -eq 'scale'){$patch=New-VxLayerScalePatch -Snapshot $snapshot -CanvasWidth $operator.canvasWidth -CanvasHeight $operator.canvasHeight;$name=$patch.layer;[byte[]]$block=$patch.block}
    else{$name=$Command.layer;$target=@($snapshot|Where-Object {$_.layer -ceq $name})[0];[byte[]]$block=New-VxLayerPatch -Block $target.block -Layer $name -Changes ([pscustomobject]@{enabled=$Command.enabled}) -Layers @($snapshot|ForEach-Object {$_.view})}
    }catch{$script:state.lastCommandResult='Rejected: '+$_.Exception.Message;return}
    $expected=@{};foreach($item in $snapshot){$expected[$item.layer]=$item.block};$expected[$name]=$block
    $null=Exchange-Operator (New-VxLayerWriteRequest -Layer $name -Block $block -Sequence (Next-OperatorSequence))
    $after=Read-OperatorLayers
    foreach($item in $after){if([Convert]::ToBase64String($item.block) -cne [Convert]::ToBase64String($expected[$item.layer])){throw 'Layer all-block readback mismatch after ACK.'}}
    $script:state.layers=@($after|ForEach-Object {$_.view})
}
function Receive-OperatorCommand {
    $command=Read-OperatorJson 'operator-command.json' 8192
    if($null -eq $command){return}
    $id=if($null -ne $command.PSObject.Properties['id']){[string]$command.id}else{'invalid'}
    if($script:persist.consumedCommandIds -contains $id -or $id -ceq $script:lastRejected){return}
    try{Assert-VxOperatorCommand -Command $command -SessionId $script:state.sessionId -ConsumedCommandIds $script:persist.consumedCommandIds}
    catch{$script:lastRejected=$id;$script:state.lastCommandId=$id;$script:state.lastCommandResult='Rejected: '+$_.Exception.Message;return}
    if($script:persist.consumedCommandIds.Count -ge 1024){throw 'Command cache full; restart owner for a new session.'}
    $script:persist.consumedCommandIds+= $command.id;Save-OperatorPersistent
    # Display transitions publish intermediate safety state. Keep the prior completed
    # command ID until this command has actually finished, so GUIs retain pending.
    $script:state.lastCommandResult='Accepted'
    try{
    if(-not $EnableControl){$script:state.lastCommandResult='Rejected: monitor only';return}
    switch($command.action){
        'preheat'{
            if($script:state.state -notin @('BLACK','WAIT_OPERATOR')){$script:state.lastCommandResult='Rejected: preparation interlock';return}
            Start-OperatorMode 'PREHEAT'
        }
        'shutdown'{
            if($script:state.state -eq 'COOLDOWN'){$script:state.lastCommandResult='Rejected: cooldown already active';return}
            if($script:state.state -in @('BLACK','WAIT_OPERATOR')){Send-OperatorDisplay 'Blackout';Send-OperatorBrightness $(if($script:state.state -eq 'WAIT_OPERATOR'){0}else{$operator.idlePercent});Start-OperatorMediaHelper;Request-OperatorMedia 'Black';$script:state.lastCommandResult='Accepted: retained black';return}
            Start-OperatorMode 'COOLDOWN'
        }
        default{
            if($script:state.state -ne 'READY'){$script:state.lastCommandResult='Rejected: layers/SCALE require READY';return}
            # Validation rejections are harmless; uncertain writes/readback failures gate the engine.
            Apply-OperatorLayer $command
        }
    }
    }catch{$script:state.lastCommandResult='Failed: '+$_.Exception.Message;throw}
    finally{$script:state.lastCommandId=$command.id}
}
try{
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$endpoint=[BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes((Get-VxConnectionKey $config)))).Replace('-','')}finally{$sha.Dispose()}
    $prefix=if($env:OS -eq 'Windows_NT'){'Global\'}else{''}
    $mutex=New-Object Threading.Mutex($false,($prefix+'NovaStarVX400-'+$endpoint))
    try{$owns=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
    if(-not $owns){throw 'Another watcher owns this endpoint.'}
    $null=[IO.Directory]::CreateDirectory($DataDirectory)
    $lock=[IO.File]::Open((Join-Path $DataDirectory 'watcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    # A damaged ledger is uncertainty, never permission to start a fresh daily run.
    $script:persist.operatorPending=$true
    $ledgerExisted=[IO.File]::Exists((Join-Path $DataDirectory 'operator-session.json'))
    $previous=Read-OperatorJson 'operator-session.json' 131072
    if($ledgerExisted -and $null -eq $previous){throw 'Invalid empty persisted operator session.'}
    if($null -ne $previous){
        if($previous.schemaVersion -ne 1 -or $previous.operatorPending -isnot [bool] -or $previous.active -isnot [bool] -or $previous.lastConsumedDay -isnot [string] -or ($previous.lastConsumedDay -ne '' -and $previous.lastConsumedDay -notmatch '^\d{4}-\d{2}-\d{2}$')){throw 'Invalid persisted operator session.'}
        if($null -ne $previous.PSObject.Properties['legacyStateHash']){
            if($previous.legacyStateHash -isnot [string] -or $previous.legacyStateHash -cnotmatch '^(?:[A-F0-9]{64})?$'){throw 'Invalid legacy state fingerprint.'}
            $script:persist.legacyStateHash=$previous.legacyStateHash
        }
        $script:persist.lastConsumedDay=$previous.lastConsumedDay
        $script:persist.operatorPending=($previous.operatorPending -or $previous.active)
    }else{$script:persist.operatorPending=$false}
    $legacyPath=Join-Path $DataDirectory 'estado.json'
    if([IO.File]::Exists($legacyPath)){
        try{
            if((Get-Item -LiteralPath $legacyPath).Length -gt 1048576){throw 'Legacy state too large.'}
            $legacyRaw=Read-VxSharedText $legacyPath
            if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$oldPlan=ConvertFrom-Json -InputObject $legacyRaw -DateKind String}else{$oldPlan=$legacyRaw|ConvertFrom-Json}
            if($oldPlan -isnot [pscustomobject] -or $null -eq $oldPlan.PSObject.Properties['state'] -or $oldPlan.state -isnot [string] -or $oldPlan.state -cnotin @('BOOT','WAITING','BLACK','STOPPED','DRY','PREHEAT','OPERATING','COOLDOWN','FAULT','WAIT_OPERATOR')){throw 'Invalid legacy controller state.'}
            if($null -ne $oldPlan.PSObject.Properties['operatorPending'] -and $oldPlan.operatorPending -isnot [bool]){throw 'Invalid legacy operator gate.'}
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$legacyHash=[BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($legacyRaw))).Replace('-','')}finally{$sha.Dispose()}
            # Content provenance survives clock rollback and copied file timestamps.
            # A genuine new Pro run/gate changes its PID, updatedUtc or gate UUID.
            if($legacyHash -cne $script:persist.legacyStateHash){
                if(($null -ne $oldPlan.PSObject.Properties['operatorPending'] -and $oldPlan.operatorPending) -or $oldPlan.state -in @('DRY','PREHEAT','OPERATING','COOLDOWN','FAULT','WAIT_OPERATOR')){$script:persist.operatorPending=$true}
                $script:persist.legacyStateHash=$legacyHash
            }
        }catch{$script:persist.operatorPending=$true;throw}
    }
    $script:state.operatorPending=$script:persist.operatorPending
    if($script:persist.operatorPending){$script:state.state='WAIT_OPERATOR';$script:state.message='Previous interruption: explicit full preparation required.'}
    Save-OperatorPersistent;Save-OperatorState
    Start-OperatorMediaHelper
    $poll=0;$success=0;$connected=$false;$firstBlack=$false;$lastLoop=$clock.Elapsed.TotalSeconds;$lastUtc=[DateTimeOffset]::UtcNow
    while($MaxPolls -eq 0 -or $poll -lt $MaxPolls){
        if([IO.File]::Exists((Join-Path $DataDirectory 'stop.request'))){[IO.File]::Delete((Join-Path $DataDirectory 'stop.request'));break}
        $poll++;$delta=$clock.Elapsed.TotalSeconds-$lastLoop;$wall=([DateTimeOffset]::UtcNow-$lastUtc).TotalSeconds
        $lastLoop=$clock.Elapsed.TotalSeconds;$lastUtc=[DateTimeOffset]::UtcNow
        if($delta -gt $config.maximumObservationGapSeconds -or [Math]::Abs($wall-$delta) -gt $config.maximumObservationGapSeconds){$success=0;$connected=$false;Open-OperatorWait 'Observation/clock gap; progress discarded.'}
        try{
            $reply=Exchange-Operator (New-VxReadRequest -Address 2 -Length 2 -Sequence (Next-OperatorSequence)) -Identity
            try{Assert-VxDeviceIdentity -Config $config -Reply $reply}catch{$script:identity=$null;throw}
            $script:identity=$reply;$script:identityStamp=[Diagnostics.Stopwatch]::GetTimestamp();$script:identityUtc=[DateTimeOffset]::UtcNow
            $success++;$connected=($success -ge $config.onlineSuccesses);$script:state.communication=if($connected){'reachable'}else{'confirming'}
        }catch{
            $success=0;$connected=$false;$script:state.communication='unreachable'
            if(-not $script:state.operatorPending){Open-OperatorWait ('Communication failed: '+$_.Exception.Message)}
        }
        if($connected){
            try{
                if($EnableControl){
                    if(-not $firstBlack){if($script:state.operatorPending){Try-OperatorDark;Request-OperatorMedia 'Black'}else{Set-OperatorBlack};$firstBlack=$true}
                    Receive-OperatorCommand
                    $day=Get-VxOperatorDay -Config $operator -TimeZone $config.timeZone -LastConsumedDay $script:persist.lastConsumedDay -MaximumObservationGapSeconds $config.maximumObservationGapSeconds
                    if($day.mode -in @('DRY','SKIP')){
                        # Consume BEFORE commands: restart, busy preparation and clock rollback cannot duplicate DRY.
                        $script:persist.lastConsumedDay=$day.day;Save-OperatorPersistent
                        if($day.mode -eq 'DRY' -and $script:state.state -eq 'BLACK' -and -not $script:state.operatorPending){$script:drySeconds=$day.durationSeconds;Start-OperatorMode 'DRY'}
                    }
                    if($script:mode){
                        $mediaReady=Test-OperatorMedia
                        if($mediaReady -and -not $script:contentReady){
                            $displayMode=if($script:mode -eq 'DRY' -and -not $operator.mediaEnabled){if($config.conditioningPattern -eq 'White'){'White'}else{'Normal'}}else{'Normal'}
                            Send-OperatorDisplay $displayMode
                            $script:contentReady=$true;$script:modeStart=$clock.Elapsed.TotalSeconds
                            if($script:mode -eq 'DRY'){
                                $remaining=Get-VxOperatorDay -Config $operator -TimeZone $config.timeZone -MaximumObservationGapSeconds ($config.maximumObservationGapSeconds+10)
                                $script:drySeconds=$remaining.durationSeconds
                                if($remaining.mode -ne 'DRY' -or $script:drySeconds -lt (($operator.dryRampMinutes+$operator.dryFallMinutes)*60)){throw 'Full dry ramps no longer fit morning window.'}
                            }
                        }
                        if($script:contentReady){
                            if($script:mode -eq 'READY'){Send-OperatorBrightness $operator.preheatPercent}
                            else{
                                $level=Get-VxOperatorLevel -Config $operator -Mode $script:mode -ElapsedSeconds ($clock.Elapsed.TotalSeconds-$script:modeStart) -CurrentBrightness $script:coolFrom -DryDurationSeconds $script:drySeconds
                                Send-OperatorBrightness $level.brightnessPercent;$script:state.phase=$level.phase;$script:state.remainingSeconds=$level.remainingSeconds
                                if($level.done){
                                    if($script:mode -eq 'PREHEAT'){$script:mode='READY';$script:state.state='READY';$script:state.phase='Ready';$script:state.preheatReady=$true;if($config.deviceModel -eq 'VX600'){$snapshot=Read-OperatorLayers;$script:state.layers=@($snapshot|ForEach-Object {$_.view})}}
                                    else{Set-OperatorBlack}
                                }
                            }
                        }
                    }elseif($operator.mediaEnabled -and $null -ne $script:mediaRequest){$null=Test-OperatorMedia}
                }else{$script:state.message='Monitor only; no hardware writes or command execution.'}
            }catch{Open-OperatorWait $_.Exception.Message}
        }
        Save-OperatorState
        # Keep heartbeat frequent even with configured long poll intervals; no UI wait blocks owner.
        $sleep=[Diagnostics.Stopwatch]::StartNew()
        while(($MaxPolls -eq 0 -or $poll -lt $MaxPolls) -and $sleep.Elapsed.TotalSeconds -lt $operatorPollSeconds){
            if([IO.File]::Exists((Join-Path $DataDirectory 'stop.request'))){break}
            Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Min(500,($operatorPollSeconds-$sleep.Elapsed.TotalSeconds)*1000)))
            Save-OperatorState
        }
    }
}catch{
    $exitCode=2
    if($null -ne $lock){try{Open-OperatorWait $_.Exception.Message}catch{}}
    Write-Error $_ -ErrorAction Continue
}finally{
    if($owns -and $null -ne $lock){
        # Persist interruption before touching hardware; killed/failed sequences cannot resume on restart.
        if($script:persist.active){$script:persist.operatorPending=$true;$script:persist.active=$false}
        try{Save-OperatorPersistent}catch{$exitCode=2}
        Try-OperatorDark
        try{Request-OperatorMedia 'Stop'}catch{}
        $script:state.state='STOPPED';$script:state.preheatReady=$false;$script:state.operatorPending=$script:persist.operatorPending
        try{Save-OperatorState}catch{$exitCode=2}
        # Keep controller ownership until our exact child releases its media mutex.
        if($null -ne $helper){try{if(-not $helper.WaitForExit(3000)){$helper.Kill();$null=$helper.WaitForExit(1000)}}catch{$exitCode=2}}
        $lock.Dispose()
    }
    if($owns){$mutex.ReleaseMutex()};if($null -ne $mutex){$mutex.Dispose()}
}
exit $exitCode
