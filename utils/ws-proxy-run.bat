@echo off
setlocal DisableDelayedExpansion
set "WS_PROXY_SCRIPT=%~dp0ws-proxy.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object System.Diagnostics.ProcessStartInfo; $p.FileName = 'powershell.exe'; $p.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + [char]34 + $env:WS_PROXY_SCRIPT + [char]34 + ' -Background'; $p.UseShellExecute = $false; $p.CreateNoWindow = $true; [void][System.Diagnostics.Process]::Start($p)"
endlocal
