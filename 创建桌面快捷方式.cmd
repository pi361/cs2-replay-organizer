@echo off
chcp 65001 >nul
title Create Desktop Shortcut
setlocal EnableExtensions
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$dir='%~dp0'; $dir=$dir.TrimEnd('\'); $target=Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '1-*' -and $_.Extension -eq '.cmd' } | Select-Object -First 1; if (-not $target) { Write-Host 'Cannot find the main entry (1-*.cmd) in this folder.'; exit 1 }; $dest=$env:CS2REPLAY_SHORTCUT_DIR; if (-not $dest) { $dest=[Environment]::GetFolderPath('Desktop') }; $lnkPath=Join-Path $dest ($target.BaseName + '.lnk'); $ws=New-Object -ComObject WScript.Shell; $lnk=$ws.CreateShortcut($lnkPath); $lnk.TargetPath=$target.FullName; $lnk.WorkingDirectory=$dir; $lnk.Description='CS2 replay organizer'; $lnk.Save(); Write-Host ('Shortcut created: ' + $lnkPath)"
if defined CS2REPLAY_SHORTCUT_TEST exit /b 0
pause
