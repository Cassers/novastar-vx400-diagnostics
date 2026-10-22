#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../Vx400.Schedule.psm1') -Force
$script:count=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:count++}
function Throws([scriptblock]$Body,[string]$Message){$thrown=$false;try{&$Body}catch{$thrown=$true};Assert $thrown $Message}
function Near([double]$A,[double]$B,[string]$Message){Assert ([Math]::Abs($A-$B) -lt 0.00001) $Message}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('vx-plan-tests-'+[Guid]::NewGuid().ToString())
$null=New-Item -ItemType Directory -Path $tmp
$utf8=New-Object Text.UTF8Encoding($false)
function Write-Json($Value,[string]$Name='test.json'){$path=Join-Path $tmp $Name;[IO.File]::WriteAllText($path,($Value|ConvertTo-Json -Depth 20),$utf8);return $path}
function Copy-Config{return (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../plan.config.json') -Raw -Encoding UTF8|ConvertFrom-Json)}
function Request([string]$Start,[string]$End,[bool]$Cancelled=$false){return [pscustomobject]@{id=[Guid]::NewGuid().ToString();title='Prueba';startUtc=$Start;endUtc=$End;cancelled=$Cancelled}}
try{
    $c=Read-VxPlanConfig (Join-Path $PSScriptRoot '../plan.config.json')
    Assert ($c.deviceModel -ceq 'VX600' -and $c.connectionType -ceq 'Ethernet' -and $c.usbDeviceKey -ceq '') distributedconnectiondefaults
    $legacy=Copy-Config
    foreach($name in @('deviceModel','connectionType','usbDeviceKey')){$legacy.PSObject.Properties.Remove($name)}
    $normalized=Read-VxPlanConfig (Write-Json $legacy)
    Assert ($normalized.deviceModel -ceq 'VX400' -and $normalized.connectionType -ceq 'Ethernet' -and $normalized.usbDeviceKey -ceq '') legacyconnectiondefaults
    foreach($bad in @('VX600 Pro','VX600S','VX1000','vx600','')){$invalid=Copy-Config;$invalid.deviceModel=$bad;$path=Write-Json $invalid;Throws {Read-VxPlanConfig $path} unsupportedmodel}
    foreach($bad in @('Auto','WiFi','usb','')){$invalid=Copy-Config;$invalid.connectionType=$bad;$path=Write-Json $invalid;Throws {Read-VxPlanConfig $path} invalidtransport}
    foreach($bad in @($null,1,('a'*257),"bad`nkey",('bad'+[char]0x7F+'key'))){$invalid=Copy-Config;$invalid.usbDeviceKey=$bad;$path=Write-Json $invalid;Throws {Read-VxPlanConfig $path} invalidusbkey}
    $invalid=Copy-Config;$invalid|Add-Member -NotePropertyName connectionTypo -NotePropertyValue 'USB';$path=Write-Json $invalid;Throws {Read-VxPlanConfig $path} unknownfieldstillrejected
    $usb=Copy-Config;$usb.connectionType='USB';$usb.usbDeviceKey='pinned-device';$path=Write-Json $usb
    Assert ((Read-VxPlanConfig $path).usbDeviceKey -ceq 'pinned-device') usbconfigofflinevalidation
    Near (Get-VxProfileSeconds $c.profiles.dry) (188*60) dry188
    Near (Get-VxProfileSeconds $c.profiles.preheat) (240*60) preheat240
    Near (Get-VxProfileSeconds $c.profiles.cooldown) (36*60) cooldown36
    Near (Get-VxPlanLevel $c.profiles.cooldown (10*60)).brightnessPercent 65 cooldownfirsthalf
    Near (Get-VxPlanLevel $c.profiles.cooldown (20*60)).brightnessPercent 50 cooldownboundary
    Near (Get-VxPlanLevel $c.profiles.cooldown (28*60)).brightnessPercent 30 cooldownsecondhalf
    Assert (-not (Get-VxPlanLevel $c.profiles.cooldown (35*60)).done) cooldownnotdone
    Assert (Get-VxPlanLevel $c.profiles.cooldown (36*60)).done cooldowndone
    Near (Get-VxPlanLevel $c.profiles.dry 0).brightnessPercent 10 start
    Near (Get-VxPlanLevel $c.profiles.dry (12*60)).brightnessPercent 30 halfup
    Near (Get-VxPlanLevel $c.profiles.dry (24*60)).brightnessPercent 50 hold
    Near (Get-VxPlanLevel $c.profiles.dry (100*60)).brightnessPercent 50 midhold
    Near (Get-VxPlanLevel $c.profiles.dry (176*60)).brightnessPercent 30 halfwaydown
    Near (Get-VxPlanLevel $c.profiles.dry (182*60)).brightnessPercent 15 drywaypoint15
    Near (Get-VxPlanLevel $c.profiles.dry (188*60)).brightnessPercent 10 end
    Assert (Get-VxPlanLevel $c.profiles.dry (188*60)).done done
    Assert (-not (Get-VxPlanLevel $c.profiles.dry (187*60)).done) notdone
    Near (Get-VxPlanLevel $c.profiles.dry -50).brightnessPercent 10 clamp
    Assert ((Get-VxPlanLevel $c.profiles.preheat 0).content -eq 'White') whitefirst
    Assert ((Get-VxPlanLevel $c.profiles.preheat (121*60)).content -eq 'FromInput') inputramp
    $decision=Get-VxPlanDecision -Config $c -NowUtc ([DateTimeOffset]'2026-10-20T09:00:00Z')
    Assert ($decision.mode -eq 'DRY' -and $decision.key -eq '2026-10-20:04:00') bogota4am
    Assert ((Get-VxPlanDecision -Config $c -NowUtc ([DateTimeOffset]'2026-10-20T12:07:59Z')).mode -eq 'DRY') dryfull188
    Assert ((Get-VxPlanDecision -Config $c -NowUtc ([DateTimeOffset]'2026-10-20T12:08:00Z')).mode -eq 'BLACK') dryends0708
    Assert ((Get-VxPlanDecision -Config $c -NowUtc ([DateTimeOffset]'2026-10-20T23:00:00Z')).mode -eq 'DRY') evening
    Assert ((Get-VxPlanDecision -Config $c -NowUtc ([DateTimeOffset]'2026-10-20T09:00:00Z') -CompletedDryKeys @('2026-10-20:04:00')).mode -eq 'BLACK') consumed
    $r=Request '2026-10-20T17:00:00Z' '2026-10-20T18:00:00Z'
    Assert ((Get-VxPlanDecision -Config $c -Requests @($r) -NowUtc ([DateTimeOffset]'2026-10-20T12:59:59Z')).mode -eq 'BLACK') beforelead
    Assert ((Get-VxPlanDecision -Config $c -Requests @($r) -NowUtc ([DateTimeOffset]'2026-10-20T13:00:00Z')).mode -eq 'PREHEAT') lead
    Assert ((Get-VxPlanDecision -Config $c -Requests @($r) -NowUtc ([DateTimeOffset]'2026-10-20T17:00:00Z')).mode -eq 'OPERATING') operation
    Assert ((Get-VxPlanDecision -Config $c -Requests @($r) -NowUtc ([DateTimeOffset]'2026-10-20T18:00:00Z')).mode -eq 'BLACK') ended
    $r.cancelled=$true
    Assert ((Get-VxPlanDecision -Config $c -Requests @($r) -NowUtc ([DateTimeOffset]'2026-10-20T17:00:00Z')).mode -eq 'BLACK') cancelled
    foreach($actual in @(0,5,20,40,55,79.6)){
        $cool=Get-VxCooldownProfile $c.profiles.cooldown $actual
        $last=$actual
        for($seconds=0;$seconds -le (Get-VxProfileSeconds $cool);$seconds+=60){$value=(Get-VxPlanLevel $cool $seconds).brightnessPercent;Assert ($value -le $last+0.00001) partialcooldown;$last=$value}
    }
    $empty=Read-VxRequests (Join-Path $tmp absent.json);Assert ($empty -is [array] -and $empty.Count -eq 0) emptyarray
    $r=Request '2026-10-20T17:00:00Z' '2026-10-20T18:00:00Z'
    $path=Write-Json ([pscustomobject]@{schemaVersion=1;items=@($r)})
    $items=Read-VxRequests $path;Assert ($items -is [array] -and $items.Count -eq 1) singletonarray
    $document=[pscustomobject]@{schemaVersion=1;items=@($r,$r)}
    $path=Write-Json $document;Throws {Read-VxRequests $path} duplicate
    $r2=Request '2026-10-20T17:30:00Z' '2026-10-20T19:00:00Z'
    $path=Write-Json ([pscustomobject]@{schemaVersion=1;items=@($r,$r2)});Throws {Read-VxRequests $path} overlap
    $r2.cancelled=$true;$path=Write-Json ([pscustomobject]@{schemaVersion=1;items=@($r,$r2)});Assert ((Read-VxRequests $path).Count -eq 2) cancelledoverlap
    $r2.cancelled=$false;$r2.startUtc='2026-10-20T20:00:00Z';$r2.endUtc='2026-10-20T19:00:00Z'
    $path=Write-Json ([pscustomobject]@{schemaVersion=1;items=@($r2)});Throws {Read-VxRequests $path} reversed
    $r2.startUtc='2026-10-20T17:00:00';$path=Write-Json ([pscustomobject]@{schemaVersion=1;items=@($r2)});Throws {Read-VxRequests $path} offsetrequired
    Throws {Read-VxPlanConfig (Join-Path $PSScriptRoot '../plan.config.json') -EnableControl} powergates
    $c=Copy-Config;$c.panelPowerCouplingVerified=$true;$c.startupProtectionVerified=$true;$path=Write-Json $c
    $null=Read-VxPlanConfig $path -EnableControl;Assert $true genericaccepted
    $manual=Read-VxPlanConfig (Join-Path $PSScriptRoot '../plan.config.json') -EnableControl -ManualControl
    Assert (-not $manual.panelPowerCouplingVerified -and -not $manual.startupProtectionVerified) manualdoesnotfalsifychecks
    Throws {Read-VxPlanConfig (Join-Path $PSScriptRoot '../plan.config.json') -ManualControl} manualrequirescontrol
    $manual.profileAccepted=$false;$manualPath=Write-Json $manual
    Throws {Read-VxPlanConfig $manualPath -EnableControl -ManualControl} manualprofilestillrequired
    foreach($bad in @('127.1','localhost','224.0.0.1','192.168.000.1')){$c=Copy-Config;$c.deviceAddress=$bad;$path=Write-Json $c;Throws {Read-VxPlanConfig $path} canonicalipv4}
    $c=Copy-Config;$c.tcpPort='5200';$path=Write-Json $c;Throws {Read-VxPlanConfig $path} stricttype
    $c=Copy-Config;$c.profiles.dry[1].from=49;$path=Write-Json $c;Throws {Read-VxPlanConfig $path} continuous
    $c=Copy-Config;$c.operatingWindows=@([pscustomobject]@{start='08:00';end='18:00';days=@(2)})
    $virtual=@(Get-VxOperatingRequests $c ([DateTimeOffset]'2026-10-20T09:00:00Z'))
    Assert ($virtual.Count -eq 1) virtualone
    Assert ([DateTimeOffset]$virtual[0].startUtc -eq [DateTimeOffset]'2026-10-20T13:00:00Z') local8
    Assert ((Get-VxPlanDecision -Config $c -NowUtc ([DateTimeOffset]'2026-10-20T09:00:00Z')).mode -eq 'PREHEAT') dailyleadpriority
    $c.operatingWindows=@([pscustomobject]@{start='22:00';end='02:00';days=@(1)})
    $v=@(Get-VxOperatingRequests $c ([DateTimeOffset]'2026-10-20T06:00:00Z'))
    Assert ([DateTimeOffset]$v[0].endUtc -eq [DateTimeOffset]'2026-10-20T07:00:00Z') overnight
    $c.operatingWindows=@([pscustomobject]@{start='02:00';end='03:00';days=@(2)})
    Assert ((Get-VxPlanDecision -Config $c -NowUtc ([DateTimeOffset]'2026-10-20T03:00:00Z')).mode -eq 'PREHEAT') preheatcrossmidnight
    $c=Copy-Config;$c.operatingWindows=@([pscustomobject]@{start='08:00';end='18:00';days=@(2)})
    $future=Request '2026-10-20T21:00:00Z' '2026-10-20T22:00:00Z'
    $priority=Get-VxPlanDecision -Config $c -Requests @($future) -NowUtc ([DateTimeOffset]'2026-10-20T18:00:00Z')
    Assert ($priority.mode -eq 'OPERATING' -and $priority.request.id.StartsWith('window:')) currentoperatingbeforefuturebooking
    $c.operatingWindows=@([pscustomobject]@{start='16:00';end='18:00';days=@(2)})
    $current=Request '2026-10-20T17:00:00Z' '2026-10-20T20:00:00Z'
    $priority=Get-VxPlanDecision -Config $c -Requests @($current) -NowUtc ([DateTimeOffset]'2026-10-20T18:00:00Z')
    Assert ($priority.mode -eq 'OPERATING' -and $priority.request.id -eq $current.id) currentbookingbeforefuturewindow
    $tiny=@([pscustomobject]@{name='tiny';from=10;to=50;minutes=.003;content='White'})
    Near (Get-VxPlanLevel $tiny .1).brightnessPercent (10+40*.1/.18) fractionalmath
    Assert (-not (Get-VxPlanLevel $tiny .17).done) fractionalminimumduration
    Assert (Get-VxPlanLevel $tiny .18).done fractionalendpoint
    Write-Output "PASS $script:count plan assertions"
}finally{Remove-Item -LiteralPath $tmp -Recurse -Force}
