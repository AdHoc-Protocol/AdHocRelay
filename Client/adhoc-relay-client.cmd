@echo off
rem AdHoc Relay Client, on Windows: a double click starts the script beside, its menu in this window.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0adhoc-relay-client.ps1" %*
