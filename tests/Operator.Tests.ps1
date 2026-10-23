#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Vx.Operator.psm1') -Force
Import-Module (Join-Path $root 'Vx.Layers.psm1') -Force
$script:passed=0
function Assert($v,$label){if(-not $v){throw "FAIL $label"};$script:passed++}
function Reject([scriptblock]$body,$label){$bad=$false;try{& $body}catch{$bad=$true};Assert $bad $label}
$c=New-VxOperatorConfig
Assert ($c.idlePercent -eq 10 -and $c.dryPercent -eq 30 -and $c.preheatPercent -eq 25 -and $c.preheatMinutes -eq 240 -and $c.cooldownMinutes -eq 36 -and -not $c.configured -and $c.screenDeviceName -eq '') 'Safe defaults'
Assert-VxOperatorConfig $c
Reject {Assert-VxOperatorConfig $c -ForControl} 'Unaccepted control rejected'
$c.configured=$true;$c.mediaEnabled=$false;Assert-VxOperatorConfig $c -ForControl
foreach($field in @('idlePercent','dryRampMinutes','preheatMinutes','canvasWidth')){$bad=$c|ConvertTo-Json|ConvertFrom-Json;$bad.$field='10';Reject {Assert-VxOperatorConfig $bad} 'Numbers strict'}
$bad=$c|ConvertTo-Json|ConvertFrom-Json;$bad|Add-Member NoteProperty arbitraryBrightness 90;Reject {Assert-VxOperatorConfig $bad} 'Unknown settings rejected'
$bad=$c|ConvertTo-Json|ConvertFrom-Json;$bad.dryRampMinutes=100;Reject {Assert-VxOperatorConfig $bad} 'Ramps fit window'
Reject {Get-VxOperatorLevel $c COOLDOWN 0 -CurrentBrightness ([double]::NaN)} 'Unknown cooldown brightness rejected'
Reject {Get-VxOperatorLevel $c DRY 0 -DryDurationSeconds ([double]::PositiveInfinity)} 'Invalid dry duration rejected'
$level=Get-VxOperatorLevel $c PREHEAT 7200
Assert ($level.brightnessPercent -eq 17.5 -and -not $level.done) 'Full preheat interpolation'
$level=Get-VxOperatorLevel $c PREHEAT 14400
Assert ($level.done -and $level.brightnessPercent -eq 25) 'Ready same ceiling'
foreach($from in @(0,4,10,17,25)){$level=Get-VxOperatorLevel $c COOLDOWN 0 -CurrentBrightness $from;Assert ($level.brightnessPercent -eq $from) 'Cooldown no jump';$level=Get-VxOperatorLevel $c COOLDOWN 2160 -CurrentBrightness $from;Assert ($level.done -and $level.brightnessPercent -le $from -and $level.brightnessPercent -le 10) 'Cooldown end bounded'}
$level=Get-VxOperatorLevel $c DRY 0;Assert ($level.brightnessPercent -eq 10) 'Dry starts idle'
$level=Get-VxOperatorLevel $c DRY 3600;Assert ($level.brightnessPercent -eq 30) 'Dry ceiling'
$level=Get-VxOperatorLevel $c DRY 7200;Assert ($level.done -and $level.brightnessPercent -eq 10) 'Dry ends idle'
$day=Get-VxOperatorDay $c 'UTC' ([DateTimeOffset]'2026-10-23T04:00:01Z') '' 30
Assert ($day.mode -eq 'DRY') 'On time daily'
$day=Get-VxOperatorDay $c 'UTC' ([DateTimeOffset]'2026-10-23T04:00:31Z') '' 30
Assert ($day.mode -eq 'SKIP') 'Late start skipped'
$day=Get-VxOperatorDay $c 'UTC' ([DateTimeOffset]'2026-10-23T04:00:01Z') '2026-10-23' 30
Assert ($day.mode -eq 'BLACK') 'No same day replay'
$day=Get-VxOperatorDay $c 'UTC' ([DateTimeOffset]'2026-10-22T04:00:01Z') '2026-10-23' 30
Assert ($day.mode -eq 'BLACK') 'Clock rollback no replay'
$session=[Guid]::NewGuid().ToString();$cmd=[pscustomobject]@{schemaVersion=1;id=[Guid]::NewGuid().ToString();sessionId=$session;utc=[DateTimeOffset]::UtcNow.ToString('o');action='preheat'}
Assert-VxOperatorCommand $cmd $session
$cmd.schemaVersion=@(1);Reject {Assert-VxOperatorCommand $cmd $session} 'Array schema version rejected';$cmd.schemaVersion=1
Reject {Assert-VxOperatorCommand $cmd $session @($cmd.id)} 'Replay denied'
Reject {Assert-VxOperatorCommand $cmd ([Guid]::NewGuid().ToString())} 'Old session denied'
$cmd|Add-Member NoteProperty percent 80;Reject {Assert-VxOperatorCommand $cmd $session} 'Arbitrary percent denied';$cmd.PSObject.Properties.Remove('percent')
$cmd.utc=[DateTimeOffset]::UtcNow.AddSeconds(-11).ToString('o');Reject {Assert-VxOperatorCommand $cmd $session} 'Stale timestamp denied'
$names=@('Main','PIP1','PIP2');$snapshot=@()
for($i=0;$i -lt 3;$i++){
 [byte[]]$b=New-Object byte[] 48;$b[0]=1;$b[1]=$i;$b[3]=$i;$b[4]=17;$b[47]=100
 [Array]::Copy([BitConverter]::GetBytes([uint32]100),0,$b,13,4);[Array]::Copy([BitConverter]::GetBytes([uint32]100),0,$b,17,4)
 for($j=21;$j -lt 47;$j++){$b[$j]=$j}
 $snapshot+=[pscustomobject]@{layer=$names[$i];block=$b}
}
$patch=New-VxLayerScalePatch $snapshot 1920 1080
Assert ($patch.layer -eq 'Main' -and [BitConverter]::ToUInt32($patch.block,13) -eq 1920 -and [BitConverter]::ToUInt32($patch.block,17) -eq 1080) 'Scale backmost active geometry'
Assert ([Convert]::ToBase64String($patch.block[21..47]) -ceq [Convert]::ToBase64String($snapshot[0].block[21..47])) 'Scale preserves reserved opacity'
Reject {New-VxLayerScalePatch $snapshot 0 1080} 'Unknown canvas rejects'
$snapshot[1].block[3]=0;Reject {New-VxLayerScalePatch $snapshot 1920 1080} 'Ambiguous priority rejects'
. (Join-Path $root 'Play-VxOperatorMedia.ps1')
$oldMedia=[pscustomobject]@{schemaVersion=1;id=[Guid]::NewGuid().ToString();sessionId=[Guid]::NewGuid().ToString();utc=[DateTimeOffset]::UtcNow.AddDays(-1).ToString('o');mode='Stop'}
Assert ($null -eq (Get-VxMediaSessionCommand $oldMedia $session ([datetime]::UtcNow) @())) 'Old session leftover media command ignored'
$oldMedia.sessionId=$session
Reject {Get-VxMediaSessionCommand $oldMedia $session ([datetime]::UtcNow) @()} 'Current session stale media remains rejected'
$oldMedia.utc=[DateTimeOffset]::UtcNow.ToString('o');$oldMedia.mode='Input'
Assert ((Get-VxMediaSessionCommand $oldMedia $session ([datetime]::UtcNow) @()).mode -eq 'Input') 'Current session hidden initial command valid'
Write-Host "PASS: $script:passed operator assertions"
