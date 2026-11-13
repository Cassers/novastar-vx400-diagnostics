@echo off
setlocal DisableDelayedExpansion
set "NOVASTAR_PRO_DIAG_ROOT=%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -Command "$ErrorActionPreference='Stop'; try { $root=[IO.Path]::GetFullPath($env:NOVASTAR_PRO_DIAG_ROOT); foreach($name in @('Diagnosticar-VxProIdentidad.ps1','Vx400.Protocol.psm1')) { $path=Join-Path $root $name; $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop; if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Extraiga los dos archivos de codigo originales sin enlaces.'}; Unblock-File -LiteralPath $path -ErrorAction Stop }; exit 0 } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
if errorlevel 1 exit /b 1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Diagnosticar-VxProIdentidad.ps1" %*
set "NOVASTAR_PRO_DIAG_EXIT=%ERRORLEVEL%"
rem A double click prompts for IPv4 in PowerShell and keeps the result visible.
if "%~1"=="" pause
exit /b %NOVASTAR_PRO_DIAG_EXIT%
