@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ── Config
set "REPO_URL=https://github.com/SR6Glory/audo-dump-mysql.git"
set "TARGET_DIR=%USERPROFILE%\audo-dump-mysql"
set "BUN_BIN=%USERPROFILE%\.bun\bin"

title "Auto setup ^& run • audo-dump-mysql"
color 0A
echo ========================================================
echo [0] Start
echo      Repo   : %REPO_URL%
echo      Target : %TARGET_DIR%
echo ========================================================

:: ── Force Run as Admin ──────────────────────────────────────────────────
>nul 2>&1 net session
if %errorlevel% neq 0 (
  echo [!] Not running as administrator — relaunching with admin rights...
  set "batchPath=%~f0"
  set "args=%*"
  set "vbs=%temp%\elevate_%random%.vbs"
  > "%vbs%" echo Set UAC = CreateObject^("Shell.Application"^)
  >>"%vbs%" echo UAC.ShellExecute "cmd.exe", "/c """"%batchPath%"""" %args%", "", "runas", 1
  cscript //nologo "%vbs%" >nul
  del "%vbs%" >nul 2>&1
  exit /b
) else (
  echo [1] OK: Running as Administrator.
)

:: ── Pick package manager ────────────────────────────────────────────────
where winget >nul 2>&1 && (set "PKG=winget") || (set "PKG=")
if not defined PKG (
  where choco >nul 2>&1 || (
    echo [2] Chocolatey not found. Installing...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    if errorlevel 1 (
      echo [X] Failed to install Chocolatey. Install it from https://chocolatey.org/install and re-run.
      pause & exit /b 1
    )
  )
  if exist "%ChocolateyInstall%\bin\refreshenv.cmd" call "%ChocolateyInstall%\bin\refreshenv.cmd"
  set "PKG=choco"
)
echo [2] Using package method: %PKG%

:: ── Node.js ─────────────────────────────────────────────────────────────
echo [3] Node.js
if /i "%PKG%"=="winget" (
  winget install -e --id OpenJS.NodeJS --silent --accept-package-agreements --accept-source-agreements
) else (
  choco install nodejs -y --force --no-progress 2>nul
  if exist "%ChocolateyInstall%\bin\refreshenv.cmd" call "%ChocolateyInstall%\bin\refreshenv.cmd"
)
if errorlevel 1 (echo [X] Node.js install failed.& pause & exit /b 1)
node -v

:: ── Bun ─────────────────────────────────────────────────────────────────
echo [4] Bun
where bun >nul 2>&1 || (
  if /i "%PKG%"=="winget" (
    winget install -e --id Oven-sh.Bun --silent --accept-package-agreements --accept-source-agreements
  ) else (
    choco install bun -y --force --no-progress 2>nul
    if exist "%ChocolateyInstall%\bin\refreshenv.cmd" call "%ChocolateyInstall%\bin\refreshenv.cmd"
  )
  if errorlevel 1 (echo [X] Bun install failed.& pause & exit /b 1)
)
if exist "%BUN_BIN%\bun.exe" set "PATH=%BUN_BIN%;%PATH%"
where bun >nul 2>&1 || (echo [X] bun not on PATH.& pause & exit /b 1)
bun --version

:: ── Git ─────────────────────────────────────────────────────────────────
echo [5] Git
if /i "%PKG%"=="winget" (
  winget install -e --id Git.Git --silent --accept-package-agreements --accept-source-agreements
) else (
  choco install git -y --force --no-progress 2>nul
  if exist "%ChocolateyInstall%\bin\refreshenv.cmd" call "%ChocolateyInstall%\bin\refreshenv.cmd"
)
if errorlevel 1 (echo [X] Git install failed.& pause & exit /b 1)
git --version

:: ── Repo ────────────────────────────────────────────────────────────────
echo [6] Repository
if exist "%CD%\.git" (
  for /f "usebackq delims=" %%r in (`git -C "%CD%" config --get remote.origin.url 2^>nul`) do set "CURR_REMOTE=%%r"
  if /i "!CURR_REMOTE!"=="%REPO_URL%" set "TARGET_DIR=%CD%"
)
echo      Target: %TARGET_DIR%
if exist "%TARGET_DIR%\.git" (
  pushd "%TARGET_DIR%" >nul
  git pull --ff-only
  if errorlevel 1 (popd >nul & echo [X] git pull failed.& pause & exit /b 1)
  popd >nul
) else (
  git clone "%REPO_URL%" "%TARGET_DIR%"
  if errorlevel 1 (echo [X] git clone failed.& pause & exit /b 1)
)

:: ── bun install ─────────────────────────────────────────────────────────
echo [8] bun install
pushd "%TARGET_DIR%" >nul
bun install
if errorlevel 1 (popd >nul & echo [X] bun install failed.& pause & exit /b 1)

:: ── Prompt for .env values ──────────────────────────────────────────────
set "ENV_FILE=%TARGET_DIR%\.env"
if not exist "%ENV_FILE%" (
  echo [8.5] Creating .env
  type nul > "%ENV_FILE%"
)

call :EnsureEnvValue "%ENV_FILE%" "MYSQL_SOURCE"       "Enter MYSQL_SOURCE DSN"       "Example: user:pass@tcp(host:3306)/db?params" ""
call :EnsureEnvValue "%ENV_FILE%" "MYSQL_DESTINATION"  "Enter MYSQL_DESTINATION DSN"  "Example: user:pass@tcp(host:3306)/db?params" ""



:: ── Run app ─────────────────────────────────────────────────────────────
echo [9] Run app
echo     bun src/index.ts
echo --------------------------------------------------------
bun src/index.ts
set "APP_EXIT=%errorlevel%"
echo --------------------------------------------------------
popd >nul

if "%APP_EXIT%" neq "0" (
  echo [X] App exited with code %APP_EXIT%.
  pause & exit /b %APP_EXIT%
)

echo [✔] Done. App finished successfully.
pause
exit /b 0

:: =========================================================
:: Helpers
:: =========================================================
:EnsureEnvValue
:: %1=file  %2=KEY  %3=promptLine  %4=exampleLine  %5=defaultValue
setlocal EnableExtensions EnableDelayedExpansion
set "FILE=%~1"
set "KEY=%~2"
set "PROMPTLINE=%~3"
set "EXAMPLELINE=%~4"
set "DEF=%~5"
set "CURR="

:: read current value (if present)
for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b /c:"!KEY!=" "!FILE!" 2^>nul`) do (
  set "CURR=%%B"
)

if defined CURR (
  endlocal & exit /b 0
)

echo.
echo    !PROMPTLINE!
if defined EXAMPLELINE echo    !EXAMPLELINE!
if defined DEF echo    [default: !DEF!]
set /p INPUT="    > "

if not defined INPUT if defined DEF set "INPUT=!DEF!"

set "TMP=%FILE%.tmp"
break > "%TMP%"
for /f "usebackq delims=" %%L in ("%FILE%") do (
  echo(%%L| findstr /b /c:"%KEY%=" >nul || (>>"%TMP%" echo(%%L)
)

>>"%TMP%" <nul set /p "=%KEY%="
>>"%TMP%" <nul set /p "=%INPUT%"
>>"%TMP%" echo.

move /y "%TMP%" "%FILE%" >nul
endlocal & exit /b 0