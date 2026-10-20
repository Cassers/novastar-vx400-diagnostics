#requires -Version 5.1
<#
.SYNOPSIS
Diagnostico VX400 original. Solo lectura salvo -EnableActiveTests.
.DESCRIPTION
No actualiza firmware, no envia comandos de guardado en flash y no programa
deshumidificacion. El firmware observado en NovaLCT no es su version de software.
#>
[CmdletBinding()]
param(
    [string]$DeviceAddress,
    [ValidateRange(1,65535)][int]$TcpPort = 5200,
    [ValidateRange(250,15000)][int]$TimeoutMs = 4000,
    [string]$OutputDirectory,
    [switch]$InventoryOnly,
    [switch]$CaptureNovaLctHardwareInfo,
    [string]$HardwareInfoTextFile,
    [string]$ObservedControllerFirmware,
    [string]$ObservedReceiverFirmware,
    [string]$ReceiverModel = 'MRV412',
    [switch]$AssumeLatestFirmware,
    [switch]$EnableActiveTests,
    [ValidateRange(-1,20)][int]$TestBrightness = -1,
    [ValidateSet('None','Blackout','White')][string]$TestPattern = 'None',
    [ValidateRange(-1,100)][int]$RestoreBrightness = -1,
    [ValidateSet('','Normal','Blackout')][string]$RestoreMode = '',
    [ValidateRange(1,10)][int]$HoldSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Vx400.Protocol.psm1') -Force

if (-not $InventoryOnly -and [string]::IsNullOrWhiteSpace($DeviceAddress)) {
    $DeviceAddress = Read-Host 'IP del puerto CONTROL del VX400 (Enter = solo inventario)'
    if ([string]::IsNullOrWhiteSpace($DeviceAddress)) { $InventoryOnly = $true }
}
$hasActiveRequest = ($TestBrightness -ge 0 -or $TestPattern -ne 'None')
if ($hasActiveRequest -and -not $EnableActiveTests) {
    throw 'Las pruebas activas requieren -EnableActiveTests. Sin ese parametro no se envia nada.'
}
if ($EnableActiveTests -and (-not $hasActiveRequest -or $InventoryOnly -or
    $RestoreBrightness -lt 0 -or $RestoreMode -eq '')) {
    throw 'Prueba activa: indique IP, prueba, -RestoreBrightness y -RestoreMode originales.'
}
if ($TestPattern -eq 'White' -and $TestBrightness -lt 0) {
    throw 'White requiere -TestBrightness explicito (0 a 20%). No se usara el brillo previo.'
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'reports' }
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6)
$runDirectory = Join-Path $OutputDirectory ('vx400-' + $runId)
$null = New-Item -ItemType Directory -Path $runDirectory -Force
$jsonPath = Join-Path $runDirectory 'diagnostico.json'
$textPath = Join-Path $runDirectory 'diagnostico.txt'
$report = [ordered]@{
    schema_version = 1
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    status = 'in_progress'
    target = [ordered]@{ address=$DeviceAddress; tcp_port=$TcpPort; expected_model='VX400 original' }
    assumptions = [ordered]@{ receiver_model_user_reported=$ReceiverModel; latest_firmware_assumed=[bool]$AssumeLatestFirmware }
    firmware = [ordered]@{
        controller = [ordered]@{ version=$ObservedControllerFirmware; source='user_observation'; verified_automatically=$false }
        receiver = [ordered]@{ version=$ObservedReceiverFirmware; source='user_observation'; verified_automatically=$false }
        tcp_firmware_query = 'not_documented_in_VX400_protocol_V1.0'
        nova_lct_hardware_view = @()
    }
    local_software = @()
    active_plan = [ordered]@{ enabled=[bool]$EnableActiveTests; brightness_percent=$TestBrightness; pattern=$TestPattern; budget_seconds=$HoldSeconds; restore_brightness_percent=$RestoreBrightness; restore_mode=$RestoreMode }
    checks = @()
    active_tests = @()
    restoration = @()
    limitations = @(
        'ModelID no es firmware. La version del ejecutable NovaLCT tampoco es firmware.',
        'ACK de un comando no demuestra efecto optico ni deshumidificacion.',
        'Autonomia de encendido y MRV412 requieren ensayo fisico y firmware observado.',
        'Restauracion best effort: un corte de red/energia o cierre forzado puede impedirla.'
    )
}

function Save-Report {
    $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('VX400 - diagnostico')
    $lines.Add('Estado: ' + $report.status)
    $lines.Add('Destino: ' + $report.target.address + ':' + $report.target.tcp_port)
    $lines.Add('Solo lectura: ' + (-not [bool]$EnableActiveTests))
    $lines.Add('Firmware controlador observado por usuario: ' + $ObservedControllerFirmware)
    $lines.Add('Firmware receptora observado por usuario: ' + $ObservedReceiverFirmware)
    $lines.Add('Ultima version asumida, NO detectada: ' + [bool]$AssumeLatestFirmware)
    foreach ($item in $report.checks) { $lines.Add($item.name + ': ' + $item.status + ' - ' + $item.detail) }
    foreach ($item in $report.active_tests) { $lines.Add('ACTIVA ' + $item.name + ': ' + $item.status) }
    foreach ($item in $report.restoration) { $lines.Add('RESTAURACION ' + $item.name + ': ' + $item.status) }
    foreach ($item in $report.limitations) { $lines.Add('Limite: ' + $item) }
    $lines.Add('Detalles, respuestas crudas y evidencia: diagnostico.json')
    $lines | Set-Content -LiteralPath $textPath -Encoding UTF8
}

function Add-Check([string]$Name, [string]$Status, [string]$Detail, $Evidence) {
    $report.checks += [ordered]@{ name=$Name; status=$Status; detail=$Detail; evidence=$Evidence }
    Save-Report
    Write-Host ($Name + ': ' + $Status + ' - ' + $Detail)
}

function Get-NovaLctLocalSoftware {
    $items = @()
    if ($env:OS -ne 'Windows_NT') { return @() }
    $paths = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($path in $paths) {
        foreach ($entry in @(Get-ItemProperty $path -ErrorAction SilentlyContinue)) {
            if ($entry.PSObject.Properties['DisplayName'] -and $entry.DisplayName -match '(?i)NovaLCT|V-Can') {
                $version = if ($entry.PSObject.Properties['DisplayVersion']) { $entry.DisplayVersion } else { $null }
                $items += [ordered]@{ name=$entry.DisplayName; software_version=$version; source='Windows uninstall registry'; is_device_firmware=$false }
            }
        }
    }
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(?i:novalct|v-can)' })) {
        try {
            $items += [ordered]@{ name=$process.ProcessName; software_version=$process.MainModule.FileVersionInfo.FileVersion; source='running executable'; is_device_firmware=$false }
        } catch { }
    }
    return $items
}

function Read-NovaLctHardwareView {
    if ($env:OS -ne 'Windows_NT') { throw 'UI Automation requiere Windows; no se inspecciono ninguna ventana.' }
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $results = @()
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(?i:novalct)' })) {
        $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
        $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
        foreach ($window in $windows) {
            $title = $window.Current.Name
            if ($title -notmatch '(?i)hardware|informaci.n.*hardware|informaci.n.*equipo|硬件') { continue }
            $elements = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $texts = @()
            $candidates = @()
            $limit = [Math]::Min($elements.Count, 2500)
            for ($index=0; $index -lt $limit; $index++) {
                try {
                    $current = $elements.Item($index)
                    $name = $current.Current.Name
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    $texts += $name
                    if ($name -match '(?i)\bV?\d+\.\d+\.\d+(?:\.\d+)?\b') {
                        $ancestors = @()
                        $node = $current
                        for ($depth=0; $depth -lt 6; $depth++) {
                            $node = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($node)
                            if ($null -eq $node) { break }
                            $ancestors += $node.Current.Name
                        }
                        $candidates += [ordered]@{ text=$name; parent_context=$ancestors; attribution='requires_check_sender_receiver_MCU_FPGA'; source='visible_NovaLCT_hardware_view' }
                    }
                } catch { }
            }
            $results += [ordered]@{ window=$title; text=$texts; version_candidates=$candidates; attribution_verified=$false }
        }
    }
    return $results
}

$script:sequence = 0
function Next-Sequence { $script:sequence = ($script:sequence + 1) % 256; return [byte]$script:sequence }
function Send-Request([byte[]]$Request) {
    Invoke-VxExchange -DeviceAddress $DeviceAddress -TcpPort $TcpPort -Request $Request -TimeoutMs $TimeoutMs
}
function Send-ActiveRequest([byte[]]$Request) {
    $remaining = $HoldSeconds*1000 - [int]$script:activeTimer.ElapsedMilliseconds
    if ($remaining -lt 250) { throw 'Presupuesto de prueba agotado; iniciando restauracion.' }
    $boundedTimeout = [Math]::Min($TimeoutMs,$remaining)
    Invoke-VxExchange -DeviceAddress $DeviceAddress -TcpPort $TcpPort -Request $Request -TimeoutMs $boundedTimeout
}
function Save-RecoveryReport {
    try { Save-Report } catch { Write-Warning ('No se pudo guardar el informe durante la restauracion: '+$_.Exception.Message) }
}
function Error-Evidence($Record) {
    $raw = $null
    if ($Record.Exception.Data.Contains('RawHex')) { $raw = $Record.Exception.Data['RawHex'] }
    return [ordered]@{ error=$Record.Exception.Message; raw_hex=$raw }
}
function Restore-Output {
    # Try dark mode first so a failed restore does not deliberately reveal bright content.
    foreach ($operation in @('Blackout','Brightness','OriginalMode')) {
        try {
            if ($operation -eq 'Brightness') {
                $rawValue = [byte][Math]::Floor($RestoreBrightness * 255.0 / 100.0)
                $reply = Send-Request (New-VxBrightnessRequest -Value $rawValue -Sequence (Next-Sequence))
            } else {
                $mode = if ($operation -eq 'Blackout') { 'Blackout' } else { $RestoreMode }
                $reply = Send-Request (New-VxDisplayRequest -Mode $mode -Sequence (Next-Sequence))
            }
            $report.restoration += [ordered]@{ name=$operation; status='acknowledged_not_optically_verified'; evidence=$reply }
        } catch {
            $report.restoration += [ordered]@{ name=$operation; status='failed'; evidence=(Error-Evidence $_) }
            # Do not restore Normal if the brightness restoration could not be acknowledged.
            Save-RecoveryReport
            return $false
        }
        Save-RecoveryReport
    }
    return $true
}

$writeAttempted = $false
$failure = $false
Save-Report
try {
    $report.local_software = @(Get-NovaLctLocalSoftware)
    Add-Check 'software_local' 'collected' 'Versiones de software separadas del firmware del equipo.' $report.local_software
    if ($CaptureNovaLctHardwareInfo) {
        try {
            $report.firmware.nova_lct_hardware_view = @(Read-NovaLctHardwareView)
            $viewStatus = if ($report.firmware.nova_lct_hardware_view.Count) { 'evidence_collected' } else { 'not_available' }
            Add-Check 'firmware_UI' $viewStatus 'Abra Settings > Hardware Information y pulse Refresh; no se automatizan clics.' $report.firmware.nova_lct_hardware_view
        } catch { Add-Check 'firmware_UI' 'not_available' $_.Exception.Message $null }
    }
    if ($HardwareInfoTextFile) {
        $file = Get-Item -LiteralPath $HardwareInfoTextFile
        if ($file.Length -gt 1048576) { throw 'La evidencia de hardware debe ocupar menos de 1 MiB.' }
        $report.firmware['hardware_text_evidence'] = [ordered]@{ source='user_selected_NovaLCT_hardware_report'; text=(Get-Content -LiteralPath $file.FullName -Raw) }
        Add-Check 'firmware_texto' 'evidence_collected' 'Conservado sin deducir versiones desde texto ambiguo.' $null
    }
    if (-not $InventoryOnly) {
        $identity = $null
        try {
            $identity = Send-Request (New-VxReadRequest -Address 2 -Length 2 -Sequence (Next-Sequence))
            $modelId = [BitConverter]::ToUInt16([byte[]]$identity.Payload,0)
            Add-Check 'identificacion' 'valid_reply' ('ModelID 0x{0:X4}; no es firmware.' -f $modelId) $identity
        } catch {
            Add-Check 'identificacion' 'inconclusive' 'No se obtuvo una respuesta valida; no demuestra ausencia de soporte.' (Error-Evidence $_)
            $failure = $true
        }
        try {
            $inputs = Send-Request (New-VxReadRequest -Address 0x13010001 -Length 256 -Sequence (Next-Sequence))
            $decodedInputs = ConvertFrom-VxInputPayload -Payload $inputs.Payload
            Add-Check 'entradas_video' 'valid_reply' 'Consulta documentada de resolucion/estado de entradas.' ([ordered]@{ response=$inputs; decoded=$decodedInputs })
        } catch {
            Add-Check 'entradas_video' 'inconclusive' 'Sin respuesta valida; conservar error para revisar compatibilidad.' (Error-Evidence $_)
            $failure = $true
        }
        if ($EnableActiveTests) {
            if ($null -eq $identity -or $modelId -ne 0x6211) { throw 'Pruebas activas bloqueadas: falta identificacion valida del VX400 esperado (0x6211).' }
            Write-Host 'Prueba activa en gabinete seco supervisado. Deben constar los valores originales de restauracion.'
            # Mark BEFORE the first send: a timeout may still mean the device applied the write.
            $script:activeTimer = [Diagnostics.Stopwatch]::StartNew()
            if ($TestBrightness -ge 0) {
                $entry = [ordered]@{ name='brightness'; requested_percent=$TestBrightness; status='attempting'; evidence=$null }
                $report.active_tests += $entry
                Save-Report
                $writeAttempted = $true
                $reply = Send-ActiveRequest (New-VxBrightnessRequest -Value ([byte][Math]::Floor($TestBrightness*255.0/100.0)) -Sequence (Next-Sequence))
                $entry.status='acknowledged_not_optically_verified'; $entry.evidence=$reply
                Save-Report
            }
            if ($TestPattern -ne 'None') {
                $entry = [ordered]@{ name=('pattern_'+$TestPattern); status='attempting'; evidence=$null }
                $report.active_tests += $entry
                Save-Report
                $writeAttempted = $true
                $reply = Send-ActiveRequest (New-VxDisplayRequest -Mode $TestPattern -Sequence (Next-Sequence))
                $entry.status='acknowledged_not_optically_verified'; $entry.evidence=$reply
                Save-Report
            }
            $remaining = $HoldSeconds*1000 - [int]$script:activeTimer.ElapsedMilliseconds
            if ($remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
        }
    }
    Add-Check 'deshumidificacion_autonoma' 'not_tested' 'No hay comando documentado VX400 para programarla; verificar NovaLCT y dos arranques sin PC.' $null
} catch {
    $failure = $true
    Add-Check 'execution' 'failed' $_.Exception.Message (Error-Evidence $_)
} finally {
    if ($writeAttempted) {
        if (-not (Restore-Output)) { $failure = $true; Write-Warning 'Restauracion incompleta: revisar localmente brillo/modo antes de continuar.' }
    }
    $report.status = if ($failure) { 'completed_with_unresolved_checks' } else { 'completed' }
    $report['finished_at'] = (Get-Date).ToUniversalTime().ToString('o')
    Save-Report
    Write-Host ('Informe: ' + $jsonPath)
    Write-Host ('Resumen: ' + $textPath)
}
if ($failure) { exit 2 }
