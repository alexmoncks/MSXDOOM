@echo off
rem MSX DOOM no openMSX (fork V9968 + geo3d), perfil 98h.
rem Espera o emulador em ..\..\openmsx-geo3d (C:\Projects\mmsoft\openmsx-geo3d);
rem para outro lugar, defina OPENMSX_DIR antes de chamar.
rem Teclas: cursores andam e giram, Z / X passo lateral, ESPACO atira.
setlocal
if "%OPENMSX_DIR%"=="" set OPENMSX_DIR=%~dp0..\..\openmsx-geo3d
if not exist "%OPENMSX_DIR%\openmsx.exe" (
  echo openmsx.exe nao encontrado em "%OPENMSX_DIR%"
  pause
  exit /b 1
)
set ROM=%~dp0release\MSXDOOM_98.ROM
if not exist "%ROM%" set ROM=%~dp0out\MSXDOOM_98.ROM
cd /d "%OPENMSX_DIR%"
start "" openmsx.exe -machine C-BIOS_V9968_JP -ext geo3d -cart "%ROM%" -romtype ASCII16
