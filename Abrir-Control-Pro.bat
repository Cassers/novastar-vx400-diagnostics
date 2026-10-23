@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0" || exit /b 1
call ".\Preparar-NovaStar.bat"
if errorlevel 1 (
  echo No se pudo preparar NovaStar. Extraiga el paquete completo y revise el mensaje anterior.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0Control-Vx400.ps1" %*
if errorlevel 1 (
  echo No se pudo abrir Pro. Revise el mensaje anterior.
  pause
)
endlocal
