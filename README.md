# GameShelf Deck

Spieleregal, Leistungsanzeige, Makro-Tasten, Philips Hue, Medien und Mixer für einen zweiten Bildschirm unter Windows 10/11 (z. B. Corsair Xeneon Edge 2560×720, auch 1920×1080 oder 2560×1440).

## Installieren

1. Unter [Releases](../../releases/latest) **GameShelf-Deck-Setup.exe** laden.
2. Starten. Windows SmartScreen warnt, weil das Setup nicht signiert ist: „Weitere Informationen“ › „Trotzdem ausführen“.
3. Der Assistent führt durch Voraussetzungen, Bildschirm, Discord, Schlüssel und Emulatoren.

Installiert wird pro Benutzer nach `%LOCALAPPDATA%\Programs\GameShelf Deck`, ohne Admin-Rechte.

## Updates

Das Deck prüft alle 6 Stunden das neueste Release hier im Repo. Gibt es eine neuere Version, erscheint ein Hinweis in der Insel und unter **Einstellungen › Allgemein › Updates**. „Jetzt installieren“ lädt das Setup, prüft Größe und SHA-256 und tauscht nur die Programmdateien – Einstellungen, Schlüssel, Cover und Spielzeiten bleiben. Während eines Spiels wird nie installiert. Scheitert der Tausch, stellt das Setup den vorigen Stand aus `update\rollback` wieder her. Protokoll: `update.log`.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `src/` | Programmdateien des Decks (PowerShell-Host, WebView2-Oberfläche, C#-Hilfsklasse) |
| `setup/Setup.cs` | Setup-Assistent und stilles Update (`Setup.exe /update <Ordner>`) |
| `setup/build.py` | Baut das Setup, prüft auf persönliche Daten und schreibt `SHA256SUMS.txt` |

Fremd-DLLs (WebView2 SDK 1.0.2903.40 von NuGet, Corsair iCUE SDK 4.0.84) liegen nicht im Repo, sondern nur im Setup; ihre Prüfsummen sind in `build.py` festgeschrieben.

## Release erstellen

1. Version in `src/Deck.ps1` (`$script:Version`) und `setup/Setup.cs` (`App.Version`) erhöhen, gleiche Schreibweise `deckos-NNN`.
2. Lokal testen (optional): `python3 setup/build.py --bin <Ordner mit den DLLs>`
3. Release-Text nach `setup/notes/deckos-NNN.md`, committen, dann `git tag deckos-NNN && git push origin deckos-NNN` – die Action baut und veröffentlicht das Release. Das Deck vergleicht nur die Zahl im Tag.

Privates Projekt für Freunde – keine Gewähr.
