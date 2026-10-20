@echo off
setlocal
title Diagnostico NovaStar VX400
echo.
echo Diagnostico VX400 - SOLO LECTURA
echo Abra NovaLCT: Settings ^> Hardware Information y pulse Refresh.
echo El diagnostico pedira la IP del puerto CONTROL del VX400.
echo Pulse Enter sin IP si solamente tiene conexion USB.
echo.
if not exist "%~dp0Test-Vx400.ps1" goto missing
if not exist "%~dp0Vx400.Protocol.psm1" goto missing
where powershell.exe >nul 2>nul
if errorlevel 1 goto no_powershell
rem RemoteSigned applies only to this process. No machine policy is changed.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Test-Vx400.ps1" -CaptureNovaLctHardwareInfo -AssumeLatestFirmware
set "vx_diag_result=%ERRORLEVEL%"
echo.
echo El diagnostico ha terminado con codigo %vx_diag_result%.
echo Los informes quedan en la subcarpeta reports junto a este BAT.
echo Si Windows bloqueo el PS1, revise el archivo y desbloqueelo desde Propiedades.
echo.
pause
exit /b %vx_diag_result%
:missing
echo Faltan archivos. Extraiga TODO el ZIP antes de abrir este BAT.
pause
exit /b 1
:no_powershell
echo Windows PowerShell no esta disponible en este equipo.
pause
exit /b 1
