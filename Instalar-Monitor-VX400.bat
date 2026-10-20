@echo off
setlocal
cd /d "%~dp0"
echo Instalacion del monitor VX400: requiere Ejecutar como administrador.
echo Solo lectura. No habilita secuencias ni cambios de brillo.
echo Si se instala, arrancara dentro de cinco minutos o al reiniciar Windows.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Install-Vx400Watcher.ps1"
set "VX400_EXIT=%ERRORLEVEL%"
echo.
if not "%VX400_EXIT%"=="0" echo Instalacion no completada. Revise el mensaje anterior.
pause
exit /b %VX400_EXIT%
