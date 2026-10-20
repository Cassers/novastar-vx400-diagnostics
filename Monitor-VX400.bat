@echo off
setlocal
title Monitor NovaStar VX400 - Solo lectura
cd /d "%~dp0"
echo Monitor continuo por Ethernet. No modifica brillo ni contenido.
echo Edite watcher.config.json para cambiar la IP. Ctrl+C para terminar.
echo Estado y eventos en watcher-data junto a este BAT.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Watch-Vx400.ps1"
echo.
echo Monitor terminado con codigo %errorlevel%.
pause
