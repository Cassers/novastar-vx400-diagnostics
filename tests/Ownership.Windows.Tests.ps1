#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){Write-Output 'SKIP ownership Windows integration: CIM/Windows process handles unavailable.';exit 0}
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Las pruebas de cierre de procesos se ejecutan solo en el runner desechable de GitHub Actions.'}
Import-Module (Join-Path $PSScriptRoot '../Vx400.Ownership.psm1') -Force
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('vx-ownership-win-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temporary)
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$children=@()
function Assert($Condition,[string]$Name){if(-not $Condition){throw $Name}}
function Start-Fixture([string]$Name,[string]$Data){
    $selectedConfig=if($Name -eq 'Watch-Vx400.ps1'){$legacyConfig}else{$config}
    $scriptFile=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('../'+$Name)))
    $arguments='-NoProfile -ExecutionPolicy RemoteSigned -File "'+$scriptFile+'" -ConfigPath "'+$selectedConfig+'" -DataDirectory "'+$Data+'" -MaxPolls 100000'
    $child=Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $null=$child.Handle
    $script:children+=$child
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(-not (Test-Path -LiteralPath (Join-Path $Data 'estado.json')) -and [DateTime]::UtcNow -lt $deadline){if($child.HasExited){throw 'Fixture exited early.'};Start-Sleep -Milliseconds 100}
    Assert (Test-Path -LiteralPath (Join-Path $Data 'estado.json')) fixturestarted
    return $child
}
try{
    # No server. Default MONITOR mode; only refused loopback reads, never display writes.
    $config=Join-Path $temporary 'config.json'
    $document=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../plan.config.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $document.deviceAddress='127.0.0.1';$document.tcpPort=65530;$document.pollIntervalSeconds=.5;$document.timeoutMs=250
    [IO.File]::WriteAllText($config,($document|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding($true)))
    $legacyConfig=Join-Path $temporary 'watcher.config.json'
    $legacyDocument=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../watcher.config.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $legacyDocument.deviceAddress='127.0.0.1';$legacyDocument.tcpPort=65530;$legacyDocument.pollIntervalSeconds=.5;$legacyDocument.timeoutMs=250
    [IO.File]::WriteAllText($legacyConfig,($legacyDocument|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding($true)))
    $data=Join-Path $temporary 'plan';$child=Start-Fixture 'Watch-Vx400Plan.ps1' $data
    $owners=@(Find-VxControllers '127.0.0.1:65530' $exe)
    Assert (@($owners|Where-Object{$_.processId -eq $child.Id}).Count -eq 1) realchildidentified
    $result=Invoke-VxOwnershipRecovery -ConfigPath $config -DataDirectory $data
    Assert ($result.success -and -not $result.needsForce) graceful
    Assert $child.WaitForExit(3000) gracefulexit
    $legacyData=Join-Path $temporary 'legacy';$legacy=Start-Fixture 'Watch-Vx400.ps1' $legacyData
    $result=Invoke-VxOwnershipRecovery -ConfigPath $config -DataDirectory $legacyData
    Assert ($result.needsForce -and -not $result.success -and -not $legacy.HasExited) noimplicitforce
    $snapshot=Join-Path $temporary 'reviewed.json';[IO.File]::WriteAllText($snapshot,($result|ConvertTo-Json -Depth 8))
    $invalid=Invoke-VxOwnershipRecovery -ConfigPath $config -DataDirectory $legacyData -Force
    Assert (-not $invalid.success -and -not $legacy.HasExited) forcerequiressnapshot
    # A second genuine owner with different PID/creation must not inherit old approval.
    # The genuine engine prevents simultaneous owners; release only our held test child,
    # then launch a different genuine child to simulate owner replacement/PID change.
    $legacy.Kill();$null=$legacy.WaitForExit(3000)
    $replacementData=Join-Path $temporary 'replacement';$replacement=Start-Fixture 'Watch-Vx400.ps1' $replacementData
    $changed=Invoke-VxOwnershipRecovery -ConfigPath $config -DataDirectory $legacyData -Force -ExpectedOwnersPath $snapshot
    Assert ($changed.needsForce -and -not $replacement.HasExited) changedsnapshot
    [IO.File]::WriteAllText($snapshot,($changed|ConvertTo-Json -Depth 8))
    $forced=Invoke-VxOwnershipRecovery -ConfigPath $config -DataDirectory $legacyData -Force -ExpectedOwnersPath $snapshot
    Assert ($forced.success -and $forced.mutexAvailable) forceverified
    Assert ($legacy.WaitForExit(3000) -and $replacement.WaitForExit(3000)) forceexited
    Write-Output 'PASS ownership Windows integration: genuine children, graceful stop, reviewed force, changed-owner refusal, mutex release. No device writes.'
}finally{
    foreach($child in $children){try{if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(3000)}}finally{$child.Dispose()}}
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
