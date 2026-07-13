@echo off
setlocal enabledelayedexpansion

if "%1"=="" goto usage
if "%2"=="" goto usage

set MODE=%1
set APP_URL=%2

if /i "%MODE%"=="disk" goto disk
if /i "%MODE%"=="cpu" goto cpu
if /i "%MODE%"=="crash" goto crash
if /i "%MODE%"=="health" goto crash
goto usage

:disk
echo Triggering disk-fill scenario against %APP_URL% ...
for /l %%i in (1,1,35) do (
    curl -s %APP_URL%/fill-disk
    echo.
)
echo Done. Check /diskinfo and wait ~2-3 min for sentinel-disk-high to fire.
curl -s %APP_URL%/diskinfo
goto end

:cpu
echo Triggering CPU-spike scenario against %APP_URL% ...
echo Each hit pegs all cores for ~20s. Calling twice to span 2 eval periods.
curl -s %APP_URL%/spike-cpu
curl -s %APP_URL%/spike-cpu
echo Done. Wait ~1-2 min for sentinel-cpu-high to fire.
goto end

:crash
echo Triggering crash scenario against %APP_URL% ...
echo Hitting /crash repeatedly to increase odds of catching a health-check poll mid-restart.
for /l %%i in (1,1,8) do (
    curl -s %APP_URL%/crash
)
echo Done. Wait ~1-2 min for sentinel-health-check-failure to fire.
goto end

:usage
echo Usage: chaos.bat [disk^|cpu^|crash] APP_URL
echo Example: chaos.bat disk http://3.80.144.223:5000
goto end

:end
endlocal