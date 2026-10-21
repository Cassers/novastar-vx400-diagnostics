#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$DataDirectory,[switch]$Force,[string]$ExpectedOwnersPath='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try{
    Import-Module (Join-Path $PSScriptRoot 'Vx400.Ownership.psm1') -Force -ErrorAction Stop
    $result=Invoke-VxOwnershipRecovery -ConfigPath $ConfigPath -DataDirectory $DataDirectory -Force:$Force -ExpectedOwnersPath $ExpectedOwnersPath
}catch{$result=[pscustomobject]@{success=$false;needsForce=$false;message=$_.Exception.Message;controllers=@();pausedTasks=@();mutexAvailable=$false}}
Write-Output ($result|ConvertTo-Json -Depth 8 -Compress)
if($result.success -or $result.needsForce){exit 0};exit 2
