# GameShelf Deck - Couch-Modus
# Laeuft als Apollo-App "Couch". Solange dieses Skript lebt, ist der Couch-Modus an.
# Lebenszeichen: schreibt user\couch.flag alle 5 s neu (das Deck verwirft die Kennung nach 20 s ohne Lebenszeichen).
# Ende: "Couch-Modus beenden" im Deck legt user\couch.quit an -> Skript endet -> Apollo beendet die App und den Stream.
$ErrorActionPreference = 'SilentlyContinue'
$dir = Join-Path $PSScriptRoot 'user'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$flag = Join-Path $dir 'couch.flag'
$quit = Join-Path $dir 'couch.quit'
Remove-Item -LiteralPath $quit -Force
$n = 0
while ($true) {
    if (Test-Path -LiteralPath $quit) { break }
    if ($n % 5 -eq 0) { Set-Content -LiteralPath $flag -Value (Get-Date -Format o) -Encoding ASCII }
    Start-Sleep -Seconds 1
    $n++
}
Remove-Item -LiteralPath $flag -Force
Remove-Item -LiteralPath $quit -Force
