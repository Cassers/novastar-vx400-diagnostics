#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$DataDirectory = '',
    [switch]$EnableSequence,
    [switch]$ValidateOnly,
    [ValidateRange(0,1000000)][int]$MaxPolls = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'watcher.config.json' }
if ([string]::IsNullOrWhiteSpace($DataDirectory)) { $DataDirectory = Join-Path $PSScriptRoot 'watcher-data' }
Import-Module (Join-Path $PSScriptRoot 'Vx400.Automation.psm1') -Force
try {
    $config = Read-VxWatcherConfig -Path $ConfigPath -EnableSequence:$EnableSequence
} catch { Write-Error $_ -ErrorAction Continue; exit 2 }
if ($ValidateOnly) {
    Write-Output ('Configuration valid. Mode: ' + $(if ($EnableSequence) { 'SEQUENCE' } else { 'MONITOR (read only)' }))
    exit 0
}
Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1') -Force
$utf8 = New-Object Text.UTF8Encoding($false)
$script:sequenceNumber = 0
$script:writeAttempted = $false
$script:trusted = $false
$script:lastReadTimestamp = 0L
$script:lastReadUtc = [DateTime]::MinValue
$script:status = [ordered]@{
    schemaVersion=1; mode=$(if ($EnableSequence) {'sequence'} else {'monitor'})
    deviceAddress=$config.deviceAddress; tcpPort=$config.tcpPort
    state='iniciando'; communication='unknown'; stage=$null; brightnessRequested=$null
    needsCycle=[bool]$EnableSequence; lastSuccessfulReadUtc=$null; lastEvent=$null; updatedUtc=$null
    notice='Communication is not electrical power or moisture measurement. No physical fail-closed guarantee.'
}
$mutex = $null; $ownsMutex = $false; $fileLock = $null
$exitCode = 0

function Save-VxState {
    $script:status.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $temporary = Join-Path $DataDirectory 'estado.json.tmp'
    $destination = Join-Path $DataDirectory 'estado.json'
    [IO.File]::WriteAllText($temporary,($script:status | ConvertTo-Json -Depth 8),$utf8)
    if ([IO.File]::Exists($destination)) { [IO.File]::Replace($temporary,$destination,[NullString]::Value) }
    else { [IO.File]::Move($temporary,$destination) }
}
function Write-VxEvent([string]$Name, [string]$Detail) {
    $log = Join-Path $DataDirectory 'eventos.jsonl'
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -ge 1048576) {
        for ($i=4; $i -ge 1; $i--) {
            $old = "$log.$i"
            if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination "$log.$($i+1)" -Force }
        }
        Move-Item -LiteralPath $log -Destination "$log.1" -Force
    }
    $entry = [ordered]@{utc=[DateTime]::UtcNow.ToString('o'); event=$Name; detail=$Detail; state=$script:status.state}
    [IO.File]::AppendAllText($log,(($entry | ConvertTo-Json -Compress) + [Environment]::NewLine),$utf8)
    $script:status.lastEvent = $entry
    Save-VxState
    Write-Host ($entry.utc + ' ' + $Name + ' - ' + $Detail)
}
function Send-VxPacket([byte[]]$Packet) {
    $exchangeTimer = [Diagnostics.Stopwatch]::StartNew()
    $before = [DateTime]::UtcNow
    $result = Invoke-VxExchange -DeviceAddress $config.deviceAddress -TcpPort $config.tcpPort -Request $Packet -TimeoutMs $config.timeoutMs
    if ($exchangeTimer.Elapsed.TotalSeconds -gt $config.maximumObservationGapSeconds -or
        ([DateTime]::UtcNow-$before).TotalSeconds -gt $config.maximumObservationGapSeconds) {
        throw 'Long observation gap during exchange; command result uncertain.'
    }
    return $result
}
function Get-VxSequenceNumber {
    $script:sequenceNumber = ($script:sequenceNumber + 1) % 256
    return [byte]$script:sequenceNumber
}
function Assert-VxFreshObservation {
    $age = ([Diagnostics.Stopwatch]::GetTimestamp()-$script:lastReadTimestamp)/[double][Diagnostics.Stopwatch]::Frequency
    if ($age -gt $config.maximumObservationGapSeconds -or
        ([DateTime]::UtcNow-$script:lastReadUtc).TotalSeconds -gt $config.maximumObservationGapSeconds) {
        throw 'Last successful observation is stale; do not advance a stage after a pause.'
    }
}
function Set-VxDisplay([string]$Mode, [switch]$Recovery) {
    if (-not $Recovery) { Assert-VxFreshObservation }
    $script:writeAttempted = $true # A missing ACK does not mean the command was not applied.
    $null = Send-VxPacket (New-VxDisplayRequest -Mode $Mode -Sequence (Get-VxSequenceNumber))
}
function Set-VxBrightness([double]$Percent, [switch]$Recovery) {
    if (-not $Recovery) { Assert-VxFreshObservation }
    $script:writeAttempted = $true
    $value = [byte][Math]::Floor($Percent*255.0/100.0)
    $null = Send-VxPacket (New-VxBrightnessRequest -Value $value -Sequence (Get-VxSequenceNumber))
    $script:status.brightnessRequested = $Percent
}
function Try-VxDark {
    # Independent attempts; logging/storage errors must never prevent these attempts.
    if ($EnableSequence -and $script:trusted) {
        try { Set-VxDisplay 'Blackout' -Recovery } catch { Write-Warning ('Blackout unconfirmed: '+$_.Exception.Message) }
        try { Set-VxBrightness 0 -Recovery } catch { Write-Warning ('Zero brightness unconfirmed: '+$_.Exception.Message) }
    }
}

try {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $endpointHash = [BitConverter]::ToString($hash.ComputeHash($utf8.GetBytes("$($config.deviceAddress):$($config.tcpPort)"))).Replace('-','') }
    finally { $hash.Dispose() }
    $prefix = if ($env:OS -eq 'Windows_NT') { 'Global\' } else { '' }
    $mutex = New-Object Threading.Mutex($false,($prefix+'NovaStarVX400-'+$endpointHash))
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another watcher owns this endpoint. Stop it before starting another instance.' }
    $null = New-Item -ItemType Directory -Path $DataDirectory -Force
    $fileLock = [IO.File]::Open((Join-Path $DataDirectory 'watcher.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    Write-VxEvent 'iniciado' 'First connection and every recovery require a complete new cycle in sequence mode.'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    [double]$lastLoopFinished = 0
    $lastLoopUtc = [DateTime]::UtcNow
    [double]$lastStateSave = 0
    [double]$stageStarted = 0
    [int]$stageIndex = -1
    [int]$failures = 0; [int]$successes = 0; [int]$polls = 0
    $connected = $false; $everConnected = $false; $offlineMarked = $false
    $active = $false; $faultLatched = $false
    $script:status.state = 'esperando'
    while ($MaxPolls -eq 0 -or $polls -lt $MaxPolls) {
        $polls++
        if (($clock.Elapsed.TotalSeconds-$lastLoopFinished) -gt $config.maximumObservationGapSeconds -or
            ([DateTime]::UtcNow-$lastLoopUtc).TotalSeconds -gt $config.maximumObservationGapSeconds) {
            Try-VxDark
            $active=$false; $connected=$false; $successes=0; $stageIndex=-1
            $script:status.needsCycle=[bool]$EnableSequence; $script:status.stage=$null
            $failures=0; $offlineMarked=$false
            if (-not $faultLatched) { $script:status.state='esperando' }
            $script:status.communication='unknown'
            Write-VxEvent 'observacion_interrumpida' 'Long process gap/suspend: discard elapsed stage time; require full cycle.'
        }
        $readError = $null
        try {
            $reply = Send-VxPacket (New-VxReadRequest -Address 2 -Length 2 -Sequence (Get-VxSequenceNumber))
            if ([BitConverter]::ToUInt16($reply.Payload,0) -ne 0x6211) {
                $script:trusted = $false
                throw 'ModelID differs from VX400 0x6211; no writes allowed.'
            }
            $script:lastReadTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
            $script:lastReadUtc = [DateTime]::UtcNow
        } catch { $readError = $_.Exception.Message }
        if ($null -ne $readError) {
            $failures++; $successes=0
            if ($failures -eq 1) {
                $active=$false; $connected=$false; $stageIndex=-1
                $script:status.needsCycle=[bool]$EnableSequence; $script:status.stage=$null
                $script:status.communication='uncertain'
                if (-not $faultLatched) { $script:status.state='esperando' }
                Try-VxDark
                Write-VxEvent 'sondeo_fallido' $readError
            }
            if ($failures -ge $config.offlineFailures -and -not $offlineMarked) {
                $offlineMarked=$true; $script:status.communication='unreachable'
                if (-not $faultLatched) { $script:status.state='sin_comunicacion' }
                Write-VxEvent 'sin_comunicacion' 'Consecutive failed protocol reads. Power-off or network problem; electrical state unknown.'
            }
        } else {
            $script:trusted=$true; $failures=0; $successes++
            $script:status.lastSuccessfulReadUtc=[DateTime]::UtcNow.ToString('o')
            if (-not $connected -and $successes -ge $config.onlineSuccesses) {
                $connected=$true; $offlineMarked=$false; $script:status.communication='reachable'
                if (-not $faultLatched) { $script:status.state='conectado' }
                $eventName = if ($everConnected) { 'comunicacion_recuperada' } else { 'conexion_inicial' }
                Write-VxEvent $eventName 'Stable valid VX400 ModelID replies; panel power and moisture remain unknown.'
                $everConnected=$true
            }
            if ($connected -and $EnableSequence -and -not $faultLatched) {
                try {
                    if ($script:status.needsCycle -and -not $active) {
                        Write-VxEvent 'inicio_ciclo' 'Blackout then first brightness before selected pattern; no skipped stages.'
                        Set-VxDisplay 'Blackout'
                        Set-VxBrightness $config.sequence.stages[0].brightnessPercent
                        if ($config.sequence.pattern -eq 'White') { Set-VxDisplay 'White' } else { Set-VxDisplay 'Normal' }
                        $stageIndex=0; $active=$true
                        $stageStarted=$clock.Elapsed.TotalSeconds
                        $script:status.state='acondicionando'; $script:status.stage=1
                        Write-VxEvent 'etapa' ('1: '+$config.sequence.stages[0].brightnessPercent+'%; '+$config.sequence.stages[0].durationSeconds+'s')
                    } elseif ($active -and ($clock.Elapsed.TotalSeconds-$stageStarted) -ge $config.sequence.stages[$stageIndex].durationSeconds) {
                        if (($stageIndex+1) -lt @($config.sequence.stages).Count) {
                            $stageIndex++
                            Set-VxBrightness $config.sequence.stages[$stageIndex].brightnessPercent
                            $stageStarted=$clock.Elapsed.TotalSeconds
                            $script:status.stage=$stageIndex+1
                            Write-VxEvent 'etapa' (($stageIndex+1).ToString()+': '+$config.sequence.stages[$stageIndex].brightnessPercent+'%; '+$config.sequence.stages[$stageIndex].durationSeconds+'s')
                        } else {
                            Set-VxDisplay 'Blackout'
                            Set-VxBrightness $config.sequence.normalBrightnessPercent
                            Set-VxDisplay 'Normal'
                            $active=$false; $script:status.needsCycle=$false
                            $script:status.stage=$null; $script:status.state='contenido'
                            Write-VxEvent 'ciclo_completado' 'Normal mode requested; this does not certify optical output or dehumidification.'
                        }
                    }
                } catch {
                    $faultLatched=$true; $active=$false
                    $script:status.needsCycle=$true; $script:status.state='fallo'
                    Try-VxDark
                    Write-VxEvent 'fallo_secuencia' ($_.Exception.Message+'; manual inspection and process restart required.')
                }
            }
        }
        if (($clock.Elapsed.TotalSeconds-$lastStateSave) -ge 60) { Save-VxState; $lastStateSave=$clock.Elapsed.TotalSeconds }
        $lastLoopFinished=$clock.Elapsed.TotalSeconds
        $lastLoopUtc=[DateTime]::UtcNow
        if ($MaxPolls -eq 0 -or $polls -lt $MaxPolls) { Start-Sleep -Milliseconds ([int]($config.pollIntervalSeconds*1000)) }
    }
    if ($faultLatched) { $exitCode=2 }
} catch {
    $exitCode=2
    Try-VxDark
    $script:status.state='fallo'
    if ($null -ne $fileLock) {
        try { Write-VxEvent 'fallo_proceso' $_.Exception.Message } catch { Write-Warning ('Cannot persist failure: '+$_.Exception.Message) }
    }
    Write-Error $_ -ErrorAction Continue
} finally {
    # Forced termination/power loss can bypass finally; physical startup protection remains essential.
    if ($script:writeAttempted) { Try-VxDark }
    if ($null -ne $fileLock) {
        if ($exitCode -eq 0) { $script:status.state='detenido' }
        try { Write-VxEvent 'detenido' 'Process ended; any requested blackout/zero is best effort.' } catch { $exitCode=2 }
        $fileLock.Dispose()
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
exit $exitCode
