#requires -Version 5.1
# Run on Windows: powershell.exe -NoProfile -STA -File tests\ProAccessGui.Tests.ps1
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){Write-Host 'SKIP: Pro native GUI requires Windows -STA';exit 0}
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'Run this native GUI test with -STA.'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Vx.ProAccess.psm1') -Force
$module=Get-Module Vx.ProAccess
$script:passed=0
$captureBase=if($env:RUNNER_TEMP){$env:RUNNER_TEMP}else{[IO.Path]::GetTempPath()}
$captureDirectory=Join-Path $captureBase 'vx-pro-access-gui'
$null=[IO.Directory]::CreateDirectory($captureDirectory)
function Assert($value,$label){if(-not $value){throw "FAIL $label"};$script:passed++}
function Save($object,$file){[IO.File]::WriteAllText($file,($object|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
function NativeRun($entries,[scriptblock]$action) {
    $state=@{queue=[Collections.Queue]::new();seen=$null;error=$null;ticks=0;masks=0}
    foreach($entry in $entries){$state.queue.Enqueue($entry)}
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=100
    $tick={
        $state.ticks++
        if($state.ticks -gt 200){
            $state.error='Native interaction timed out.'
            foreach($open in @([Windows.Forms.Application]::OpenForms)){
                $open.DialogResult=[Windows.Forms.DialogResult]::Cancel;$open.Close()
            }
            return
        }
        $form=[Windows.Forms.Application]::OpenForms['VxProAccessDialog']
        if($null -eq $form -or [object]::ReferenceEquals($state.seen,$form)){return}
        $state.seen=$form
        try {
            if($state.queue.Count -eq 0){throw 'Unexpected native dialog.'}
            $entry=$state.queue.Dequeue()
            $hasNew=$null -ne $form.Controls['NewPassword']
            if($hasNew -ne ($entry.mode -eq 'Change')){throw 'Wrong native dialog mode.'}
            foreach($name in @('CurrentPassword','NewPassword','ConfirmPassword')){
                $box=$form.Controls[$name]
                if($null -ne $box){
                    if(-not $box.UseSystemPasswordChar){throw 'Unmasked password field.'}
                    $state.masks++
                    if($entry.ContainsKey($name)){$box.Text=$entry[$name]}
                }
            }
            if($entry.ContainsKey('error') -and $form.Controls['ErrorText'].Text -notlike $entry.error){throw 'Expected inline error missing.'}
            $form.Refresh()
            $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
            try {
                $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
                $imagePath=Join-Path $captureDirectory ($entry.mode+'-'+[Guid]::NewGuid().ToString('N')+'.png')
                $bitmap.Save($imagePath,[Drawing.Imaging.ImageFormat]::Png)
            } finally {$bitmap.Dispose()}
            if($entry.cancel){$form.Controls['Cancel'].PerformClick()}else{$form.Controls['Submit'].PerformClick()}
        } catch {$state.error=$_.Exception.Message;$form.DialogResult=[Windows.Forms.DialogResult]::Cancel;$form.Close()}
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    try {
        $timer.Start();$result=& $action
        if($state.error){throw $state.error}
        Assert ($state.queue.Count -eq 0) 'Native interaction queue consumed'
        Assert ($state.masks -gt 0) 'Native password fields masked'
        return $result
    } finally {$timer.Stop();$timer.Remove_Tick($tick);$timer.Dispose()}
}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('vx-pro-gui-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($directory);$path=Join-Path $directory 'pro-access.json'
$password=ConvertTo-SecureString 'native-initial-secret-2026' -AsPlainText -Force
$replacement=ConvertTo-SecureString 'native-replaced-secret-2026' -AsPlainText -Force
try {
    $policy=New-VxProAccessPolicy -Password $password;Save $policy $path
    $result=NativeRun @(@{mode='Login';cancel=$true}) {Request-VxProAccess $path}
    Assert (-not $result) 'Native login cancel denied'
    $result=NativeRun @(@{mode='Login';cancel=$false;CurrentPassword='native-wrong-secret-2026'},@{mode='Login';cancel=$true;error='*incorrecta*'}) {Request-VxProAccess $path}
    Assert (-not $result) 'Native incorrect login cannot enter'
    $result=NativeRun @(@{mode='Login';cancel=$false;CurrentPassword='native-initial-secret-2026'}) {Request-VxProAccess $path}
    Assert $result 'Native correct login grants'
    Assert (Request-VxProAccess $path) 'Native same process cache returns without dialog'
    $policy=New-VxProAccessPolicy -Password $password -RequireChange;Save $policy $path
    $original=[IO.File]::ReadAllText($path)
    $result=NativeRun @(@{mode='Login';cancel=$false;CurrentPassword='native-initial-secret-2026'},@{mode='Change';cancel=$true;error='*temporal*'}) {Request-VxProAccess $path}
    Assert (-not $result) 'Native forced change cancel denies'
    Assert ([IO.File]::ReadAllText($path) -ceq $original) 'Native canceled change leaves policy untouched'
    $result=NativeRun @(@{mode='Change';cancel=$false;CurrentPassword='native-initial-secret-2026';NewPassword='native-replaced-secret-2026';ConfirmPassword='native-mismatch-secret-2026'},@{mode='Change';cancel=$true;error='*confirmacion*'}) {Request-VxProPasswordChange $path}
    Assert (-not $result) 'Native confirmation mismatch denied'
    Assert ([IO.File]::ReadAllText($path) -ceq $original) 'Native mismatch leaves policy untouched'
    $result=NativeRun @(@{mode='Change';cancel=$false;CurrentPassword='native-initial-secret-2026';NewPassword='native-initial-secret-2026';ConfirmPassword='native-initial-secret-2026'},@{mode='Change';cancel=$true;error='*diferente*'}) {Request-VxProPasswordChange $path}
    Assert (-not $result) 'Native same password denied'
    $result=NativeRun @(@{mode='Login';cancel=$false;CurrentPassword='native-initial-secret-2026'},@{mode='Change';cancel=$false;CurrentPassword='native-initial-secret-2026';NewPassword='native-replaced-secret-2026';ConfirmPassword='native-replaced-secret-2026'}) {Request-VxProAccess $path}
    Assert $result 'Native forced first change grants only after save'
    $changed=Read-VxProAccessPolicy $path
    Assert (-not $changed.requireChange -and (Test-VxProPassword $changed $replacement) -and -not (Test-VxProPassword $changed $password)) 'Native new secret replaces temporary secret'
    # Invoke actual entrypoints with valid auth fixtures and deliberately unusable configs.
    # Cancellation must return before config parsing, controller construction or hardware access.
    $planPath=Join-Path $directory 'plan.config.json';$profilePath=Join-Path $directory 'operator.config.json'
    [IO.File]::WriteAllText($planPath,'{}');[IO.File]::WriteAllText($profilePath,'{}')
    $dataPath=Join-Path $directory 'untouched-data'
    $originalPolicy=[IO.File]::ReadAllText($path)
    foreach($entrypoint in @('Control-Vx400.ps1','Configurar-VxUsuarios.ps1')){
        & $module {$script:proGrants=@{}}
        $entryPath=Join-Path $root $entrypoint
        $result=NativeRun @(@{mode='Login';cancel=$true}) {& $entryPath -ConfigPath $planPath -DataDirectory $dataPath}
        Assert ([Windows.Forms.Application]::OpenForms.Count -eq 0) "Canceled $entrypoint opens no protected form"
        Assert ([IO.File]::ReadAllText($planPath) -ceq '{}' -and [IO.File]::ReadAllText($profilePath) -ceq '{}') "Canceled $entrypoint preserves configs"
        Assert ([IO.File]::ReadAllText($path) -ceq $originalPolicy -and -not [IO.Directory]::Exists($dataPath)) "Canceled $entrypoint has no policy or engine mutation"
    }
    Write-Host "PASS: $script:passed native Pro GUI assertions"
} finally {
    $password.Dispose();$replacement.Dispose()
    Remove-Item $directory -Recurse -Force
}
