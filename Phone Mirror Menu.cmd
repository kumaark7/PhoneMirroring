@echo off
title Phone Mirror Menu
:menu
cls
echo ============================
echo       PHONE MIRROR MENU
echo ============================
echo.
echo 1. USB Mirror
echo 2. Wireless Mirror
echo 3. Pair Wireless Mirror
echo 4. USB Mirror Dim Phone Screen
echo 5. Wireless Mirror Dim Phone Screen
echo 6. Pair Wireless Dim Phone Screen
echo 7. Saved Wireless Devices
echo 8. Exit
echo.
set /p choice=Enter choice: 

if "%choice%"=="1" goto usb
if "%choice%"=="2" goto wireless
if "%choice%"=="3" goto pair
if "%choice%"=="4" goto usb_dim
if "%choice%"=="5" goto wireless_dim
if "%choice%"=="6" goto pair_dim
if "%choice%"=="7" goto saved_wireless
if "%choice%"=="8" goto end

echo.
echo Invalid choice.
pause
goto menu

:usb
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-phone-mirror.ps1"
pause
goto menu

:wireless
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-phone-mirror.ps1" -Wireless
pause
goto menu

:pair
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-phone-mirror.ps1" -PairWireless
pause
goto menu

:usb_dim
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-phone-mirror.ps1" -DimPhoneScreen
pause
goto menu

:wireless_dim
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-phone-mirror.ps1" -Wireless -DimPhoneScreen
pause
goto menu

:pair_dim
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-phone-mirror.ps1" -PairWireless -DimPhoneScreen
pause
goto menu

:saved_wireless
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Saved Wireless Devices.ps1"
pause
goto menu

:end
exit
