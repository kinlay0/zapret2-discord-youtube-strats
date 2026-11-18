@echo off
chcp 437 > nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ws-proxy.ps1" -Logs
