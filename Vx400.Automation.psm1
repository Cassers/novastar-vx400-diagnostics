#requires -Version 5.1
Set-StrictMode -Version Latest

function Assert-VxNumber($Value, [double]$Minimum, [double]$Maximum, [string]$Name, [switch]$Integer) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or
        [double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value) -or
        [double]$Value -lt $Minimum -or [double]$Value -gt $Maximum -or
        ($Integer -and [Math]::Floor([double]$Value) -ne [double]$Value)) {
        throw "Invalid $Name; expected number $Minimum..$Maximum."
    }
}
function Read-VxWatcherConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$EnableSequence)
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.schemaVersion -ne 1) { throw 'Unsupported schemaVersion.' }
    $ip = $null
    if ($config.deviceAddress -isnot [string] -or
        -not [Net.IPAddress]::TryParse($config.deviceAddress,[ref]$ip) -or
        $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $ip.GetAddressBytes()[0] -eq 0 -or $ip.GetAddressBytes()[0] -ge 224) {
        throw 'deviceAddress must be a unicast IPv4 literal (no DNS).'
    }
    # IPAddress accepts legacy forms (127.1); canonicalize before endpoint locking.
    $config.deviceAddress = $ip.ToString()
    Assert-VxNumber $config.tcpPort 1 65535 tcpPort -Integer
    Assert-VxNumber $config.pollIntervalSeconds 0.5 60 pollIntervalSeconds
    Assert-VxNumber $config.timeoutMs 250 15000 timeoutMs -Integer
    Assert-VxNumber $config.offlineFailures 1 20 offlineFailures -Integer
    Assert-VxNumber $config.onlineSuccesses 1 20 onlineSuccesses -Integer
    Assert-VxNumber $config.maximumObservationGapSeconds 5 300 maximumObservationGapSeconds
    if ($config.maximumObservationGapSeconds -le ($config.pollIntervalSeconds + $config.timeoutMs/1000.0)) {
        throw 'maximumObservationGapSeconds must exceed poll interval plus timeout.'
    }
    if ($EnableSequence) {
        $profile = $config.sequence
        foreach ($field in @('approved','panelPowerCouplingVerified','startupProtectionVerified')) {
            if ($profile.$field -isnot [bool] -or -not $profile.$field) {
                throw "Sequence blocked: sequence.$field must be verified and true."
            }
        }
        if ($profile.curveReference -isnot [string] -or [string]::IsNullOrWhiteSpace($profile.curveReference)) {
            throw 'Sequence blocked: curveReference must identify the approved panel-specific curve.'
        }
        if ($profile.pattern -notin @('White','FromInput')) { throw 'pattern must be White or FromInput.' }
        Assert-VxNumber $profile.normalBrightnessPercent 0 100 normalBrightnessPercent
        if ($null -eq $profile.stages -or @($profile.stages).Count -lt 1 -or @($profile.stages).Count -gt 32) {
            throw 'Sequence requires 1..32 stages.'
        }
        [double]$last = -1
        [double]$total = 0
        foreach ($stage in $profile.stages) {
            Assert-VxNumber $stage.brightnessPercent 0 100 brightnessPercent
            Assert-VxNumber $stage.durationSeconds 1 86400 durationSeconds
            if ($stage.brightnessPercent -lt $last) { throw 'Stage brightness must be nondecreasing.' }
            $last = $stage.brightnessPercent
            $total += $stage.durationSeconds
        }
        if ($total -gt 604800) { throw 'Sequence exceeds 7 days.' }
    }
    return $config
}
Export-ModuleMember -Function Read-VxWatcherConfig
