@echo off
setlocal
cd /d "%~dp0"
echo Quitar tarea VX400: requiere Ejecutar como administrador.
echo Conserva los archivos, configuracion y registros de auditoria.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Install-Vx400Watcher.ps1" -Remove
set "VX400_EXIT=%ERRORLEVEL%"
echo.
if not "%VX400_EXIT%"=="0" echo Tarea no retirada. Revise el mensaje anterior.
pause
exit /b %VX400_EXIT%
