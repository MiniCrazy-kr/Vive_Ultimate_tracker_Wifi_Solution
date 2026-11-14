@echo off
setlocal
set "LOG_ROOT=%~dp0..\backups"
if exist "%LOG_ROOT%\*.ndjson" del /q "%LOG_ROOT%\*.ndjson"
if exist "%LOG_ROOT%\utk_wifi_only_app\*.log" del /q "%LOG_ROOT%\utk_wifi_only_app\*.log"
