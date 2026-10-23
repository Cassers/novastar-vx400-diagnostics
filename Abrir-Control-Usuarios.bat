@echo off
setlocal
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0Control-VxUsuarios.ps1" %*
if errorlevel 1 (
  echo No se pudo abrir Usuarios. Revise el mensaje anterior.
  pause
)
endlocal
