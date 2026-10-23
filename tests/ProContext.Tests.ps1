#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Control-Vx400.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Pro source does not parse.'}
# Execute the real resolution branches with isolated roots; never open a window or policy.
$branches=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
    ($n.Extent.Text.StartsWith('if (-not $explicitConfig) {') -or $n.Extent.Text.StartsWith('if ([string]::IsNullOrWhiteSpace($DataDirectory)) {'))},$false))
if($branches.Count -ne 2){throw 'Default resolution structure changed; review this regression harness.'}
$resolver=[scriptblock]::Create(($branches|ForEach-Object {$_.Extent.Text.Replace('$PSScriptRoot','$AppRoot')}) -join [Environment]::NewLine)
$directory=Join-Path ([IO.Path]::GetTempPath()) ('vx-pro-context-'+[guid]::NewGuid().ToString('N'))
$portable=Join-Path $directory 'portable';$installed=Join-Path $directory 'installed'
$null=[IO.Directory]::CreateDirectory($portable);$null=[IO.Directory]::CreateDirectory($installed)
[IO.File]::WriteAllText((Join-Path $portable 'plan.config.json'),'{}')
[IO.File]::WriteAllText((Join-Path $installed 'plan.config.json'),'{}')
$commonData=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'NovaStar-VX400-Control'
$script:passed=0
function Check([string]$AppRoot,[string]$ConfigPath,[string]$DataDirectory,[string]$ExpectedConfig,[string]$ExpectedData){
    $explicitConfig=-not [string]::IsNullOrWhiteSpace($ConfigPath)
    $explicitData=-not [string]::IsNullOrWhiteSpace($DataDirectory)
    $installedRoot=$installed
    . $resolver
    if($ConfigPath -cne $ExpectedConfig -or $DataDirectory -cne $ExpectedData){throw ('Wrong context: '+$ConfigPath+' | '+$DataDirectory)}
    $script:passed++
}
try {
    [IO.File]::WriteAllText((Join-Path $portable 'pro-access.json'),'existence fixture; not a valid policy')
    Check $portable '' '' (Join-Path $portable 'plan.config.json') (Join-Path $portable 'plan-data')
    # Invalid local policies remain in local context for the authentication gate to reject.
    Remove-Item -LiteralPath (Join-Path $portable 'pro-access.json')
    Check $portable '' '' (Join-Path $installed 'plan.config.json') $commonData
    [IO.File]::WriteAllText((Join-Path $installed 'pro-access.json'),'installed existence fixture')
    Check $installed '' '' (Join-Path $installed 'plan.config.json') $commonData
    Check $portable (Join-Path $directory 'explicit-plan.json') '' (Join-Path $directory 'explicit-plan.json') (Join-Path $portable 'plan-data')
    Check $portable '' (Join-Path $directory 'explicit-data') (Join-Path $portable 'plan.config.json') (Join-Path $directory 'explicit-data')
    [IO.File]::WriteAllText((Join-Path $portable 'pro-access.json'),'local policy existence')
    Check $portable (Join-Path $directory 'other-plan.json') (Join-Path $directory 'other-data') (Join-Path $directory 'other-plan.json') (Join-Path $directory 'other-data')
    Remove-Item -LiteralPath (Join-Path $portable 'pro-access.json')
    Remove-Item -LiteralPath (Join-Path $installed 'plan.config.json')
    Check $portable '' '' (Join-Path $portable 'plan.config.json') (Join-Path $portable 'plan-data')
    Write-Output ('PASS '+$script:passed+' Pro portable/installed context regressions (no windows, no hardware)')
}finally{Remove-Item -LiteralPath $directory -Recurse -Force}
