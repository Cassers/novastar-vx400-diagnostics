#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Play-VxOperatorMedia.ps1')
Import-Module (Join-Path $root 'Vx400.Schedule.psm1') -Force
$script:passed=0
function Assert-True($Value,[string]$Label){if(-not $Value){throw ('FAIL: '+$Label)};$script:passed++}
function Reject([scriptblock]$Action,[string]$Label){$failed=$false;try{& $Action}catch{$failed=$true};Assert-True $failed $Label}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('vx-media-tests-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temp)
try{
    $folder=Join-Path $temp 'PANTALLA';$null=[IO.Directory]::CreateDirectory($folder)
    $video=Join-Path $folder 'loop.mp4';$image=Join-Path $folder 'NEGRO.png'
    [IO.File]::WriteAllText($video,'validation fixture, not a video')
    [IO.File]::WriteAllText($image,'validation fixture, not an image')
    $config=Join-Path $temp 'operator.config.json'
    $profile=[pscustomobject]@{schemaVersion=1;configured=$true;mediaEnabled=$true;mediaFolder=$folder;videoFile=$video;blackImageFile=$image;screenDeviceName='fixture-screen-explicit';allowPrimaryScreen=$false}
    [IO.File]::WriteAllText($config,($profile|ConvertTo-Json))
    Assert-True ((Read-VxMediaProfile $config).videoFile -eq $video) 'Absolute media inside configured folder accepted without GUI'
    foreach($invalid in @('relative.mp4','https://example.com/video.mp4','\\server\media\x.mp4','file:///tmp/x.mp4')){
        Reject {Assert-VxMediaLocalPath $invalid $folder @('.mp4')} 'Network/relative/URL paths rejected'
    }
    if($env:OS -ne 'Windows_NT'){
        $link=Join-Path $folder 'linked.mp4';$null=New-Item -ItemType SymbolicLink -Path $link -Target $video
        Reject {Assert-VxMediaLocalPath $link $folder @('.mp4')} 'Symbolic link media rejected'
    }
    $outside=Join-Path $temp 'outside.mp4';[IO.File]::WriteAllText($outside,'fixture')
    Reject {Assert-VxMediaLocalPath $outside $folder @('.mp4')} 'Sibling outside configured folder rejected'
    Reject {Assert-VxMediaLocalPath $image $folder @('.mp4')} 'Wrong media extension rejected'
    Reject {Assert-VxMediaLocalPath (Join-Path $folder 'missing.mp4') $folder @('.mp4')} 'Missing file rejected'
    $profile.screenDeviceName='';[IO.File]::WriteAllText($config,($profile|ConvertTo-Json))
    Reject {Read-VxMediaProfile $config} 'Unselected output rejected'
    $profile.screenDeviceName='explicit';$profile.allowPrimaryScreen='false';[IO.File]::WriteAllText($config,($profile|ConvertTo-Json))
    Reject {Read-VxMediaProfile $config} 'Boolean strings rejected'
    $profile.allowPrimaryScreen=$false;$profile.configured=$false;[IO.File]::WriteAllText($config,($profile|ConvertTo-Json))
    Reject {Read-VxMediaProfile $config} 'Unaccepted defaults rejected'
    $profile.configured=$true;$profile.schemaVersion=$true;[IO.File]::WriteAllText($config,($profile|ConvertTo-Json))
    Reject {Read-VxMediaProfile $config} 'Boolean schema rejected'
    $profile.schemaVersion=1;$profile.mediaEnabled=$false;$profile.screenDeviceName='';[IO.File]::WriteAllText($config,($profile|ConvertTo-Json))
    Assert-True (-not (Read-VxMediaProfile $config).mediaEnabled) 'Disabled profile validation needs no output selection'
    $profile.mediaEnabled=$true;$profile.screenDeviceName='fixture-screen-explicit';[IO.File]::WriteAllText($config,($profile|ConvertTo-Json))
    $session=[guid]::NewGuid().ToString();$now=[datetime]::UtcNow
    foreach($mode in @('Video','Black','Input','Stop')){
        $cmd=[pscustomobject]@{schemaVersion=1;id=[guid]::NewGuid().ToString();sessionId=$session;utc=$now.ToString('o');mode=$mode}
        Assert-VxMediaCommand $cmd $session $now @();Assert-True $true 'Typed mode accepted'
    }
    foreach($mutation in @('extra','schema','bool-schema','session','id','mode','stale','future','time','string-version')){
        $cmd=[pscustomobject]@{schemaVersion=1;id=[guid]::NewGuid().ToString();sessionId=$session;utc=$now.ToString('o');mode='Video'}
        switch($mutation){
            'extra'{$cmd|Add-Member NoteProperty executable 'evil.ps1'}
            'schema'{$cmd.schemaVersion=2}
            'bool-schema'{$cmd.schemaVersion=$true}
            'string-version'{$cmd.schemaVersion='1'}
            'session'{$cmd.sessionId=[guid]::NewGuid().ToString()}
            'id'{$cmd.id=[guid]::Empty.ToString()}
            'mode'{$cmd.mode='video'}
            'stale'{$cmd.utc=$now.AddSeconds(-11).ToString('o')}
            'future'{$cmd.utc=$now.AddSeconds(3).ToString('o')}
            'time'{$cmd.utc='FridayZ'}
        }
        Reject {Assert-VxMediaCommand $cmd $session $now @()} ('Malformed command '+$mutation)
    }
    $cmd=[pscustomobject]@{schemaVersion=1;id=[guid]::NewGuid().ToString();sessionId=$session;utc=$now.ToString('o');mode='Video'}
    Reject {Assert-VxMediaCommand $cmd $session $now @($cmd.id)} 'Replay rejected'
    $owner=[pscustomobject]@{schemaVersion=1;sessionId=$session;ownerProcessId=$PID;updatedUtc=$now.ToString('o')}
    Test-VxMediaOwner $owner $session $now;Assert-True $true 'Live matching owner accepted'
    $owner.updatedUtc=$now.AddSeconds(-11).ToString('o');Reject {Test-VxMediaOwner $owner $session $now} 'Stale owner rejected'
    $owner.updatedUtc=$now.ToString('o');Reject {Test-VxMediaOwner $owner ([guid]::NewGuid().ToString()) $now} 'Different engine session rejected'
    $owner.ownerProcessId=2147483647;Reject {Test-VxMediaOwner $owner $session $now} 'Dead owner rejected'
    $statePath=Join-Path $temp 'operator-media-state.json'
    Write-VxMediaState $statePath $cmd.id $session $true 'Video' 'test-only ACK'
    Write-VxMediaState $statePath $cmd.id $session $false 'Video' 'test failure'
    $state=Read-VxSharedText $statePath|ConvertFrom-Json
    Assert-True ($state.id -eq $cmd.id -and $state.sessionId -eq $session -and -not $state.success -and $state.mode -eq 'Video') 'Atomic ACK replacement preserves typed ID/session/error'
    [IO.File]::WriteAllText((Join-Path $temp 'operator-media.json'),($cmd|ConvertTo-Json))
    Reject {& (Join-Path $root 'Play-VxOperatorMedia.ps1') -OperatorConfigPath (Join-Path $temp 'missing-profile.json') -DataDirectory $temp -SessionId $session} 'Startup failure exits without creating output window'
    $failure=Read-VxSharedText $statePath|ConvertFrom-Json
    Assert-True (-not $failure.success -and $failure.sessionId -eq $session -and $failure.id -eq $cmd.id -and $failure.message.Length -gt 0) 'Startup failure publishes same-session error ACK'
    $validation=& (Join-Path $root 'Play-VxOperatorMedia.ps1') -OperatorConfigPath $config -ValidateOnly
    Assert-True $validation.success 'ValidateOnly runs without GUI/engine/session'
    if($env:OS -eq 'Windows_NT'){
        foreach($assembly in @('System.Windows.Forms','System.Drawing','System.Xaml','WindowsBase','PresentationCore','PresentationFramework','WindowsFormsIntegration')){Add-Type -AssemblyName $assembly}
        $refs=@('System.Windows.Forms.Form','System.Drawing.Bitmap','System.Xaml.XamlReader','System.Windows.DependencyObject','System.Windows.Media.MediaPlayer','System.Windows.Controls.MediaElement','System.Windows.Forms.Integration.ElementHost')|ForEach-Object{([type]$_).Assembly.Location}
        Add-Type -Path (Join-Path $root 'Vx.Operator.Media.cs') -ReferencedAssemblies $refs
        Assert-True ($null -ne ([Vx.Operator.MediaWindow].GetConstructor([type[]]@([bool])))) 'Native WPF/WinForms source compiles and exposes preview constructor (no window created)'
        if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run native media tests in Windows PowerShell -STA.'}
        $cover=New-Object Vx.Operator.MediaWindow($true)
        try{
            $cover.Fail('Fixture: unbound output')
            Assert-True (-not $cover.Visible -and -not $cover.Success) 'Failure never occupies an unselected output'
            $cover.BindOutput((New-Object Drawing.Rectangle(40,40,160,100)))
            $cover.Fail('Fixture: decoder failure')
            [Windows.Forms.Application]::DoEvents()
            Assert-True ($cover.Visible -and -not $cover.Success -and $cover.BackColor -eq [Drawing.Color]::Black) 'Decoder failure retains a visible black cover and negative ACK'
            $cover.RevokeOutput()
            Assert-True (-not $cover.Visible) 'Revoked output cannot cover an unauthorized primary screen'
        }finally{$cover.Dispose()}
    }else{Write-Host 'SKIP: Windows framework compilation; no Windows media framework on this host.'}
    Write-Host "PASS: $script:passed operator-media assertions. Codec playback/fullscreen placement intentionally untested."
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
