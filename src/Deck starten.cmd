@echo off
rem Startet das GameShelf Deck auf dem Zweitbildschirm, ohne Konsolenfenster.
rem Ein erneuter Start ersetzt ein laufendes Deck (praktisch nach Aenderungen).
start "" conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Deck.ps1"
