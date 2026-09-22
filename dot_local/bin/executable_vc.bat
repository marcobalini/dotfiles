@echo off
if "%1"=="" goto usage
set VCPROGRAMFILES=%ProgramFiles(x86)%
if "%PROCESSOR_ARCHITECTURE%"=="x86" (
  set VCPROGRAMFILES=%ProgramFiles%
  set VCAMD64=x86_amd64
  set VCIA64=x86_ia64
)
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
  set VCAMD64=amd64
  set VCIA64=x86_ia64
)
if "%PROCESSOR_ARCHITECTURE%"=="EM64T" (
  set VCAMD64=x86_amd64
  set VCIA64=ia64
)
if "%1"=="2" goto vc2
if "%1"=="6" goto vc6
if "%1"=="8" goto vs2005
if "%1"=="9" goto vs2008
if "%1"=="10" goto vs2010
if "%1"=="11" goto vs2012
if "%1"=="12" goto vs2013
if "%1"=="14" goto vs2015
if "%1"=="15" goto vs2015
if "%1"=="17" set "VCVERSION=2017" && goto newvs
if "%1"=="19" set "VCVERSION=2019" && goto newvs
if "%1"=="22" set "VCVERSION=2022" && goto newvs
if "%1"=="26" set "VCVERSION=2026" && goto newvs
goto usage
:vc2
@set INCLUDE=
@set LIB=
if not exist "C:\MSVC20\BIN\VCVARS32.BAT" echo C:\MSVC20\BIN\VCVARS32.BAT not found! && goto error
@call C:\MSVC20\BIN\VCVARS32.BAT
goto done
:vc6
@set VCINSTALLDIR="%VCPROGRAMFILES%\Microsoft Visual Studio\VC98"
if not exist "%VCPROGRAMFILES%\Microsoft Visual Studio\VC98\Bin\VCVARS32.BAT" echo %VCPROGRAMFILES%\Microsoft Visual Studio\VC98\Bin\VCVARS32.BAT not found! && goto error
@call "%VCPROGRAMFILES%\Microsoft Visual Studio\VC98\Bin\VCVARS32.BAT"
goto done
:vs2005
@set VCVERSION=8
goto vs
:vs2008
@set VCVERSION=9.0
goto vs
:vs2010
@set VCVERSION=10.0
goto vs
:vs2012
@set VCVERSION=11.0
goto vs
:vs2013
@set VCVERSION=12.0
goto vs
:vs2015
@set VCVERSION=14.0
goto vs
:vs
@set VCVISUALSTUDIO=%VCPROGRAMFILES%\Microsoft Visual Studio %VCVERSION%
if not exist "%VCVISUALSTUDIO%\" echo %VCVISUALSTUDIO% not found! && goto error
if "%2"=="" (
  @call "%VCVISUALSTUDIO%\Vc\bin\vcvars32.bat"
) else (
  if "%2"=="x64" (
    @call "%VCVISUALSTUDIO%\Vc\vcvarsall.bat" %VCAMD64%
  ) else (
    if "%2"=="ia64" (
      @call "%VCVISUALSTUDIO%\Vc\vcvarsall.bat" %VCIA64%
    ) else (
      goto usage
    )
  )
)
goto done
:newvs
set "VCVISUALSTUDIO="
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -property installationPath 2^>nul`) do (
  echo "%%i" | find "\%VCVERSION%\" >nul 2>&1 && set "VCVISUALSTUDIO=%%i\VC\Auxiliary\Build"
)
if not defined VCVISUALSTUDIO echo VS %VCVERSION% not found! && goto error
if "%2"=="" (
  @call "%VCVISUALSTUDIO%\vcvarsall.bat" x86
) else (
  if "%2"=="x64" (
    @call "%VCVISUALSTUDIO%\vcvarsall.bat" %VCAMD64%
  ) else (
    if "%2"=="ia64" (
      @call "%VCVISUALSTUDIO%\vcvarsall.bat" %VCIA64%
    ) else (
      goto usage
    )
  )
)
goto done
:usage
echo usage: %0 2^|6^|8^|9^|10^|11^|12^|14^|17^|19^|22^|26 [x64^|ia64]
:error
set "VCERROR=1"
:done
set "VCVERSION="
set "VCVISUALSTUDIO="
set "VCAMD64="
set "VCIA64="
set "VCPROGRAMFILES="
if defined VCERROR (set "VCERROR=" & exit /b 1)