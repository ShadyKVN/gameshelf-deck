# Baut das Setup fuer ein Release: payload.zip aus fester Dateiliste -> GameShelf-Deck-Setup.exe (+ SHA256SUMS.txt).
# Bricht ab, wenn persoenliche Daten im Paket oder in einer Datei des Repos stehen.
#
#   python3 setup/build.py --bin <Ordner mit lib\*.dll und iCUESDK.x64_2019.dll> [--private <Deck-Ordner mit deck.json/config.json>]
#
# Die Fremd-DLLs liegen bewusst nicht im Repo:
#   lib/*.dll            NuGet Microsoft.Web.WebView2 1.0.2903.40 (lib/net462, runtimes/win-x64/native)
#   iCUESDK.x64_2019.dll Corsair iCUE SDK 4.0.84
# Ihre SHA-256 sind unten festgeschrieben, damit nur genau diese Dateien ins Setup kommen.
# Uebersetzen braucht Mono: mono-mcs + libmono-system-{windows-forms,io-compression,io-compression-filesystem,web-extensions}4.0-cil
import argparse, hashlib, json, os, re, subprocess, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__)); REPO = os.path.dirname(HERE); SRC = os.path.join(REPO, 'src')
PIN = {
    'lib/Microsoft.Web.WebView2.Core.dll': '88a3b62f45225a811cdb85df6dfd95c2bff9a0e43e3b04f813b125eaca56cc9f',
    'lib/Microsoft.Web.WebView2.Wpf.dll': '1c5b6c792916d168093ef9b836f33e818d2d15d0c81f0864b5cddff97d913319',
    'lib/WebView2Loader.dll': '462b36fd1be6ca9f7563466a89e57c41ef4a4def3e0a84fa885d203aea4a3aaf',
    'iCUESDK.x64_2019.dll': 'd72fd819b91fd1d3b0c3db2ea17a47dcfe3b38e26269aa967ecfee10d2e93884',
}
SRC_FILES = ['Deck.ps1', 'Deck.html', 'GameShelf.Core.ps1', 'DeckNative.cs', 'deck.ico', 'Deck starten.cmd', 'Deck beenden.cmd',
             'CouchHold.ps1', 'CouchFps.ps1', 'LIESMICH.txt']
TEXT = ('.ps1', '.html', '.txt', '.cmd', '.cs', '.py', '.md', '.yml', '.json', '.gitignore')

def sha(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()

ap = argparse.ArgumentParser(); ap.add_argument('--bin', required=True); ap.add_argument('--private'); ap.add_argument('--out', default=os.path.join(REPO, 'dist'))
a = ap.parse_args()

# Versionen muessen uebereinstimmen
ver_ps = re.search(r"\$script:Version = '([^']+)'", open(os.path.join(SRC, 'Deck.ps1'), encoding='utf-8-sig').read()).group(1)
ver_cs = re.search(r'public const string Version = "([^"]+)"', open(os.path.join(HERE, 'Setup.cs'), encoding='utf-8').read()).group(1)
if ver_ps != ver_cs: sys.exit('ABBRUCH: Version Deck.ps1 (%s) != Setup.cs (%s)' % (ver_ps, ver_cs))

files = [(f, os.path.join(SRC, f)) for f in SRC_FILES]
for arc, h in PIN.items():
    p = os.path.join(a.bin, arc.replace('/', os.sep))
    if sha(p) != h: sys.exit('ABBRUCH: %s hat nicht die festgeschriebene Pruefsumme' % arc)
    files.append((arc, p))

# Sperrliste: feste Muster + (optional) echte Werte des Besitzers. Werte werden nie ausgegeben.
secrets = {'Nachname': 'Metz', 'E-Mail': 'kevin.metz', 'Benutzerpfad': 'Users\\kevin', 'Vorname': 'Kevin', 'Vorname2': 'Kati', 'Heimnetz-Adresse': '192.168.'}
if a.private:
    deck = json.load(open(os.path.join(a.private, 'deck.json'), encoding='utf-8-sig')); conf = json.load(open(os.path.join(a.private, 'config.json'), encoding='utf-8-sig'))
    secrets.update({'SteamGridDB-Schluessel': conf.get('steamGridDbKey'), 'Steam-Schluessel': deck.get('steamKey'), 'Hue-Kopplung': deck.get('hueUser'),
                    'Hue-Adresse': deck.get('hueIp'), 'Breitengrad': deck.get('wxLat'), 'Laengengrad': deck.get('wxLon'), 'Ort': deck.get('wxName')})
CASE = {'Vorname', 'Vorname2'}   # Vornamen nur in Grossschreibung als Wort sperren (kein Treffer in "Katalog" o. ae.)

def scan(label_file, b, text):
    bad = []
    for label, val in secrets.items():
        if not val: continue
        v = str(val)
        if label in CASE:
            if re.search(rb'\b' + re.escape(v.encode()) + rb'\b', b): bad.append((label_file, label))
            continue
        for enc in (v.encode('utf-8'), v.encode('utf-16le')):
            if enc.lower() in b.lower(): bad.append((label_file, label))
    if text:
        for m in re.finditer(rb'(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])', b):
            if m.group(0).lower() not in (b'0123456789abcdef0123456789abcdef', b'f' * 32): bad.append((label_file, '32-stellige Hex-Folge'))
    return bad

bad = []
for arc, src in files: bad += scan(arc, open(src, 'rb').read(), arc.endswith(TEXT))
# Alles, was ins oeffentliche Repo kommt, ebenfalls pruefen (ausser dieser Datei, die die Muster selbst enthaelt)
tracked = subprocess.run(['git', '-C', REPO, 'ls-files', '--cached', '--others', '--exclude-standard'], capture_output=True, text=True).stdout.split('\n')
for t in [x for x in tracked if x and x != 'setup/build.py']:
    p = os.path.join(REPO, t)
    if os.path.isfile(p): bad += scan('repo:' + t, open(p, 'rb').read(), t.endswith(TEXT))
if bad:
    print('ABBRUCH - persoenliche Daten gefunden:'); [print('  ', x) for x in sorted(set(bad))]; sys.exit(1)
print('Sperrpruefung ok (%d Paketdateien, %d Repo-Dateien)' % (len(files), len(tracked)))

os.makedirs(a.out, exist_ok=True)
pz = os.path.join(HERE, 'payload.zip')
if os.path.exists(pz): os.remove(pz)
with zipfile.ZipFile(pz, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for arc, src in files: z.write(src, arc)
exe = os.path.join(a.out, 'GameShelf-Deck-Setup.exe')
cmd = ['mcs', '-target:winexe', '-platform:x64', '-win32icon:' + os.path.join(SRC, 'deck.ico'), '-resource:' + pz + ',payload.zip',
       '-resource:' + os.path.join(SRC, 'deck.ico') + ',deck.ico', '-r:System.Windows.Forms.dll', '-r:System.Drawing.dll', '-r:System.IO.Compression.dll',
       '-r:System.IO.Compression.FileSystem.dll', '-r:System.Web.Extensions.dll', '-out:' + exe, os.path.join(HERE, 'Setup.cs')]
r = subprocess.run(cmd, capture_output=True, text=True)
if r.returncode != 0: print(r.stdout, r.stderr); sys.exit('ABBRUCH: Uebersetzen fehlgeschlagen')
os.remove(pz)
h = sha(exe)
open(os.path.join(a.out, 'SHA256SUMS.txt'), 'w', newline='\n').write('%s  GameShelf-Deck-Setup.exe\n' % h)
print('Version', ver_ps, '|', exe, os.path.getsize(exe), 'Bytes | SHA-256', h)
