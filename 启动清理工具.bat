@echo off
rem ============================================================
rem  DiskCleanerPro launcher (ASCII only, no Chinese here)
rem  Prefers pwsh 7.x (STA) and falls back to Windows PowerShell 5.1
rem ============================================================
cd /d "%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
  start "" pwsh -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0DiskCleaner.ps1"
) else (
  start "" "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0DiskCleaner.ps1"
)
