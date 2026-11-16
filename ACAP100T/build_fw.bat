@echo off
setlocal
set ROOT=%~dp0

if "%VIVADO_BIN%"=="" set VIVADO_BIN=vivado

"%VIVADO_BIN%" -mode batch -source "%ROOT%scripts\build.tcl" -tclargs -part xc7a100tfgg484-2 -jobs 8 -outdir "%ROOT%output"
if errorlevel 1 (
    echo.
    echo Build FAILED.
    exit /b 1
)

echo.
echo Build complete:
echo   output\acap100t.bit
echo   output\acap100t.bin
echo   output\acap100t_flash.bin
echo   output\acap100t.mcs
