@echo off
rem Start the tray app. Use start-console.cmd for the original interactive menu.
setlocal
set "HERE=%~dp0"
if not exist "%HERE%start-tray.vbs" exit /b 1
wscript.exe "%HERE%start-tray.vbs"
endlocal
