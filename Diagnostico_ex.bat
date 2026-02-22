@echo off
:: O -NoExit impede que a janela feche em caso de erro
PowerShell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0Diagnostico.ps1"