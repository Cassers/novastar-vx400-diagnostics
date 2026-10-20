#requires -Version 5.1
# Pure planning tests. Values are synthetic and are NEVER sent to a controller.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Vx400.Automation.psm1') -Force
$path = Join-Path ([IO.Path]::GetTempPath()) ('vx400-ramp-'+[Guid]::NewGuid().ToString('N')+'.json')
$script:checks = 0
function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Save-Config($Config) { $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8 }
function Assert-Rejected($Config,[string]$Message) {
    Save-Config $Config
    $failed=$false
    try { $null = Read-VxWatcherConfig -Path $path -EnableSequence } catch { $failed=$true }
    Assert-True $failed $Message
}
try {
    $config = Get-Content (Join-Path $root 'watcher.config.json') -Raw | ConvertFrom-Json
    Assert-Rejected $config 'Shipped profile must stay disabled.'
    $config.sequence.approved=$true
    $config.sequence.panelPowerCouplingVerified=$true
    $config.sequence.startupProtectionVerified=$true
    $config.sequence.curveReference='SIMULATOR ONLY: synthetic math fixture, no thermal recommendation'
    $config.sequence.normalBrightnessPercent=30
    Assert-Rejected $config 'Unknown starting brightness must block live mode.'
    $config.sequence.ramp.startBrightnessPercent=5
    Save-Config $config
    $plan = Read-VxWatcherConfig -Path $path -EnableSequence
    Assert-True (@($plan.sequence.stages).Count -eq 140) '70-minute/30-second ramp should have 140 intervals.'
    Assert-True ($plan.sequence.stages[0].brightnessPercent -eq 5) 'First interval must start at configured brightness.'
    $total=0.0; $last=-1.0
    foreach ($stage in $plan.sequence.stages) {
        if ($stage.brightnessPercent -lt $last -or $stage.brightnessPercent -ge 30) { throw 'Ramp must increase below its final endpoint.' }
        $last=$stage.brightnessPercent; $total+=$stage.durationSeconds
    }
    Assert-True ([Math]::Abs($total-4200) -lt 0.001) 'Ramp intervals must total 70 minutes.'
    Assert-True ([Math]::Abs(($plan.sequence.stages[-1].brightnessPercent+25.0/140)-30) -lt 0.00001) 'Final command must be the last equal increment.'
    Assert-True ($plan.sequence.normalBrightnessPercent -eq 30) 'Ramp must end at configured normal brightness.'
    $config.sequence.stages=@([pscustomobject]@{brightnessPercent=5; durationSeconds=1})
    Assert-Rejected $config 'Ramp and explicit stages must not silently override each other.'
    $config.sequence.stages=@()
    $config.sequence.ramp.startBrightnessPercent=30
    Assert-Rejected $config 'Constant/descending ramp must be rejected.'
    $config.sequence.ramp.startBrightnessPercent=29.99
    Assert-Rejected $config 'Sub-hardware-level ramp must be rejected.'
    $config.sequence.ramp.startBrightnessPercent=5
    $config.sequence.ramp.durationMinutes=10080
    $config.sequence.ramp.stepSeconds=1
    Save-Config $config
    $bounded = Read-VxWatcherConfig -Path $path -EnableSequence
    Assert-True (@($bounded.sequence.stages).Count -eq 256) 'Ramp expansion must be bounded.'
    $config.sequence.ramp.durationMinutes=0
    Assert-Rejected $config 'Zero duration must be rejected.'
    $config.sequence.ramp.enabled=$false
    $config.sequence.stages=@([pscustomobject]@{brightnessPercent=5;durationSeconds=1})
    $config.sequence.PSObject.Properties.Remove('ramp')
    Save-Config $config
    $legacy=Read-VxWatcherConfig -Path $path -EnableSequence
    Assert-True (@($legacy.sequence.stages).Count -eq 1) 'Existing explicit-stage profiles must remain compatible.'
    Write-Output "PASS: $script:checks ramp planning assertions (no network)."
} finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
