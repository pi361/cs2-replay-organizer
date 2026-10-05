@echo off
chcp 65001 >nul
title CS2 Replay Organizer
setlocal EnableExtensions
set "PS1="
for /r "%~dp0" %%F in (*.ps1) do if not defined PS1 set "PS1=%%~fF"
if not defined PS1 (
  echo [ERROR] Script file not found. Please keep the tool folder complete.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
if errorlevel 1 (
  echo.
  echo [ERROR] Something went wrong. See the log file in the tool folder.
  pause
)
