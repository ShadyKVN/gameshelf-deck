@echo off
rem Beendet das laufende GameShelf Deck.
powershell.exe -NoProfile -Command "try { [void][Threading.EventWaitHandle]::OpenExisting('GameShelfDeck_Quit').Set() } catch {}"
