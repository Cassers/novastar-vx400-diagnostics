#requires -Version 5.1
# Native qualification: real entrypoints, real password dialogs, no SmokeTest/auth mocks.
# powershell.exe -NoProfile -STA -File tests\ProStartup.Windows.Tests.ps1
[CmdletBinding()]
param([switch]$Worker,[string]$FixtureDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){Write-Host 'SKIP: real Pro startup requires native Windows PowerShell 5.1 -STA';exit 0}
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'Run with native Windows PowerShell 5.1.'}

# A parent process bounds even failures before a message loop or a native MessageBox.
if(-not $Worker){
    $temporary=Join-Path ([IO.Path]::GetTempPath()) ('vx-pro-startup-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($temporary)
    $child=$null
    try{
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $output=Join-Path $temporary 'worker.out';$errors=Join-Path $temporary 'worker.err'
        $arguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File "{0}" -Worker -FixtureDirectory "{1}"' -f $PSCommandPath,$temporary
        $child=Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -RedirectStandardOutput $output -RedirectStandardError $errors
        $null=$child.Handle
        $timedOut=-not $child.WaitForExit(45000)
        if($timedOut){$child.Kill();$child.WaitForExit()}
        $child.WaitForExit()
        $captured=if([IO.File]::Exists($output)){[IO.File]::ReadAllText($output)}else{''}
        Write-Host $captured
        if($timedOut){throw ('Real Pro startup exceeded its 45-second process watchdog. '+[IO.File]::ReadAllText($errors))}
        if($child.ExitCode -ne 0){throw ('Real Pro startup failed: '+[IO.File]::ReadAllText($errors))}
        if($captured -notmatch 'PASS: \d+ real Pro startup assertions'){throw 'Worker exited without completing real Pro startup assertions.'}
    }finally{
        if($null -ne $child){if(-not $child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
        # An outer watchdog can interrupt worker finally; retain identity of its only child.
        $ownedPath=Join-Path $temporary 'duplicate-process.json'
        if([IO.File]::Exists($ownedPath)){
            $owned=Get-Content -LiteralPath $ownedPath -Raw|ConvertFrom-Json
            $duplicateProcess=Get-Process -Id $owned.id -ErrorAction SilentlyContinue
            if($null -ne $duplicateProcess){
                try{
                    if($duplicateProcess.StartTime.ToUniversalTime().Ticks -eq [long]$owned.startedUtcTicks){
                        if(-not $duplicateProcess.HasExited){$duplicateProcess.Kill();$duplicateProcess.WaitForExit()}
                    }
                }finally{$duplicateProcess.Dispose()}
            }
        }
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
    exit 0
}
if([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA){throw 'Worker requires -STA.'}
if(-not [IO.Directory]::Exists($FixtureDirectory)){throw 'Parent fixture directory missing.'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root=Split-Path $PSScriptRoot -Parent
$runtime=Join-Path $FixtureDirectory 'runtime';$null=[IO.Directory]::CreateDirectory($runtime)
$script:sentinel=Join-Path $FixtureDirectory 'unexpected-launch.txt'
$script:passed=0
function Assert($Condition,[string]$Label){if(-not $Condition){throw ('FAIL: '+$Label)};$script:passed++}
function Write-Json($Value,[string]$Path){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))}

# Copy the complete shipped runtime, never its private policy. Only fixture copies are guarded.
Import-Module (Join-Path $root 'Vx.Operator.Deployment.psm1') -Force
$package=@(Get-VxUserPackageFiles)
foreach($name in $package){Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $runtime $name)}
foreach($name in @('plan.config.json','operator.config.json')){Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $runtime $name)}
$planPath=Join-Path $runtime 'plan.config.json';$profilePath=Join-Path $runtime 'operator.config.json'
$policyPath=Join-Path $runtime 'pro-access.json';$data=Join-Path $FixtureDirectory 'isolated-data'
$plan=Get-Content -LiteralPath $planPath -Raw|ConvertFrom-Json
$plan.connectionType='Ethernet';$plan.deviceAddress='127.0.0.1';$plan.tcpPort=9
Write-Json $plan $planPath
$profile=Get-Content -LiteralPath $profilePath -Raw|ConvertFrom-Json
$profile.mediaEnabled=$false;Write-Json $profile $profilePath
$planBefore=(Get-FileHash -LiteralPath $planPath).Hash;$profileBefore=(Get-FileHash -LiteralPath $profilePath).Hash

# Defense in depth: prohibit process launch and hardware transports, including module calls.
$fatal="[IO.File]::AppendAllText('"+$script:sentinel.Replace("'","''")+"', 'Unexpected launch or hardware call'+[Environment]::NewLine);throw 'Forbidden test hardware/process entrypoint.'"
foreach($name in $package){
    if([IO.Path]::GetExtension($name) -eq '.ps1' -and $name -notin @('Control-Vx400.ps1','Configurar-VxUsuarios.ps1','Play-VxOperatorMedia.ps1')){
        [IO.File]::WriteAllText((Join-Path $runtime $name),$fatal)
    }
}
# Configurator dot-sources pure validators; preserve them and its real dot-source return.
$mediaPath=Join-Path $runtime 'Play-VxOperatorMedia.ps1'
$media=[IO.File]::ReadAllText($mediaPath)
$guard="if(`$MyInvocation.InvocationName -eq '.'){return}"
$guardIndex=$media.IndexOf($guard,[StringComparison]::Ordinal)
Assert ($guardIndex -ge 0) 'Media validator dot-source guard exists'
[IO.File]::WriteAllText($mediaPath,$media.Substring(0,$guardIndex)+$guard+[Environment]::NewLine+$fatal,[Text.UTF8Encoding]::new($true))
foreach($entry in @(
    @{file='Vx400.Protocol.psm1';functions=@('Invoke-VxExchange')},
    @{file='Vx.Connection.psm1';functions=@('Invoke-VxConfiguredExchange')},
    @{file='Vx.Usb.psm1';functions=@('Get-VxUsbDevices','Invoke-VxUsbExchange')},
    @{file='Vx400.Ownership.psm1';functions=@('Invoke-VxOwnershipRecovery')}
)){
    foreach($name in $entry.functions){[IO.File]::AppendAllText((Join-Path $runtime $entry.file),([Environment]::NewLine+'function '+$name+' {'+$fatal+'}'+[Environment]::NewLine+'Export-ModuleMember -Function '+$name+[Environment]::NewLine))}
}
function Start-Process { [IO.File]::AppendAllText($script:sentinel,'Unexpected Start-Process');throw 'Pro startup must not launch a process.' }

Import-Module (Join-Path $runtime 'Vx.ProAccess.psm1') -Force
# These are public, disposable test values, unrelated to the distributed private key.
$initialText='fixture-temporary-key-2026';$changedText='fixture-changed-key-2026'
$initial=ConvertTo-SecureString $initialText -AsPlainText -Force
$changed=ConvertTo-SecureString $changedText -AsPlainText -Force

function Get-NativeTabs($Control){
    if($Control -is [Windows.Forms.TabControl]){return ,$Control}
    foreach($childControl in $Control.Controls){Get-NativeTabs $childControl}
}
function Close-OwnedForms {
    # All OpenForms here belong to this disposable worker, never the user's process.
    foreach($open in @([Windows.Forms.Application]::OpenForms)){
        if($open.Name -eq 'VxProAccessDialog'){$open.DialogResult=[Windows.Forms.DialogResult]::Cancel}
        $open.Close()
    }
}
function Invoke-NativeStartup([string]$Entrypoint,$Steps,[string]$TitlePattern,[int]$ExpectedTabs,[switch]$TestDuplicate){
    Assert ([Windows.Forms.Application]::OpenForms.Count -eq 0) 'Worker starts without open forms'
    $state=@{queue=[Collections.Queue]::new();seen=$null;error='';trace=[Collections.Generic.List[string]]::new();mainSeen=$false;mainSince=$null;watch=[Diagnostics.Stopwatch]::StartNew();duplicate=$null;duplicateSince=$null;duplicateDone=$false}
    $duplicateOutput=Join-Path $FixtureDirectory 'duplicate.out';$duplicateError=Join-Path $FixtureDirectory 'duplicate.err'
    foreach($step in $Steps){$state.queue.Enqueue($step)}
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=100
    $tick={
        try{
            if($state.watch.Elapsed.TotalSeconds -ge 35){throw 'Native Forms watchdog expired.'}
            $dialog=[Windows.Forms.Application]::OpenForms['VxProAccessDialog']
            if($null -ne $dialog){
                if([object]::ReferenceEquals($state.seen,$dialog)){return}
                $state.seen=$dialog
                $mode=if($null -ne $dialog.Controls['NewPassword']){'Change'}else{'Login'}
                $label=[string]$dialog.Controls['ErrorText'].Text
                $state.trace.Add($mode+': '+$label)
                Write-Host ('Native '+$Entrypoint+' dialog '+$mode+': '+$label)
                if($state.mainSeen -or $state.queue.Count -eq 0){throw ('Unexpected auth dialog: '+$mode+' '+$label)}
                $step=$state.queue.Dequeue()
                if($mode -cne $step.mode){throw ('Expected '+$step.mode+', received '+$mode)}
                if($step.mode -eq 'Change' -and $label -notlike '*temporal*'){throw 'Forced temporary-password explanation missing.'}
                if($step.mode -eq 'Login' -and $label){throw ('Unexpected login error: '+$label)}
                foreach($name in @('CurrentPassword','NewPassword','ConfirmPassword')){
                    $box=$dialog.Controls[$name]
                    if($null -ne $box){
                        if(-not $box.UseSystemPasswordChar){throw ('Unmasked '+$name)}
                        $box.Text=$step[$name]
                    }
                }
                $dialog.Controls['Submit'].PerformClick()
                return
            }
            foreach($open in @([Windows.Forms.Application]::OpenForms)){
                if($open.Text -notlike $TitlePattern){throw ('Unexpected window: '+$open.Text)}
                if($state.queue.Count -ne 0){throw 'Protected main form opened before the required auth steps.'}
                $tabs=@(Get-NativeTabs $open)
                if($tabs.Count -ne 1 -or $tabs[0].TabPages.Count -ne $ExpectedTabs){throw ('Wrong real main tab count: '+$ExpectedTabs)}
                if(-not $open.Visible){throw 'Main form is not visible.'}
                if(-not $state.mainSeen){$state.mainSeen=$true;$state.mainSince=$state.watch.Elapsed.TotalSeconds}
                if($TestDuplicate -and -not $state.duplicateDone){
                    if($null -eq $state.duplicate){
                        $open.WindowState=[Windows.Forms.FormWindowState]::Minimized
                        if($open.WindowState -ne [Windows.Forms.FormWindowState]::Minimized){throw 'Could not minimize the original Pro.'}
                        $duplicateExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                        $duplicateArguments='-NoProfile -STA -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}" -DataDirectory "{2}"' -f (Join-Path $runtime $Entrypoint),$planPath,$data
                        # Test-owned process only: application launches still hit the fatal wrapper.
                        $state.duplicate=Microsoft.PowerShell.Management\Start-Process -FilePath $duplicateExe -ArgumentList $duplicateArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $duplicateOutput -RedirectStandardError $duplicateError
                        $null=$state.duplicate.Handle
                        Write-Json @{id=$state.duplicate.Id;startedUtcTicks=$state.duplicate.StartTime.ToUniversalTime().Ticks} (Join-Path $FixtureDirectory 'duplicate-process.json')
                        $state.duplicateSince=$state.watch.Elapsed.TotalSeconds
                        return
                    }
                    if(($state.watch.Elapsed.TotalSeconds-$state.duplicateSince) -ge 10){throw 'Duplicate Pro did not exit and restore the original window within 10 seconds (possible second password prompt).'}
                    if(-not $state.duplicate.HasExited){return}
                    $state.duplicate.WaitForExit()
                    $detail=[IO.File]::ReadAllText($duplicateError)
                    if($state.duplicate.ExitCode -ne 0){throw ('Duplicate Pro failed: '+$detail)}
                    if($detail.Trim()){throw ('Duplicate Pro emitted an error: '+$detail)}
                    if($open.WindowState -eq [Windows.Forms.FormWindowState]::Minimized){return}
                    if([Windows.Forms.Application]::OpenForms.Count -ne 1){throw 'Duplicate activation opened an extra local form.'}
                    $state.duplicateDone=$true
                    Write-Host 'Native duplicate Pro exited without credentials and restored the original unlocked window.'
                    $state.mainSince=$state.watch.Elapsed.TotalSeconds
                }
                # Observe the normal Pro UI timer (>1s), including any unintended engine start.
                if(($state.watch.Elapsed.TotalSeconds-$state.mainSince) -ge 1.5){$open.Close()}
            }
        }catch{
            $state.error=$_.Exception.Message
            Close-OwnedForms
        }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    try{
        $timer.Start()
        # Actual entrypoint invocation: intentionally no SmokeTest or grant injection.
        & (Join-Path $runtime $Entrypoint) -ConfigPath $planPath -DataDirectory $data
        if($state.error){throw ($state.error+'; dialogs: '+($state.trace -join ' | '))}
        Assert $state.mainSeen ($Entrypoint+' reached its real protected main form')
        Assert ($state.queue.Count -eq 0) ($Entrypoint+' consumed every real auth step')
        if($TestDuplicate){Assert $state.duplicateDone 'Second real Pro launch restored the existing unlocked form without another login'}
        Assert ([Windows.Forms.Application]::OpenForms.Count -eq 0) ($Entrypoint+' closed cleanly')
        Assert (-not [IO.File]::Exists($script:sentinel)) ($Entrypoint+' never launched an engine/player/installer or hardware call')
    }finally{
        $timer.Stop();$timer.Remove_Tick($tick);$timer.Dispose();Close-OwnedForms
        if($null -ne $state.duplicate){
            if(-not $state.duplicate.HasExited){$state.duplicate.Kill();$state.duplicate.WaitForExit()}
            $state.duplicate.Dispose()
        }
    }
}
try{
    Write-Json (New-VxProAccessPolicy -Password $initial -RequireChange) $policyPath
    $policyBefore=(Get-FileHash -LiteralPath $policyPath).Hash
    Invoke-NativeStartup 'Control-Vx400.ps1' @(
        @{mode='Login';CurrentPassword=$initialText},
        @{mode='Change';CurrentPassword=$initialText;NewPassword=$changedText;ConfirmPassword=$changedText}
    ) '*Pro v0.8.2' 6 -TestDuplicate
    $policy=Read-VxProAccessPolicy $policyPath
    Assert (-not $policy.requireChange) 'Real first login saved the required key change'
    Assert (-not (Test-VxProPassword $policy $initial)) 'Temporary fixture key no longer authenticates'
    Assert (Test-VxProPassword $policy $changed) 'Replacement fixture key authenticates'
    Assert ((Get-FileHash -LiteralPath $policyPath).Hash -cne $policyBefore) 'Policy persisted the real key change'
    $policyAfter=(Get-FileHash -LiteralPath $policyPath).Hash
    # Reproduce reopening Pro with the changed key and a cold auth module.
    Remove-Module Vx.ProAccess -Force
    Invoke-NativeStartup 'Control-Vx400.ps1' @(@{mode='Login';CurrentPassword=$changedText}) '*Pro v0.8.2' 6
    Assert ((Get-FileHash -LiteralPath $policyPath).Hash -ceq $policyAfter) 'Reopened Pro preserves the replacement policy'
    # Drop the real module to remove its process grant; standalone configurator must prompt.
    Remove-Module Vx.ProAccess -Force -ErrorAction SilentlyContinue
    Invoke-NativeStartup 'Configurar-VxUsuarios.ps1' @(@{mode='Login';CurrentPassword=$changedText}) 'Pro * Configurar Usuarios' 4
    Assert ((Get-FileHash -LiteralPath $policyPath).Hash -ceq $policyAfter) 'Standalone login preserves the replacement policy'
    Assert ((Get-FileHash -LiteralPath $planPath).Hash -ceq $planBefore) 'Opening real Pro preserves the plan byte for byte'
    Assert ((Get-FileHash -LiteralPath $profilePath).Hash -ceq $profileBefore) 'Opening both real forms preserves the user profile byte for byte'
    Assert (-not [IO.File]::Exists($script:sentinel)) 'All process/hardware sentinels remained untouched'
    Write-Host "PASS: $script:passed real Pro startup assertions (native WinPS5.1, temporary password -> required change -> 6-tab Pro -> cold changed-key Pro -> fresh login -> 4-tab configurator; no hardware)."
}finally{$initial.Dispose();$changed.Dispose();Remove-Module Vx.ProAccess -Force -ErrorAction SilentlyContinue}
