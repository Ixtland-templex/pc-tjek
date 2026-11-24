@echo off
title Opticon installation
rem Fjern "hentet fra internettet"-maerket fra filerne i denne mappe, saa Windows kan koere dem sikkert
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0.' -File | Unblock-File"
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Install-PCTjek.ps1"
