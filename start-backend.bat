@echo off
REM Keep this window open even if a command fails.
if /I not "%~1"=="stay" (
  cmd /k "%~f0" stay
  exit /b
)

cd /d "%~dp0backend"
if errorlevel 1 goto fail

echo Starting AR Car Customizer Backend...
echo Leave this window open while you use the app.
echo.

echo Making sure Docker DB is running...
docker compose up -d
if errorlevel 1 goto fail

echo.
echo Syncing schema and demo user (demo@arcar.com / demo-password)...
call npx prisma db push
if errorlevel 1 goto fail

call npx prisma db seed
if errorlevel 1 goto fail

echo.
echo Starting NestJS server...
echo.
call npm run start:dev
echo.
echo The server stopped.
pause
exit /b 0

:fail
echo.
echo Backend startup failed. Read the messages above, then press a key.
pause
exit /b 1
