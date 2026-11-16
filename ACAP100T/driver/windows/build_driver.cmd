@echo off
setlocal

rem Run this from an "x64 Native Tools Command Prompt for VS 2022" with the
rem Windows Driver Kit installed.  The post-build step copies acap.inf into
rem build\Release and generates acap.cat with Inf2Cat.

if "%VCToolsInstallDir%"=="" (
    echo ERROR: please use the x64 Native Tools Command Prompt for VS 2022.
    exit /b 1
)

msbuild acap.vcxproj /p:Configuration=Release /p:Platform=x64 /m
if errorlevel 1 (
    echo ERROR: driver build failed.
    exit /b 1
)

echo.
echo Driver built in %~dp0build\Release
echo Run sign_test.ps1 from an elevated PowerShell to sign and install.
