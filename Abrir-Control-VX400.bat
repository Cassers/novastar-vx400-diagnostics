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
  echo.
  echo No se pudo abrir el control VX400. Revise el mensaje anterior.
  echo Para guardar una instalacion o cambiar el inicio automatico, use Ejecutar como administrador.
  pause
)
endlocal
