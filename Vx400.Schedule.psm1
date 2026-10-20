#requires -Version 5.1
Set-StrictMode -Version Latest

function Read-VxSharedText([string]$Path) {
    # Readers permit atomic replacement while retaining a consistent open-file snapshot.
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}
function Move-VxAtomicFile([string]$Source,[string]$Destination) {
    # Windows readers outside this app may briefly deny FILE_SHARE_DELETE.
    # Retry only sharing/lock violations; disk, ACL and other failures remain fatal.
    $retry=[Diagnostics.Stopwatch]::StartNew()
    while($true) {
        try {
            if([IO.File]::Exists($Destination)){[IO.File]::Replace($Source,$Destination,[NullString]::Value)}
            else{[IO.File]::Move($Source,$Destination)}
            return
        } catch {
            $cause=$_.Exception.GetBaseException()
            $code=$cause.HResult -band 65535
            if($cause -isnot [IO.IOException] -or $code -notin @(32,33) -or $retry.ElapsedMilliseconds -ge 750){throw}
            Start-Sleep -Milliseconds 25
        }
    }
}

function Assert-VxPlanObject($Value, [string[]]$Fields, [string]$Name) {
    if ($Value -isnot [pscustomobject]) { throw "$Name must be a JSON object." }
    $actual = @($Value.PSObject.Properties.Name)
    foreach ($field in $Fields) { if ($actual -notcontains $field) { throw "Missing $Name.$field." } }
    foreach ($field in $actual) { if ($Fields -notcontains $field) { throw "Unknown $Name.$field." } }
}
function Assert-VxPlanNumber($Value, [double]$Min, [double]$Max, [string]$Name, [switch]$Integer) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or $Value -is [System.Array] -or $Value -is [pscustomobject]) {
        throw "$Name must be a number."
    }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $Min -or $number -gt $Max -or
        ($Integer -and [Math]::Floor($number) -ne $number)) { throw "$Name must be $Min..$Max." }
}
function Resolve-VxPlanTimeZone([string]$Id) {
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($Id) } catch {
        if ($Id -eq 'SA Pacific Standard Time') { return [TimeZoneInfo]::FindSystemTimeZoneById('America/Bogota') }
        if ($Id -eq 'America/Bogota') { return [TimeZoneInfo]::FindSystemTimeZoneById('SA Pacific Standard Time') }
        throw "Unknown timeZone: $Id"
    }
}
function Get-VxProfileSeconds {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Profile)
    [double]$total = 0
    foreach ($segment in $Profile) { $total += [double]$segment.minutes * 60 }
    return $total
}
function Get-VxPlanLevel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Profile, [Parameter(Mandatory)][double]$ElapsedSeconds, [string]$DefaultContent='FromInput')
    if ($Profile.Count -lt 1 -or [double]::IsNaN($ElapsedSeconds) -or [double]::IsInfinity($ElapsedSeconds)) { throw 'Invalid profile or elapsed time.' }
    $elapsed = [Math]::Max([double]0,$ElapsedSeconds)
    $total = Get-VxProfileSeconds $Profile
    if ($elapsed -ge $total) { return [pscustomobject]@{brightnessPercent=[double]$Profile[-1].to; phase=[string]$Profile[-1].name; content=$(if ($null -ne $Profile[-1].PSObject.Properties['content']) {$Profile[-1].content} else {$DefaultContent}); done=$true} }
    foreach ($segment in $Profile) {
        $seconds = [double]$segment.minutes*60
        if ($elapsed -lt $seconds) {
            return [pscustomobject]@{brightnessPercent=([double]$segment.from + ([double]$segment.to-[double]$segment.from)*$elapsed/$seconds); phase=[string]$segment.name; content=$(if ($null -ne $segment.PSObject.Properties['content']) {$segment.content} else {$DefaultContent}); done=$false}
        }
        $elapsed -= $seconds
    }
    throw 'Unreachable profile position.'
}
function Read-VxPlanConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$EnableControl)
    if ((Get-Item -LiteralPath $Path).Length -gt 262144) { throw 'Config exceeds 256 KiB.' }
    $config = Read-VxSharedText -Path $Path | ConvertFrom-Json
    Assert-VxPlanObject $config @('schemaVersion','deviceAddress','tcpPort','pollIntervalSeconds','timeoutMs','offlineFailures','onlineSuccesses','maximumObservationGapSeconds','timeZone','profileAccepted','profileSource','panelPowerCouplingVerified','startupProtectionVerified','conditioningPattern','idleBrightnessPercent','operatingBrightnessPercent','dailyStarts','operatingWindows','profiles') 'config'
    Assert-VxPlanNumber $config.schemaVersion 1 1 schemaVersion -Integer
    $ip = $null
    if ($config.deviceAddress -isnot [string] -or -not [Net.IPAddress]::TryParse($config.deviceAddress,[ref]$ip) -or
        $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.ToString() -cne $config.deviceAddress -or
        $ip.GetAddressBytes()[0] -eq 0 -or $ip.GetAddressBytes()[0] -ge 224) { throw 'deviceAddress must be canonical unicast IPv4.' }
    Assert-VxPlanNumber $config.tcpPort 1 65535 tcpPort -Integer
    Assert-VxPlanNumber $config.pollIntervalSeconds 0.1 60 pollIntervalSeconds
    Assert-VxPlanNumber $config.timeoutMs 250 15000 timeoutMs -Integer
    Assert-VxPlanNumber $config.offlineFailures 1 20 offlineFailures -Integer
    Assert-VxPlanNumber $config.onlineSuccesses 1 20 onlineSuccesses -Integer
    Assert-VxPlanNumber $config.maximumObservationGapSeconds 1 300 maximumObservationGapSeconds
    if ($config.maximumObservationGapSeconds -le ($config.pollIntervalSeconds + $config.timeoutMs/1000.0)) { throw 'maximumObservationGapSeconds must exceed poll interval plus timeout.' }
    if ($config.timeZone -isnot [string] -or [string]::IsNullOrWhiteSpace($config.timeZone)) { throw 'timeZone required.' }
    $null = Resolve-VxPlanTimeZone $config.timeZone
    foreach ($field in @('profileAccepted','panelPowerCouplingVerified','startupProtectionVerified')) {
        if ($config.$field -isnot [bool]) { throw "$field must be boolean." }
        if ($EnableControl -and -not $config.$field) { throw "Control blocked: $field must be true." }
    }
    if ($config.profileSource -isnot [string] -or [string]::IsNullOrWhiteSpace($config.profileSource) -or $config.profileSource.Length -gt 1024) { throw 'profileSource required, maximum 1024 characters.' }
    if ($config.conditioningPattern -isnot [string] -or $config.conditioningPattern -cnotin @('White','FromInput')) { throw 'conditioningPattern must be White or FromInput.' }
    Assert-VxPlanNumber $config.idleBrightnessPercent 0 100 idleBrightnessPercent
    Assert-VxPlanNumber $config.operatingBrightnessPercent 0 100 operatingBrightnessPercent
    if ($config.operatingBrightnessPercent -le $config.idleBrightnessPercent) { throw 'Operating brightness must exceed idle brightness.' }
    if ($config.dailyStarts -isnot [array] -or $config.dailyStarts.Count -gt 24) { throw 'dailyStarts must be an array of up to 24 times.' }
    $seen = @{}
    foreach ($start in $config.dailyStarts) {
        if ($start -isnot [string] -or $start -cnotmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$' -or $seen.ContainsKey($start)) { throw 'dailyStarts requires unique HH:mm values.' }
        $seen[$start] = $true
    }
    if ($config.operatingWindows -isnot [array] -or $config.operatingWindows.Count -gt 32) { throw 'operatingWindows must be an array of up to 32 windows.' }
    foreach ($window in $config.operatingWindows) {
        Assert-VxPlanObject $window @('start','end','days') operatingWindow
        foreach ($field in @('start','end')) { if ($window.$field -isnot [string] -or $window.$field -cnotmatch '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$') { throw 'Operating window requires HH:mm.' } }
        if ($window.start -eq $window.end -or $window.days -isnot [array] -or $window.days.Count -lt 1 -or $window.days.Count -gt 7) { throw 'Operating window requires distinct on/off and 1..7 days.' }
        $seenDays=@{}
        foreach ($day in $window.days) { Assert-VxPlanNumber $day 0 6 day -Integer; if ($seenDays.ContainsKey([int]$day)) {throw 'Duplicate operating day.'}; $seenDays[[int]$day]=$true }
    }
    Assert-VxPlanObject $config.profiles @('dry','preheat','cooldown') 'profiles'
    foreach ($name in @('dry','preheat','cooldown')) {
        $profile = $config.profiles.$name
        if ($profile -isnot [array] -or $profile.Count -lt 1 -or $profile.Count -gt 64) { throw "profiles.$name requires 1..64 segments." }
        $previous = $null
        foreach ($segment in $profile) {
            $segmentFields=@('name','from','to','minutes'); if ($null -ne $segment.PSObject.Properties['content']) { $segmentFields+='content'; if ($segment.content -isnot [string] -or $segment.content -cnotin @('White','FromInput')) {throw 'Invalid phase content.'} }
            Assert-VxPlanObject $segment $segmentFields "profiles.$name segment"
            if ($segment.name -isnot [string] -or [string]::IsNullOrWhiteSpace($segment.name) -or $segment.name.Length -gt 128) { throw 'Segment name required (maximum 128 characters).' }
            Assert-VxPlanNumber $segment.from 0 100 from
            Assert-VxPlanNumber $segment.to 0 100 to
            Assert-VxPlanNumber $segment.minutes 0.001 10080 minutes
            if ($null -ne $previous -and [double]$segment.from -ne $previous) { throw "Discontinuous $name profile." }
            if ($name -eq 'cooldown' -and $segment.to -gt $segment.from) { throw 'Cooldown cannot increase brightness.' }
            if ($name -eq 'preheat' -and $segment.to -lt $segment.from) { throw 'Preheat cannot decrease brightness.' }
            $previous = [double]$segment.to
        }
        if ((Get-VxProfileSeconds $profile) -gt 604800) { throw "$name exceeds seven days." }
    }
    if ($config.profiles.dry[0].from -ne $config.idleBrightnessPercent -or $config.profiles.dry[-1].to -ne $config.idleBrightnessPercent -or
        $config.profiles.preheat[0].from -ne $config.idleBrightnessPercent -or $config.profiles.preheat[-1].to -ne $config.operatingBrightnessPercent -or
        $config.profiles.cooldown[0].from -ne $config.operatingBrightnessPercent -or $config.profiles.cooldown[-1].to -ne $config.idleBrightnessPercent) { throw 'Profile endpoints must match idle/operating brightness.' }
    # No expanded command list: each poll interpolates one level, bounded by 64 segments/profile.
    for($day=0;$day -lt 7;$day++) { $null = Get-VxOperatingRequests -Config $config -NowUtc ([DateTimeOffset]::UtcNow.AddDays($day)) }
    return $config
}
function ConvertTo-VxRequestTime($Value, [string]$Name) {
    $parsed = [DateTimeOffset]::MinValue
    if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$' -or
        -not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)) { throw "Invalid ${Name}: explicit ISO timestamp/offset required." }
    return $parsed.ToUniversalTime()
}
function Read-VxRequests {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { if(Test-Path -LiteralPath $Path){throw 'Requests path must be a regular file.'}; return ,@() }
    if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw 'Requests exceed 1 MiB.' }
    $json=Read-VxSharedText -Path $Path
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $document=ConvertFrom-Json -InputObject $json -DateKind String } else { $document=ConvertFrom-Json -InputObject $json }
    Assert-VxPlanObject $document @('schemaVersion','items') requests
    Assert-VxPlanNumber $document.schemaVersion 1 1 schemaVersion -Integer
    if ($document.items -isnot [array] -or $document.items.Count -gt 1000) { throw 'Requests require items array with up to 1000 entries.' }
    $ids = @{}; $active = @()
    foreach ($item in $document.items) {
        Assert-VxPlanObject $item @('id','title','startUtc','endUtc','cancelled') request
        $id = [Guid]::Empty
        if ($item.id -isnot [string] -or -not [Guid]::TryParseExact($item.id,'D',[ref]$id) -or $id -eq [Guid]::Empty -or $ids.ContainsKey($id.ToString())) { throw 'Request id must be a unique nonempty GUID.' }
        $ids[$id.ToString()] = $true
        if ($item.title -isnot [string] -or [string]::IsNullOrWhiteSpace($item.title) -or $item.title.Length -gt 256) { throw 'Request title required (maximum 256 characters).' }
        if ($item.cancelled -isnot [bool]) { throw 'cancelled must be boolean.' }
        $start = ConvertTo-VxRequestTime $item.startUtc startUtc
        $end = ConvertTo-VxRequestTime $item.endUtc endUtc
        if ($end -le $start -or ($end-$start).TotalDays -gt 7) { throw 'Booking duration must be positive and no more than seven days.' }
        if (-not $item.cancelled) { $active += [pscustomobject]@{start=$start; end=$end} }
    }
    $ordered = @($active | Sort-Object start)
    for ($i=1; $i -lt $ordered.Count; $i++) { if ($ordered[$i].start -lt $ordered[$i-1].end) { throw 'Bookings overlap.' } }
    return ,@($document.items)
}
function Get-VxPlanDecision {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [AllowEmptyCollection()][object[]]$Requests=@(), [Parameter(Mandatory)][DateTimeOffset]$NowUtc, [string[]]$CompletedDryKeys=@())
    $preheat = Get-VxProfileSeconds $Config.profiles.preheat
    $candidates=@($Requests | Sort-Object { [DateTimeOffset]$_.startUtc }) + @(Get-VxOperatingRequests -Config $Config -NowUtc $NowUtc)
    $ordered=@($candidates | Sort-Object @{Expression={[DateTimeOffset]$_.startUtc}},@{Expression={$_.id.StartsWith('window:')}})
    # Current usage wins over preparations for a future request/window.
    foreach($wantedMode in @('OPERATING','PREHEAT')) {
        foreach ($item in $ordered) {
            if ($item.cancelled) { continue }
            $start = [DateTimeOffset]$item.startUtc; $end = [DateTimeOffset]$item.endUtc
            if ($NowUtc -ge $start.AddSeconds(-$preheat) -and $NowUtc -lt $end) {
                $mode = if ($NowUtc -lt $start) { 'PREHEAT' } else { 'OPERATING' }
                if($mode -eq $wantedMode){return [pscustomobject]@{mode=$mode; key=('request:'+$item.id); request=$item}}
            }
        }
    }
    $zone = Resolve-VxPlanTimeZone $Config.timeZone
    $local = [TimeZoneInfo]::ConvertTime($NowUtc,$zone)
    $drySeconds = Get-VxProfileSeconds $Config.profiles.dry
    # Look back enough days for a validated (at most seven-day) dry profile crossing midnight.
    for ($day=0; $day -le [Math]::Ceiling($drySeconds/86400.0); $day++) {
        $date = $local.Date.AddDays(-$day)
        foreach ($start in @($Config.dailyStarts | Sort-Object -Descending)) {
            $slotLocal = [DateTime]::SpecifyKind($date.Add([TimeSpan]::ParseExact($start,'hh\:mm',[Globalization.CultureInfo]::InvariantCulture)),[DateTimeKind]::Unspecified)
            if ($zone.IsInvalidTime($slotLocal)) { continue }
            $slotUtc = [DateTimeOffset]([TimeZoneInfo]::ConvertTimeToUtc($slotLocal,$zone))
            $key = $date.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)+':'+$start
            if ($NowUtc -ge $slotUtc -and $NowUtc -lt $slotUtc.AddSeconds($drySeconds) -and $CompletedDryKeys -notcontains $key) { return [pscustomobject]@{mode='DRY';key=$key;request=$null} }
        }
    }
    return [pscustomobject]@{mode='BLACK';key='';request=$null}
}
function Get-VxCooldownProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Profile, [Parameter(Mandatory)][double]$CurrentBrightness)
    Assert-VxPlanNumber $CurrentBrightness 0 100 CurrentBrightness
    # Clip every knot to actual last acknowledged brightness: never jump up to nominal 80%.
    $result = @(foreach ($segment in $Profile) {
        [pscustomobject]@{name=$segment.name;from=[Math]::Min($CurrentBrightness,[double]$segment.from);to=[Math]::Min($CurrentBrightness,[double]$segment.to);minutes=$segment.minutes;content='FromInput'}
    })
    return ,$result
}
function Get-VxOperatingRequests {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][DateTimeOffset]$NowUtc)
    $zone=Resolve-VxPlanTimeZone $Config.timeZone
    $local=[TimeZoneInfo]::ConvertTime($NowUtc,$zone)
    $result=@()
    # Seven-day profile limit also supports intentionally long synthetic/configured preheat.
    $lookAhead=[Math]::Max(1,[Math]::Ceiling((Get-VxProfileSeconds $Config.profiles.preheat)/86400.0))
    for ($day=-1; $day -le $lookAhead; $day++) {
        $date=$local.Date.AddDays($day)
        $index=0
        foreach ($window in $Config.operatingWindows) {
            $index++
            if ($window.days -notcontains [int]$date.DayOfWeek) {continue}
            $start=$date.Add([TimeSpan]::ParseExact($window.start,'hh\:mm',[Globalization.CultureInfo]::InvariantCulture))
            $end=$date.Add([TimeSpan]::ParseExact($window.end,'hh\:mm',[Globalization.CultureInfo]::InvariantCulture))
            if ($end -le $start) {$end=$end.AddDays(1)}
            $start=[DateTime]::SpecifyKind($start,[DateTimeKind]::Unspecified); $end=[DateTime]::SpecifyKind($end,[DateTimeKind]::Unspecified)
            if ($zone.IsInvalidTime($start) -or $zone.IsInvalidTime($end) -or $zone.IsAmbiguousTime($start) -or $zone.IsAmbiguousTime($end)) {throw 'Operating window falls on invalid/ambiguous daylight-saving time.'}
            $result += [pscustomobject]@{id=('window:'+ $date.ToString('yyyy-MM-dd')+':'+$index);title=('Horario '+$window.start+'-'+$window.end);startUtc=([TimeZoneInfo]::ConvertTimeToUtc($start,$zone).ToString('o'));endUtc=([TimeZoneInfo]::ConvertTimeToUtc($end,$zone).ToString('o'));cancelled=$false}
        }
    }
    $sorted=@($result | Sort-Object {[DateTimeOffset]$_.startUtc})
    for($i=1;$i -lt $sorted.Count;$i++){if([DateTimeOffset]$sorted[$i].startUtc -lt [DateTimeOffset]$sorted[$i-1].endUtc){throw 'Operating windows overlap.'}}
    return $sorted
}
Export-ModuleMember -Function Read-VxSharedText,Move-VxAtomicFile,Read-VxPlanConfig,Get-VxProfileSeconds,Get-VxPlanLevel,Read-VxRequests,Get-VxPlanDecision,Get-VxCooldownProfile,Get-VxOperatingRequests
