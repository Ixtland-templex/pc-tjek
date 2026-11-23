@echo off
rem Starter appen uden installation (beder om UAC hver gang). Brug hellere "Installer PC-Tjek.cmd".
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0PC-Tjek-App.ps1"
