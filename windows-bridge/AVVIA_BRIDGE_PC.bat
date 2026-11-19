@echo off
title PC-Companion Bridge v1.1.0 (Bluetooth RFCOMM)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PC-Companion-Bridge.ps1"
pause
