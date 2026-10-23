#requires -Version 5.1
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1')
function New-VxOperatorConfig {
    [pscustomobject][ordered]@{schemaVersion=1;configured=$false;dailyStart='04:00';dailyEnd='06:00';idlePercent=10;dryPercent=30;dryRampMinutes=24;dryFallMinutes=24;preheatPercent=25;preheatMinutes=240;cooldownMinutes=36;mediaEnabled=$true;mediaFolder='';videoFile='';blackImageFile='';screenDeviceName='';allowPrimaryScreen=$false;canvasWidth=0;canvasHeight=0}
}
function Assert-VxOperatorConfig {
    param([Parameter(Mandatory)]$Config,[switch]$ForControl)
    $expected=@((New-VxOperatorConfig).PSObject.Properties.Name)
    if($Config -isnot [pscustomobject]){throw 'Operator config must be an object.'}
    $actual=@($Config.PSObject.Properties.Name)
    if($actual.Count -ne $expected.Count -or @($expected|Where-Object{$actual -cnotcontains $_}).Count){throw 'Operator config fields must match schemaVersion 1 exactly.'}
    foreach($name in @('configured','mediaEnabled','allowPrimaryScreen')){if($Config.$name -isnot [bool]){throw "$name must be boolean."}}
    foreach($name in @('schemaVersion','idlePercent','dryPercent','dryRampMinutes','dryFallMinutes','preheatPercent','preheatMinutes','cooldownMinutes','canvasWidth','canvasHeight')){
        $v=$Config.$name
        if($null -eq $v -or $v -is [bool] -or $v -is [string] -or $v -is [array] -or $v -is [pscustomobject]){throw "$name must be numeric."}
        $n=[double]$v;if([double]::IsNaN($n) -or [double]::IsInfinity($n)){throw "$name must be finite."}
    }
    if($Config.schemaVersion -ne 1){throw 'Unsupported operator schemaVersion.'}
    foreach($name in @('dailyStart','dailyEnd')){if($Config.$name -isnot [string] -or $Config.$name -cnotmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$'){throw "$name requires HH:mm."}}
    $start=[TimeSpan]::ParseExact($Config.dailyStart,'hh\:mm',[Globalization.CultureInfo]::InvariantCulture)
    $end=[TimeSpan]::ParseExact($Config.dailyEnd,'hh\:mm',[Globalization.CultureInfo]::InvariantCulture)
    if($end -le $start){throw 'Daily window must end after start on the same morning.'}
    if($Config.idlePercent -lt 0 -or $Config.idlePercent -ge $Config.preheatPercent -or $Config.preheatPercent -gt $Config.dryPercent -or $Config.dryPercent -gt 100){throw 'Require 0 <= idle < preheat <= dry <= 100.'}
    foreach($name in @('dryRampMinutes','dryFallMinutes','preheatMinutes','cooldownMinutes')){if($Config.$name -lt 0.001 -or $Config.$name -gt 10080){throw "$name requires 0.001..10080 minutes."}}
    if(($Config.dryRampMinutes+$Config.dryFallMinutes) -gt ($end-$start).TotalMinutes){throw 'Dry ramps must fit daily window.'}
    foreach($name in @('canvasWidth','canvasHeight')){if($Config.$name -lt 0 -or $Config.$name -gt 32768 -or [Math]::Floor($Config.$name) -ne $Config.$name){throw "$name requires integer 0..32768."}}
    foreach($name in @('mediaFolder','videoFile','blackImageFile','screenDeviceName')){if($Config.$name -isnot [string] -or $Config.$name.Length -gt 4096){throw "$name requires text up to 4096 characters."}}
    if($ForControl){
        if(-not $Config.configured){throw 'Operator configuration has not been explicitly accepted in Pro.'}
        if($Config.mediaEnabled){
            if([string]::IsNullOrWhiteSpace($Config.screenDeviceName)){throw 'Select an explicit Windows output in Pro.'}
            foreach($name in @('videoFile','blackImageFile')){
                if([string]::IsNullOrWhiteSpace($Config.$name)){throw "$name required when media enabled."}
                $path=Resolve-VxOperatorMediaPath -Config $Config -File $Config.$name
                if(-not [IO.File]::Exists($path)){throw "Missing media: $name."}
            }
        }
    }
}
function Resolve-VxOperatorMediaPath {
    param($Config,[string]$File)
    if($File -match '^[\\/]{2}|^[a-zA-Z]+://' -or $Config.mediaFolder -match '^[\\/]{2}|^[a-zA-Z]+://'){throw 'Media requires local filesystem paths.'}
    if([IO.Path]::IsPathRooted($File)){return [IO.Path]::GetFullPath($File)}
    if([string]::IsNullOrWhiteSpace($Config.mediaFolder)){throw 'Relative media files require mediaFolder.'}
    return [IO.Path]::GetFullPath((Join-Path $Config.mediaFolder $File))
}
function Read-VxOperatorConfig {
    param([Parameter(Mandatory)][string]$Path,[switch]$ForControl)
    if((Get-Item -LiteralPath $Path).Length -gt 32768){throw 'Operator config exceeds 32 KiB.'}
    $value=Read-VxSharedText -Path $Path|ConvertFrom-Json
    Assert-VxOperatorConfig -Config $value -ForControl:$ForControl
    return $value
}
function Get-VxOperatorLevel {
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][ValidateSet('DRY','PREHEAT','COOLDOWN')][string]$Mode,[double]$ElapsedSeconds=0,[double]$CurrentBrightness=0,[double]$DryDurationSeconds=0)
    if([double]::IsNaN($ElapsedSeconds) -or [double]::IsInfinity($ElapsedSeconds) -or $ElapsedSeconds -lt 0){throw 'Invalid elapsed time.'}
    if([double]::IsNaN($DryDurationSeconds) -or [double]::IsInfinity($DryDurationSeconds) -or $DryDurationSeconds -lt 0){throw 'Invalid dry duration.'}
    if($Mode -eq 'COOLDOWN' -and ([double]::IsNaN($CurrentBrightness) -or [double]::IsInfinity($CurrentBrightness) -or $CurrentBrightness -lt 0 -or $CurrentBrightness -gt 100)){throw 'Invalid confirmed cooldown brightness.'}
    $from=[double]$Config.idlePercent;$to=[double]$Config.preheatPercent
    if($Mode -eq 'COOLDOWN'){$from=$CurrentBrightness;$to=[Math]::Min($from,[double]$Config.idlePercent);$total=$Config.cooldownMinutes*60;$phase='Cooldown'}
    elseif($Mode -eq 'PREHEAT'){$total=$Config.preheatMinutes*60;$phase='Preheat'}
    else{
        if($DryDurationSeconds -le 0){$DryDurationSeconds=([TimeSpan]::Parse($Config.dailyEnd)-[TimeSpan]::Parse($Config.dailyStart)).TotalSeconds}
        $total=$DryDurationSeconds;$rise=$Config.dryRampMinutes*60;$fall=$Config.dryFallMinutes*60
        if($total -lt ($rise+$fall)){throw 'Dry window cannot fit full ramps.'}
        if($ElapsedSeconds -lt $rise){$to=$Config.dryPercent;$totalSegment=$rise;$elapsedSegment=$ElapsedSeconds;$phase='Dry rise'}
        elseif($ElapsedSeconds -lt ($total-$fall)){$from=$Config.dryPercent;$to=$from;$totalSegment=1;$elapsedSegment=0;$phase='Dry hold'}
        else{$from=$Config.dryPercent;$to=$Config.idlePercent;$totalSegment=$fall;$elapsedSegment=$ElapsedSeconds-($total-$fall);$phase='Dry fall'}
    }
    if($Mode -ne 'DRY'){$totalSegment=$total;$elapsedSegment=$ElapsedSeconds}
    $value=$from+($to-$from)*[Math]::Min([double]1,[Math]::Max([double]0,$elapsedSegment/$totalSegment))
    return [pscustomobject]@{brightnessPercent=$value;phase=$phase;done=($ElapsedSeconds -ge $total);remainingSeconds=[Math]::Max([double]0,$total-$ElapsedSeconds)}
}
function Get-VxOperatorDay {
    param($Config,[string]$TimeZone,[DateTimeOffset]$NowUtc=[DateTimeOffset]::UtcNow,[string]$LastConsumedDay='',[double]$MaximumObservationGapSeconds=30)
    try{$zone=[TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)}catch{if($TimeZone -eq 'SA Pacific Standard Time'){$zone=[TimeZoneInfo]::FindSystemTimeZoneById('America/Bogota')}elseif($TimeZone -eq 'America/Bogota'){$zone=[TimeZoneInfo]::FindSystemTimeZoneById('SA Pacific Standard Time')}else{throw}}
    $local=[TimeZoneInfo]::ConvertTime($NowUtc,$zone);$day=$local.ToString('yyyy-MM-dd')
    $start=[DateTime]::SpecifyKind($local.Date.Add([TimeSpan]::Parse($Config.dailyStart)),[DateTimeKind]::Unspecified)
    $end=[DateTime]::SpecifyKind($local.Date.Add([TimeSpan]::Parse($Config.dailyEnd)),[DateTimeKind]::Unspecified)
    $mode='BLACK';$seconds=0
    if(-not $zone.IsInvalidTime($start) -and -not $zone.IsAmbiguousTime($start) -and -not $zone.IsInvalidTime($end) -and -not $zone.IsAmbiguousTime($end)){
        $startUtc=[DateTimeOffset][TimeZoneInfo]::ConvertTimeToUtc($start,$zone);$endUtc=[DateTimeOffset][TimeZoneInfo]::ConvertTimeToUtc($end,$zone)
        if($day -cgt $LastConsumedDay -and $NowUtc -ge $startUtc){
            if($NowUtc -lt $endUtc -and ($NowUtc-$startUtc).TotalSeconds -le $MaximumObservationGapSeconds){$mode='DRY';$seconds=($endUtc-$NowUtc).TotalSeconds}
            else{$mode='SKIP'}
        }
    }
    # Lexical date high-water mark survives clock rollback and edits to dailyStart.
    [pscustomobject]@{day=$day;mode=$mode;durationSeconds=$seconds}
}
function Assert-VxOperatorCommand {
    param($Command,[string]$SessionId,[string[]]$ConsumedCommandIds=@(),[DateTimeOffset]$NowUtc=[DateTimeOffset]::UtcNow)
    if($Command -isnot [pscustomobject]){throw 'Command requires object.'}
    $fields=@('schemaVersion','id','sessionId','utc','action')
    if($Command.action -ceq 'layer'){$fields+=@('layer','enabled')}
    $actual=@($Command.PSObject.Properties.Name)
    if($actual.Count -ne $fields.Count -or @($fields|Where-Object{$actual -cnotcontains $_}).Count){throw 'Invalid command fields.'}
    if(($Command.schemaVersion -isnot [int] -and $Command.schemaVersion -isnot [long]) -or $Command.schemaVersion -ne 1 -or $Command.action -cnotin @('preheat','shutdown','layer','scale')){throw 'Invalid command action/schema.'}
    foreach($name in @('id','sessionId')){$id=[Guid]::Empty;if($Command.$name -isnot [string] -or -not [Guid]::TryParseExact($Command.$name,'D',[ref]$id) -or $id -eq [Guid]::Empty){throw 'Command UUID required.'}}
    if($Command.sessionId -cne $SessionId -or $ConsumedCommandIds -contains $Command.id){throw 'Old session or replayed command.'}
    $utc=[DateTimeOffset]::MinValue
    if($Command.utc -isnot [string] -or $Command.utc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$' -or -not [DateTimeOffset]::TryParse($Command.utc,[ref]$utc) -or ($NowUtc-$utc).TotalSeconds -gt 10 -or ($NowUtc-$utc).TotalSeconds -lt -2){throw 'Stale command timestamp.'}
    if($Command.action -ceq 'layer' -and ($Command.layer -cnotin @('Main','PIP1','PIP2') -or $Command.enabled -isnot [bool])){throw 'Invalid layer command.'}
}
Export-ModuleMember -Function New-VxOperatorConfig,Read-VxOperatorConfig,Assert-VxOperatorConfig,Resolve-VxOperatorMediaPath,Get-VxOperatorLevel,Get-VxOperatorDay,Assert-VxOperatorCommand
