@echo off
rem Atajo para no tener que cambiar la ExecutionPolicy de PowerShell.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uv4070.ps1" %*
set rc=%errorlevel%
rem Con doble clic (sin argumentos) muestra el estado y espera.
if "%~1"=="" pause
exit /b %rc%
