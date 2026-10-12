@echo off
rem ============================================================
rem  Codex Quota Autopilot - ASCII launcher only.
rem  Keep this file pure ASCII: cmd.exe reads .cmd in the
rem  system ANSI codepage, so non-ASCII text here gets mangled.
rem  All Chinese UI lives in start-menu.ps1 (UTF-8 with BOM).
rem ============================================================
setlocal
set "HERE=%~dp0"

set "PWSH="
where pwsh >nul 2>nul && set "PWSH=pwsh"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH set "PWSH=powershell"

rem ---- self-heal before every launch -------------------------
rem  These scripts contain Chinese text. If any of them was saved
rem  as UTF-8 WITHOUT a BOM, Windows PowerShell decodes it as ANSI,
rem  the Chinese breaks the string quoting, and the script fails to
rem  parse ("Unexpected token"). fix-encoding.ps1 restores the BOM.
rem  Running it here means a broken file heals on the next launch.
if exist "%HERE%fix-encoding.ps1" (
    "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%fix-encoding.ps1" >nul 2>nul
    if errorlevel 1 (
        echo PowerShell script validation failed. Run fix-encoding.ps1 to see the error.
        pause
        exit /b 1
    )
)

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%start-menu.ps1"
endlocal
