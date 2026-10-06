@echo off
start "zapret: cf-tunnel" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cf-tunnel.ps1"
