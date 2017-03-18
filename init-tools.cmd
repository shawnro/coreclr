@if not defined _echo @echo off
setlocal

set INIT_TOOLS_LOG=%~dp0init-tools.log
set PACKAGES_DIR=%~dp0packages\
set TOOLRUNTIME_DIR=%~dp0Tools
set DOTNET_PATH=%TOOLRUNTIME_DIR%\dotnetcli\
set DOTNET_CMD=%DOTNET_PATH%dotnet.exe
if [%BUILDTOOLS_SOURCE%]==[] set BUILDTOOLS_SOURCE=https://dotnet.myget.org/F/dotnet-buildtools/api/v3/index.json
set /P BUILDTOOLS_VERSION=< "%~dp0BuildToolsVersion.txt"
set BUILD_TOOLS_PATH=%PACKAGES_DIR%Microsoft.DotNet.BuildTools\%BUILDTOOLS_VERSION%\lib\
set PROJECT_JSON_PATH=%TOOLRUNTIME_DIR%\%BUILDTOOLS_VERSION%
set PROJECT_JSON_FILE=%PROJECT_JSON_PATH%\project.json
set PROJECT_JSON_CONTENTS={ "dependencies": { "Microsoft.DotNet.BuildTools": "%BUILDTOOLS_VERSION%" , "Microsoft.DotNet.BuildTools.Coreclr": "1.0.4-prerelease"}, "frameworks": { "dnxcore50": { } } }
set BUILD_TOOLS_SEMAPHORE=%PROJECT_JSON_PATH%\init-tools.completed0
set TOOLS_INIT_RETURN_CODE=0
set NUGET_PATH=%PACKAGES_DIR%NuGet.exe

:: if force option is specified then clean the tool runtime and build tools package directory to force it to get recreated
if [%1]==[force] (
  if exist "%TOOLRUNTIME_DIR%" rmdir /S /Q "%TOOLRUNTIME_DIR%"
  if exist "%PACKAGES_DIR%Microsoft.DotNet.BuildTools" rmdir /S /Q "%PACKAGES_DIR%Microsoft.DotNet.BuildTools"
)

:: if dependency option is specified then check the dependency is installed and if not, install it
if [%1]==[dependency] for /f "tokens=1,* delims= " %%i in ("%*") do call :EnsureDependency %%j || exit /b %ERRORLEVEL%

:: If sempahore exists do nothing
if exist "%BUILD_TOOLS_SEMAPHORE%" (
  echo Tools are already initialized.
  goto :DONE
)

if exist "%TOOLRUNTIME_DIR%" rmdir /S /Q "%TOOLRUNTIME_DIR%"

call :DownloadNuGet

if NOT exist "%PROJECT_JSON_PATH%" mkdir "%PROJECT_JSON_PATH%"
echo %PROJECT_JSON_CONTENTS% > "%PROJECT_JSON_FILE%"
echo Running %0 > "%INIT_TOOLS_LOG%"

set /p DOTNET_VERSION=< "%~dp0DotnetCLIVersion.txt"
if exist "%DOTNET_CMD%" goto :afterdotnetrestore

echo Installing dotnet cli...
if NOT exist "%DOTNET_PATH%" mkdir "%DOTNET_PATH%"
if [%PROCESSOR_ARCHITECTURE%]==[x86] (set DOTNET_ZIP_NAME=dotnet-dev-win-x86.%DOTNET_VERSION%.zip) else (set DOTNET_ZIP_NAME=dotnet-dev-win-x64.%DOTNET_VERSION%.zip)
set DOTNET_REMOTE_PATH=https://dotnetcli.blob.core.windows.net/dotnet/preview/Binaries/%DOTNET_VERSION%/%DOTNET_ZIP_NAME%
set DOTNET_LOCAL_PATH=%DOTNET_PATH%%DOTNET_ZIP_NAME%
echo Installing '%DOTNET_REMOTE_PATH%' to '%DOTNET_LOCAL_PATH%' >> "%INIT_TOOLS_LOG%"
powershell -NoProfile -ExecutionPolicy unrestricted -Command "$retryCount = 0; $success = $false; do { try { (New-Object Net.WebClient).DownloadFile('%DOTNET_REMOTE_PATH%', '%DOTNET_LOCAL_PATH%'); $success = $true; } catch { if ($retryCount -ge 6) { throw; } else { $retryCount++; Start-Sleep -Seconds (5 * $retryCount); } } } while ($success -eq $false); Add-Type -Assembly 'System.IO.Compression.FileSystem' -ErrorVariable AddTypeErrors; if ($AddTypeErrors.Count -eq 0) { [System.IO.Compression.ZipFile]::ExtractToDirectory('%DOTNET_LOCAL_PATH%', '%DOTNET_PATH%') } else { (New-Object -com shell.application).namespace('%DOTNET_PATH%').CopyHere((new-object -com shell.application).namespace('%DOTNET_LOCAL_PATH%').Items(),16) }" >> "%INIT_TOOLS_LOG%"
if NOT exist "%DOTNET_LOCAL_PATH%" (
  echo ERROR: Could not install dotnet cli correctly. See '%INIT_TOOLS_LOG%' for more details.
  set TOOLS_INIT_RETURN_CODE=1
  goto :DONE
)

:afterdotnetrestore

if exist "%BUILD_TOOLS_PATH%" goto :afterbuildtoolsrestore
echo Restoring BuildTools version %BUILDTOOLS_VERSION%...
echo Running: "%DOTNET_CMD%" restore "%PROJECT_JSON_FILE%" --packages "%PACKAGES_DIR% " --source "%BUILDTOOLS_SOURCE%" >> "%INIT_TOOLS_LOG%"
call "%DOTNET_CMD%" restore "%PROJECT_JSON_FILE%" --packages "%PACKAGES_DIR% " --source "%BUILDTOOLS_SOURCE%" >> "%INIT_TOOLS_LOG%"
if NOT exist "%BUILD_TOOLS_PATH%init-tools.cmd" (
  echo ERROR: Could not restore build tools correctly. See '%INIT_TOOLS_LOG%' for more details.
  set TOOLS_INIT_RETURN_CODE=1
  goto :DONE
)

:afterbuildtoolsrestore

echo Initializing BuildTools ...
echo Running: "%BUILD_TOOLS_PATH%init-tools.cmd" "%~dp0" "%DOTNET_CMD%" "%TOOLRUNTIME_DIR%" >> "%INIT_TOOLS_LOG%"
call "%BUILD_TOOLS_PATH%init-tools.cmd" "%~dp0" "%DOTNET_CMD%" "%TOOLRUNTIME_DIR%" >> "%INIT_TOOLS_LOG%"

echo Updating CLI NuGet Frameworks map...
robocopy "%TOOLRUNTIME_DIR%" "%TOOLRUNTIME_DIR%\dotnetcli\sdk\%DOTNET_VERSION%" NuGet.Frameworks.dll /XO >> "%INIT_TOOLS_LOG%"
set UPDATE_CLI_ERRORLEVEL=%ERRORLEVEL%
if %UPDATE_CLI_ERRORLEVEL% GTR 1 (
  echo ERROR: Failed to update Nuget for CLI {Error level %UPDATE_CLI_ERRORLEVEL%}. Please check '%INIT_TOOLS_LOG%' for more details. 1>&2
  exit /b %UPDATE_CLI_ERRORLEVEL%
)

:: Create sempahore file
echo Done initializing tools.
echo Init-Tools.cmd completed for BuildTools Version: %BUILDTOOLS_VERSION% > "%BUILD_TOOLS_SEMAPHORE%"

:DONE

:: if we need to update PATH, endlocal and update so it carries forward
if defined DEPENDENCY_ADD_PATH endlocal & echo Adding "%DEPENDENCY_ADD_PATH%" to PATH & set PATH=%DEPENDENCY_ADD_PATH%;%PATH%

exit /b %TOOLS_INIT_RETURN_CODE%

:DownloadNuGet
if NOT exist "%NUGET_PATH%" (
  for /f %%i in ("%NUGET_PATH%") do if NOT exist "%%~dpi" mkdir "%%~dpi"
  powershell -NoProfile -ExecutionPolicy unrestricted -Command "(New-Object Net.WebClient).DownloadFile('https://www.nuget.org/nuget.exe', '%NUGET_PATH%')
)
goto :EOF

:EnsureDependency
if []==[%3] (
  echo Usage: %~nx0 dependency [name] [source.package] [version] ^<target:[installPath]^> ^<addpath:^<fileName^>^>
  goto :EOF
)

set DEPENDENCY_TARGET=%PACKAGES_DIR:~0,-1%
set DEPENDENCY_NAME=%1
for /f "tokens=1,* delims=." %%i in ("%2") do (
  set DEPENDENCY_SOURCE=%%i
  set DEPENDENCY_PACKAGE=%%j
) 
set DEPENDENCY_VERSION=%3

:OptionalArgLoop
if NOT []==[%4] (
  for /f "tokens=1,* delims=:" %%i in ("%4") do (
    if [target]==[%%i] set DEPENDENCY_TARGET=%%j& shift /4 & goto :OptionalArgLoop
    if [addpath]==[%%i] set DEPENDENCY_ADD_PATH=%%j& shift /4 goto :OptionalArgLoop
  )
)

echo Installing %DEPENDENCY_NAME% %DEPENDENCY_VERSION% from %DEPENDENCY_SOURCE% to "%DEPENDENCY_TARGET%" ...

call :CASE_%DEPENDENCY_SOURCE% || call :CASE_DEFAULT
goto :SKIP_CASE

:CASE_NUGET
  call :NuGetInstall || exit /b %ERRORLEVEL%
  goto :END_CASE
:CASE_DEFAULT
  echo Unknown dependency source "%DEPENDENCY_SOURCE%"
  goto END_CASE
:END_CASE
  ver> nul
  goto :EOF
:SKIP_CASE

:: nothing to add to PATH, exit early
if not defined DEPENDENCY_ADD_PATH exit /b 0

:: search for path to file and set that path as the one to add to PATH
for /f "tokens=*" %%i in ('dir /b /s "%DEPENDENCY_TARGET%\%DEPENDENCY_ADD_PATH%"') do set DEPENDENCY_ADD_PATH=%%~dpi

:: if location already exists in PATH, don't add it again
echo %PATH% | find /i "%DEPENDENCY_ADD_PATH%"> nul && set DEPENDENCY_ADD_PATH=

exit /b 0

:NuGetInstall  
call :DownloadNuGet
set INSTALL_CMD="%NUGET_PATH%" install "%DEPENDENCY_PACKAGE%" -version "%DEPENDENCY_VERSION%" -outputdirectory "%DEPENDENCY_TARGET%"
echo Running: %INSTALL_CMD% >> "%INIT_TOOLS_LOG%"
%INSTALL_CMD% >> "%INIT_TOOLS_LOG%"
set INSTALL_DEPENDENCY_ERRORLEVEL=%ERRORLEVEL%
if %INSTALL_DEPENDENCY_ERRORLEVEL% GEQ 1 (
  echo ERROR: Failed to install %DEPENDENCY_NAME% {Error level %INSTALL_DEPENDENCY_ERRORLEVEL%}. Please check '%INIT_TOOLS_LOG%' for more details. 1>&2
  exit /b %INSTALL_DEPENDENCY_ERRORLEVEL%
)
goto :EOF

