@echo off
REM Keep this window open even if Flutter exits.
if /I not "%~1"=="stay" (
  cmd /k "%~f0" stay
  exit /b
)

setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
if errorlevel 1 goto fail

echo ================================================
echo   AR Car Customizer - Run on Samsung S25 Ultra
echo ================================================
echo.
set "BACKEND_ENDPOINT=http://192.168.100.66:3000/graphql"
if exist "%~dp0backend-url.txt" (
  set /p LOADED_URL=<"%~dp0backend-url.txt"
  if defined LOADED_URL set "BACKEND_ENDPOINT=!LOADED_URL!"
)

echo Backend URL: !BACKEND_ENDPOINT!
echo Make sure your backend (local or VPS) is reachable.
echo A USB cable is not required.
echo.

call :find_adb
if errorlevel 1 goto fail

call :ensure_phone
if errorlevel 1 goto fail

cd /d "%~dp0client"
if errorlevel 1 goto fail

echo.
echo ================================================
echo   Starting Flutter on !DEVICE!
echo   First run can take 5-15 minutes. Leave this window open.
echo ================================================
echo.

call flutter run --dart-define=API_URL=!BACKEND_ENDPOINT! -d "!DEVICE!"
echo.
echo Flutter exited.
pause
exit /b 0

:find_adb
set "ADB="
if defined ANDROID_HOME if exist "%ANDROID_HOME%\platform-tools\adb.exe" set "ADB=%ANDROID_HOME%\platform-tools\adb.exe"
if not defined ADB if defined ANDROID_SDK_ROOT if exist "%ANDROID_SDK_ROOT%\platform-tools\adb.exe" set "ADB=%ANDROID_SDK_ROOT%\platform-tools\adb.exe"
if not defined ADB if exist "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" set "ADB=%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"
if not defined ADB (
  echo adb.exe was not found. Install Android SDK platform-tools.
  exit /b 1
)
"%ADB%" start-server >nul
exit /b 0

:ensure_phone
call :flutter_android_id
if defined DEVICE exit /b 0

if exist "%~dp0phone-wifi.txt" (
  set /p SAVED=<"%~dp0phone-wifi.txt"
  echo Trying last wireless address: !SAVED!
  "%ADB%" connect !SAVED!
  call :flutter_android_id
  if defined DEVICE exit /b 0
  echo That address is no longer listening. Reopen Wireless debugging on the phone.
)

echo.
echo On the phone: Settings ^> Developer options ^> Wireless debugging.
echo Leave that screen open. Phone and laptop must be on the same Wi-Fi.
echo.
set /p NEED_PAIR=Pair this phone now? Y the first time, N if it was paired before: 
if /I "!NEED_PAIR!"=="Y" goto do_pair
goto do_connect

:do_pair
echo.
echo Tap "Pair device with pairing code".
set /p PAIR_ADDR=Pairing IP:port from that popup: 
set /p PAIR_CODE=6-digit pairing code: 
"%ADB%" pair !PAIR_ADDR! !PAIR_CODE!
if errorlevel 1 (
  echo Pairing failed. Check the IP, port, and code, then run this again.
  exit /b 1
)

:do_connect
echo.
echo On the main Wireless debugging screen, not the pairing popup,
echo copy "IP address & Port".
set /p CONNECT_ADDR=Wireless debugging IP:port: 
"%ADB%" connect !CONNECT_ADDR!
if errorlevel 1 (
  echo Could not connect to !CONNECT_ADDR!.
  exit /b 1
)
>"%~dp0phone-wifi.txt" echo !CONNECT_ADDR!
call :flutter_android_id
if not defined DEVICE (
  echo adb connected, but Flutter cannot see an Android phone.
  echo Accept the debugging prompt on the phone, then run this again.
  exit /b 1
)
exit /b 0

:flutter_android_id
set "DEVICE="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -File "%~dp0android-device-id.ps1"`) do (
  set "DEVICE=%%I"
)
exit /b 0

:fail
echo.
echo The phone launch failed. Read the messages above, then press a key.
pause
exit /b 1
