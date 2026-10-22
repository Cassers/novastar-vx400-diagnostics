#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'GUI smoke requires Windows PowerShell 5.1 and Windows Forms.'}
$root=Split-Path $PSScriptRoot -Parent
if([string]::IsNullOrWhiteSpace($OutputDirectory)){
    $temporaryRoot=if([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){[IO.Path]::GetTempPath()}else{$env:RUNNER_TEMP}
    $OutputDirectory=Join-Path $temporaryRoot 'vx400-gui'
}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('vx400-gui-test-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$files=@('Control-Vx400.ps1','Vx400.Schedule.psm1','Vx.Connection.psm1','Vx400.Protocol.psm1','plan.config.json')
$hashes=@{}
foreach($name in $files){$hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash}
try{
    foreach($name in $files){Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $fixture $name)}
    $sentinel=Join-Path $fixture 'unexpected-controller-run.txt'
    # These stubs make accidental controller/installer launches observable and remain hardware-free.
    $stub="[IO.File]::WriteAllText('$($sentinel.Replace("'","''"))','Unexpected launch'); exit 97"
    [IO.File]::WriteAllText((Join-Path $fixture 'Watch-Vx400Plan.ps1'),$stub,(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText((Join-Path $fixture 'Install-Vx400Control.ps1'),$stub,(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText((Join-Path $fixture 'Set-Vx400Manual.ps1'),$stub,(New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText((Join-Path $fixture 'Recover-Vx400.ps1'),$stub,(New-Object Text.UTF8Encoding($true)))
    $config=Join-Path $fixture 'plan.config.json'
    $data=Join-Path $fixture 'never-write-real-data'
    $before=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output=& $powershell -NoProfile -STA -ExecutionPolicy RemoteSigned -File (Join-Path $fixture 'Control-Vx400.ps1') -ConfigPath $config -DataDirectory $data -SmokeTest -ScreenshotPath $OutputDirectory 2>&1
    $output|Out-File -LiteralPath (Join-Path $OutputDirectory 'smoke-output.txt') -Encoding UTF8
    if($LASTEXITCODE -ne 0){throw ('GUI smoke failed: '+($output -join [Environment]::NewLine))}
    if(Test-Path -LiteralPath $sentinel){throw 'Smoke launched a controller or installer.'}
    if(Test-Path -LiteralPath $data){throw 'Smoke wrote to the supplied real data directory.'}
    if((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -ne $before){throw 'Smoke changed the supplied configuration.'}
    Add-Type -AssemblyName System.Drawing
    foreach($name in @('00-Estado.png','01-Horarios.png','02-Secuencias.png','03-Solicitudes.png','04-Control-manual.png','05-Registro.png')){
        $path=Join-Path $OutputDirectory $name
        if(-not (Test-Path -LiteralPath $path)){throw "Missing screenshot $name"}
        $bitmap=[Drawing.Image]::FromFile($path)
        # Windows can constrain the requested minimum to its desktop working area (1044 x 788 in CI).
        try{if($bitmap.Width -lt 1000 -or $bitmap.Height -lt 650){throw "Unexpected screenshot dimensions: $name ($($bitmap.Width)x$($bitmap.Height))"}}finally{$bitmap.Dispose()}
    }
    foreach($name in $files){if((Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash -ne $hashes[$name]){throw "Source modified by smoke: $name"}}
    Write-Output ($output -join [Environment]::NewLine)
    Write-Output ('Screenshots: '+$OutputDirectory)
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
