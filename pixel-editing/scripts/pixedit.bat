@echo off
rem OS/arch-agnostic launcher for pixedit on Windows.
rem Detects the current architecture and executes the appropriate binary from bin\.

setlocal

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
set BIN_DIR=%ROOT_DIR%\bin

rem Detect architecture via PROCESSOR_ARCHITECTURE
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
    set ARCH=amd64
) else if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
    set ARCH=arm64
) else if /i "%PROCESSOR_ARCHITEW6432%"=="AMD64" (
    rem 32-bit process on 64-bit Windows
    set ARCH=amd64
) else (
    echo pixedit: unsupported architecture: %PROCESSOR_ARCHITECTURE% 1>&2
    exit /b 1
)

set BIN=%BIN_DIR%\pixedit-windows-%ARCH%.exe

if not exist "%BIN%" (
    rem Fall back to bare pixedit.exe in the project root
    set BIN=%ROOT_DIR%\pixedit.exe
)

if not exist "%BIN%" (
    echo pixedit: binary not found: %BIN% 1>&2
    echo pixedit: build it with: set GOOS=windows ^&^& set GOARCH=%ARCH% ^&^& go build -o "%BIN%" . 1>&2
    exit /b 1
)

"%BIN%" %*
