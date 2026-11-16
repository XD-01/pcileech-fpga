@echo off
setlocal

rem Run from an x64 Native Tools Command Prompt for VS 2022.
if "%VCToolsInstallDir%"=="" (
    echo ERROR: please use the x64 Native Tools Command Prompt for VS 2022.
    exit /b 1
)

cl /nologo /O2 /W3 /I..\driver\windows /I..\driver\linux acap_capture_win.c
if errorlevel 1 exit /b 1

echo Built acap_capture_win.exe
