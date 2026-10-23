#requires -Version 5.1
[CmdletBinding()]
param([string]$OperatorConfigPath,[string]$DataDirectory,[string]$SessionId,[switch]$ValidateOnly,[switch]$SmokeTest)
$ErrorActionPreference='Stop'

function ConvertFrom-VxMediaJson([string]$Text){
    # PS7.5+ otherwise converts ISO JSON strings to DateTime; keep the IPC wire schema.
    if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){return ConvertFrom-Json -InputObject $Text -DateKind String}
    return ConvertFrom-Json -InputObject $Text
}
function Assert-VxMediaLocalPath([string]$Path,[string]$Folder,[string[]]$Extensions,[switch]$Directory) {
    if([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or $Path -match '^[\\/]{2}|^[a-zA-Z]+://' -or $Path -match ':.*:') { throw 'Media paths must be absolute local filesystem paths.' }
    $full=[IO.Path]::GetFullPath($Path)
    if($env:OS -eq 'Windows_NT' -and $full -notmatch '^[a-zA-Z]:\\'){throw 'Media must use a local drive path.'}
    if($Directory){if(-not [IO.Directory]::Exists($full)){throw 'Media folder is missing.'}}
    elseif(-not [IO.File]::Exists($full) -or $Extensions -notcontains [IO.Path]::GetExtension($full).ToLowerInvariant()){throw 'Media file is missing or has an unsupported extension.'}
    if($Folder){
        $prefix=[IO.Path]::GetFullPath($Folder).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Media file must be inside the configured media folder.'}
    }
    $item=Get-Item -LiteralPath $full -Force
    while($null -ne $item){
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Media reparse points, links and junctions are not allowed.'}
        if($item -is [IO.FileInfo]){$item=$item.Directory}else{$item=$item.Parent}
    }
    if($env:OS -eq 'Windows_NT'){
        $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
        if($drive.DriveType -ne [IO.DriveType]::Fixed -and $drive.DriveType -ne [IO.DriveType]::Removable){throw 'Media drive must be local (fixed or removable).'}
    }
    return $full
}
function Read-VxMediaProfile([string]$Path){
    $c=ConvertFrom-VxMediaJson (Read-VxSharedText $Path)
    if($c -isnot [pscustomobject] -or ($c.schemaVersion -isnot [int] -and $c.schemaVersion -isnot [long]) -or $c.schemaVersion -ne 1 -or $c.configured -isnot [bool] -or -not $c.configured){throw 'Save an accepted operator profile in Pro before starting media.'}
    foreach($name in @('mediaEnabled','allowPrimaryScreen')){if($c.$name -isnot [bool]){throw "Invalid operator media boolean: $name."}}
    foreach($name in @('mediaFolder','videoFile','blackImageFile','screenDeviceName')){if($c.$name -isnot [string]){throw "Invalid operator media string: $name."}}
    if(-not $c.mediaEnabled){return $c}
    if([string]::IsNullOrWhiteSpace($c.screenDeviceName)){throw 'Select an output screen explicitly in Pro.'}
    $null=Assert-VxMediaLocalPath $c.mediaFolder '' @() -Directory
    $null=Assert-VxMediaLocalPath $c.videoFile $c.mediaFolder @('.mp4','.wmv','.avi','.m4v','.mov')
    $null=Assert-VxMediaLocalPath $c.blackImageFile $c.mediaFolder @('.png','.jpg','.jpeg','.bmp')
    return $c
}
function Assert-VxMediaCommand($Command,[string]$ExpectedSession,[datetime]$Now,[string[]]$Seen){
    $fields=@('schemaVersion','id','sessionId','utc','mode')
    if($Command -isnot [pscustomobject]){throw 'Media command must be an object.'}
    $actual=@($Command.PSObject.Properties.Name)
    if($actual.Count -ne $fields.Count){throw 'Invalid media command fields.'}
    foreach($field in $actual){if($fields -cnotcontains $field){throw 'Unknown media command field.'}}
    if(($Command.schemaVersion -isnot [int] -and $Command.schemaVersion -isnot [long]) -or $Command.schemaVersion -ne 1){throw 'Invalid media schema.'}
    $id=[guid]::Empty;$session=[guid]::Empty
    if($Command.id -isnot [string] -or -not [guid]::TryParseExact($Command.id,'D',[ref]$id) -or $id -eq [guid]::Empty -or $Seen -contains $Command.id){throw 'Invalid/replayed media command ID.'}
    if($Command.sessionId -isnot [string] -or -not [guid]::TryParseExact($Command.sessionId,'D',[ref]$session) -or $Command.sessionId -cne $ExpectedSession){throw 'Media session mismatch.'}
    if(@('Video','Black','Input','Stop') -cnotcontains $Command.mode){throw 'Invalid media mode.'}
    $utc=[datetimeoffset]::MinValue
    if($Command.utc -isnot [string] -or $Command.utc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|\+00:00)$' -or -not [datetimeoffset]::TryParse($Command.utc,[ref]$utc)){throw 'Invalid UTC media timestamp.'}
    $age=($Now.ToUniversalTime()-$utc.UtcDateTime).TotalSeconds
    if($age -gt 10 -or $age -lt -2){throw 'Media command is stale or future dated.'}
}
function Get-VxMediaSessionCommand($Command,[string]$ExpectedSession,[datetime]$Now,[string[]]$Seen){
    # Old owners may leave Stop/Black on disk. Ignore only a well-formed foreign session
    # UUID; validate every current-session command with the unchanged strict validator.
    $foreign=[guid]::Empty
    if($Command -is [pscustomobject] -and $null -ne $Command.PSObject.Properties['sessionId'] -and
       $Command.sessionId -is [string] -and [guid]::TryParseExact($Command.sessionId,'D',[ref]$foreign) -and
       $foreign -ne [guid]::Empty -and $Command.sessionId -cne $ExpectedSession){return $null}
    Assert-VxMediaCommand $Command $ExpectedSession $Now $Seen
    return $Command
}
function Test-VxMediaOwner($State,[string]$ExpectedSession,[datetime]$Now){
    if($null -eq $State -or $State.sessionId -cne $ExpectedSession -or ($State.schemaVersion -isnot [int] -and $State.schemaVersion -isnot [long]) -or $State.schemaVersion -ne 1){throw 'Media owner session mismatch.'}
    $utc=[datetimeoffset]::MinValue
    if(-not [datetimeoffset]::TryParse([string]$State.updatedUtc,[ref]$utc) -or ($Now.ToUniversalTime()-$utc.UtcDateTime).TotalSeconds -gt 10 -or ($utc.UtcDateTime-$Now.ToUniversalTime()).TotalSeconds -gt 2){throw 'Media owner heartbeat is stale.'}
    if(($State.ownerProcessId -isnot [int] -and $State.ownerProcessId -isnot [long]) -or [int]$State.ownerProcessId -le 0){throw 'Invalid media owner PID.'}
    $null=Get-Process -Id ([int]$State.ownerProcessId) -ErrorAction Stop
}
function Write-VxMediaState([string]$Path,[string]$Id,[string]$Session,[bool]$Success,[string]$Mode,[string]$Message){
    $state=[ordered]@{schemaVersion=1;id=$Id;sessionId=$Session;updatedUtc=[datetime]::UtcNow.ToString('o');success=$Success;mode=$Mode;message=$Message}
    $temp=$Path+'.'+$PID+'.tmp'
    try{[IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)));Move-VxAtomicFile $temp $Path}
    finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
# Dot-source exposes pure validation functions without loading GUI assemblies or running a process.
if($MyInvocation.InvocationName -eq '.'){return}
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force
if(-not $OperatorConfigPath){$OperatorConfigPath=Join-Path $PSScriptRoot 'operator.config.json'}
if($ValidateOnly){$profile=Read-VxMediaProfile $OperatorConfigPath;[pscustomobject]@{success=$true;mediaEnabled=$profile.mediaEnabled;message='Paths/profile validated; screen availability and decoding require Windows session acceptance.'};return}
if(-not $DataDirectory -or -not [IO.Directory]::Exists($DataDirectory)){throw 'An existing engine DataDirectory is required.'}
$guid=[guid]::Empty
if(-not [guid]::TryParseExact($SessionId,'D',[ref]$guid) -or $guid -eq [guid]::Empty){throw 'A nonempty engine session UUID is required.'}
$statePath=Join-Path $DataDirectory 'operator-media-state.json'
$id=[guid]::Empty.ToString();$mode='Input';$window=$null;$mutex=$null;$owns=$false
try{
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($DataDirectory).ToLowerInvariant()))).Replace('-','')}finally{$hash.Dispose()}
    $mutex=New-Object Threading.Mutex($false,('Local\VxOperatorMedia_'+$key))
    try{$owns=$mutex.WaitOne(3000)}catch [Threading.AbandonedMutexException]{$owns=$true}
    if(-not $owns){throw 'A media helper already owns this data directory.'}
    $initialPath=Join-Path $DataDirectory 'operator-media.json'
    if([IO.File]::Exists($initialPath)){
        $initial=ConvertFrom-VxMediaJson (Read-VxSharedText $initialPath)
        $initial=Get-VxMediaSessionCommand $initial $SessionId ([datetime]::UtcNow) @()
        if($null -ne $initial){$id=$initial.id;$mode=$initial.mode}
    }
    if($env:OS -ne 'Windows_NT' -or -not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0){throw 'Media requires an interactive Windows session.'}
    if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Start media helper with Windows PowerShell -STA.'}
    $profile=Read-VxMediaProfile $OperatorConfigPath
    if(-not $profile.mediaEnabled){throw 'Media output is disabled in Pro.'}
    try{
        foreach($assembly in @('System.Windows.Forms','System.Drawing','System.Xaml','WindowsBase','PresentationCore','PresentationFramework','WindowsFormsIntegration')){Add-Type -AssemblyName $assembly}
        $refs=@('System.Windows.Forms.Form','System.Drawing.Bitmap','System.Xaml.XamlReader','System.Windows.DependencyObject','System.Windows.Media.MediaPlayer','System.Windows.Controls.MediaElement','System.Windows.Forms.Integration.ElementHost')|ForEach-Object{([type]$_).Assembly.Location}
        Add-Type -Path (Join-Path $PSScriptRoot 'Vx.Operator.Media.cs') -ReferencedAssemblies $refs
    }catch{throw ('Windows native WPF media components unavailable. Enable the Windows media feature through your administrator; no player/codecs were installed. '+$_.Exception.Message)}
    $window=New-Object Vx.Operator.MediaWindow([bool]$SmokeTest)
    if($SmokeTest){
        $window.BindOutput((New-Object Drawing.Rectangle(40,40,320,180)))
        $window.Output('Black',$profile.videoFile,$profile.blackImageFile)
        $until=[datetime]::UtcNow.AddSeconds(1)
        while([datetime]::UtcNow -lt $until){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
        [pscustomobject]@{success=$window.Success;message='Disposable image preview/native binding completed. Video codecs and physical screen placement unverified.'};return
    }
    $seen=New-Object 'Collections.Generic.List[string]';$rawLast='';$lastPublish=[datetime]::MinValue;$lastCheck=[datetime]::MinValue
    while($true){
        [Windows.Forms.Application]::DoEvents()
        $now=[datetime]::UtcNow
        if(($now-$lastCheck).TotalSeconds -ge 1){
            Test-VxMediaOwner (ConvertFrom-VxMediaJson (Read-VxSharedText (Join-Path $DataDirectory 'operator-state.json'))) $SessionId $now
            $screen=@([Windows.Forms.Screen]::AllScreens|Where-Object{$_.DeviceName -ceq $profile.screenDeviceName})
            if($screen.Count -ne 1 -or ($screen[0].Primary -and -not $profile.allowPrimaryScreen)){throw 'Configured output unavailable or primary screen not authorized.'}
            $window.BindOutput($screen[0].Bounds)
            $null=Assert-VxMediaLocalPath $profile.videoFile $profile.mediaFolder @('.mp4','.wmv','.avi','.m4v','.mov')
            $null=Assert-VxMediaLocalPath $profile.blackImageFile $profile.mediaFolder @('.png','.jpg','.jpeg','.bmp')
            $lastCheck=$now
        }
        $commandPath=Join-Path $DataDirectory 'operator-media.json'
        if([IO.File]::Exists($commandPath)){
            $raw=Read-VxSharedText $commandPath
            if($raw -cne $rawLast){
                $command=ConvertFrom-VxMediaJson $raw
                $command=Get-VxMediaSessionCommand $command $SessionId $now $seen.ToArray()
                if($null -eq $command){$rawLast=$raw;continue}
                $id=$command.id;$mode=$command.mode;$rawLast=$raw;$seen.Add($id)
                if($seen.Count -gt 512){$seen.RemoveAt(0)}
                $window.Output($mode,$profile.videoFile,$profile.blackImageFile);$lastPublish=[datetime]::MinValue
                if($mode -eq 'Stop'){Write-VxMediaState $statePath $id $SessionId $true $mode 'Stopped.';break}
            }
        }
        $window.PollPlayback()
        if(($now-$lastPublish).TotalSeconds -ge 1 -and -not ($mode -eq 'Video' -and -not $window.Success -and $window.Message -like 'Opening *')){Write-VxMediaState $statePath $id $SessionId $window.Success $mode $window.Message;$lastPublish=$now}
        # A decoder failure keeps a visible black cover and a negative ACK. The owner
        # can acknowledge blackout and send a new Black/Input command after review.
        Start-Sleep -Milliseconds 100
    }
}catch{
    $message=$_.Exception.Message
    if($null -ne $window){
        try{
            $safeScreen=@([Windows.Forms.Screen]::AllScreens|Where-Object{$_.DeviceName -ceq $profile.screenDeviceName -and (-not $_.Primary -or $profile.allowPrimaryScreen)})
            if($safeScreen.Count -eq 1){$window.BindOutput($safeScreen[0].Bounds)}else{$window.RevokeOutput()}
        }catch{$window.RevokeOutput()}
        $window.Fail($message)
    }
    if($owns){try{Write-VxMediaState $statePath $id $SessionId $false $mode $message}catch{}}
    if($null -ne $window -and -not $SmokeTest){
        # A fatal helper error must not uncover the desktop before hardware blackout
        # is acknowledged. A dead owner leaves the black cover until a new owner
        # confirms blackout or the exact child is stopped during explicit recovery.
        while($true){
            [Windows.Forms.Application]::DoEvents()
            try{
                $safeScreen=@([Windows.Forms.Screen]::AllScreens|Where-Object{$_.DeviceName -ceq $profile.screenDeviceName -and (-not $_.Primary -or $profile.allowPrimaryScreen)})
                if($safeScreen.Count -eq 1){$window.BindOutput($safeScreen[0].Bounds);$window.Fail($message)}else{$window.RevokeOutput()}
            }catch{$window.RevokeOutput()}
            try{
                $owner=ConvertFrom-VxMediaJson (Read-VxSharedText (Join-Path $DataDirectory 'operator-state.json'))
                $stamp=[DateTimeOffset]::MinValue
                $fresh=[DateTimeOffset]::TryParse([string]$owner.updatedUtc,[ref]$stamp) -and ([DateTimeOffset]::UtcNow-$stamp).TotalSeconds -ge -2 -and ([DateTimeOffset]::UtcNow-$stamp).TotalSeconds -le 10
                if($fresh -and $null -ne $owner.PSObject.Properties['outputBlackoutConfirmed'] -and $owner.outputBlackoutConfirmed -is [bool] -and $owner.outputBlackoutConfirmed){break}
                $pending=ConvertFrom-VxMediaJson (Read-VxSharedText (Join-Path $DataDirectory 'operator-media.json'))
                $pending=Get-VxMediaSessionCommand $pending $SessionId ([datetime]::UtcNow) @()
                if($null -ne $pending -and $pending.mode -ceq 'Stop'){break}
            }catch{# Keep covering output when owner/command cannot be verified.
            }
            try{Write-VxMediaState $statePath $id $SessionId $false $mode $message}catch{}
            Start-Sleep -Milliseconds 100
        }
    }
    throw
}finally{
    if($null -ne $window){$window.Dispose()}
    if($owns){$mutex.ReleaseMutex()}
    if($null -ne $mutex){$mutex.Dispose()}
}
