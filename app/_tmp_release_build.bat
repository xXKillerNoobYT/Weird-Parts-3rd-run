@echo off
set "ProgramFiles(x86)=C:\Program Files (x86)"
call "%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
cd /d "%~dp0"
C:\Users\weird\flutter\bin\flutter.bat build windows --release
exit /b %ERRORLEVEL%
