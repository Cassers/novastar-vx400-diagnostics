@echo off
setlocal DisableDelayedExpansion
cd /d "%~dp0" || exit /b 1
".\Abrir-Control-Usuarios.bat" %*
