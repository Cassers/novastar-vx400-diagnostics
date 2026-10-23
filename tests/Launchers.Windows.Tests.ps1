#requires -Version 5.1
# Self-contained native BAT/MOTW regression; only disposable fixture files execute.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){Write-Output 'SKIP launcher Windows integration: Windows PowerShell 5.1, cmd.exe and NTFS ADS required.';exit 0}
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run this regression with native Windows PowerShell 5.1.'}
$policiesBefore=Get-ExecutionPolicy -List|ConvertTo-Json -Compress
if((Get-ExecutionPolicy -Scope MachinePolicy) -ne 'Undefined' -or (Get-ExecutionPolicy -Scope UserPolicy) -ne 'Undefined'){
    throw 'The isolated runner must have undefined Group Policy execution policies so RemoteSigned is effective.'
}
$source=Split-Path $PSScriptRoot -Parent
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('vx-launchers-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temporary)
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cmd=Join-Path $env:SystemRoot 'System32\cmd.exe'
$launchers=@('Abrir-Control-Pro.bat','Abrir-Control-Usuarios.bat','Abrir-Control-NovaStar.bat','Abrir-Control-VX400.bat','Abrir-NovaStar.bat')
$zone="[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://example.invalid/release.zip`r`n"
$utf8=New-Object Text.UTF8Encoding($true)
$children=New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Set-Mark([string]$Path){[IO.File]::WriteAllText(($Path+':Zone.Identifier'),$zone)}
function Get-Mark([string]$Path){Get-Content -LiteralPath $Path -Stream Zone.Identifier -Raw -ErrorAction Stop}
function Test-Mark([string]$Path){$null -ne (Get-Item -LiteralPath $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue)}
function Write-Fixture([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,$utf8);Set-Mark $Path}
function Invoke-Owned([string]$File,[string]$Arguments,[string]$BatPath=''){
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$File;$start.Arguments=$Arguments;$start.WorkingDirectory=$temporary
    $start.EnvironmentVariables['NOVASTAR_PREPARE_ROOT']=$temporary
    if($BatPath){$start.EnvironmentVariables['NOVASTAR_TEST_BAT']=$BatPath}
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $child=New-Object Diagnostics.Process;$child.StartInfo=$start
    $null=$child.Start();$null=$child.Handle;$children.Add($child)
    $child.StandardInput.Close()
    $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
    if(-not $child.WaitForExit(20000)){
        # Retain and use only our exact process handle; never kill by executable name.
        $child.Kill();$null=$child.WaitForExit(3000)
        throw ('Fixture exceeded 20 seconds: '+$File+' '+$Arguments)
    }
    Assert ($stdout.Wait(3000) -and $stderr.Wait(3000)) 'Fixture descendants retained redirected streams.'
    [pscustomobject]@{exitCode=$child.ExitCode;output=$stdout.Result+$stderr.Result}
}
function Invoke-Bat([string]$Path,[string]$Arguments=''){
    # Explorer's cmd boundary, including a caller that has delayed expansion enabled.
    # Expand an environment variable once so the harness does not consume literal
    # %USERNAME% in the BAT path before the launcher's own parsing is exercised.
    Invoke-Owned $cmd ('/D /V:ON /S /C ""%NOVASTAR_TEST_BAT%" '+$Arguments+'"') $Path
}
function New-Fixture([string]$Name){
    $app=Join-Path $temporary ($Name+" app & O'Brien %USERNAME%");$null=[IO.Directory]::CreateDirectory($app)
    foreach($bat in @($launchers)+@('Preparar-NovaStar.bat')){
        Copy-Item -LiteralPath (Join-Path $source $bat) -Destination (Join-Path $app $bat)
        Set-Mark (Join-Path $app $bat)
    }
    $stub=@'
param([string]$MarkerPath,[string]$Sentinel)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Vx400.Schedule.psm1') -Force -ErrorAction Stop
@{entrypoint=$MyInvocation.MyCommand.Name;apartmentState=[Threading.Thread]::CurrentThread.ApartmentState.ToString();sentinel=$Sentinel;moduleValue=(Get-LauncherFixtureValue)}|ConvertTo-Json|Set-Content -LiteralPath $MarkerPath -Encoding UTF8
'@
    Write-Fixture (Join-Path $app 'Control-Vx400.ps1') $stub
    Write-Fixture (Join-Path $app 'Control-VxUsuarios.ps1') $stub
    Write-Fixture (Join-Path $app 'Vx400.Schedule.psm1') "function Get-LauncherFixtureValue { 'fixture-module-imported' };Export-ModuleMember -Function Get-LauncherFixtureValue"
    # Preserve both content and ADS of data, unrelated code, nested and outside files.
    $nested=Join-Path $app 'nested';$null=[IO.Directory]::CreateDirectory($nested)
    $protected=@('plan.config.json','operator.config.json','pro-access.json','unrelated.ps1','nested\Control-Vx400.ps1')
    foreach($name in $protected){Write-Fixture (Join-Path $app $name) ('{"fixture":"'+$name.Replace('\','/')+'"}')}
    $outside=Join-Path $temporary ($Name+' outside Control-Vx400.ps1');Write-Fixture $outside 'outside fixture: must retain MOTW'
    $snapshots=@()
    foreach($path in @($protected|ForEach-Object{Join-Path $app $_})+@($outside)+@(@($launchers)+@('Preparar-NovaStar.bat')|ForEach-Object{Join-Path $app $_})){
        $snapshots+=@{path=$path;hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;zone=(Get-Mark $path)}
    }
    [pscustomobject]@{app=$app;outside=$outside;snapshots=$snapshots}
}
function Assert-Protected($Fixture){
    foreach($snapshot in $Fixture.snapshots){
        Assert ((Get-FileHash -LiteralPath $snapshot.path -Algorithm SHA256).Hash -ceq $snapshot.hash) ('Changed protected content: '+$snapshot.path)
        Assert ((Get-Mark $snapshot.path) -ceq $snapshot.zone) ('Changed out-of-scope MOTW: '+$snapshot.path)
    }
}
function Assert-Launched($Result,[string]$Marker,[string]$Expected,[string]$Sentinel){
    Assert ($Result.exitCode -eq 0) ('BAT failed: '+$Result.output)
    Assert ([IO.File]::Exists($Marker)) ('Entry point did not write marker: '+$Result.output)
    $record=Get-Content -LiteralPath $Marker -Raw|ConvertFrom-Json
    Assert ($record.entrypoint -ceq $Expected) 'Launcher reached wrong entry point.'
    Assert ($record.apartmentState -ceq 'STA') 'Launcher lost Windows Forms STA apartment.'
    Assert ($record.sentinel -ceq $Sentinel) 'Launcher changed forwarded arguments.'
    Assert ($record.moduleValue -ceq 'fixture-module-imported') 'Bundled module was not imported.'
}
try{
    for($index=0;$index -lt $launchers.Count;$index++){
        $launcher=$launchers[$index];$fixture=New-Fixture ('launcher-'+$index)
        $marker=Join-Path $temporary ("marker-"+$index+" & O'Brien.json");$sentinel="argument with spaces & O'Brien"
        $forward='-MarkerPath "'+$marker+'" -Sentinel "'+$sentinel+'"'
        $expected=if($launcher -in @('Abrir-Control-Usuarios.bat','Abrir-NovaStar.bat')){'Control-VxUsuarios.ps1'}else{'Control-Vx400.ps1'}
        $script=Join-Path $fixture.app $expected
        $blocked=Invoke-Owned $exe ('-NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File "'+$script+'" '+$forward)
        Assert ($blocked.exitCode -ne 0 -and -not [IO.File]::Exists($marker)) 'MOTW fixture ineffective: direct RemoteSigned -File must refuse it.'
        Assert (Test-Mark $script) 'Negative control unexpectedly removed MOTW.'
        $result=Invoke-Bat (Join-Path $fixture.app $launcher) $forward
        Assert-Launched $result $marker $expected $sentinel
        foreach($name in @('Control-Vx400.ps1','Control-VxUsuarios.ps1','Vx400.Schedule.psm1')){
            Assert (-not (Test-Mark (Join-Path $fixture.app $name))) ('Bundled code still has MOTW: '+$name)
        }
        Assert-Protected $fixture
        Remove-Item -LiteralPath $marker
        $again=Invoke-Bat (Join-Path $fixture.app $launcher) $forward
        Assert-Launched $again $marker $expected $sentinel
        Assert-Protected $fixture
        Write-Output ('PASS marked download, quoted args, STA, module import, scope and repeated launch: '+$launcher)
    }
    # A missing preflight must fail closed even when the runtime itself is unmarked.
    $missing=New-Fixture 'missing-helper';Remove-Item -LiteralPath (Join-Path $missing.app 'Preparar-NovaStar.bat')
    foreach($name in @('Control-Vx400.ps1','Control-VxUsuarios.ps1','Vx400.Schedule.psm1')){Remove-Item -LiteralPath (Join-Path $missing.app $name) -Stream Zone.Identifier}
    foreach($launcher in $launchers){
        $marker=Join-Path $temporary 'must-not-launch.json'
        $result=Invoke-Bat (Join-Path $missing.app $launcher) ('-MarkerPath "'+$marker+'" -Sentinel unused')
        Assert ($result.exitCode -ne 0 -and -not [IO.File]::Exists($marker)) ('Missing helper did not fail closed: '+$launcher+' '+$result.output)
    }
    Write-Output 'PASS all launchers refuse a missing helper without running the entry point.'
    $linked=New-Fixture 'leaf-link';$leaf=Join-Path $linked.app 'Vx400.Schedule.psm1'
    Remove-Item -LiteralPath $leaf
    $linkCreated=$false
    try{$null=New-Item -ItemType SymbolicLink -Path $leaf -Value $linked.outside -ErrorAction Stop;$linkCreated=$true}catch{Write-Output ('SKIP leaf reparse-point execution check: symbolic-link creation unavailable: '+$_.Exception.Message)}
    if($linkCreated){
        $outsideZone=Get-Mark $linked.outside
        $result=Invoke-Bat (Join-Path $linked.app 'Preparar-NovaStar.bat')
        Assert ($result.exitCode -ne 0) 'Preflight must reject allowlisted leaf reparse points.'
        Assert ((Get-Mark $linked.outside) -ceq $outsideZone) 'Preflight followed a leaf symlink and removed outside MOTW.'
        # Remove the link explicitly before recursive fixture cleanup.
        [IO.File]::Delete($leaf)
        Write-Output 'PASS allowlisted leaf symlink rejected without unblocking its target.'
    }
    Assert ((Get-ExecutionPolicy -List|ConvertTo-Json -Compress) -ceq $policiesBefore) 'Launcher changed global or session execution policy.'
    Write-Output 'PASS native launcher integration; execution policies unchanged; only inert fixture scripts ran.'
}finally{
    foreach($child in $children){try{if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(3000)}}finally{$child.Dispose()}}
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
