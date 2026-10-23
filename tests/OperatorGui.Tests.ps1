#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'Operator GUI tests require Windows PowerShell 5.1 / WinForms.'}
$root=Split-Path $PSScriptRoot -Parent
if(-not $OutputDirectory){$temporaryRoot=if($env:RUNNER_TEMP){$env:RUNNER_TEMP}else{[IO.Path]::GetTempPath()};$OutputDirectory=Join-Path $temporaryRoot 'vx-operator-gui'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory);$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('vx-user-gui-test-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($fixture)
$files=@('Control-VxUsuarios.ps1','Configurar-VxUsuarios.ps1','Vx.Operator.psm1','Vx400.Schedule.psm1','Vx400.Ownership.psm1','Vx.Connection.psm1','Vx400.Protocol.psm1','Play-VxOperatorMedia.ps1','plan.config.json','operator.config.json')
$hashes=@{}
try{
    foreach($name in $files){$hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash;Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $fixture $name)}
    $sentinel=Join-Path $fixture 'unexpected-launch.txt'
    # These are sentinels, never media playback substitutes: any accidental launch fails.
    $stub="[IO.File]::WriteAllText('$($sentinel.Replace("'","''"))','Unexpected process launch');exit 97"
    foreach($name in @('Watch-VxOperator.ps1','Recover-VxOperatorUi.ps1','Install-Vx400Control.ps1','Install-VxUsuariosStartup.ps1','Export-VxUsuarios.ps1')){[IO.File]::WriteAllText((Join-Path $fixture $name),$stub,(New-Object Text.UTF8Encoding($true)))}
    $mediaPath=Join-Path $fixture 'Play-VxOperatorMedia.ps1'
    $media=[IO.File]::ReadAllText($mediaPath);$pureGuard="if(`$MyInvocation.InvocationName -eq '.'){return}"
    if(-not $media.Contains($pureGuard)){throw 'Media pure-validation entrypoint guard changed; review fixture sentinel.'}
    [IO.File]::WriteAllText($mediaPath,$media.Replace($pureGuard,($pureGuard+[Environment]::NewLine+$stub)),(New-Object Text.UTF8Encoding($true)))
    $plan=Join-Path $fixture 'plan.config.json';$profile=Join-Path $fixture 'operator.config.json';$data=Join-Path $fixture 'never-touch-real-data'
    $beforePlan=(Get-FileHash -LiteralPath $plan).Hash;$beforeProfile=(Get-FileHash -LiteralPath $profile).Hash
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach($scriptName in @('Control-VxUsuarios.ps1','Configurar-VxUsuarios.ps1')){
        $output=& $exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File (Join-Path $fixture $scriptName) -ConfigPath $plan -OperatorConfigPath $profile -DataDirectory $data -SmokeTest -ScreenshotPath $OutputDirectory 2>&1
        $output|Out-File -LiteralPath (Join-Path $OutputDirectory ($scriptName+'.txt')) -Encoding UTF8
        if($LASTEXITCODE -ne 0){throw ($scriptName+' failed: '+($output -join [Environment]::NewLine))}
        if(($output -join ' ') -notmatch 'PASS Operator'){throw ($scriptName+' did not report smoke completion.')}
    }
    if([IO.File]::Exists($sentinel)){throw 'Smoke launched an engine, player, recovery, export or installer.'}
    if([IO.Directory]::Exists($data)){throw 'Smoke wrote to supplied real data directory.'}
    if((Get-FileHash -LiteralPath $plan).Hash -ne $beforePlan -or (Get-FileHash -LiteralPath $profile).Hash -ne $beforeProfile){throw 'Smoke mutated supplied configurations.'}
    Add-Type -AssemblyName System.Drawing
    foreach($name in @('usuarios.png','config-0.png','config-1.png','config-2.png','config-3.png')){
        $path=Join-Path $OutputDirectory $name;if(-not [IO.File]::Exists($path)){throw ('Missing screenshot: '+$name)}
        $bitmap=[Drawing.Image]::FromFile($path)
        try{if($bitmap.Width -lt 900 -or $bitmap.Height -lt 650){throw ('Screenshot too small: '+$name)}}finally{$bitmap.Dispose()}
    }
    foreach($name in $files){if((Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash -ne $hashes[$name]){throw ('Source modified by smoke: '+$name)}}
    Write-Output 'PASS Operator native GUI smoke: command gates, stale owner, pending ACK, typed commands, profile roundtrip, invalid save preservation, acceptance, lock exclusion, screenshots, zero engine launches.'
    Write-Output ('Screenshots: '+$OutputDirectory)
}finally{if([IO.Directory]::Exists($fixture)){Remove-Item -LiteralPath $fixture -Recurse -Force}}
