# GameShelf Deck - Zweitbildschirm (CX133): Discord-Platz, Regal und Gaming-HUD.
# Start ueber "Deck starten.cmd". Einstellungen in deck.json, Fehler in deck.log.
# Oberflaeche: Deck.html in WebView2. Dieses Skript ist der Host: Fenster, Discord, Spiele, Afterburner, Hotkeys.

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = Join-Path $script:Root 'deck.log'
$script:SettingsFile = Join-Path $script:Root 'deck.json'
$script:ConfigFile = Join-Path $script:Root 'config.json'
$script:CacheFile = Join-Path $script:Root 'cache.json'
$script:CoverDir = Join-Path $script:Root 'covers'
$script:UserDir = Join-Path $script:Root 'user'
$script:Lib = Join-Path $script:Root 'lib'
$script:EmuProc = @{ Eden = 'eden'; PokeDinner = 'eglantine'; Fritchii = 'lichii' }
$script:NamesFile = Join-Path $script:UserDir 'names.json'
$script:HiddenFile = Join-Path $script:UserDir 'hidden.json'
$script:HiddenMsg = @()
$script:CouchFlag = Join-Path $script:UserDir 'couch.flag'
$script:CouchQuit = Join-Path $script:UserDir 'couch.quit'
$script:StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'GameShelf Deck.lnk'

function Log($msg) {
    try {
        if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 512KB) { Move-Item $script:LogFile ($script:LogFile + '.old') -Force }
        Add-Content -Path $script:LogFile -Value ("{0}  {1}" -f (Get-Date -Format s), $msg) -Encoding UTF8
    } catch { try { [DeckErr]::L('Z20', $_) } catch {} }
}

# Abgefangene Fehler protokollieren (gilt in allen Threads/Runspaces): deck-fehler.log, je Stelle max. 1 Zeile pro Minute
try {
    if (-not ('DeckErr' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.IO; using System.Collections.Generic;
public static class DeckErr {
    public static string Path;
    static readonly object K = new object();
    static readonly Dictionary<string, DateTime> Last = new Dictionary<string, DateTime>();
    static readonly Dictionary<string, int> Skip = new Dictionary<string, int>();
    public static void L(string tag, object err) {
        try {
            if (Path == null) return;
            lock (K) {
                DateTime now = DateTime.Now, t; int n;
                if (Last.TryGetValue(tag, out t) && (now - t).TotalSeconds < 60) { Skip.TryGetValue(tag, out n); Skip[tag] = n + 1; return; }
                Skip.TryGetValue(tag, out n); Skip[tag] = 0; Last[tag] = now;
                string msg = err == null ? "" : err.ToString().Replace("\r", " ").Replace("\n", " ");
                if (msg.Length > 300) msg = msg.Substring(0, 300);
                FileInfo fi = new FileInfo(Path);
                if (fi.Exists && fi.Length > 524288) { try { File.Copy(Path, Path + ".old", true); File.Delete(Path); } catch { } }
                File.AppendAllText(Path, now.ToString("s") + "  " + tag + "  " + msg + (n > 0 ? "  (+" + n + " weitere)" : "") + "\r\n");
            }
        } catch { }
    }
}
'@
    }
    [DeckErr]::Path = Join-Path $script:Root 'deck-fehler.log'
} catch { Log "Fehlerprotokoll nicht verfuegbar: $_" }

# ------------------------------------------------------------ eine Instanz; ein neuer Start loest die alte ab
$script:QuitEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'GameShelfDeck_Quit')
$script:Mutex = New-Object System.Threading.Mutex($false, 'GameShelfDeck_SingleInstance')
$own = $false
try { $own = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $own = $true }
if (-not $own) {
    [void]$script:QuitEvent.Set()
    try { $own = $script:Mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $own = $true }
    if (-not $own) { Log 'Alte Instanz reagiert nicht - Start abgebrochen.'; exit }
}
[void]$script:QuitEvent.Reset()
$script:Version = 'deckos-184'
Log '--- Start'
Log "Version $($script:Version)"

try {
    # ------------------------------------------------------------ Windows-Hilfen (einmal uebersetzt, danach als DLL)
    $nativeDll = Join-Path $script:Root 'DeckNative1.dll'
    $nativeSrc = Join-Path $script:Root 'DeckNative.cs'
    $loaded = $false
    if ((Test-Path $nativeDll) -and (Get-Item $nativeDll).LastWriteTime -ge (Get-Item $nativeSrc).LastWriteTime) {
        try { Add-Type -Path $nativeDll; $loaded = $true } catch { Log "Hilfs-DLL nicht ladbar: $_" }
    }
    if (-not $loaded) {
        $code = [IO.File]::ReadAllText($nativeSrc)
        try {
            if (Test-Path $nativeDll) { Remove-Item $nativeDll -Force -ErrorAction SilentlyContinue }
            Add-Type -TypeDefinition $code -OutputAssembly $nativeDll -ReferencedAssemblies System.Core
            Add-Type -Path $nativeDll
        } catch {
            Log "DLL-Ablage nicht moeglich, uebersetze im Speicher: $_"
            Add-Type -TypeDefinition $code -ReferencedAssemblies System.Core
        }
    }
    # Controller-Sperre: erkennt Vollbild-/Spielfenster im Vordergrund (auch Spiele, die nicht im Deck stehen)
    $script:PadGuardOk = $false
    try {
        if (-not ('DeckPadGuard' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class DeckPadGuard {
    [StructLayout(LayoutKind.Sequential)] struct RC { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct MI { public int cbSize; public RC rcMonitor; public RC rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RC r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MI i);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
    [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong32(IntPtr h, int i);
    static readonly string[] Shell = { "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow", "TopLevelWindowForOverflowXamlIsland", "NotifyIconOverflowWindow", "ForegroundStaging", "MultitaskingViewFrame", "TaskSwitcherWnd" };
    public static string LastClass = "";
    static readonly int Me = System.Diagnostics.Process.GetCurrentProcess().Id;
    // Vordergrundfenster: 0 = Desktop/Taskleiste/Deck/keins, 1 = normales Fenster, 2 = Vollbild/randlos ueber den ganzen Monitor
    public static int FgInfo(IntPtr deck, out int pid)
    {
        pid = 0;
        IntPtr fg = GetForegroundWindow();
        if (fg == IntPtr.Zero || !IsWindowVisible(fg) || IsIconic(fg)) return 0;
        IntPtr root = GetAncestor(fg, 2); if (root == IntPtr.Zero) root = fg;
        if (deck != IntPtr.Zero && root == deck) return 0;
        uint p; GetWindowThreadProcessId(root, out p); pid = (int)p;
        if (pid == Me) return 0;
        var sb = new StringBuilder(256); GetClassName(root, sb, 256); LastClass = sb.ToString();
        if (Array.IndexOf(Shell, LastClass) >= 0) return 0;
        RC w; if (!GetWindowRect(root, out w)) return 1;
        IntPtr mon = MonitorFromWindow(root, 2);
        MI mi = new MI(); mi.cbSize = Marshal.SizeOf(typeof(MI));
        if (mon == IntPtr.Zero || !GetMonitorInfo(mon, ref mi)) return 1;
        bool covers = w.L <= mi.rcMonitor.L && w.T <= mi.rcMonitor.T && w.R >= mi.rcMonitor.R && w.B >= mi.rcMonitor.B;
        if (!covers) return 1;
        const int WS_CAPTION = 0x00C00000;
        bool caption = (GetWindowLong32(root, -16) & WS_CAPTION) == WS_CAPTION;
        if (IsZoomed(root) && caption) return 1;   // nur maximiert (z. B. Browser bei ausgeblendeter Taskleiste) - kein Spiel
        return 2;
    }
}
'@
        }
        $script:PadGuardOk = $true
    } catch { Log "Controller-Sperre: Vordergrund-Erkennung nicht verfuegbar ($_)" }
    # Couch-Modus: Hauptbildschirm (virtueller Apollo-Bildschirm) ermitteln, Deck nach vorn holen
    $script:CouchOk = $false
    try {
        if (-not ('DeckCouch' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class DeckCouch {
    [StructLayout(LayoutKind.Sequential)] struct RC { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct MI { public int cbSize; public RC rcMonitor; public RC rcWork; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential)] struct PT { public int X, Y; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(PT pt, uint f);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MI i);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool on);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    // Hauptbildschirm (im Couch-Modus der virtuelle Apollo-Bildschirm): x, y, Breite, Hoehe in physischen Pixeln
    public static int[] Primary()
    {
        PT p = new PT(); p.X = 0; p.Y = 0;
        IntPtr m = MonitorFromPoint(p, 1);
        MI mi = new MI(); mi.cbSize = Marshal.SizeOf(typeof(MI));
        if (m == IntPtr.Zero || !GetMonitorInfo(m, ref mi)) return null;
        return new int[] { mi.rcMonitor.L, mi.rcMonitor.T, mi.rcMonitor.R - mi.rcMonitor.L, mi.rcMonitor.B - mi.rcMonitor.T };
    }
    // Fenster nach vorn holen (Windows blockt SetForegroundWindow sonst oft)
    public static bool Front(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        IntPtr fg = GetForegroundWindow();
        if (fg == h) return true;
        uint pid; uint ft = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out pid);
        uint me = GetCurrentThreadId();
        bool att = ft != 0 && ft != me && AttachThreadInput(me, ft, true);
        try { ShowWindow(h, 5); BringWindowToTop(h); SetForegroundWindow(h); }
        finally { if (att) AttachThreadInput(me, ft, false); }
        return GetForegroundWindow() == h;
    }
}
'@
        }
        $script:CouchOk = $true
    } catch { Log "Couch-Modus: Hilfsfunktionen nicht verfuegbar ($_)" }
    $script:IdleOk = $false
    try {
        if (-not ('DeckIdle' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class DeckIdle {
    [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII i);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    // Sekunden seit der letzten Eingabe am PC (Maus, Tastatur, Touch); Controller zaehlt hier nicht
    public static double Seconds()
    {
        LII i = new LII(); i.cbSize = (uint)Marshal.SizeOf(typeof(LII));
        if (!GetLastInputInfo(ref i)) return 0;
        return unchecked(GetTickCount() - i.dwTime) / 1000.0;
    }
    // Fenster nach oben legen, ohne es zu aktivieren (Idle-Bildschirm ueber Discord)
    public static bool Raise(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        return SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }
}
'@
        }
        $script:IdleOk = $true
    } catch { Log "Idle-Bildschirm: Eingabe-Erkennung nicht verfuegbar ($_)" }
    $script:Idle = $false; $script:IdlePad = [datetime]::UtcNow; $script:IdlePrev = $null
    $pm = [DeckNative]::PerMonitorAware()
    Log "DPI pro Monitor: $pm"
    try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { try { [DeckErr]::L('Z88', $_) } catch {} }

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
    try { Get-ChildItem $script:Lib -File | Unblock-File } catch { try { [DeckErr]::L('Z91', $_) } catch {} }
    Add-Type -Path (Join-Path $script:Lib 'Microsoft.Web.WebView2.Core.dll')
    Add-Type -Path (Join-Path $script:Lib 'Microsoft.Web.WebView2.Wpf.dll')
    [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($script:Lib)

    . (Join-Path $script:Root 'GameShelf.Core.ps1')
    # Erster Start: Einstellungen, Cover und Spieleliste aus einem vorhandenen GameShelf uebernehmen (nur lokal).
    $oldGs = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GameShelf'
    try {
        if (-not (Test-Path $script:ConfigFile) -and (Test-Path (Join-Path $oldGs 'config.json'))) { Copy-Item (Join-Path $oldGs 'config.json') $script:ConfigFile; Log 'GameShelf-Einstellungen uebernommen' }
        if (-not (Test-Path $script:CoverDir)) {
            New-Item -ItemType Directory -Path $script:CoverDir | Out-Null
            if (Test-Path (Join-Path $oldGs 'covers')) { Copy-Item (Join-Path $oldGs 'covers\*') $script:CoverDir -Recurse -ErrorAction SilentlyContinue; Log 'GameShelf-Cover uebernommen' }
        }
        if (-not (Test-Path $script:CacheFile) -and (Test-Path (Join-Path $oldGs 'cache.json'))) { Copy-Item (Join-Path $oldGs 'cache.json') $script:CacheFile }
    } catch { Log "Uebernahme aus GameShelf: $_" }
    $script:Config = Read-Config $script:ConfigFile
    $script:SteamRoot = Get-SteamRoot
    $script:RunningPid = 0

    # ------------------------------------------------------------ Einstellungen
    # dcposP/shareP gelten hochkant (Discord oben/unten), dcposL/shareL quer (Discord links/rechts, z. B. Xeneon Edge).
    $script:Settings = [ordered]@{ form = 'reel'; style = 'glas'; dtheme = 'dark'; dcposP = 'a'; shareP = 0.6; dcposL = 'b'; shareL = 0.5
        mode = 'auto'; monitor = ''; vramGB = 0; discordSplit = $true; autostart = $true
        modMusic = $true; modVoice = $true; modMixer = $true; modStats = $true; modHue = $true; hudArt = $true; touchOnly = $false; idleOn = $true; idleMin = 5; idleGlow = '#6D28D9'; idleLab = 'accent'; ui = 'os'; macroCustom = ''; hueIp = ''; hueUser = ''; flashSel = ''
        bg = 'deck'; blur = 'light'; tint = 'mid'; tone = 'system'; accentSel = 'accent'
        voiceMicKeys = 'Ctrl+Shift+F9'; voiceDeafKeys = 'Ctrl+Shift+F10' }
    foreach ($sf in @($script:SettingsFile, ($script:SettingsFile + '.bak'))) {   # ist deck.json beschaedigt, gilt die letzte gute Fassung (deckos-178)
        if (-not (Test-Path $sf)) { continue }
        try {
            $raw = Get-Content $sf -Raw -Encoding UTF8
            if (-not $raw -or -not $raw.Trim()) { throw 'Datei ist leer' }
            $j = $raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $script:Settings[$p.Name] = $p.Value }
            if ($j.PSObject.Properties['dcpos'] -and -not $j.PSObject.Properties['dcposP']) { $script:Settings.dcposP = [string]$j.dcpos }
            if ($j.PSObject.Properties['share'] -and -not $j.PSObject.Properties['shareP']) { $script:Settings.shareP = [double]$j.share }
            if ($j.PSObject.Properties['enforceDiscord'] -and -not $j.PSObject.Properties['discordSplit']) { $script:Settings.discordSplit = [bool]$j.enforceDiscord }
            foreach ($old in 'dcpos', 'share', 'enforceDiscord') { if ($script:Settings.Contains($old)) { $script:Settings.Remove($old) } }
            if ($sf -ne $script:SettingsFile) { Log 'deck.json aus der Sicherungskopie deck.json.bak gelesen' }
            break
        } catch { Log "deck.json nicht lesbar ($(Split-Path -Leaf $sf)): $_" }
    }
    if (@('auto', 'shelf', 'hud') -notcontains [string]$script:Settings.mode) { $script:Settings.mode = 'auto' }
    if (-not [string]$script:Settings.flashSel) { $script:Settings.flashSel = $(if ([string]$script:Config.flashColor) { ([string]$script:Config.flashColor).ToUpper() } else { '#7FB2FF' }) }
    # Erst in eine Nebendatei schreiben, dann tauschen; die vorige Fassung bleibt als deck.json.bak liegen (deckos-178)
    function Save-Settings {
        try {
            $json = ($script:Settings | ConvertTo-Json)
            $tmp = $script:SettingsFile + '.tmp'
            [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $true))
            if (Test-Path $script:SettingsFile) { [IO.File]::Replace($tmp, $script:SettingsFile, ($script:SettingsFile + '.bak')) } else { [IO.File]::Move($tmp, $script:SettingsFile) }
        } catch {
            Log "deck.json (sicheres Schreiben): $_"
            try { ($script:Settings | ConvertTo-Json) | Set-Content -Path $script:SettingsFile -Encoding UTF8 } catch { Log "deck.json: $_" }
        }
    }

    # Autostart ueber eine Verknuepfung im Autostart-Ordner des Nutzers.
    function Set-Autostart([bool]$on) {
        try {
            if ($on) {
                $sh = New-Object -ComObject WScript.Shell
                $l = $sh.CreateShortcut($script:StartupLink)
                $l.TargetPath = Join-Path $env:WINDIR 'System32\conhost.exe'
                $l.Arguments = '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "' + (Join-Path $script:Root 'Deck.ps1') + '"'
                $l.WorkingDirectory = $script:Root
                $l.WindowStyle = 7
                $l.Description = 'GameShelf Deck'
                $l.Save()
            } elseif (Test-Path $script:StartupLink) { Remove-Item $script:StartupLink -Force }
            Log ("Autostart: {0}" -f $on)
        } catch { Log "Autostart: $_" }
    }

    # Nutzer des PCs: Anzeigename und Kontobild.
    function Get-UserInfo {
        $name = $null
        try { Add-Type -AssemblyName System.DirectoryServices.AccountManagement; $name = [System.DirectoryServices.AccountManagement.UserPrincipal]::Current.DisplayName } catch { try { [DeckErr]::L('Z152', $_) } catch {} }
        if (-not $name) { try { $name = (Get-LocalUser -Name $env:USERNAME -ErrorAction Stop).FullName } catch { try { [DeckErr]::L('Z153', $_) } catch {} } }
        if (-not $name) { $n = [string]$env:USERNAME; if ($n) { $name = $n.Substring(0, 1).ToUpper() + $n.Substring(1) } }
        $avatar = ''
        try {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $k = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid" -ErrorAction Stop
            $src = $null
            foreach ($v in 'Image448', 'Image240', 'Image208', 'Image192', 'Image96') { if ($k.$v -and (Test-Path $k.$v)) { $src = $k.$v; break } }
            if ($src) {
                if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
                $dst = Join-Path $script:UserDir ('avatar' + [IO.Path]::GetExtension($src))
                if (Test-Path $dst) { try { [IO.File]::SetAttributes($dst, [IO.FileAttributes]::Normal) } catch { try { [DeckErr]::L('Z164', $_) } catch {} } }
                [IO.File]::WriteAllBytes($dst, [IO.File]::ReadAllBytes($src))
                [IO.File]::SetAttributes($dst, [IO.FileAttributes]::Normal)
                $avatar = 'https://gs.deck/user/' + [IO.Path]::GetFileName($dst) + '?v=' + (Get-Item $dst).LastWriteTimeUtc.Ticks
            } else { Log ("Profilbild: kein Bild in Registry fuer {0}" -f $sid) }
        } catch { Log "Profilbild (Registry): $_" }
        if (-not $avatar) {
            # Microsoft-Konto: Bild steckt in %APPDATA%\Microsoft\Windows\AccountPictures\*.accountpicture-ms (eingebettete JPEG/PNG)
            try {
                $ap = Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\AccountPictures') -Filter '*.accountpicture-ms' -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($ap) {
                    $b = [IO.File]::ReadAllBytes($ap.FullName); $best = $null; $i = 0
                    while ($i -lt $b.Length - 3) {
                        if ($b[$i] -eq 0xFF -and $b[$i + 1] -eq 0xD8 -and $b[$i + 2] -eq 0xFF) {
                            $j = $i + 2
                            while ($j -lt $b.Length - 1 -and -not ($b[$j] -eq 0xFF -and $b[$j + 1] -eq 0xD9)) { $j++ }
                            if (-not $best -or ($j - $i) -gt $best[1]) { $best = @($i, ($j + 2 - $i)) }
                            $i = $j
                        }
                        $i++
                    }
                    if ($best) {
                        if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
                        $dst = Join-Path $script:UserDir 'avatar.jpg'
                        if (Test-Path $dst) { try { [IO.File]::SetAttributes($dst, [IO.FileAttributes]::Normal) } catch { try { [DeckErr]::L('Z188', $_) } catch {} } }
                        $fs = [IO.File]::Create($dst); $fs.Write($b, $best[0], $best[1]); $fs.Close()
                        $avatar = 'https://gs.deck/user/avatar.jpg?v=' + (Get-Item $dst).LastWriteTimeUtc.Ticks
                    }
                }
            } catch { Log "Profilbild: $_" }
        }
        if (-not $avatar) {
            # Rueckfall: zuletzt erfolgreich kopiertes Bild weiterverwenden
            $f = Get-ChildItem $script:UserDir -Filter 'avatar.*' -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($f) { $avatar = 'https://gs.deck/user/' + $f.Name + '?v=' + $f.LastWriteTimeUtc.Ticks }
        }
        [ordered]@{ name = [string]$name; avatar = $avatar }
    }

    # ------------------------------------------------------------ Musik (Windows-Mediensteuerung) in eigenem Runspace
    $script:Media = [hashtable]::Synchronized(@{ Stop = $false; Title = ''; Artist = ''; App = ''; Playing = $false; Art = ''; Err = '' })
    $script:MediaCmds = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:MediaPs = $null
    function Start-MediaWorker {
        if ($script:MediaPs) { return }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            param($state, $cmds, $artDir)
            $ErrorActionPreference = 'Stop'
            try {
                Add-Type -AssemblyName System.Runtime.WindowsRuntime
                $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
                $null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
                $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
                $null = [Windows.Storage.Streams.InputStreamOptions, Windows.Storage.Streams, ContentType = WindowsRuntime]
                $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
                $asStream = $null; try { $asStream = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [type[]]@([Windows.Storage.Streams.IInputStream])) } catch { }
                function Await($op, [type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); if (-not $task.Wait(4000)) { throw 'Zeitueberschreitung' }; $task.Result }
                $mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
            } catch { $state.Err = "Start: $_"; return }
            $lastKey = ''; $n = 0; $artTries = 0
            while (-not $state.Stop) {
                try {
                    $s = $mgr.GetCurrentSession()
                    $c = $null
                    while ($cmds.TryDequeue([ref]$c)) {
                        if (-not $s) { continue }
                        switch ($c) {
                            'toggle' { [void](Await ($s.TryTogglePlayPauseAsync()) ([bool])) }
                            'next' { [void](Await ($s.TrySkipNextAsync()) ([bool])) }
                            'prev' { [void](Await ($s.TrySkipPreviousAsync()) ([bool])) }
                        }
                        Start-Sleep -Milliseconds 250
                    }
                    if ($s) {
                        $p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                        $pb = $s.GetPlaybackInfo()
                        $app = [string]$s.SourceAppUserModelId
                        $app = ($app -replace '\.exe$', '' -replace '^.*!', '' -replace '^.*\\', '')
                        if ($app -match '^Spotify') { $app = 'Spotify' }
                        elseif ($app -match '^([A-Za-z]+)\.[A-Za-z0-9]{8,}') { $app = $Matches[1] }   # z. B. Vivaldi.SMY6OBBMK… -> Vivaldi
                        switch -regex ($app) { '^msedge$' { $app = 'Edge' } '^chrome$' { $app = 'Chrome' } '^firefox$' { $app = 'Firefox' } '^opera' { $app = 'Opera' } '^brave$' { $app = 'Brave' } }
                        if ($app.Length -gt 1 -and $app -cmatch '^[a-z]') { $app = $app.Substring(0, 1).ToUpper() + $app.Substring(1) }
                        $state.Title = [string]$p.Title; $state.Artist = [string]$p.Artist; $state.App = $app
                        $state.Playing = ([string]$pb.PlaybackStatus -eq 'Playing')
                        $state.Album = [string]$p.AlbumTitle
                        try { $tl = $s.GetTimelineProperties(); $state.Pos = [double]$tl.Position.TotalSeconds; $state.Dur = [double]($tl.EndTime - $tl.StartTime).TotalSeconds; $state.PosAt = [double]$tl.LastUpdatedTime.ToUnixTimeMilliseconds() } catch { $state.Dur = 0 }
                        $key = "$($p.Title)|$($p.Artist)"
                        if ($key -ne $lastKey) { $lastKey = $key; $state.Art = ''; $artTries = 0 }
                        # Browser (YouTube u. a.) liefern das Vorschaubild oft erst nach dem Titel: bis ca. 10 s lang erneut versuchen
                        if (-not $state.Art -and $artTries -lt 12) {
                            $artTries++
                            if ($p.Thumbnail) {
                                try {
                                    $rs = Await ($p.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
                                    # Groesse wird von Browsern oft als 0 gemeldet: stueckweise bis zum Ende lesen (max. 8 MB)
                                    $ms = New-Object IO.MemoryStream
                                    $rd = $null; try { $rd = New-Object Windows.Storage.Streams.DataReader ($rs.GetInputStreamAt(0)) } catch { $rd = $null }
                                    if ($rd) {
                                        $rd.InputStreamOptions = [Windows.Storage.Streams.InputStreamOptions]::Partial
                                        for ($k = 0; $k -lt 128; $k++) {
                                            $got = [uint32](Await ($rd.LoadAsync(65536)) ([uint32]))
                                            if ($got -eq 0) { break }
                                            $chunk = New-Object byte[] $got; $rd.ReadBytes($chunk); $ms.Write($chunk, 0, $chunk.Length)
                                        }
                                        $rd.Dispose()
                                    } elseif ($asStream) {
                                        # deckos-179: PowerShell sieht den Datenstrom mancher Apps (Spotify) nur als COM-Objekt; dann ueber .NET lesen (max. 8 MB)
                                        $ns = $asStream.Invoke($null, @($rs)); $cb = New-Object byte[] 65536
                                        for ($k = 0; $k -lt 128; $k++) { $got = $ns.Read($cb, 0, $cb.Length); if ($got -le 0) { break }; $ms.Write($cb, 0, $got) }
                                        try { $ns.Dispose() } catch { }
                                    } else { throw 'Datenstrom nicht lesbar' }
                                    $buf = $ms.ToArray(); $ms.Dispose()
                                    if ($buf.Length -gt 500) {
                                        $n++; $ext = $(if ($buf[0] -eq 0x89) { 'png' } else { 'jpg' }); $f = Join-Path $artDir ("media{0}.{1}" -f ($n % 4), $ext)
                                        [IO.File]::WriteAllBytes($f, $buf)
                                        $state.Art = [IO.Path]::GetFileName($f) + '?v=' + $n; $state.ArtErr = ''
                                    } elseif ($artTries -ge 12) { $state.ArtErr = "Vorschaubild leer ($($buf.Length) Bytes, gemeldet $($rs.Size)) von $app" }
                                    try { $rs.Dispose() } catch { try { [DeckErr]::L('Z273', $_) } catch {} }
                                } catch { $state.ArtErr = "Vorschaubild: $($_.Exception.Message)" }
                            } elseif ($artTries -ge 12) { $state.ArtErr = "kein Vorschaubild von $app" }
                        }
                    } else { $state.Title = ''; $state.Artist = ''; $state.App = ''; $state.Playing = $false; $state.Art = ''; $state.Album = ''; $state.Dur = 0; $lastKey = '' }
                    $state.Err = ''
                } catch { $state.Err = "$_" }
                Start-Sleep -Milliseconds 900
            }
        }.ToString())
        if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
        [void]$ps.AddArgument($script:Media).AddArgument($script:MediaCmds).AddArgument($script:UserDir)
        $script:MediaPs = $ps
        [void]$ps.BeginInvoke()
        Log 'Musik-Steuerung gestartet'
    }

    # ------------------------------------------------------------ DeckOS: Philips Hue direkt ueber die Bridge (eigener Runspace)
    $script:Hue = [hashtable]::Synchronized(@{ Stop = $false; Active = $false; Ip = [string]$script:Settings.hueIp; User = [string]$script:Settings.hueUser; Out = ''; Stamp = 0; Save = $false; Log = '' })
    $script:HueCmds = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:HuePs = $null; $script:HueStamp = 0
    function Start-HueWorker {
        if ($script:HuePs) { return }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            param($H, $Q)
            $ErrorActionPreference = 'Stop'
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { try { [DeckErr]::L('Z300', $_) } catch {} }
            function Put($o) { $H.Out = ($o | ConvertTo-Json -Compress -Depth 6); $H.Stamp++ }
            function Api($method, $path, $body) {
                $u = "http://$($H.Ip)/api/$($H.User)$path"
                # Die Bridge schickt UTF-8 ohne Zeichensatz-Angabe: selbst als UTF-8 lesen (sonst wird aus "Küche" "KÃ¼che")
                $prm = @{ Method = $method; Uri = $u; TimeoutSec = 4; UseBasicParsing = $true }
                if ($null -ne $body) { $prm.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5)); $prm.ContentType = 'application/json; charset=utf-8' }
                $r = Invoke-WebRequest @prm
                return ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json)
            }
            $last = [datetime]::MinValue; $lastFind = [datetime]::MinValue; $findWait = 60
            while (-not $H.Stop) {
                try {
                    $c = $null
                    while ($Q.TryDequeue([ref]$c)) {
                        $o = $c | ConvertFrom-Json
                        switch ([string]$o.op) {
                            'discover' { $H.Ip = ''; $lastFind = [datetime]::MinValue; $findWait = 60 }
                            'pair' {
                                if ($H.Ip) {
                                    $r = Invoke-RestMethod -Method Post -Uri "http://$($H.Ip)/api" -Body '{"devicetype":"gameshelf_deck#pc"}' -ContentType 'application/json' -TimeoutSec 4
                                    $ok = @($r | Where-Object { $_.success }) | Select-Object -First 1
                                    if ($ok) { $H.User = [string]$ok.success.username; $H.Save = $true; $H.Log = 'Hue gekoppelt' }
                                    else { Put ([ordered]@{ type = 'hue'; status = 'pair'; ip = $H.Ip; msg = 'Link-Knopf nicht gedrueckt' }) }
                                }
                            }
                            'room' {
                                $b = [ordered]@{}
                                if ($null -ne $o.on) { $b.on = [bool]$o.on }
                                if ($null -ne $o.bri) { $b.bri = [int]$o.bri }
                                if ($null -ne $o.xy) { $b.xy = @([double]$o.xy[0], [double]$o.xy[1]) }
                                [void](Api 'Put' "/groups/$($o.id)/action" $b)
                            }
                            'scene' { [void](Api 'Put' "/groups/$($o.group)/action" ([ordered]@{ scene = [string]$o.id })) }
                            'scenebyname' {
                                $sc = Api 'Get' '/scenes' $null
                                $hit = $sc.PSObject.Properties | Where-Object { [string]$_.Value.name -match [regex]::Escape([string]$o.name) -and $_.Value.group } | Select-Object -First 1
                                if ($hit) { [void](Api 'Put' "/groups/$($hit.Value.group)/action" ([ordered]@{ scene = $hit.Name })) } else { $H.Log = "Hue: keine Szene '$($o.name)'" }
                            }
                            'alloff' { [void](Api 'Put' '/groups/0/action' ([ordered]@{ on = $false })) }
                        }
                        $last = [datetime]::MinValue
                    }
                    if (-not $H.Ip) {
                        if (((Get-Date) - $lastFind).TotalSeconds -ge $findWait) {
                            $lastFind = Get-Date
                            Put ([ordered]@{ type = 'hue'; status = 'search' })
                            try { $r = @(Invoke-RestMethod -Uri 'https://discovery.meethue.com/' -TimeoutSec 6); if ($r.Count -and $r[0].internalipaddress) { $H.Ip = [string]$r[0].internalipaddress; $H.Save = $true } } catch { try { [DeckErr]::L('Z347', $_) } catch {} }
                            if (-not $H.Ip) { Put ([ordered]@{ type = 'hue'; status = 'nobridge' }); $findWait = [math]::Min(3600, $findWait * 4) } else { $findWait = 60 }   # keine Bruecke: 4, 16, 60 min statt jede Minute (deckos-179, sonst 429 vom Suchdienst)
                        }
                    } elseif (-not $H.User) {
                        if (((Get-Date) - $last).TotalSeconds -ge 5) { $last = Get-Date; Put ([ordered]@{ type = 'hue'; status = 'pair'; ip = $H.Ip }) }
                    } elseif ($H.Active -and ((Get-Date) - $last).TotalSeconds -ge 3) {
                        $last = Get-Date
                        $g = Api 'Get' '/groups' $null
                        if ($g -is [array] -and $g[0].error) { if ([int]$g[0].error.type -eq 1) { $H.User = ''; $H.Save = $true }; throw [string]$g[0].error.description }
                        $rooms = @(); foreach ($p in $g.PSObject.Properties) { $v = $p.Value; if ($v.type -eq 'Room' -or $v.type -eq 'Zone') { $rooms += [ordered]@{ id = [string]$p.Name; name = [string]$v.name; lights = @($v.lights).Count; on = [bool]$v.state.any_on; bri = [int]$v.action.bri; zone = ($v.type -eq 'Zone'); xy = @($v.action.xy); ct = [int]$v.action.ct; cm = [string]$v.action.colormode } } }
                        $rooms = @($rooms | Sort-Object { $_.zone }, { $_.name })
                        $sc = Api 'Get' '/scenes' $null
                        $seen = @{}; $scenes = @()
                        foreach ($p in $sc.PSObject.Properties) { $v = $p.Value; if ($v.type -eq 'GroupScene' -and -not $v.recycle -and -not $seen.ContainsKey([string]$v.name)) { $seen[[string]$v.name] = 1; $scenes += [ordered]@{ id = [string]$p.Name; name = [string]$v.name; group = [string]$v.group } } }
                        $pref = 'gaming|film|kino|hell|gem.tlich|entspann|nacht|konzentr'
                        $scenes = @($scenes | Sort-Object { if ($_.name -match $pref) { 0 } else { 1 } }, { $_.name })
                        Put ([ordered]@{ type = 'hue'; status = 'ok'; rooms = $rooms; scenes = $scenes })
                    }
                } catch { Put ([ordered]@{ type = 'hue'; status = 'error'; ip = $H.Ip; msg = "$_" }); Start-Sleep -Seconds 2 }
                Start-Sleep -Milliseconds 250
            }
        }.ToString())
        [void]$ps.AddArgument($script:Hue).AddArgument($script:HueCmds)
        $script:HuePs = $ps
        [void]$ps.BeginInvoke()
        Log 'Hue-Anbindung gestartet'
    }
    function Poll-Hue {
        if (-not $script:HuePs) { return }
        if ($script:Hue.Save) {
            $script:Hue.Save = $false
            $script:Settings.hueIp = [string]$script:Hue.Ip; $script:Settings.hueUser = [string]$script:Hue.User; Save-Settings
            Log ("Hue: Bridge {0}{1}" -f $script:Hue.Ip, $(if ($script:Hue.User) { ' gekoppelt' } else { '' }))
        }
        if ($script:Hue.Log) { Log $script:Hue.Log; $script:Hue.Log = '' }
        if ($script:Hue.Stamp -ne $script:HueStamp -and $script:Hue.Out -and $script:Ready) {
            $script:HueStamp = $script:Hue.Stamp
            try { $script:Wv.CoreWebView2.PostWebMessageAsJson([string]$script:Hue.Out) } catch { try { [DeckErr]::L('Z384', $_) } catch {} }
        }
    }

    # ------------------------------------------------------------ DeckOS: Makro-Tasten
    function Send-KeySpec([string]$spec) {
        $map = @{ CTRL = 0x11; STRG = 0x11; SHIFT = 0x10; UMSCHALT = 0x10; ALT = 0x12; WIN = 0x5B }
        $vks = @()
        foreach ($p in ($spec.ToUpper() -split '\+')) {
            $p = $p.Trim()
            if ($map.ContainsKey($p)) { $vks += $map[$p] }
            elseif ($p -match '^F(\d{1,2})$') { $vks += 0x6F + [int]$Matches[1] }
            elseif ($p.Length -eq 1) { $vks += [int][char]$p }
        }
        if ($vks.Count) { [void][DeckNative]::SendCombo([int[]]$vks) }
    }
    $script:WpPaused = $false
    # ---------- Farbige App-Symbole fuer Vollbild-Meldungen (einmal erzeugt, in user\icons zwischengespeichert) ----------
    $script:AppIcons = [hashtable]::Synchronized(@{ Busy = $false; Done = $false; Map = @{}; Log = '' })
    function Start-AppIcons {
        if ($script:AppIcons.Busy) { return }; $script:AppIcons.Busy = $true; $script:AppIcons.Done = $false
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
        $ps = [PowerShell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($A, $Dir, $SteamRoot)
            $note = New-Object System.Collections.ArrayList
            try {
                if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
                if (-not ('DeckIconX2' -as [type])) {
                    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class DeckIconX2 {
  [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm); }
  [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx; public int cy; }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)] static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
  public static bool Save(string parsingName, string png, int size) {
    IShellItemImageFactory f; SHCreateItemFromParsingName(parsingName, IntPtr.Zero, new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), out f);
    IntPtr hb; int hr = f.GetImage(new SIZE { cx = size, cy = size }, 0x1 | 0x4, out hb); if (hr != 0 || hb == IntPtr.Zero) return false;
    try {
      using (Bitmap b = Image.FromHbitmap(hb)) {
        Rectangle r = new Rectangle(0, 0, b.Width, b.Height); BitmapData d = b.LockBits(r, ImageLockMode.ReadOnly, b.PixelFormat);
        try { using (Bitmap a = new Bitmap(d.Width, d.Height, d.Stride, PixelFormat.Format32bppArgb, d.Scan0)) using (Bitmap c = new Bitmap(a)) c.Save(png, ImageFormat.Png); } finally { b.UnlockBits(d); }
      }
    } finally { DeleteObject(hb); }
    KnockOut(png);
    return true;
  }
  // Volle quadratische Kachel (z. B. NVIDIA): Hintergrund von den Ecken aus transparent machen, damit nur das Logo bleibt
  public static void KnockOut(string png) {
    Bitmap src; using (var fs = System.IO.File.OpenRead(png)) src = new Bitmap(fs);
    using (src) {
      int w = src.Width, h = src.Height; Color c0 = src.GetPixel(1, 1);
      if (c0.A < 250) return;
      foreach (var p in new[] { new Point(w - 2, 1), new Point(1, h - 2), new Point(w - 2, h - 2) }) { Color c = src.GetPixel(p.X, p.Y); if (Math.Abs(c.R - c0.R) + Math.Abs(c.G - c0.G) + Math.Abs(c.B - c0.B) > 30) return; }
      var bmp = new Bitmap(src); var seen = new bool[w, h]; var q = new System.Collections.Generic.Queue<Point>();
      q.Enqueue(new Point(0, 0)); q.Enqueue(new Point(w - 1, 0)); q.Enqueue(new Point(0, h - 1)); q.Enqueue(new Point(w - 1, h - 1));
      while (q.Count > 0) {
        var p = q.Dequeue(); if (p.X < 0 || p.Y < 0 || p.X >= w || p.Y >= h || seen[p.X, p.Y]) continue; seen[p.X, p.Y] = true;
        Color c = bmp.GetPixel(p.X, p.Y); int d = Math.Abs(c.R - c0.R) + Math.Abs(c.G - c0.G) + Math.Abs(c.B - c0.B);
        if (d > 40 || c.A < 10) continue;
        bmp.SetPixel(p.X, p.Y, Color.FromArgb(0, c.R, c.G, c.B));
        q.Enqueue(new Point(p.X + 1, p.Y)); q.Enqueue(new Point(p.X - 1, p.Y)); q.Enqueue(new Point(p.X, p.Y + 1)); q.Enqueue(new Point(p.X, p.Y - 1));
      }
      src.Dispose(); bmp.Save(png, ImageFormat.Png); bmp.Dispose();
    }
  }
}
"@
                }
                $apps = @{}; try { foreach ($sa in Get-StartApps) { $apps[[string]$sa.Name] = [string]$sa.AppID } } catch { try { [DeckErr]::L('Z455', $_) } catch {} }
                $byName = { param($rx) foreach ($k in $apps.Keys) { if ($k -match $rx) { return 'shell:AppsFolder\' + $apps[$k] } }; $null }
                $byPath = { param($paths) foreach ($pp in $paths) { if ($pp -and (Test-Path $pp)) { return $pp } }; $null }
                $srcs = [ordered]@{
                    whatsapp = (& $byName '^WhatsApp$')
                    vivaldi = (& $byPath @((Join-Path $env:LOCALAPPDATA 'Vivaldi\Application\vivaldi.exe'), (Join-Path $env:ProgramFiles 'Vivaldi\Application\vivaldi.exe')))
                    huesync = (& $byPath @((Join-Path $env:ProgramFiles 'Hue Sync\HueSync.exe')))
                    steam = (& $byPath @($(if ($SteamRoot) { Join-Path $SteamRoot 'steam.exe' })))
                    nvidia = (& $byName '^NVIDIA( App)?$')
                    wallpaper = (& $byPath @($(if ($SteamRoot) { Join-Path $SteamRoot 'steamapps\common\wallpaper_engine\wallpaper64.exe' })))
                    snip = (& $byName '^(Snipping Tool|Snipping-Tool|Ausschneide-Tool)$')
                    xbox = (& $byName '^(Xbox|Xbox Accessories|Xbox-Zubeh.r)$')
                    logitech = (& $byName '^(LGHUB|Logitech G HUB|G HUB)$')
                    corsair = (& $byName '^iCUE')
                    steelseries = (& $byName '^SteelSeries GG$')
                    afterburner = (& $byName '^MSI Afterburner$')
                    settings = (& $byName '^(Einstellungen|Settings)$')
                    spotify = (& $byName '^Spotify')
                    edge = (& $byName '^Microsoft Edge$')
                    chrome = (& $byName '^Google Chrome$')
                    firefox = (& $byName '^Firefox')
                    applemusic = (& $byName '^Apple Music$')
                    discord = (& $byName '^Discord$')
                    claude = (& $byName '^Claude$')
                    rhi = (& $byName '(^|\W)RHI(\W|$)')
                    dlss = (& $byName '^DLSS ?Swapper')
                    nordvpn = $(if (& $byName '^NordVPN') { & $byName '^NordVPN' } else { & $byPath @((Join-Path $env:ProgramFiles 'NordVPN\NordVPN.exe')) })
                    aniworld = $(if (& $byName 'ani ?world') { & $byName 'ani ?world' } else { & $byPath @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Aniworld.lnk'), (Join-Path $env:USERPROFILE 'Desktop\Aniworld.lnk')) })
                    explorer = (& $byPath @((Join-Path $env:WINDIR 'explorer.exe')))
                }
                foreach ($k in $srcs.Keys) {
                    $f = Join-Path $Dir ($k + '.png'); $s = $srcs[$k]
                    if ((Test-Path $f) -and ((Get-Date) - (Get-Item $f).LastWriteTime).TotalDays -lt 30) { $A.Map[$k] = $f; continue }
                    if (-not $s) { [void]$note.Add("$k fehlt"); continue }
                    try { if ([DeckIconX2]::Save($s, $f, 256)) { $A.Map[$k] = $f } else { [void]$note.Add("$k leer") } } catch { [void]$note.Add("$k : $($_.Exception.Message)") }
                }
                # Webseiten: Favicons in hoher Aufloesung
                try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { try { [DeckErr]::L('Z491', $_) } catch {} }
                foreach ($w in @(@('youtube', 'youtube.com'), @('nexusmods', 'nexusmods.com'), @('amazon', 'amazon.de'), @('reddit', 'reddit.com'))) {
                    $f = Join-Path $Dir ($w[0] + '.png')
                    if ((Test-Path $f) -and ((Get-Date) - (Get-Item $f).LastWriteTime).TotalDays -lt 30) { $A.Map[$w[0]] = $f; continue }
                    try { Invoke-WebRequest -Uri ("https://www.google.com/s2/favicons?domain=" + $w[1] + "&sz=256") -OutFile $f -UseBasicParsing -TimeoutSec 15; if ((Get-Item $f).Length -gt 200) { $A.Map[$w[0]] = $f } } catch { [void]$note.Add("$($w[0]) Favicon: $($_.Exception.Message)") }
                }
            } catch { [void]$note.Add([string]$_.Exception.Message) }
            $A.Log = ($note -join '; '); $A.Done = $true; $A.Busy = $false
        }.ToString())
        [void]$ps.AddArgument($script:AppIcons).AddArgument((Join-Path $script:UserDir 'icons2')).AddArgument($script:SteamRoot)
        [void]$ps.BeginInvoke()
    }
    function Send-AppIcons {
        $m = [ordered]@{}; foreach ($k in @($script:AppIcons.Map.Keys)) { $f = $script:AppIcons.Map[$k]; if (Test-Path $f) { $m[$k] = 'https://gs.deck/user/icons2/' + [IO.Path]::GetFileName($f) + '?v=' + (Get-Item $f).LastWriteTimeUtc.Ticks } }
        Send ([ordered]@{ type = 'appicons'; map = $m })
    }
    function Poll-AppIcons { if ($script:AppIcons.Done) { $script:AppIcons.Done = $false; if ($script:AppIcons.Log) { Log "App-Symbole: $($script:AppIcons.Log)" }; Send-AppIcons } }
    # ---------- Steam-Downloads: appmanifest_*.acf aller Bibliotheken beobachten (nur geaenderte Dateien lesen) ----------
    $script:Dl = @{ Libs = @(); LibsAt = [datetime]::MinValue; Files = @{}; Act = @{}; Last = ''; Rx = [int64]0; RxT = $null }
    function Get-SteamLibs {
        $libs = @(); if (-not $script:SteamRoot) { return $libs }
        $libs += (Join-Path $script:SteamRoot 'steamapps')
        $f = Join-Path $script:SteamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path $f) { foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f), '"path"\s+"([^"]+)"')) { $p = ($m.Groups[1].Value -replace '\\\\', '\') ; $sa = Join-Path $p 'steamapps'; if ((Test-Path $sa) -and ($libs -notcontains $sa)) { $libs += $sa } } }
        $libs
    }
    function Read-Acf([string]$path) {
        $tx = [IO.File]::ReadAllText($path); $o = @{}
        foreach ($k in 'appid', 'name', 'StateFlags', 'BytesToDownload', 'BytesDownloaded', 'BytesToStage', 'BytesStaged') { $m = [regex]::Match($tx, '"' + $k + '"\s+"([^"]*)"'); if ($m.Success) { $o[$k] = $m.Groups[1].Value } }
        $o
    }
    # Steam schreibt BytesDownloaded nur selten in die Manifest-Datei. Live-Stand daher: letzter Manifest-Stand + seitdem empfangene Netzwerk-Bytes.
    function Get-NetRx { $s = [int64]0; try { foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) { if ($n.OperationalStatus -eq 'Up' -and $n.NetworkInterfaceType -ne 'Loopback' -and $n.NetworkInterfaceType -ne 'Tunnel') { $s += $n.GetIPStatistics().BytesReceived } } } catch { try { [DeckErr]::L('Z523', $_) } catch {} }; $s }
    # Groesse von steamapps\downloading\<appid> im Hintergrund messen (Steam schreibt BytesDownloaded erst am Ende)
    $script:DlSize = [hashtable]::Synchronized(@{})
    function Start-DlSize([string]$lib, [string]$id) {
        $k = "$id|busy"; if ($script:DlSize[$k]) { return }; $script:DlSize[$k] = $true
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({ param($S, $Dir, $Id) $sum = [int64]0; try { if (Test-Path $Dir) { foreach ($f in [IO.Directory]::EnumerateFiles($Dir, '*', [IO.SearchOption]::AllDirectories)) { try { $sum += ([IO.FileInfo]$f).Length } catch { try { [DeckErr]::L('Z529a', $_) } catch {} } } } } catch { try { [DeckErr]::L('Z529b', $_) } catch {} }; $S[$Id] = $sum; $S["$Id|at"] = Get-Date; $S["$Id|busy"] = $false }.ToString())
        [void]$ps.AddArgument($script:DlSize).AddArgument((Join-Path $lib ("downloading\" + $id))).AddArgument($id)
        [void]$ps.BeginInvoke()
    }
    function Poll-SteamDownloads {
        if (-not $script:SteamRoot) { return }
        if (((Get-Date) - $script:Dl.LibsAt).TotalSeconds -gt 120) { $script:Dl.Libs = Get-SteamLibs; $script:Dl.LibsAt = Get-Date }
        $now = Get-Date; $rx = Get-NetRx; $items = New-Object System.Collections.ArrayList; $done = $null
        $rate = 0.0; if ($script:Dl.RxT) { $dt = ($now - $script:Dl.RxT).TotalSeconds; if ($dt -gt 0.5) { $rate = [math]::Max(0.0, [double](($rx - $script:Dl.Rx) / $dt)) } }
        $script:Dl.Rx = $rx; $script:Dl.RxT = $now
        $seenIds = @{}
        foreach ($lib in $script:Dl.Libs) {
            foreach ($fi in @(Get-ChildItem -Path $lib -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
                $key = $fi.FullName; $c = $script:Dl.Files[$key]
                if (-not $c -or $c.T -ne $fi.LastWriteTimeUtc) { try { $c = @{ T = $fi.LastWriteTimeUtc; D = (Read-Acf $key) }; $script:Dl.Files[$key] = $c } catch { continue } }
                $d = $c.D; $id = [string]$d.appid; if (-not $id) { continue }
                $flags = [int64]$(if ($d.StateFlags) { $d.StateFlags } else { 0 }); $tot = [int64]$(if ($d.BytesToDownload) { $d.BytesToDownload } else { 0 }); $got = [int64]$(if ($d.BytesDownloaded) { $d.BytesDownloaded } else { 0 })
                $active = (($flags -band 1024) -ne 0) -or ($tot -gt 0 -and $got -lt $tot -and $flags -ne 4)
                $a = $script:Dl.Act[$id]
                if ($active) {
                    $seenIds[$id] = 1
                    # Fortschritt: Steam schreibt BytesDownloaded erst am Ende, der Download-Ordner ist vorab voll belegt.
                    # Daher zaehlt das Deck die empfangenen Netzwerk-Bytes selbst mit und merkt sie sich ueber Neustarts (user\dl-progress.json).
                    if (-not $a) {
                        $acc = [int64]0; try { $pf = Join-Path $script:UserDir 'dl-progress.json'; if (Test-Path $pf) { $pj = Get-Content $pf -Raw | ConvertFrom-Json; if ($pj.$id) { $acc = [int64]$pj.$id } } } catch { try { [DeckErr]::L('Z553', $_) } catch {} }
                        $a = @{ name = [string]$d.name; acc = [math]::Max($acc, $got); lastRx = $rx; miss = 0; saved = $now }; $script:Dl.Act[$id] = $a
                        Log ("Steam-Download: {0} (StateFlags {1}, Steam meldet {2} von {3} Bytes, Deck-Zaehler {4})" -f $d.name, $flags, $got, $tot, $a.acc)
                    }
                    $a.miss = 0
                    $a.acc += [math]::Max(0, $rx - $a.lastRx); $a.lastRx = $rx
                    if ($got -gt $a.acc) { $a.acc = $got }
                    if (($now - $a.saved).TotalSeconds -ge 10) { $a.saved = $now; try { $pm = @{}; foreach ($kk in $script:Dl.Act.Keys) { $pm[$kk] = [int64]$script:Dl.Act[$kk].acc }; ($pm | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $script:UserDir 'dl-progress.json') -Encoding UTF8 } catch { try { [DeckErr]::L('Z560', $_) } catch {} } }
                    $live = [int64]$a.acc; if ($tot -gt 0) { $live = [math]::Min($live, [int64]($tot * 0.995)) }
                    $pct = $(if ($tot -gt 0) { [math]::Round($live * 100.0 / $tot, 1) } else { -1 })
                    [void]$items.Add([ordered]@{ appid = $id; name = [string]$d.name; upd = (($flags -band 4) -ne 0) })
                } elseif ($a) {
                    if ($flags -eq 4) { $script:Dl.Act.Remove($id); $done = [ordered]@{ appid = $id; name = $a.name }; Log "Steam-Download fertig: $($a.name)"; try { $pm = @{}; foreach ($kk in $script:Dl.Act.Keys) { $pm[$kk] = [int64]$script:Dl.Act[$kk].acc }; ($pm | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $script:UserDir 'dl-progress.json') -Encoding UTF8 } catch { try { [DeckErr]::L('Z565', $_) } catch {} } }
                    else { $a.miss++; if ($a.miss -ge 10) { $script:Dl.Act.Remove($id) } else { [void]$items.Add([ordered]@{ appid = $id; name = $a.name; upd = $true }) } }   # kurz nicht aktiv (Pause/Umschalten): nicht flackern
                }
            }
        }
        $msg = [ordered]@{ type = 'dl'; items = @($items); done = $done }
        $j = ($msg | ConvertTo-Json -Depth 4 -Compress); if ($j -ne $script:Dl.Last -or $done) { $script:Dl.Last = $j; Send $msg }
    }
    # Mixer: Browser-Prozess -> echter Browsername (Symbol kommt ueber denselben Namen)
    function Get-BrowserName([string]$n) {
        switch -Regex ($n) { '^msedge$' { 'Edge' } '^chrome$' { 'Chrome' } '^firefox$' { 'Firefox' } '^vivaldi$' { 'Vivaldi' } '^opera$' { 'Opera' } '^brave$' { 'Brave' } default { $n } }
    }
    # App aus dem Startmenue oeffnen (auch installierte Web-Apps); Name per Muster
    function Open-StartApp([string]$rx, [string]$label, [switch]$Quiet) {
        $all = @(); try { $all = @(Get-StartApps) } catch { try { [DeckErr]::L('Z579', $_) } catch {} }
        $hit = $all | Where-Object { $_.Name -match $rx } | Select-Object -First 1
        if ($hit) { Start-Process explorer.exe ('shell:AppsFolder\' + $hit.AppID); Log "Makro: $label -> $($hit.Name)"; return $true }
        if (-not $Quiet) { Log ("Makro: $label nicht im Startmenue gefunden. Vorhanden: " + (($all | ForEach-Object { $_.Name }) -join ', ')) } else { Log "Makro: $label nicht im Startmenue, nehme Ersatz" }
        return $false
    }
    # Vivaldi mit fester Seite oeffnen (neuer Tab im laufenden Fenster)
    function Open-Vivaldi([string]$url) {
        $exe = $null
        foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\vivaldi.exe', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\vivaldi.exe') { try { $v = (Get-ItemProperty $k -ErrorAction Stop).'(default)'; if ($v -and (Test-Path $v)) { $exe = $v; break } } catch { try { [DeckErr]::L('Z588', $_) } catch {} } }
        if (-not $exe) { foreach ($c in @((Join-Path $env:LOCALAPPDATA 'Vivaldi\Application\vivaldi.exe'), (Join-Path $env:ProgramFiles 'Vivaldi\Application\vivaldi.exe'))) { if (Test-Path $c) { $exe = $c; break } } }
        if ($exe) { Start-Process -FilePath $exe -ArgumentList $url } else { Log 'Makro: Vivaldi nicht gefunden – oeffne im Standardbrowser'; Start-Process $url }
    }
    # Hue-Sync-App: oeffnen (falls noetig) und den Sync-Knopf per Windows-Bedienungshilfe (UI Automation) druecken.
    # Danach geht der Fokus an das vorher aktive Fenster (z. B. das Spiel) zurueck.
    $script:HueSync = [hashtable]::Synchronized(@{ Busy = $false; Done = $false; Res = ''; Log = '' })
    function Start-HueSyncToggle {
        if ($script:HueSync.Busy) { return }
        $script:HueSync.Busy = $true; $script:HueSync.Done = $false
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            param($H)
            $note = New-Object System.Collections.ArrayList
            try {
                Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
                if (-not ('HsWin' -as [type])) { Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class HsWin { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }' }
                $fg = [HsWin]::GetForegroundWindow()
                $findProc = { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(HueSync|Hue ?Sync|huesync)$' }) }
                $procs = & $findProc
                $exe = $null
                foreach ($c in @((Join-Path $env:ProgramFiles 'Hue Sync\HueSync.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Hue Sync\HueSync.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\hue-sync\HueSync.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\Hue Sync\HueSync.exe'))) { if ($c -and (Test-Path $c)) { $exe = $c; break } }
                if (-not $exe -and $procs.Count) { try { $exe = $procs[0].Path } catch { try { [DeckErr]::L('Z610', $_) } catch {} } }
                $win = $null
                $getWin = { param($ps2) foreach ($pp in $ps2) { $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pp.Id); $w = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $c); if ($w) { return $w } }; $null }
                if ($procs.Count) { $win = & $getWin $procs }
                if (-not $win) {
                    if ($exe) { Start-Process -FilePath $exe; [void]$note.Add("gestartet: $exe") } else { try { Start-Process 'shell:AppsFolder\Signify.HueSync_' -ErrorAction Stop } catch { try { [DeckErr]::L('Z615', $_) } catch {} }; [void]$note.Add('HueSync.exe nicht gefunden') }
                    for ($i = 0; $i -lt 30 -and -not $win; $i++) { Start-Sleep -Milliseconds 400; $procs = & $findProc; if ($procs.Count) { $win = & $getWin $procs } }
                }
                if (-not $win) { throw 'Hue-Sync-Fenster nicht gefunden' }
                $btnCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
                $btn = $null
                for ($i = 0; $i -lt 10 -and -not $btn; $i++) {
                    $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
                    $names = @(); foreach ($b in $all) { $n = [string]$b.Current.Name; if ($n) { $names += $n }; if (-not $btn -and $n -match '(sync|synchron)') { $btn = $b } }
                    if (-not $btn) { Start-Sleep -Milliseconds 500 }
                }
                if (-not $btn) { throw ('Sync-Knopf nicht gefunden. Knoepfe: ' + (($names | Select-Object -First 15) -join ' | ')) }
                $label = [string]$btn.Current.Name
                $ip = $null; if ($btn.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) { $ip.Invoke() } else { throw "Knopf '$label' laesst sich nicht ausloesen" }
                $H.Res = $(if ($label -match '(stop|beend|anhalt)') { 'stop' } else { 'start' }); [void]$note.Add("Knopf: $label")
                Start-Sleep -Milliseconds 300
                if ($fg -ne [IntPtr]::Zero -and [HsWin]::GetForegroundWindow() -ne $fg) { [void][HsWin]::SetForegroundWindow($fg) }
            } catch { $H.Res = 'err'; [void]$note.Add([string]$_.Exception.Message) }
            $H.Log = ($note -join '; '); $H.Done = $true; $H.Busy = $false
        }.ToString())
        [void]$ps.AddArgument($script:HueSync)
        [void]$ps.BeginInvoke()
    }
    function Poll-HueSync {
        if (-not $script:HueSync.Done) { return }
        $script:HueSync.Done = $false; Log "Hue Sync: $($script:HueSync.Res) – $($script:HueSync.Log)"
        Send ([ordered]@{ type = 'huesync'; res = [string]$script:HueSync.Res; info = $(if ($script:HueSync.Res -eq 'err') { [string]$script:HueSync.Log } else { '' }) })
    }
    function Invoke-Macro([string]$id) {
        try {
            switch ($id) {
                'shot' { [void][DeckNative]::SendCombo([int[]](0x5B, 0x10, 0x53)) }   # Snipping Tool: Win + Umschalt + S
                'clip' { [void][DeckNative]::SendCombo([int[]](0x12, 0x79)) }
                'rec' { [void][DeckNative]::SendCombo([int[]](0x12, 0x78)) }
                'notif' { [void][DeckNative]::SendCombo([int[]](0x5B, 0x4E)) }
                'voldown' { [void][DeckNative]::SendCombo([int[]](0xAE)) }
                'volup' { [void][DeckNative]::SendCombo([int[]](0xAF)) }
                'lock' { Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,LockWorkStation' }
                'wp' {
                    $wp = Get-Process -Name wallpaper64, wallpaper32 -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
                    if ($wp) { $script:WpPaused = -not $script:WpPaused; Start-Process -FilePath $wp.Path -ArgumentList '-control', $(if ($script:WpPaused) { 'pause' } else { 'play' }) } else { Log 'Makro: Wallpaper Engine laeuft nicht' }
                }
                'huegaming' { Start-HueWorker; $script:HueCmds.Enqueue('{"op":"scenebyname","name":"gaming"}') }
                'huesync' {
                    # nur die Hue-Sync-App oeffnen (bzw. nach vorn holen) – Fernbedienung der App klappt nicht (31.10.)
                    $hs = $null; foreach ($c in @((Join-Path $env:ProgramFiles 'Hue Sync\HueSync.exe'), (Join-Path ${env:ProgramFiles(x86)} 'Hue Sync\HueSync.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\Hue Sync\HueSync.exe'))) { if ($c -and (Test-Path $c)) { $hs = $c; break } }
                    if ($hs) { Start-Process -FilePath $hs } else { Log 'Makro: Hue Sync nicht gefunden' }
                }
                'vyt' { Open-Vivaldi 'https://www.youtube.com/' }
                'vnexus' { Open-Vivaldi 'https://www.nexusmods.com/' }
                'vamazon' { Open-Vivaldi 'https://www.amazon.de/' }
                'vreddit' { Open-Vivaldi 'https://www.reddit.com/' }
                'vclaude' { Open-Claude }
                'vrhi' { [void](Open-StartApp '(^|\W)RHI(\W|$)' 'RHI') }
                'vdlss' { [void](Open-StartApp '^DLSS ?Swapper' 'DLSS Swapper') }
                'vnord' {
                    if (-not (Open-StartApp '^NordVPN' 'NordVPN' -Quiet)) {
                        $nv = $null
                        foreach ($c in @((Join-Path $env:ProgramFiles 'NordVPN\NordVPN.exe'), (Join-Path ${env:ProgramFiles(x86)} 'NordVPN\NordVPN.exe'))) { if ($c -and (Test-Path $c)) { $nv = $c; break } }
                        if ($nv) { Start-Process -FilePath $nv } else { Log 'Makro: NordVPN nicht gefunden' }
                    }
                }
                'vani' {
                    # Verknuepfung auf dem Desktop (Vivaldi-Web-App) hat Vorrang
                    $lnk = $null; foreach ($c in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Aniworld.lnk'), (Join-Path $env:USERPROFILE 'Desktop\Aniworld.lnk'))) { if ($c -and (Test-Path -LiteralPath $c)) { $lnk = $c; break } }
                    if ($lnk) { Start-Process -FilePath $lnk; Log "Makro: AniWorld -> $lnk" }
                    elseif (-not (Open-StartApp 'ani ?world' 'AniWorld' -Quiet)) { Open-Vivaldi 'https://aniworld.to/' }
                }
                'custom' { if ([string]$script:Settings.macroCustom) { Send-KeySpec ([string]$script:Settings.macroCustom) } else { Log 'Makro: macroCustom in deck.json ist leer' } }
            }
            Log "Makro: $id"
        } catch { Log "Makro $id fehlgeschlagen: $_" }
    }
    $script:OsPage = ''
    $script:LastMutes = ''
    function Send-Mutes {
        $mi = -1; $sp = -1
        try { $mi = [DeckNative]::EndpointMute(1, -1); $sp = [DeckNative]::EndpointMute(0, -1) } catch { try { [DeckErr]::L('Z685', $_) } catch {} }
        $k = "$mi|$sp"; if ($k -eq $script:LastMutes) { return }
        $script:LastMutes = $k
        Send ([ordered]@{ type = 'mutes'; mic = ($mi -eq 1); deaf = ($sp -eq 1) })
    }
    # Kamera: Windows-Datenschutzschalter (HKCU, kein Admin) + Erkennung, ob gerade eine App die Kamera nutzt
    $script:CamKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'
    # Hart-Modus: geplante Aufgabe \GameShelfDeck\Kamera (eingerichtet per "Kamera einrichten.cmd") deaktiviert die USB-Kamera wirklich
    $script:CamHard = $null; $script:CamHardAt = [datetime]::MinValue; $script:CamOn = $null; $script:CamReqAt = $null; $script:CamErr = ''
    function Test-CamHard {
        return $false   # Hart-Modus auf Wunsch zurueckgenommen (31.10., Disable-PnpDevice meldete "Allgemeiner Fehler")
        if ($script:CamHard -or ((Get-Date) - $script:CamHardAt).TotalSeconds -lt 30) { return [bool]$script:CamHard }
        $script:CamHardAt = Get-Date
        $script:CamHard = [bool](Get-ScheduledTask -TaskPath '\GameShelfDeck\' -TaskName 'Kamera' -ErrorAction SilentlyContinue)
        if ($script:CamHard -and $null -eq $script:CamOn) {
            try { $d = @(Get-PnpDevice -ErrorAction Stop | Where-Object { ($_.Class -eq 'Camera' -or $_.Class -eq 'Image') -and $_.InstanceId -like 'USB\*' }); $script:CamOn = [bool](@($d | Where-Object { $_.Status -eq 'OK' }).Count) } catch { $script:CamOn = $true }
            Log ("Kamera: Hart-Modus aktiv, Kamera " + $(if ($script:CamOn) { 'an' } else { 'aus' }))
        }
        return [bool]$script:CamHard
    }
    function Read-CamResult {
        if (-not $script:CamReqAt) { return }
        $f = Join-Path $script:UserDir 'cam-result.txt'
        if ((Test-Path $f) -and (Get-Item $f).LastWriteTime -ge $script:CamReqAt) {
            $r = [IO.File]::ReadAllText($f).Trim(); $script:CamReqAt = $null
            if ($r -like 'on|*') { $script:CamOn = $true } elseif ($r -like 'off|*') { $script:CamOn = $false } else { $script:CamErr = ($r -replace '^err\|', '') }
            Log "Kamera: $r"
        } elseif (((Get-Date) - $script:CamReqAt).TotalSeconds -gt 12) { $script:CamReqAt = $null; $script:CamErr = 'Keine Antwort der Aufgabe'; Log 'Kamera: keine Antwort der geplanten Aufgabe' }
    }
    function Get-CamState {
        # Registry direkt ueber .NET lesen (gleiche Werte wie frueher per Get-ChildItem, aber ohne den langsamen PowerShell-Provider)
        $allowed = $true; $app = ''
        if ($script:CamReqAt) { Read-CamResult }
        $hard = Test-CamHard
        if ($hard) { $allowed = [bool]$script:CamOn }
        $root = $null; $np = $null
        try {
            $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam')
            if ($root) {
                if (-not $hard) { $v = $root.GetValue('Value'); if ($v -eq 'Deny') { $allowed = $false } }
                $cands = New-Object System.Collections.ArrayList
                foreach ($n in $root.GetSubKeyNames()) { if ($n -ne 'NonPackaged') { [void]$cands.Add(@($root, $n)) } }
                $np = $root.OpenSubKey('NonPackaged'); if ($np) { foreach ($n in $np.GetSubKeyNames()) { [void]$cands.Add(@($np, $n)) } }
                foreach ($c in $cands) {
                    $k = $null; try { $k = $c[0].OpenSubKey($c[1]) } catch { try { [DeckErr]::L('Z729', $_) } catch {} }
                    if (-not $k) { continue }
                    $s0 = $k.GetValue('LastUsedTimeStart'); $s1 = $k.GetValue('LastUsedTimeStop'); $k.Close()
                    if ($s0 -and [int64]$s0 -gt 0 -and $null -ne $s1 -and [int64]$s1 -eq 0) { $n = ([string]$c[1] -split '#')[-1] -replace '\.exe$', '' -replace '_[a-z0-9]{13}$', ''; $app = $n; break }
                }
            }
        } catch { try { [DeckErr]::L('Z735a', $_) } catch {} } finally { if ($np) { try { $np.Close() } catch { try { [DeckErr]::L('Z735b', $_) } catch {} } }; if ($root) { try { $root.Close() } catch { try { [DeckErr]::L('Z735c', $_) } catch {} } } }
        return @{ allowed = $allowed; app = $app }
    }
    function Send-Cam([switch]$Force) {
        $c = Get-CamState; $err = $script:CamErr; $script:CamErr = ''; $k = "$($c.allowed)|$($c.app)|$err"
        if (-not $Force -and $k -eq $script:LastCam) { return }
        $script:LastCam = $k
        Send ([ordered]@{ type = 'cam'; allowed = [bool]$c.allowed; app = [string]$c.app; hard = [bool]$script:CamHard; busy = [bool]$script:CamReqAt; err = [string]$err })
    }
    # Einmal pro Start: Kamera wieder vollstaendig einschalten (Geraet per Aufgabe aktivieren, Datenschutz-Schalter auf Erlauben)
    $script:CamRestored = $false
    function Restore-Cam {
        if ($script:CamRestored) { return }; $script:CamRestored = $true
        try { Set-ItemProperty -Path $script:CamKey -Name Value -Value 'Allow'; $np = Join-Path $script:CamKey 'NonPackaged'; if (Test-Path $np) { $prev = [string]$script:Settings['camNP']; if (-not $prev) { $prev = 'Allow' }; Set-ItemProperty -Path $np -Name Value -Value $prev } } catch { Log "Kamera-Wiederherstellung (Zugriff): $($_.Exception.Message)" }
        try {
            if (Get-ScheduledTask -TaskPath '\GameShelfDeck\' -TaskName 'Kamera' -ErrorAction SilentlyContinue) {
                if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
                [IO.File]::WriteAllText((Join-Path $script:UserDir 'cam-request.txt'), 'on'); $script:CamReqAt = (Get-Date).AddSeconds(-1)
                Start-ScheduledTask -TaskPath '\GameShelfDeck\' -TaskName 'Kamera'; Log 'Kamera: Wiederherstellung – Geraet einschalten angefordert'
            }
        } catch { Log "Kamera-Wiederherstellung (Geraet): $($_.Exception.Message)" }
    }
    function Set-Cam([bool]$allow) {
        if (Test-CamHard) {
            if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
            [IO.File]::WriteAllText((Join-Path $script:UserDir 'cam-request.txt'), $(if ($allow) { 'on' } else { 'off' }))
            $script:CamReqAt = (Get-Date).AddSeconds(-1)
            Start-ScheduledTask -TaskPath '\GameShelfDeck\' -TaskName 'Kamera'
            Log ("Kamera: hart " + $(if ($allow) { 'einschalten' } else { 'ausschalten' }) + " angefordert"); return
        }
        $np = Join-Path $script:CamKey 'NonPackaged'
        if (-not $allow) {
            try { $script:Settings['camNP'] = [string](Get-ItemProperty -Path $np -Name Value -ErrorAction Stop).Value; Save-Settings } catch { try { [DeckErr]::L('Z767', $_) } catch {} }
            Set-ItemProperty -Path $script:CamKey -Name Value -Value 'Deny'
            if (Test-Path $np) { Set-ItemProperty -Path $np -Name Value -Value 'Deny' }
        } else {
            Set-ItemProperty -Path $script:CamKey -Name Value -Value 'Allow'
            $prev = [string]$script:Settings['camNP']; if (-not $prev) { $prev = 'Allow' }
            if (Test-Path $np) { Set-ItemProperty -Path $np -Name Value -Value $prev }
        }
        Log ("Kamera-Zugriff: " + $(if ($allow) { 'erlaubt' } else { 'gesperrt' }))
    }
    function Send-Bright {
        $v = -1
        try { $v = [DeckNative]::Brightness([string]$script:Settings.monitor, -1) } catch { Log "Helligkeit: $_" }
        if ($v -lt 0 -and -not $script:BrightLogged) { Log 'Helligkeit: DDC/CI nicht verfuegbar'; $script:BrightLogged = $true }
        Send ([ordered]@{ type = 'bright'; value = $v })
    }
    $script:LastMediaKey = ''
    function Send-Media {
        $m = $script:Media
        if ($m.Err -and $m.Err -ne $script:LastMediaErr) { Log ("Musik: " + $m.Err); $script:LastMediaErr = $m.Err }
        if ($m.ArtErr -and $m.ArtErr -ne $script:LastArtErr) { Log ("Musik: " + $m.ArtErr); $script:LastArtErr = $m.ArtErr }
        $art = ''; if ($m.Art) { $art = 'https://gs.deck/user/' + $m.Art }
        $obj = [ordered]@{ title = [string]$m.Title; artist = [string]$m.Artist; app = [string]$m.App; playing = [bool]$m.Playing; art = $art; album = [string]$m.Album; pos = [math]::Round([double]$m.Pos, 1); dur = [math]::Round([double]$m.Dur, 1); posAt = [double]$m.PosAt }
        $key = ($obj | ConvertTo-Json -Compress)
        if ($key -eq $script:LastMediaKey) { return }
        $script:LastMediaKey = $key
        Send ([ordered]@{ type = 'media'; media = $obj })
    }

    # ------------------------------------------------------------ Lautstaerke-Mixer: Spiel, Discord, Musik
    $script:MusicProcs = 'Spotify|AppleMusic|iTunes|foobar2000|MusicBee|TIDAL|Deezer|vlc|msedge|chrome|firefox|vivaldi|opera|brave'
    function Get-MixerGroups {
        $sess = @([DeckNative]::AudioSessions())
        $groups = New-Object System.Collections.ArrayList
        $gamePids = @()
        if ($script:Running) {
            $g = $script:Games | Where-Object { $_.Id -eq $script:Running } | Select-Object -First 1
            foreach ($s in $sess) {
                $hit = $false
                if ($script:RunningPid -and $s.Pid -eq $script:RunningPid) { $hit = $true }
                elseif ($g -and $g.InstallDir) { try { $pp = (Get-Process -Id $s.Pid -ErrorAction Stop).Path; if ($pp -and $pp.StartsWith($g.InstallDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $hit = $true } } catch { try { [DeckErr]::L('Z807', $_) } catch {} } }
                if ($hit) { $gamePids += $s.Pid }
            }
        }
        $pick = {
            param($key, $label, $pids)
            $ss = @($sess | Where-Object { $pids -contains $_.Pid })
            if ($ss.Count) { [void]$groups.Add([ordered]@{ key = $key; label = $label; vol = [math]::Round(($ss | Measure-Object Vol -Maximum).Maximum, 2); mute = (@($ss | Where-Object { -not $_.Mute }).Count -eq 0); pids = @($ss | ForEach-Object { $_.Pid }) }) }
        }
        if ($gamePids.Count) { & $pick 'game' 'Spiel' $gamePids }
        & $pick 'discord' 'Discord' @($sess | Where-Object { $_.Name -match '^Discord' } | ForEach-Object { $_.Pid })
        $mus = @($sess | Where-Object { $_.Name -match "^($($script:MusicProcs))$" -and $gamePids -notcontains $_.Pid })
        if ($mus.Count) {
            $first = ($mus | Where-Object { $_.Name -eq 'Spotify' } | Select-Object -First 1); if (-not $first) { $first = $mus[0] }
            $lab = Get-BrowserName $first.Name
            & $pick 'music' $lab @($mus | Where-Object { $_.Name -eq $first.Name } | ForEach-Object { $_.Pid })
        }
        if ($script:OsPage -eq 'media') {
            $used = @($groups | ForEach-Object { $_.pids } | ForEach-Object { $_ })
            $rest = @($sess | Where-Object { $used -notcontains $_.Pid -and $_.Name -and $_.Name -notmatch '^(Idle|System|audiodg)$' })
            foreach ($nm in @($rest | ForEach-Object { $_.Name } | Select-Object -Unique)) {
                $lab = Get-BrowserName $nm; if ($lab -ne $nm) { } elseif ($nm -match '^wallpaper(32|64)$') { $lab = 'Wallpaper' }
                & $pick ('p:' + $nm) $lab @($rest | Where-Object { $_.Name -eq $nm } | ForEach-Object { $_.Pid })
            }
        }
        $script:MixerGroups = $groups
        , $groups
    }
    function Send-Mixer {
        $g = Get-MixerGroups
        Send ([ordered]@{ type = 'mixer'; sessions = @($g | ForEach-Object { [ordered]@{ key = $_.key; label = $_.label; vol = $_.vol; mute = $_.mute } }) })
    }

    # ------------------------------------------------------------ Discord: Mikro/Ton ueber Discords globale Tastenkuerzel
    function Send-VoiceKey($which) {
        $spec = [string]$(if ($which -eq 'mic') { $script:Settings.voiceMicKeys } else { $script:Settings.voiceDeafKeys })
        $map = @{ CTRL = 0x11; STRG = 0x11; SHIFT = 0x10; UMSCHALT = 0x10; ALT = 0x12 }
        $vks = @()
        foreach ($p in ($spec.ToUpper() -split '\+')) {
            $p = $p.Trim()
            if ($map.ContainsKey($p)) { $vks += $map[$p] }
            elseif ($p -match '^F(\d{1,2})$') { $vks += 0x6F + [int]$Matches[1] }
            elseif ($p.Length -eq 1) { $vks += [int][char]$p }
        }
        if ($vks.Count) { [void][DeckNative]::SendCombo([int[]]$vks); Log "Discord-Kuerzel $spec gesendet ($which)" }
    }

    # ------------------------------------------------------------ Rechtsklick-Aktionen
    function Invoke-GameContext($action, $id, $name) {
        $g = $script:Games | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        try {
            switch ($action) {
                'files' { if ($g -and $g.InstallDir -and (Test-Path $g.InstallDir)) { Start-Process explorer.exe ('"' + $g.InstallDir + '"') } }
                'nexus' { Start-Process ('https://www.nexusmods.com/search?keyword=' + [Uri]::EscapeDataString([string]$name)) }
                'store' { if ($g -and $g.SteamAppId) { Start-Process ('steam://store/' + $g.SteamAppId) } }
            }
            Log "Kontextmenue: $action ($name)"
        } catch { Log "Kontextmenue $action : $_" }
    }

    # Spielzeit der letzten zwei Wochen je Steam-App (Steam: Playtime2wks, Minuten).
    function Get-SteamPlaytimes2w($steamRoot) {
        $h = @{}
        if (-not $steamRoot) { return $h }
        $ud = Join-Path $steamRoot 'userdata'
        if (-not (Test-Path $ud)) { return $h }
        $f = Get-ChildItem $ud -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'config\localconfig.vdf' } |
            Where-Object { Test-Path $_ } | Get-Item | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $f) { return $h }
        $t = [IO.File]::ReadAllText($f.FullName)
        $rx = New-Object Text.RegularExpressions.Regex ('"(\d+)"\s*\{(?:[^{}]|\{[^{}]*\})*?"Playtime2wks"\s+"(\d+)"')
        foreach ($m in $rx.Matches($t)) { $v = [int]$m.Groups[2].Value; if ($v -gt 0) { $h[$m.Groups[1].Value] = $v } }
        $h
    }

    # Grafikspeicher der groessten Grafikkarte aus der Registry (fuer "VRAM von x GB").
    function Get-VramGB {
        if ([double]$script:Settings.vramGB -gt 0) { return [int]$script:Settings.vramGB }
        $best = 0
        try {
            Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | ForEach-Object {
                $v = (Get-ItemProperty $_.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
                if ($v -and [double]$v -gt $best) { $best = [double]$v }
            }
        } catch { try { [DeckErr]::L('Z891', $_) } catch {} }
        if ($best -gt 0) { return [int][math]::Round($best / 1GB) }
        16
    }

    function Get-AccentHex {
        try {
            $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -ErrorAction Stop).AccentColorMenu
            if ($null -ne $v) {
                $n = [uint32]([int64]$v -band 4294967295)   # Wert kommt je nach System als Int32 oder UInt32 (deckos-178)
                return ('#{0:X2}{1:X2}{2:X2}' -f ($n -band 0xFF), (($n -shr 8) -band 0xFF), (($n -shr 16) -band 0xFF))
            }
        } catch { try { [DeckErr]::L('Z903', $_) } catch {} }
        '#3B82F6'
    }

    # ------------------------------------------------------------ Spiele (eigene Liste, im Hintergrund aktualisiert)
    $script:CacheStamp = [DateTime]::MinValue
    $script:Games = @()
    $script:LibCache = $null
    if ($script:SteamRoot) { $lc = Join-Path $script:SteamRoot 'appcache\librarycache'; if (Test-Path $lc) { $script:LibCache = $lc } }

    function Get-AssetUrl($path) {
        if (-not $path) { return '' }
        $full = [IO.Path]::GetFullPath($path)
        $base = $null; $hostName = $null
        if ($full.StartsWith($script:Root + '\', [StringComparison]::OrdinalIgnoreCase)) { $base = $script:Root; $hostName = 'gs.deck' }
        elseif ($script:LibCache -and $full.StartsWith($script:LibCache + '\', [StringComparison]::OrdinalIgnoreCase)) { $base = $script:LibCache; $hostName = 'steam.deck' }
        if (-not $base) { return '' }
        $parts = $full.Substring($base.Length + 1).Split('\') | ForEach-Object { [Uri]::EscapeDataString($_) }
        $v = ''; if ($hostName -eq 'gs.deck') { try { $v = '?v=' + (Get-Item $full).LastWriteTimeUtc.Ticks } catch { try { [DeckErr]::L('Z921', $_) } catch {} } }
        return ('https://' + $hostName + '/' + ($parts -join '/') + $v)
    }

    $script:LogoBox = @{}
    function Get-LogoBox([string]$p) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $null }
        $key = $p + '|' + (Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks
        if ($script:LogoBox.ContainsKey($key)) { return $script:LogoBox[$key] }
        $res = $null
        try {
            $img = [System.Drawing.Image]::FromFile($p)
            try {
                $tw = 160; $th = [math]::Max(1, [int][math]::Round($img.Height * $tw / [math]::Max(1, $img.Width)))
                $bmp = New-Object System.Drawing.Bitmap $tw, $th
                $gr = [System.Drawing.Graphics]::FromImage($bmp); $gr.DrawImage($img, 0, 0, $tw, $th); $gr.Dispose()
                $x0 = $tw; $y0 = $th; $x1 = -1; $y1 = -1
                for ($y = 0; $y -lt $th; $y++) { for ($x = 0; $x -lt $tw; $x++) { if ($bmp.GetPixel($x, $y).A -gt 24) { if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x }; if ($y -lt $y0) { $y0 = $y }; if ($y -gt $y1) { $y1 = $y } } } }
                $bmp.Dispose()
                if ($x1 -ge $x0 -and $y1 -ge $y0) { $res = @([math]::Round($x0 / $tw, 4), [math]::Round($y0 / $th, 4), [math]::Round(($x1 + 1 - $x0) / $tw, 4), [math]::Round(($y1 + 1 - $y0) / $th, 4), $img.Width, $img.Height) }
            } finally { $img.Dispose() }
        } catch { Log "Logo-Rand: $_" }
        $script:LogoBox[$key] = $res
        return $res
    }
    function Load-Games {
        $list = @(Read-GameCache $script:CacheFile)
        if ($list.Count -eq 0 -and @($script:Games).Count -gt 0) { return }
        $hidden = @($script:Config.hidden)
        $pattern = [string]$script:Config.excludePattern
        $times = @{}
        try { $times = Get-SteamPlaytimes $script:SteamRoot } catch { Log "Spielzeiten: $_" }
        $times2 = @{}; try { $times2 = Get-SteamPlaytimes2w $script:SteamRoot } catch { try { [DeckErr]::L('Z953', $_) } catch {} }
        $emu = @{}; try { $emu = Read-EmuPlayed } catch { Log "Emulator-Spielzeiten: $_" }
        $names = Read-GameNames
        $hidUser = Read-HiddenGames
        $hidOut = New-Object System.Collections.ArrayList
        foreach ($g in $list) {
            $o = [string]$g.Name
            if ($names.ContainsKey([string]$g.Id)) { $g | Add-Member -NotePropertyName NameOrig -NotePropertyValue $o -Force; $g.Name = [string]$names[[string]$g.Id] }
        }
        $t2w = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 14 * 86400
        $out = New-Object System.Collections.ArrayList
        foreach ($g in ($list | Sort-Object @{ Expression = 'LastPlayed'; Descending = $true }, Name)) {
            if ($hidden -contains $g.Id) { continue }
            if ($hidUser.ContainsKey([string]$g.Id)) {
                $hc0 = Find-CoverFile '' $g.Id; if (-not $hc0) { $hc0 = Find-CoverFile 'auto_' $g.Id }
                if (-not $hc0 -and $g.SteamAppId) { try { $hc0 = Find-SteamLocalCover $script:SteamRoot $g.SteamAppId } catch { try { [DeckErr]::L('Z958h', $_) } catch {} } }
                [void]$hidOut.Add([ordered]@{ id = $g.Id; name = $g.Name; src = [string]$g.Source; cover = (Get-AssetUrl $hc0) })
                continue
            }
            if ($pattern -and $g.Source -eq 'Steam' -and $g.Name -match $pattern) { continue }
            $cover = Find-CoverFile '' $g.Id
            $custom = [bool]$cover
            if (-not $cover) { $cover = Find-CoverFile 'auto_' $g.Id }
            if (-not $cover -and $g.SteamAppId) { try { $cover = Find-SteamLocalCover $script:SteamRoot $g.SteamAppId } catch { try { [DeckErr]::L('Z961', $_) } catch {} } }
            $hero = $null
            if ($g.SteamAppId) { try { $hero = Resolve-Hero $g $script:SteamRoot } catch { try { [DeckErr]::L('Z963', $_) } catch {} } }
            # Spiel-Logo: eigenes/geladenes (covers\logo_<id>.png) oder lokal aus Steam - ohne Netz
            $logo = Find-CoverFile 'logoc_' $g.Id; $cLogo = [bool]$logo   # eigenes Logo (Metadaten anpassen) vor geladenem
            if (-not $logo) { $logo = Find-CoverFile 'logo_' $g.Id }
            if (-not $logo -and $g.SteamAppId) { try { $logo = Find-SteamLocalAsset $script:SteamRoot $g.SteamAppId @('logo.png') } catch { try { [DeckErr]::L('Z966', $_) } catch {} } }
            $min = 0
            if ($g.SteamAppId -and $times.ContainsKey([string]$g.SteamAppId)) { $min = [int]$times[[string]$g.SteamAppId] }
            $min2 = 0; if ($g.SteamAppId -and $times2.ContainsKey([string]$g.SteamAppId)) { $min2 = [int]$times2[[string]$g.SteamAppId] }
            if (-not $hero) { $hero = Find-CoverFile 'hero_' $g.Id }   # Nicht-Steam: Titelbild von SteamGridDB
            $hc = Find-CoverFile 'heroc_' $g.Id; $cHero = [bool]$hc; if ($hc) { $hero = $hc }   # eigenes Titelbild (Metadaten anpassen)
            if ($script:EmuProc.ContainsKey([string]$g.Source) -and $emu.ContainsKey($g.Id)) { $e = $emu[$g.Id]; $min = [int]$e.min; foreach ($x in @($e.s)) { if ($x.t -ge $t2w) { $min2 += [int]$x.m } } }
            $nOrig = [string]$g.Name; if ($g.PSObject.Properties['NameOrig'] -and $g.NameOrig) { $nOrig = [string]$g.NameOrig }
            [void]$out.Add([ordered]@{ id = $g.Id; name = $g.Name; nameOrig = $nOrig; renamed = ($nOrig -ne [string]$g.Name); last = [int64]$g.LastPlayed; time = $min; time2w = $min2; hasDir = [bool]($g.InstallDir -and (Test-Path $g.InstallDir)); steam = [bool]$g.SteamAppId; custom = $custom; customLogo = $cLogo; customHero = $cHero; cover = (Get-AssetUrl $cover); hero = (Get-AssetUrl $hero); logo = (Get-AssetUrl $logo); logoBox = (Get-LogoBox $logo) })
        }
        $script:Games = $list
        $script:GamesMsg = @($out)
        $script:HiddenMsg = @($hidOut | Sort-Object { $_.name })
        try { $script:CacheStamp = (Get-Item $script:CacheFile).LastWriteTimeUtc } catch { try { [DeckErr]::L('Z974', $_) } catch {} }
        try { $script:CacheText = [IO.File]::ReadAllText($script:CacheFile) } catch { $script:CacheText = $null }
        $script:PlayStamp = Get-PlayStamp
        Log ("Spiele geladen: {0}" -f $out.Count)
    }
    # Zeitstempel der Steam-Spielzeiten (localconfig.vdf) - nur wenn der sich aendert, muessen die Spielzeiten neu gelesen werden
    function Get-PlayStamp {
        try {
            if (-not $script:SteamRoot) { return '' }
            $ud = Join-Path $script:SteamRoot 'userdata'; if (-not (Test-Path $ud)) { return '' }
            $t = [datetime]::MinValue
            foreach ($d in [IO.Directory]::GetDirectories($ud)) { $f = [IO.Path]::Combine($d, 'config', 'localconfig.vdf'); if ([IO.File]::Exists($f)) { $w = [IO.File]::GetLastWriteTimeUtc($f); if ($w -gt $t) { $t = $w } } }
            return [string]$t.Ticks
        } catch { return '' }
    }
    # Spieleliste neu laden, aber nur wenn sich die Bibliothek oder die Spielzeiten wirklich geaendert haben
    function Test-GamesChanged {
        try {
            $w = (Get-Item $script:CacheFile).LastWriteTimeUtc
            if ($w -ne $script:CacheStamp) {
                $txt = [IO.File]::ReadAllText($script:CacheFile)
                if ($txt -ne $script:CacheText) { return $true }
                $script:CacheStamp = $w   # nur neu geschrieben, Inhalt gleich
            }
        } catch { try { [DeckErr]::L('Z998', $_) } catch {} }
        return $false
    }

    # Bibliothek neu einlesen (Steam, Epic, Xbox, eigene Eintraege) und fehlende Cover holen - in eigenem Runspace.
    $script:RefreshPs = $null; $script:RefreshHandle = $null
    function Start-LibraryRefresh {
        if ($script:RefreshHandle -and -not $script:RefreshHandle.IsCompleted) { return }
        if ($script:RefreshPs) { try { [void]$script:RefreshPs.EndInvoke($script:RefreshHandle) } catch { try { [DeckErr]::L('Z1006', $_) } catch {} }; $script:RefreshPs.Dispose() }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            param($core, $cfgFile, $cacheFile, $coverDir, $logFile)
            $ErrorActionPreference = 'Continue'
            . $core
            $script:LogFile = $logFile; $script:CoverDir = $coverDir
            $script:Config = Read-Config $cfgFile
            $sr = Get-SteamRoot
            $games = @(Get-AllGames $script:Config $sr)
            if ($games.Count -eq 0) { return }
            $old = ''; if (Test-Path $cacheFile) { $old = [IO.File]::ReadAllText($cacheFile) }
            $new = ConvertTo-Json -InputObject @($games) -Depth 4
            $missing = @($games | Where-Object { -not (Find-CoverFile '' $_.Id) -and -not (Find-CoverFile 'auto_' $_.Id) -and -not ($_.SteamAppId -and (Find-SteamLocalCover $sr $_.SteamAppId)) })
            $got = 0; foreach ($g in $missing) { try { if (Resolve-Cover $g $sr) { $got++ } } catch { try { [DeckErr]::L('Z1020', $_) } catch {} } }
            if ($old -ne $new -or $got -gt 0) { Save-GameCache $games $cacheFile }   # vorher bei jedem fehlenden Cover alle 5 min neu geschrieben -> unnoetiges Neuladen
        }.ToString())
        [void]$ps.AddArgument((Join-Path $script:Root 'GameShelf.Core.ps1')).AddArgument($script:ConfigFile).AddArgument($script:CacheFile).AddArgument($script:CoverDir).AddArgument($script:LogFile)
        $script:RefreshPs = $ps
        $script:RefreshHandle = $ps.BeginInvoke()
    }

    # ------------------------------------------------------------ Spiel-Logos im Hintergrund nachladen (SteamGridDB), einmal je Sitzung
    $script:LogoPs = $null; $script:LogoHandle = $null; $script:LogoDone = $false
    function Start-LogoFetch {
        if ($script:LogoPs -or $script:LogoDone) { return }
        if (-not $script:LogoTried) { $script:LogoTried = @{} }   # je Sitzung jedes Spiel nur einmal nachschlagen
        $missing = @($script:GamesMsg | Where-Object { (-not $_.logo -or (-not $_.steam -and -not $_.hero)) -and -not $script:LogoTried.ContainsKey($_.id) } | ForEach-Object { $script:LogoTried[$_.id] = 1; $id = $_.id; $script:Games | Where-Object { $_.Id -eq $id } | Select-Object -First 1 })
        if ($missing.Count -eq 0) { $script:LogoDone = $true; return }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            param($core, $cfgFile, $coverDir, $logFile, $steamRoot, $games)
            $n = 0
            try {
                . $core
                $script:LogFile = $logFile; $script:CoverDir = $coverDir
                $script:Config = Read-Config $cfgFile
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                foreach ($g in $games) { try { if (Resolve-Logo $g $steamRoot) { $n++ } } catch { try { [DeckErr]::L('Z1043', $_) } catch {} }; if (-not $g.SteamAppId) { try { if (-not (Find-CoverFile 'hero_' $g.Id) -and (Resolve-HeroSgdb $g)) { $n++ } } catch { try { [DeckErr]::L('Z1043h', $_) } catch {} } }; Start-Sleep -Milliseconds 300 }
            } catch { try { [DeckErr]::L('Z1044', $_) } catch {} }
            "LOGOS:$n"
        }.ToString())
        [void]$ps.AddArgument((Join-Path $script:Root 'GameShelf.Core.ps1')).AddArgument($script:ConfigFile).AddArgument($script:CoverDir).AddArgument($script:LogFile).AddArgument($script:SteamRoot).AddArgument($missing)
        $script:LogoPs = $ps; $script:LogoHandle = $ps.BeginInvoke()
        Log "Spiel-Logos: suche $($missing.Count) fehlende"
    }
    function Poll-LogoFetch {
        if (-not $script:LogoPs -or -not $script:LogoHandle.IsCompleted) { return }
        $n = 0; try { $out = $script:LogoPs.EndInvoke($script:LogoHandle); foreach ($o in $out) { if ([string]$o -match '^LOGOS:(\d+)') { $n = [int]$Matches[1] } } } catch { try { [DeckErr]::L('Z1053', $_) } catch {} }
        try { $script:LogoPs.Dispose() } catch { try { [DeckErr]::L('Z1054', $_) } catch {} }; $script:LogoPs = $null; $script:LogoDone = $true
        Log "Spiel-Logos: $n geladen"
        if ($n -gt 0) { Load-Games; Send ([ordered]@{ type = 'games'; games = $script:GamesMsg; hidden = @($script:HiddenMsg) }) }
    }

    # ------------------------------------------------------------ Cover per SteamGridDB waehlen (Rechtsklick) - Netz im eigenen Runspace
    $script:SgdbJob = $null
    function Start-SgdbJob($kind, $id, $arg, $art) {
        if ($art -ne 'logo' -and $art -ne 'hero') { $art = 'cover' }
        $g = $script:Games | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $g) { Log "SteamGridDB: Spiel nicht gefunden ($id)"; return }
        if ($script:SgdbJob) { try { $script:SgdbJob.Ps.Stop(); $script:SgdbJob.Ps.Dispose() } catch { try { [DeckErr]::L('Z1064', $_) } catch {} }; $script:SgdbJob = $null }
        $page = 0; if ($kind -eq 'grids') { $page = [int]$arg }
        $ps = [PowerShell]::Create()
        # Der Runspace liefert genau eine fertige JSON-Nachricht (String) - keine Objekt-Umwandlung im Host noetig.
        [void]$ps.AddScript({
            param($core, $cfgFile, $coverDir, $logFile, $kind, $gid, $gname, $appid, $arg, $page, $art)
            $ErrorActionPreference = 'Continue'
            $items = New-Object System.Collections.ArrayList
            $err = ''
            try {
                . $core
                $script:LogFile = $logFile; $script:CoverDir = $coverDir
                $script:Config = Read-Config $cfgFile
                if (-not $script:Config.steamGridDbKey) { throw 'Kein SteamGridDB-Schluessel hinterlegt (config.json: steamGridDbKey).' }
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                if ($kind -eq 'save') {
                    $pre = @{ cover = ''; logo = 'logoc_'; hero = 'heroc_' }[$art]
                    $f = Save-CoverFromUrl ([pscustomobject]@{ Id = $gid }) $arg $pre
                    if (-not (Test-Path $f) -or (Get-Item $f).Length -lt $(if ($art -eq 'logo') { 300 } else { 2000 })) { throw 'Download unvollstaendig.' }
                } else {
                    $ep = @{ cover = 'grids'; logo = 'logos'; hero = 'heroes' }[$art]
                    $q = '?types=static&nsfw=false&humor=false&page=' + $page; if ($art -eq 'cover') { $q = '?dimensions=600x900,342x482,660x930&types=static&nsfw=false&humor=false&page=' + $page }
                    $r = $null
                    if ($appid) { try { $r = Invoke-Sgdb "/$ep/steam/$appid$q" } catch { $err = "steam/${appid}: " + $_.Exception.Message } }
                    if (-not $r -or -not $r.success -or -not $r.data) {
                        $sid = Get-SgdbGameId ([pscustomobject]@{ Name = $gname })
                        if ($sid) { $r = Invoke-Sgdb "/$ep/game/$sid$q"; $err = '' }
                    }
                    if ($r -and $r.success -and $r.data) {
                        foreach ($x in @($r.data)) {
                            if ([string]$x.url -notmatch '\.(png|jpe?g)(\?|$)') { continue }
                            [void]$items.Add([ordered]@{ url = [string]$x.url; thumb = [string]$x.thumb; w = [int]$x.width; h = [int]$x.height; by = [string]$x.author.name })
                        }
                        $err = ''
                    }
                }
            } catch { $err = [string]$_.Exception.Message }
            $msg = [ordered]@{ type = $(if ($kind -eq 'save') { 'sgdbSaved' } else { 'sgdb' }); id = $gid; page = $page; art = $art; items = $items; error = $err }
            ConvertTo-Json -InputObject $msg -Depth 5 -Compress
        }.ToString())
        [void]$ps.AddArgument((Join-Path $script:Root 'GameShelf.Core.ps1')).AddArgument($script:ConfigFile).AddArgument($script:CoverDir).AddArgument($script:LogFile).AddArgument($kind).AddArgument($g.Id).AddArgument($g.Name).AddArgument([string]$g.SteamAppId).AddArgument([string]$arg).AddArgument($page).AddArgument($art)
        $script:SgdbJob = @{ Ps = $ps; Handle = $ps.BeginInvoke(); Kind = $kind; Id = $g.Id; Page = $page; Art = $art }
        Log "SteamGridDB: $kind ($($g.Name), Seite $page)"
    }
    function Poll-SgdbJob {
        $j = $script:SgdbJob
        if (-not $j -or -not $j.Handle.IsCompleted) { return }
        $script:SgdbJob = $null
        $json = $null; $why = ''
        try {
            $out = $j.Ps.EndInvoke($j.Handle)
            foreach ($o in $out) { $t = [string]$o; if ($t.StartsWith('{"type"')) { $json = $t } }
        } catch { $why = [string]$_.Exception.Message }
        if (-not $json) {
            try { $why += ' | ' + (($j.Ps.Streams.Error | Select-Object -First 3 | ForEach-Object { [string]$_ }) -join ' / ') + ' | Zustand: ' + $j.Ps.InvocationStateInfo.State + ' ' + [string]$j.Ps.InvocationStateInfo.Reason } catch { try { [DeckErr]::L('Z1116', $_) } catch {} }
            Log "SteamGridDB $($j.Kind): keine Antwort - $why"
            $json = ConvertTo-Json -Compress -InputObject ([ordered]@{ type = $(if ($j.Kind -eq 'save') { 'sgdbSaved' } else { 'sgdb' }); id = $j.Id; page = $j.Page; art = $j.Art; items = @(); error = 'Interner Fehler (siehe deck.log).' })
        }
        try { $j.Ps.Dispose() } catch { try { [DeckErr]::L('Z1120', $_) } catch {} }
        try { $chk = $json | ConvertFrom-Json; if ($chk.error) { Log "SteamGridDB $($j.Kind): $($chk.error)" } else { Log ("SteamGridDB {0}: ok ({1} Bilder)" -f $j.Kind, @($chk.items).Count) } } catch { try { [DeckErr]::L('Z1121', $_) } catch {} }
        if ($j.Kind -eq 'save' -and -not $chk.error) { Load-Games; Send ([ordered]@{ type = 'games'; games = $script:GamesMsg; hidden = @($script:HiddenMsg) }) }
        if ($script:Ready) { try { $script:Wv.CoreWebView2.PostWebMessageAsJson($json) } catch { Log "Senden: $_" } }
    }
    # Metadaten anpassen: eigenes Bild von der Festplatte (Cover / Logo / Titelbild) oder zurücksetzen
    function Get-ArtPrefix($art) { switch ($art) { 'logo' { 'logoc_' } 'hero' { 'heroc_' } default { '' } } }
    function Select-GameArt($id, $art) {
        $g = $script:Games | Where-Object { $_.Id -eq $id } | Select-Object -First 1; if (-not $g) { return }
        try {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = $(switch ($art) { 'logo' { 'Logo' } 'hero' { 'Titelbild' } default { 'Cover' } }) + ' für ' + $g.Name + ' auswählen'
            $dlg.Filter = $(if ($art -eq 'logo') { 'Logo (*.png;*.webp)|*.png;*.webp|Alle Bilder|*.png;*.webp;*.jpg;*.jpeg' } else { 'Bilder (*.jpg;*.jpeg;*.png;*.webp)|*.jpg;*.jpeg;*.png;*.webp' })
            $dlg.InitialDirectory = [Environment]::GetFolderPath('MyPictures')
            if (-not $dlg.ShowDialog()) { return }
            $src = $dlg.FileName
            if ((Get-Item $src).Length -gt 30MB) { Log 'Gameart: Datei zu gross (> 30 MB)'; return }
            $pre = Get-ArtPrefix $art
            foreach ($e in 'png', 'jpg', 'jpeg', 'webp') { $old = Join-Path $script:CoverDir "$pre$id.$e"; if (Test-Path $old) { Remove-Item $old -Force } }
            $ext = [IO.Path]::GetExtension($src).ToLower().TrimStart('.'); if ($ext -eq 'jpeg') { $ext = 'jpg' }
            Copy-Item $src (Join-Path $script:CoverDir "$pre$id.$ext") -Force
            Log "Gameart ($art) gesetzt: $($g.Name)"
            Load-Games; Send ([ordered]@{ type = 'games'; games = $script:GamesMsg; hidden = @($script:HiddenMsg) }); Send ([ordered]@{ type = 'artDone'; id = $id; art = $art })
        } catch { Log "Gameart ($art): $_" }
    }
    function Reset-GameArt($id, $art) {
        $pre = Get-ArtPrefix $art
        foreach ($e in 'png', 'jpg', 'jpeg', 'webp') { $f = Join-Path $script:CoverDir "$pre$id.$e"; if (Test-Path $f) { Remove-Item $f -Force } }
        Load-Games; Send ([ordered]@{ type = 'games'; games = $script:GamesMsg; hidden = @($script:HiddenMsg) }); Log "Gameart ($art) zurueckgesetzt: $id"
    }
    # Metadaten anpassen: eigener Spielname, lokal in user\names.json (uebersteht das Neueinlesen der Bibliothek)
    function Read-GameNames {
        $h = @{}
        try {
            if (Test-Path $script:NamesFile) {
                $j = Get-Content $script:NamesFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($p in $j.PSObject.Properties) { if ([string]$p.Value) { $h[$p.Name] = [string]$p.Value } }
            }
        } catch { Log "Spielnamen nicht lesbar: $_" }
        $h
    }
    function Set-GameName($id, $name) {
        $g = $script:Games | Where-Object { $_.Id -eq $id } | Select-Object -First 1; if (-not $g) { return }
        try {
            $orig = [string]$g.Name; if ($g.PSObject.Properties['NameOrig'] -and $g.NameOrig) { $orig = [string]$g.NameOrig }
            $name = ([string]$name).Trim(); if ($name.Length -gt 80) { $name = $name.Substring(0, 80) }
            $h = Read-GameNames
            if (-not $name -or $name -ceq $orig) { [void]$h.Remove($id); $name = $orig } else { $h[$id] = $name }
            if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
            (ConvertTo-Json -InputObject $h -Compress) | Set-Content -Path $script:NamesFile -Encoding UTF8
            if ($script:EmuRun -and $script:EmuRun.id -eq $id) { $script:EmuRun.name = $name }
            if ($script:Running -eq $id) { $script:RunningName = $name }
            Log "Spielname gesetzt: $id"
            Load-Games; Send ([ordered]@{ type = 'games'; games = $script:GamesMsg; hidden = @($script:HiddenMsg) }); Send ([ordered]@{ type = 'nameDone'; id = $id; name = $name })
        } catch { Log "Spielname: $_" }
    }
    # Bibliothek: ausgeblendete Spiele, lokal in user\hidden.json (Liste von Ids, uebersteht das Neueinlesen)
    function Read-HiddenGames {
        $h = @{}
        try {
            if (Test-Path $script:HiddenFile) {
                $j = Get-Content $script:HiddenFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($x in $j) { if ([string]$x) { $h[[string]$x] = $true } }
            }
        } catch { Log "Ausgeblendete Spiele nicht lesbar: $_" }
        $h
    }
    function Set-GameHidden($id, [bool]$hide) {
        try {
            $id = [string]$id; if (-not $id) { return }
            $h = Read-HiddenGames
            if ($hide) { $h[$id] = $true } else { [void]$h.Remove($id) }
            if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
            (ConvertTo-Json -InputObject @($h.Keys | Sort-Object) -Compress) | Set-Content -Path $script:HiddenFile -Encoding UTF8
            Log ("Bibliothek: {0} {1}" -f $id, $(if ($hide) { 'ausgeblendet' } else { 'wieder angezeigt' }))
            Load-Games
            Send ([ordered]@{ type = 'games'; games = $script:GamesMsg; hidden = @($script:HiddenMsg) })
            Send ([ordered]@{ type = 'hideDone'; id = $id; hidden = $hide })
        } catch { Log "Ausblenden: $_" }
    }
    function Reset-Cover($id) {
        $f = Find-CoverFile '' $id
        while ($f) { Remove-Item $f -Force; $f = Find-CoverFile '' $id }
        Load-Games; Send ([ordered]@{ type = 'games'; games = $script:GamesMsg; hidden = @($script:HiddenMsg) }); Log "Cover zurueckgesetzt: $id"
    }

    # ------------------------------------------------------------ Fritchii: Nutzerprofile (profiles.dat im Yuzu-Format) fuer "Wer spielt?" vor dem Start
    $script:FchUserFile = Join-Path $script:UserDir 'fch-user.json'
    function Get-FchProfileFile {
        $roots = @()
        try { $ed = Split-Path -Parent ([string]$script:Config.fchExe); if ($ed) { $roots += (Join-Path $ed 'user') } } catch {}
        if ($env:APPDATA) { $roots += (Join-Path $env:APPDATA 'fritchii') }
        foreach ($r in $roots) {
            if (-not (Test-Path -LiteralPath $r)) { continue }
            $nand = Join-Path $r 'nand'
            $ini = Join-Path $r 'config\qt-config.ini'
            if (Test-Path -LiteralPath $ini) {
                try {
                    $isDef = $true; $val = ''
                    foreach ($ln in [IO.File]::ReadAllLines($ini)) {
                        if ($ln -match '^nand_directory\\default=(\w+)') { $isDef = ($Matches[1] -eq 'true') }
                        elseif ($ln -match '^nand_directory=(.*)$') { $val = $Matches[1].Trim().Trim('"') }
                    }
                    if (-not $isDef -and $val) { $pv = ($val -replace '/', '\').TrimEnd('\'); if (Test-Path -LiteralPath $pv) { $nand = $pv } }
                } catch { Log "Fritchii-Profile: Konfiguration nicht lesbar: $_" }
            }
            $dat = Join-Path $nand 'system\save\8000000000000010\su\avators\profiles.dat'
            if (Test-Path -LiteralPath $dat) { return $dat }
        }
        $null
    }
    function Get-FchProfiles {
        $out = @()
        $dat = Get-FchProfileFile
        if (-not $dat) { return $out }
        try {
            $b = [IO.File]::ReadAllBytes($dat)
            $crops = Read-FchCrops
            for ($i = 0; $i -lt 8; $i++) {
                $o = 0x10 + $i * 0xC8
                if ($o + 0x48 -gt $b.Length) { break }
                $u = New-Object byte[] 16; [Array]::Copy($b, $o, $u, 0, 16)
                $nz = $false; foreach ($x in $u) { if ($x -ne 0) { $nz = $true; break } }
                if (-not $nz) { continue }
                $nb = New-Object byte[] 32; [Array]::Copy($b, $o + 0x28, $nb, 0, 32)
                $z = [Array]::IndexOf($nb, [byte]0); if ($z -lt 0) { $z = 32 }
                $name = [Text.Encoding]::UTF8.GetString($nb, 0, $z).Trim()
                $img = ''; $own = Get-FchOwnAvatar $name; if ($own) { $img = Get-AssetUrl $own.FullName }   # nur eigene Bilder (Fritchii-Bilder zu unscharf, 12.11.)
                $cr = ''; $ck = Get-FchAvKey $name; if ($crops.ContainsKey($ck)) { $cr = [string]$crops[$ck] }
                $out += [ordered]@{ i = $out.Count; name = $name; img = $img; crop = $cr }
            }
        } catch { Log "Fritchii-Profile: $_" }
        $out
    }
    # eigene Profilbilder (Einstellungen > Bibliothek): user\fch-av\<name>.<ext>
    $script:FchAvDir = Join-Path $script:UserDir 'fch-av'
    function Get-FchAvKey($name) { $k = ([string]$name).Trim().ToLower() -replace '[^a-z0-9]', '_'; if (-not $k) { $k = '_' }; $k }
    function Get-FchOwnAvatar($name) {
        if (-not (Test-Path -LiteralPath $script:FchAvDir)) { return $null }
        $k = Get-FchAvKey $name
        Get-ChildItem -LiteralPath $script:FchAvDir -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -eq $k -and $_.Extension -ne '.json' } | Select-Object -First 1
    }
    $script:FchCropFile = Join-Path $script:FchAvDir 'crop.json'
    function Read-FchCrops {
        $h = @{}
        try { if (Test-Path -LiteralPath $script:FchCropFile) { $j = ConvertFrom-Json ([IO.File]::ReadAllText($script:FchCropFile)); foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = [string]$p.Value } } } catch { Log "Fritchii-Bildausschnitt lesen: $_" }
        $h
    }
    function Set-FchCrop($name, $crop) {
        try {
            $h = Read-FchCrops; $k = Get-FchAvKey $name
            if ($crop) { if ([string]$crop -notmatch '^\d{1,3}(\.\d+)?,\d{1,3}(\.\d+)?,\d(\.\d+)?$') { Log "Fritchii-Bildausschnitt abgelehnt: $crop"; return }; $h[$k] = [string]$crop } else { $h.Remove($k) }
            if (-not (Test-Path -LiteralPath $script:FchAvDir)) { New-Item -ItemType Directory -Path $script:FchAvDir | Out-Null }
            [IO.File]::WriteAllText($script:FchCropFile, ($h | ConvertTo-Json -Compress))
            Log "Fritchii-Bildausschnitt gespeichert: $name"
        } catch { Log "Fritchii-Bildausschnitt speichern: $_" }
    }
    function Select-FchAvatar($name) {
        try {
            if (-not (@(Get-FchProfiles) | Where-Object { $_.name -eq [string]$name })) { Log "Fritchii-Profilbild: unbekanntes Profil '$name'"; return }
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = "Profilbild für $name auswählen"
            $dlg.Filter = 'Bilder (*.jpg;*.jpeg;*.png;*.webp;*.bmp)|*.jpg;*.jpeg;*.png;*.webp;*.bmp'
            $dlg.InitialDirectory = [Environment]::GetFolderPath('MyPictures')
            if (-not $dlg.ShowDialog()) { return }
            $src = $dlg.FileName
            if ((Get-Item -LiteralPath $src).Length -gt 40MB) { Log 'Fritchii-Profilbild: Datei zu gross (> 40 MB)'; return }
            if (-not (Test-Path -LiteralPath $script:FchAvDir)) { New-Item -ItemType Directory -Path $script:FchAvDir | Out-Null }
            $old = Get-FchOwnAvatar $name; if ($old) { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue }
            Copy-Item -LiteralPath $src (Join-Path $script:FchAvDir ((Get-FchAvKey $name) + [IO.Path]::GetExtension($src).ToLower())) -Force
            Set-FchCrop $name ''
            Log "Fritchii-Profilbild gesetzt: $name"
            Send-FchProfiles
        } catch { Log "Fritchii-Profilbild: $_" }
    }
    function Clear-FchAvatar($name) {
        try { $old = Get-FchOwnAvatar $name; if ($old) { Remove-Item -LiteralPath $old.FullName -Force; Log "Fritchii-Profilbild entfernt: $name" } } catch { Log "Fritchii-Profilbild entfernen: $_" }
        Set-FchCrop $name ''
        Send-FchProfiles
    }
    function Send-FchProfiles {
        $list = @(Get-FchProfiles)
        $last = 0
        try { if (Test-Path -LiteralPath $script:FchUserFile) { $last = [int](ConvertFrom-Json ([IO.File]::ReadAllText($script:FchUserFile))).last } } catch { Log "Fritchii-Profil (zuletzt) nicht lesbar: $_" }
        Send ([ordered]@{ type = 'fchprof'; list = @($list); last = $last })
    }

    function Start-DeckGame($id, $user = $null) {
        $g = $script:Games | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $g) { Log "Unbekanntes Spiel: $id"; return }
        Log "Starte $($g.Name)"
        if ($script:EmuProc.ContainsKey([string]$g.Source)) {   # Emulator: welches Spiel laeuft und wann zuletzt gespielt, merkt sich das Deck selbst
            $script:EmuRun = @{ id = $g.Id; name = $g.Name; src = [string]$g.Source }
            try { $h = Read-EmuPlayed; if (-not $h.ContainsKey($g.Id)) { $h[$g.Id] = @{ last = 0; min = 0; s = @() } }; $h[$g.Id].last = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); Save-EmuPlayed $h } catch { Log "Emulator-Spielzeiten speichern: $_" }
            Start-LibraryRefresh
        }
        try {
            switch ($g.Type) {
                'url' { Start-Process $g.Target }
                'aumid' { Start-Process 'explorer.exe' ("shell:AppsFolder\" + $g.Target) }
                'exe' {
                    $wd = Split-Path -Parent $g.Target
                    if ([string]$g.Source -eq 'Fritchii' -and $null -ne $user -and ([string]$user) -match '^[0-7]$') {
                        Log "Fritchii: Start mit Profil $user"
                        try { [IO.File]::WriteAllText($script:FchUserFile, ('{"last":' + [int]$user + '}')) } catch { Log "Fritchii-Profil merken: $_" }
                        Start-Process -FilePath $g.Target -ArgumentList ('-u ' + [int]$user + ' ' + $g.Args) -WorkingDirectory $wd
                    }
                    elseif ($g.Args) { Start-Process -FilePath $g.Target -ArgumentList $g.Args -WorkingDirectory $wd } else { Start-Process -FilePath $g.Target -WorkingDirectory $wd }
                }
            }
        } catch { Log "Start fehlgeschlagen ($($g.Name)): $_" }
    }

    # ------------------------------------------------------------ Selbst-Neustart, wenn WebView2 nicht hochkommt (deckos-178)
    # Hoechstens 3 Versuche in 10 Minuten; nicht, wenn das Deck gerade beendet oder von einem neuen Start abgeloest wird.
    $script:Closing = $false
    function Restart-Deck([string]$why) {
        try {
            if ($script:Closing -or $script:QuitEvent.WaitOne(0)) { return $false }
            $n = 0; try { $n = [int]$env:GSDECK_RETRY } catch { $n = 0 }
            $at = [datetime]::MinValue; try { $at = [datetime]::Parse([string]$env:GSDECK_RETRY_AT) } catch { $at = [datetime]::MinValue }
            if (((Get-Date) - $at).TotalMinutes -gt 10) { $n = 0 }
            if ($n -ge 3) { Log "Neustart abgelehnt ($why): schon $n Versuche in 10 Minuten"; return $false }
            $env:GSDECK_RETRY = [string]($n + 1); $env:GSDECK_RETRY_AT = (Get-Date).ToString('o')
            $self = (Join-Path $script:Root 'Deck.ps1').Replace("'", "''")
            $cmd = '"Start-Sleep -Seconds 4; & ' + "'" + $self + "'" + '"'
            Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -ArgumentList @('--headless', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-Command', $cmd) -WorkingDirectory $script:Root
            Log "Neustart angefordert ($why), Versuch $($n + 1) von 3"
            return $true
        } catch { Log "Neustart fehlgeschlagen ($why): $_"; return $false }
    }

    # ------------------------------------------------------------ Fenster mit WebView2
    $script:Ready = $false
    $win = New-Object Windows.Window
    $win.Title = 'GameShelf Deck'
    $win.WindowStyle = 'None'
    $win.ResizeMode = 'NoResize'
    $win.ShowInTaskbar = $false
    $win.ShowActivated = $false
    $win.WindowStartupLocation = 'Manual'
    $win.Left = 0; $win.Top = 0; $win.Width = 400; $win.Height = 400
    $win.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(14, 15, 18))
    $script:Win = $win

    $wv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $cp = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
    $cp.UserDataFolder = Join-Path $env:LOCALAPPDATA 'GameShelfDeck\WebView2'
    $cp.AdditionalBrowserArguments = '--disable-features=msSmartScreenProtection,CalculateNativeWinOcclusion --autoplay-policy=no-user-gesture-required'
    $wv.CreationProperties = $cp
    $wv.DefaultBackgroundColor = [System.Drawing.Color]::FromArgb(255, 14, 15, 18)
    $win.Content = $wv
    $script:Wv = $wv

    # Durchscheinend: Fenster, WPF-Flaeche und WebView2 transparent, DWM legt die Unschaerfe darunter.
    function Set-Backdrop {
        if (-not $script:Hwnd) { return }
        $clear = ([string]$script:Settings.bg -eq 'clear')
        try {
            $src = [Windows.Interop.HwndSource]::FromHwnd($script:Hwnd)
            if ($clear) {
                $script:Win.Background = [Windows.Media.Brushes]::Transparent
                if ($src) { $src.CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent }
                $script:Wv.DefaultBackgroundColor = [System.Drawing.Color]::FromArgb(0, 0, 0, 0)
                $mode = $(switch ([string]$script:Settings.blur) { 'strong' { 2 } 'none' { 3 } default { 1 } })
            } else {
                $c = [Windows.Media.Color]::FromRgb(14, 15, 18)
                $script:Win.Background = New-Object Windows.Media.SolidColorBrush $c
                if ($src) { $src.CompositionTarget.BackgroundColor = $c }
                $script:Wv.DefaultBackgroundColor = [System.Drawing.Color]::FromArgb(255, 14, 15, 18)
                $mode = 0
            }
            $ok = [DeckNative]::SetBackdrop($script:Hwnd, $mode)
            Log ("Hintergrund: {0} (Unschaerfe {1}, ok={2})" -f $script:Settings.bg, $mode, $ok)
        } catch { Log "Hintergrund: $_" }
    }

    # Windows-App-Farbmodus (Hell/Dunkel) fuer die Glasfarbe "System"
    function Get-SysLight {
        try { return ([int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 1) } catch { return $false }
    }
    $script:SysLight = Get-SysLight

    function Send($obj) {
        if (-not $script:Ready) { return }
        try { $script:Wv.CoreWebView2.PostWebMessageAsJson(($obj | ConvertTo-Json -Depth 6 -Compress)) } catch { Log "Senden: $_" }
    }
    # ------------------------------------------------------------ Home: eigenes Foto (Bilderrahmen neben der Uhr), Auswahl per Explorer
    function Get-HomePhoto { Get-ChildItem $script:UserDir -Filter 'homephoto.*' -File -ErrorAction SilentlyContinue | Select-Object -First 1 }
    function Send-HomePhoto { $f = Get-HomePhoto; Send ([ordered]@{ type = 'homephoto'; url = $(if ($f) { Get-AssetUrl $f.FullName } else { '' }) }) }
    function Select-HomePhoto {
        try {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'Foto für Home auswählen'
            $dlg.Filter = 'Bilder (*.jpg;*.jpeg;*.png;*.webp;*.bmp)|*.jpg;*.jpeg;*.png;*.webp;*.bmp'
            $dlg.InitialDirectory = [Environment]::GetFolderPath('MyPictures')
            if (-not $dlg.ShowDialog()) { return }
            $src = $dlg.FileName
            if ((Get-Item $src).Length -gt 40MB) { Log 'Home-Foto: Datei zu gross (> 40 MB)'; return }
            if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
            Get-ChildItem $script:UserDir -Filter 'homephoto.*' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Copy-Item $src (Join-Path $script:UserDir ('homephoto' + [IO.Path]::GetExtension($src).ToLower())) -Force
            Log 'Home-Foto: neues Bild gesetzt'
            Send-HomePhoto
        } catch { Log "Home-Foto: $_" }
    }

    function Send-Init {
        $setOut = [ordered]@{}; foreach ($k in @($script:Settings.Keys)) { if ($k -ne 'steamKey') { $setOut[$k] = $script:Settings[$k] } }; $setOut['steamKeySet'] = [bool][string]$script:Settings['steamKey']
        Send ([ordered]@{ type = 'init'; sysLight = $script:SysLight; settings = $setOut; accent = (Get-AccentHex); flash = [string]$script:Config.flashColor; vramTotal = $script:VramGB; user = $script:User; games = $script:GamesMsg; hidden = @($script:HiddenMsg); couch = [bool]$script:Couch })
        $script:LastLayoutMsg = $null; $script:LastStateMsg = $null
        Update-Layout $true; Send-State
    }

    $wv.add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) { Log "WebView2 nicht gestartet: $($e.InitializationException)"; [void](Restart-Deck 'WebView2 nicht gestartet'); return }
        try {
            $c = $script:Wv.CoreWebView2
            $c.Settings.AreDefaultContextMenusEnabled = $false
            $c.Settings.IsZoomControlEnabled = $false
            $c.Settings.IsStatusBarEnabled = $false
            $c.Settings.AreBrowserAcceleratorKeysEnabled = $false
            $c.Settings.IsPinchZoomEnabled = $false
            $allow = [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow
            $c.SetVirtualHostNameToFolderMapping('deck.local', $script:Root, $allow)
            $c.SetVirtualHostNameToFolderMapping('gs.deck', $script:Root, $allow)
            if ($script:LibCache) { $c.SetVirtualHostNameToFolderMapping('steam.deck', $script:LibCache, $allow) }
            $c.add_WebMessageReceived({ param($s2, $e2); try { On-Message ($e2.WebMessageAsJson | ConvertFrom-Json) } catch { Log "Nachricht: $_" } })
            $c.add_ProcessFailed({ param($s3, $e3); Log "WebView2-Prozess ausgefallen: $($e3.ProcessFailedKind)"; try { $script:Wv.CoreWebView2.Reload() } catch { try { [DeckErr]::L('Z1244', $_) } catch {}; [void](Restart-Deck "WebView2-Prozess $($e3.ProcessFailedKind)") } })
            try { $p = [Diagnostics.Process]::GetProcessById([int]$c.BrowserProcessId); $p.PriorityClass = 'BelowNormal' } catch { try { [DeckErr]::L('Z1245', $_) } catch {} }
            $c.Navigate('https://deck.local/Deck.html')
        } catch { Log "WebView2-Einrichtung: $_" }
    })

    # ------------------------------------------------------------ OTA-Update ueber GitHub-Releases (deckos-181)
    # Prueft 2 min nach dem Start und dann alle 6 h das neueste Release. Installiert NUR nach Tipp in der Oberflaeche und nie waehrend eines Spiels.
    # Ablauf: Setup-EXE laden -> Groesse + SHA-256 pruefen -> "Setup.exe /update <Ordner>" starten. Das Setup beendet das Deck, tauscht nur
    # Programmdateien (Einstellungen/Daten bleiben), stellt bei Fehler den vorigen Stand wieder her und startet das Deck neu.
    # Im Entwicklerordner (Unterordner Sicherung oder Entwurf) wird nie installiert.
    $script:UpdRepoDefault = 'ShadyKVN/gameshelf-deck'
    $script:UpdAsset = 'GameShelf-Deck-Setup.exe'
    $script:Upd = [hashtable]::Synchronized(@{ Busy = $false; Done = $false; Kind = ''; Err = ''; Tag = ''; Name = ''; Notes = ''; Url = ''; Size = [int64]0; Sha = ''; File = ''; Page = '' })
    $script:UpdLastStart = (Get-Date).AddHours(-6).AddMinutes(2)   # erste Pruefung rund 2 min nach dem Start
    $script:UpdAvail = $null; $script:UpdManual = $false; $script:UpdPs = $null
    function Get-UpdRepo { $r = [string]$script:Settings['updateRepo']; if ($r -match '^[\w.-]+/[\w.-]+$') { return $r }; if ($script:UpdRepoDefault -match '^[\w.-]+/[\w.-]+$') { return $script:UpdRepoDefault }; return '' }
    function Test-DevFolder { (Test-Path (Join-Path $script:Root 'Sicherung')) -or (Test-Path (Join-Path $script:Root 'Entwurf')) }
    function Get-VerNum([string]$v) { if ($v -match '(\d+)\s*$') { return [int]$matches[1] }; if ($v -match '(\d+)') { return [int]$matches[1] }; return 0 }
    function Send-UpdState([string]$state, [string]$msg = '') {
        $o = [ordered]@{ type = 'update'; state = $state; cur = $script:Version; msg = $msg; dev = [bool](Test-DevFolder) }
        if ($script:UpdAvail) { $o.ver = $script:UpdAvail.Tag; $o.name = $script:UpdAvail.Name; $o.notes = $script:UpdAvail.Notes; $o.page = $script:UpdAvail.Page; $o.mb = [math]::Round($script:UpdAvail.Size / 1048576.0, 1) }
        Send $o
    }
    function Start-UpdJob([string]$kind) {
        $repo = Get-UpdRepo
        if (-not $repo) { if ($script:UpdManual) { Send-UpdState 'error' 'Kein Update-Kanal eingetragen' }; return }
        if ($script:Upd.Busy) { return }
        if ($kind -eq 'check' -and $false -eq $script:Settings['updateCheck'] -and -not $script:UpdManual) { return }
        $script:Upd.Busy = $true; $script:Upd.Done = $false; $script:Upd.Kind = $kind; $script:Upd.Err = ''
        if ($kind -eq 'check') { $script:UpdLastStart = Get-Date }
        if ($script:UpdPs) { try { $script:UpdPs.Dispose() } catch { } }
        $ps = [PowerShell]::Create(); $script:UpdPs = $ps
        [void]$ps.AddScript({
            param($U, $Repo, $Asset, $Ver, $Kind)
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
            $hdr = @{ 'User-Agent' = "GameShelfDeck/$Ver"; 'Accept' = 'application/vnd.github+json' }
            try {
                if ($Kind -eq 'check') {
                    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $hdr -TimeoutSec 20
                    $a = @($r.assets | Where-Object { $_.name -eq $Asset }) | Select-Object -First 1
                    if (-not $a) { throw "Release $($r.tag_name) ohne $Asset" }
                    $sha = ''
                    if ([string]$a.digest -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $matches[1] }
                    if (-not $sha) {
                        $s = @($r.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' }) | Select-Object -First 1
                        if ($s) { $t = [string](Invoke-RestMethod -Uri $s.browser_download_url -Headers @{ 'User-Agent' = "GameShelfDeck/$Ver" } -TimeoutSec 20); foreach ($ln in ($t -split "`n")) { if ($ln -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($Asset) + '\s*$')) { $sha = $matches[1] } } }
                    }
                    if (-not $sha) { throw 'Pruefsumme fehlt im Release' }
                    $U.Tag = [string]$r.tag_name; $U.Name = [string]$r.name; $U.Notes = [string]$r.body; $U.Page = [string]$r.html_url
                    $U.Url = [string]$a.browser_download_url; $U.Size = [int64]$a.size; $U.Sha = $sha.ToLower()
                } else {
                    if ($U.Url -notmatch '^https://(github\.com|objects\.githubusercontent\.com|release-assets\.githubusercontent\.com)/') { throw 'Download-Adresse unzulaessig' }
                    $dir = Join-Path $env:TEMP 'GameShelfDeck'; [void](New-Item -ItemType Directory -Force -Path $dir)
                    $f = Join-Path $dir ("Setup-" + ($U.Tag -replace '[^\w.-]', '_') + ".exe")
                    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
                    $wc = New-Object Net.WebClient; $wc.Headers.Add('User-Agent', "GameShelfDeck/$Ver")
                    try { $wc.DownloadFile($U.Url, $f) } finally { $wc.Dispose() }
                    $len = (Get-Item $f).Length
                    if ($U.Size -gt 0 -and $len -ne $U.Size) { Remove-Item $f -Force -ErrorAction SilentlyContinue; throw "Groesse falsch ($len statt $($U.Size))" }
                    $h = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLower()
                    if ($h -ne $U.Sha) { Remove-Item $f -Force -ErrorAction SilentlyContinue; throw 'Pruefsumme stimmt nicht - Datei verworfen' }
                    $b = [IO.File]::ReadAllBytes($f); if ($b.Length -lt 2 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { Remove-Item $f -Force -ErrorAction SilentlyContinue; throw 'Keine Programmdatei' }
                    $U.File = $f
                }
            } catch {
                $c = 0; try { $c = [int]$_.Exception.Response.StatusCode } catch { }
                $U.Err = $(if ($c -eq 404) { 'Noch kein Release veroeffentlicht' } elseif ($c -eq 403) { 'GitHub-Abruflimit erreicht, spaeter erneut' } else { [string]$_.Exception.Message }) + $(if ($c -and $c -ne 404 -and $c -ne 403) { " ($c)" } else { '' })
            }
            $U.Done = $true; $U.Busy = $false
        }.ToString())
        [void]$ps.AddArgument($script:Upd).AddArgument($repo).AddArgument($script:UpdAsset).AddArgument($script:Version).AddArgument($kind)
        [void]$ps.BeginInvoke()
        if ($kind -eq 'download') { Send-UpdState 'loading' }
    }
    function Poll-Update {
        if ($script:Upd.Done) {
            $script:Upd.Done = $false; $kind = $script:Upd.Kind; $man = $script:UpdManual; $script:UpdManual = $false
            if ($script:Upd.Err) {
                Log "Update ($kind): $($script:Upd.Err)"
                if ($man -or $kind -eq 'download') { Send-UpdState 'error' $script:Upd.Err }
            } elseif ($kind -eq 'check') {
                if ((Get-VerNum $script:Upd.Tag) -gt (Get-VerNum $script:Version)) {
                    $new = (-not $script:UpdAvail) -or ($script:UpdAvail.Tag -ne $script:Upd.Tag)
                    $script:UpdAvail = @{ Tag = $script:Upd.Tag; Name = $script:Upd.Name; Notes = $script:Upd.Notes; Page = $script:Upd.Page; Size = $script:Upd.Size }
                    if ($new) { Log "Update verfuegbar: $($script:Upd.Tag) (installiert: $($script:Version))" }
                    Send-UpdState 'avail'
                } else { $script:UpdAvail = $null; if ($man) { Send-UpdState 'none' } }
            } elseif ($kind -eq 'download') { Invoke-UpdInstall }
        }
        if (-not $script:Upd.Busy -and ((Get-Date) - $script:UpdLastStart).TotalHours -ge 6) { Start-UpdJob 'check' }
    }
    function Invoke-UpdInstall {
        $f = [string]$script:Upd.File
        if (-not $f -or -not (Test-Path $f)) { Send-UpdState 'error' 'Download fehlt'; return }
        if (Test-DevFolder) { Log "Update $($script:Upd.Tag) geladen, aber Entwicklerordner - keine Installation ($f)"; Send-UpdState 'error' 'Entwicklerordner: Update wird hier nicht installiert'; return }
        if ($script:Running) { Send-UpdState 'error' 'Waehrend eines Spiels wird nicht installiert'; return }
        Log "Update: starte Setup $($script:Upd.Tag) -> $($script:Root)"
        Send-UpdState 'installing'
        try {
            Start-Process -FilePath $f -ArgumentList @('/update', ('"' + $script:Root.TrimEnd('\') + '"')) -WorkingDirectory (Split-Path $f)
        } catch { Log "Update: Setup nicht startbar: $_"; Send-UpdState 'error' ("Setup nicht startbar: " + $_.Exception.Message) }
        # Das Setup setzt GameShelfDeck_Quit; das Deck beendet sich darueber selbst und wird vom Setup neu gestartet.
    }
    $script:UpdJustFrom = ''
    try {
        $vf = Join-Path $script:UserDir 'version.txt'; $old = ''
        if (Test-Path $vf) { $old = ([IO.File]::ReadAllText($vf)).Trim() }
        if ($old -and $old -ne $script:Version) { $script:UpdJustFrom = $old; Log "Aktualisiert: $old -> $($script:Version)" }
        if ($old -ne $script:Version) { [void](New-Item -ItemType Directory -Force -Path $script:UserDir); [IO.File]::WriteAllText($vf, $script:Version) }
    } catch { Log "Versionsdatei: $_" }
    function On-UpdMsg($m) {
        switch ([string]$m.op) {
            'check' { $script:UpdManual = $true; if ($script:Upd.Busy) { return }; Send-UpdState 'checking'; Start-UpdJob 'check' }
            'install' {
                if (-not $script:UpdAvail) { Send-UpdState 'none'; return }
                if ($script:Running) { Send-UpdState 'error' 'Waehrend eines Spiels wird nicht installiert'; return }
                if (Test-DevFolder) { Send-UpdState 'error' 'Entwicklerordner: Update wird hier nicht installiert'; return }
                Start-UpdJob 'download'
            }
            'state' { if ($script:UpdAvail) { Send-UpdState 'avail' } else { Send-UpdState 'idle' } }
            'page' { if ($script:UpdAvail -and $script:UpdAvail.Page -match '^https://github\.com/') { try { Start-Process $script:UpdAvail.Page } catch { Log "Update-Seite: $_" } } }
        }
    }

    # Blitz beim Spielstart: Lichtstreifen ueber die ganze Unterkante des Deck-Monitors (quer), auch ueber dem angedockten Discord.
    $script:EdgeWin = $null; $script:EdgeHwnd = [IntPtr]::Zero
    function Show-EdgeFlash([double]$k, [string]$color) {
        try {
            $m = $script:Mon; if (-not $m -or $m.H -ge $m.W) { return }
            if (-not $script:EdgeWin) {
                $ew = New-Object Windows.Window
                $ew.WindowStyle = 'None'; $ew.AllowsTransparency = $true; $ew.ResizeMode = 'NoResize'
                $ew.ShowInTaskbar = $false; $ew.ShowActivated = $false; $ew.Topmost = $true; $ew.Focusable = $false
                $ew.Background = [Windows.Media.Brushes]::Transparent
                $ew.WindowStartupLocation = 'Manual'; $ew.Left = 0; $ew.Top = 0; $ew.Width = 10; $ew.Height = 20
                # 60 Hz: kein Weichzeichner-Effekt (wird in transparenten WPF-Fenstern per CPU gerechnet), das Gluehen ist ein Verlauf
                $grid = New-Object Windows.Controls.Grid
                $grid.IsHitTestVisible = $false; $grid.Opacity = 0
                $glow = New-Object Windows.Shapes.Rectangle
                $glow.Height = 16; $glow.VerticalAlignment = 'Bottom'; $glow.HorizontalAlignment = 'Stretch'; $glow.Opacity = 0.55
                $mask = New-Object Windows.Media.LinearGradientBrush
                $mask.StartPoint = New-Object Windows.Point -ArgumentList 0.5, 1; $mask.EndPoint = New-Object Windows.Point -ArgumentList 0.5, 0
                [void]$mask.GradientStops.Add((New-Object Windows.Media.GradientStop -ArgumentList ([Windows.Media.Color]::FromArgb(255, 0, 0, 0)), 0.0))
                [void]$mask.GradientStops.Add((New-Object Windows.Media.GradientStop -ArgumentList ([Windows.Media.Color]::FromArgb(0, 0, 0, 0)), 1.0))
                $glow.OpacityMask = $mask
                $rect = New-Object Windows.Shapes.Rectangle
                $rect.Height = 3.5; $rect.VerticalAlignment = 'Bottom'; $rect.HorizontalAlignment = 'Stretch'
                [void]$grid.Children.Add($glow); [void]$grid.Children.Add($rect)
                $sc = New-Object Windows.Media.ScaleTransform 0.05, 1
                $grid.RenderTransform = $sc
                $ew.Content = $grid
                $script:EdgeGlow = $glow; $script:EdgeGrid = $grid
                $ew.add_SourceInitialized({
                    $script:EdgeHwnd = (New-Object Windows.Interop.WindowInteropHelper $script:EdgeWin).Handle
                    [DeckNative]::MakeToolNoActivate($script:EdgeHwnd)
                })
                $script:EdgeWin = $ew; $script:EdgeRect = $rect; $script:EdgeScale = $sc
            }
            try { $c = [Windows.Media.ColorConverter]::ConvertFromString($color) } catch { $c = [Windows.Media.Color]::FromRgb(127, 178, 255) }
            if (-not $c) { $c = [Windows.Media.Color]::FromRgb(127, 178, 255) }
            # an beiden Enden auslaufend
            $ct = [Windows.Media.Color]::FromArgb(0, $c.R, $c.G, $c.B)
            $gb = New-Object Windows.Media.LinearGradientBrush
            $gb.StartPoint = New-Object Windows.Point -ArgumentList 0, 0.5; $gb.EndPoint = New-Object Windows.Point -ArgumentList 1, 0.5
            foreach ($gs in @(@($ct, 0.0), @($c, 0.2), @($c, 0.8), @($ct, 1.0))) { [void]$gb.GradientStops.Add((New-Object Windows.Media.GradientStop -ArgumentList $gs[0], ([double]$gs[1]))) }
            $script:EdgeRect.Fill = $gb; $script:EdgeGlow.Fill = $gb
            # Ursprung des Streifens: Mitte des Covers, umgerechnet von der Deck-Flaeche auf die ganze Monitorbreite
            $kx = (($script:DeckX - $m.X) + [math]::Max(0, [math]::Min(1, $k)) * $script:DeckW) / [double]$m.W
            $ox = [double][math]::Max(0, [math]::Min(1, $kx))
            $script:EdgeGrid.RenderTransformOrigin = New-Object Windows.Point -ArgumentList $ox, 0.5
            $hp = [int][math]::Ceiling(20 * $m.Dpi / 96.0)
            if (-not $script:EdgeWin.IsVisible) { $script:EdgeWin.Show() }
            # zweimal setzen: beim Wechsel auf den Edge-Monitor passt WPF die Groesse an dessen DPI an
            if ($script:EdgeHwnd -ne [IntPtr]::Zero) { [void][DeckNative]::MoveTo($script:EdgeHwnd, $m.X, $m.Y + $m.H - $hp, $m.W, $hp) }
            if ($script:EdgeHwnd -ne [IntPtr]::Zero) { [void][DeckNative]::MoveTo($script:EdgeHwnd, $m.X, $m.Y + $m.H - $hp, $m.W, $hp) }
            $script:EdgeWin.Topmost = $false; $script:EdgeWin.Topmost = $true
            $ms = { param($t) [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($t)) }
            $op = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
            foreach ($kf in @(@(0, 0), @(455, 0), @(780, 1), @(1300, 0))) { [void]$op.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame ([double]$kf[1]), (& $ms $kf[0]))) }
            $sx = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
            foreach ($kf in @(@(0, 0.05), @(455, 0.05), @(780, 1), @(1300, 1))) { [void]$sx.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame ([double]$kf[1]), (& $ms $kf[0]))) }
            [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($op, 60); [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($sx, 60)
            $op.add_Completed({ try { $script:EdgeWin.Hide() } catch { try { [DeckErr]::L('Z1308', $_) } catch {} } })
            $script:EdgeGrid.BeginAnimation([Windows.UIElement]::OpacityProperty, $op)
            $script:EdgeScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $sx)
        } catch { Log "Kantenblitz: $_" }
    }

    $script:HudVisible = $false
    function On-Message($m) {
        switch ([string]$m.type) {
            'ready' { $script:Ready = $true; Send-Init; $script:LastMutes = ''; Send-Mutes; $script:LastCam = ''; try { Restore-Cam } catch { try { [DeckErr]::L('Z1317a', $_) } catch {} }; try { Send-Cam } catch { try { [DeckErr]::L('Z1317b', $_) } catch {} }; $script:LastBat = ''; try { Send-PadBat } catch { try { [DeckErr]::L('Z1317c', $_) } catch {} }; try { Send-FpsTarget -Force } catch { try { [DeckErr]::L('Z1317d', $_) } catch {} }; $script:WaLast = -1; if ($script:Cal.At) { Send-Cal } else { Start-CalFetch }; Send-HomePhoto; try { if ($script:UpdJustFrom) { Send-UpdState 'done' $script:UpdJustFrom; $script:UpdJustFrom = '' } elseif ($script:UpdAvail) { Send-UpdState 'avail' } else { Send-UpdState 'idle' } } catch { }; try { Send-FchProfiles } catch { Log "Fritchii-Profile senden: $_" }; $script:DevBatStamp = -1; $script:FrLastMsg = ''; Send-Friends; if ($script:AppIcons.Map.Count) { Send-AppIcons } else { Start-AppIcons }
                try { $tf = Join-Path $script:UserDir 'timers.json'; if (Test-Path $tf) { $tl = @(ConvertFrom-Json ([IO.File]::ReadAllText($tf)) | ForEach-Object { $_ }); Send ([ordered]@{ type = 'timers'; list = @($tl) }) } } catch { Log "Timer laden: $_" } }
            'launch' {
                if ([string]$m.src -eq 'pad' -and ($script:PadLocked -or $script:Running)) { Log "Controller-Start abgelehnt (Spiel/Vollbild aktiv): $([string]$m.id)" }
                else { Start-DeckGame ([string]$m.id) $m.user }
            }
            'fchprof' { Send-FchProfiles }
            'fchavpick' { Select-FchAvatar ([string]$m.name) }
            'fchavclear' { Clear-FchAvatar ([string]$m.name) }
            'fchcrop' { Set-FchCrop ([string]$m.name) ([string]$m.crop) }
            'edgeflash' { Show-EdgeFlash ([double]$m.k) ([string]$m.color) }
            'idlewake' { $script:IdlePrev = $null; $script:IdlePad = [datetime]::UtcNow; Update-Idle }
            'idleprev' { $script:IdlePrev = [datetime]::UtcNow; Update-Idle }
            'context' { Invoke-GameContext ([string]$m.action) ([string]$m.id) ([string]$m.name) }
            'sgdbList' { Start-SgdbJob 'grids' ([string]$m.id) ([int]$m.page) ([string]$m.art) }
            'artFile' { Select-GameArt ([string]$m.id) ([string]$m.art) }
            'artReset' { Reset-GameArt ([string]$m.id) ([string]$m.art) }
            'rename' { Set-GameName ([string]$m.id) ([string]$m.name) }
            'hide' { Set-GameHidden ([string]$m.id) ([bool]$m.on) }
            'couchquit' { Request-CouchQuit }
            'couchpause' { Suspend-Couch }
            'sgdbSet' {
                $u = [string]$m.url
                if ($u -match '^https://([a-z0-9-]+\.)*steamgriddb\.com/') { Start-SgdbJob 'save' ([string]$m.id) $u ([string]$m.art) } else { Log "SteamGridDB: URL abgelehnt ($u)" }
            }
            'coverReset' { Reset-Cover ([string]$m.id) }
            'media' { $script:MediaCmds.Enqueue([string]$m.cmd) }
            'openuri' {
                $u = [string]$m.uri
                if ($u -match '^steam://(url/SteamIDPage/\d{17}|friends/message/\d{17}|store/\d+|openurl/https://steamcommunity\.com/my/stats/\d+/achievements)$' -or $u -match '^https://store\.steampowered\.com/app/\d+/?$') { Start-Process $u } else { Log "openuri abgelehnt: $u" }
            }
            'steamkey' {
                $v = ([string]$m.value).Trim()
                if ($v -and $v -notmatch '^[0-9A-Fa-f]{32}$') { Send ([ordered]@{ type = 'friends'; state = 'err'; err = 'Der Schluessel muss 32 Zeichen (0-9, A-F) lang sein' }); $script:FrLastMsg = '' }
                else { $script:Settings['steamKey'] = $v; Save-Settings; $script:Fr.List = $null; $script:Fr.Err = ''; $script:FrLastMsg = ''; $script:FrLastStart = [datetime]::MinValue; Log ("Steam-Schluessel " + $(if ($v) { 'gespeichert' } else { 'entfernt' })); Send ([ordered]@{ type = 'steamkey'; set = [bool]$v }); Start-FriendsFetch }
            }
            'cam' { try { if (-not $script:CamReqAt) { $c = Get-CamState; Set-Cam (-not $c.allowed) } } catch { Log "Kamera: $($_.Exception.Message)"; $script:CamErr = $_.Exception.Message }; Send-Cam -Force }
            'voice' {
                # systemweit: Mikro = Standard-Aufnahmegeraet, Ton = Standard-Ausgabegeraet
                $flow = $(if ([string]$m.which -eq 'mic') { 1 } else { 0 })
                $dg0 = ''; try { $dg0 = [DeckNative]::EndpointMuteDiag($flow) } catch { $dg0 = 'nicht verfuegbar' }
                $r = [DeckNative]::EndpointMute($flow, 2)
                try { Log ("Ton-Diagnose ({0}): vorher [{1}] nachher [{2}]" -f $(if ($flow) { 'Mikrofon' } else { 'Ausgabe' }), $dg0, [DeckNative]::EndpointMuteDiag($flow)); $script:MuteDiag = @{ flow = $flow; at = $script:Tick + 8 } } catch { }
                Log ("{0} systemweit: {1}" -f $(if ($flow) { 'Mikrofon' } else { 'Ton' }), $(switch ($r) { 1 { 'stumm' } 0 { 'an' } default { 'kein Geraet' } }))
                $script:LastMutes = ''; Send-Mutes
            }
            'volume' { $grp = @($script:MixerGroups | Where-Object { $_.key -eq [string]$m.key }) | Select-Object -First 1; if ($grp) { [void][DeckNative]::SetVolume([int[]]$grp.pids, [float]$m.value) } }
            'mute' { $grp = @($script:MixerGroups | Where-Object { $_.key -eq [string]$m.key }) | Select-Object -First 1; if ($grp) { [void][DeckNative]::SetMute([int[]]$grp.pids, (-not [bool]$grp.mute)); Send-Mixer } }
            'set' {
                $k = [string]$m.key
                if ($k -eq 'monitor') {   # Bildschirm des Decks (deckos-179): '' = automatisch, sonst Geraetename
                    $v = [string]$m.value
                    if ($v -eq '' -or $v -match '^\\\\\.\\DISPLAY\d{1,3}$') {
                        $script:Settings.monitor = $v; Save-Settings
                        Log ("Bildschirm gewaehlt: {0}" -f $(if ($v) { $v } else { 'automatisch' }))
                        $script:PlaceTries = 0; $script:MonList = $null
                        Update-Layout $true
                        try { Send-Bright } catch { Log "Helligkeit: $_" }
                    } else { Log "Bildschirm: ungueltiger Wert" }
                }
                $port = (-not $script:Mon) -or ($script:Mon.H -ge $script:Mon.W)
                if ($k -eq 'dcpos') { $k = $(if ($port) { 'dcposP' } else { 'dcposL' }) }
                if ($k -eq 'share') { $k = $(if ($port) { 'shareP' } else { 'shareL' }) }
                if (@('updateCheck', 'form', 'style', 'dtheme', 'dcposP', 'dcposL', 'shareP', 'shareL', 'mode', 'discordSplit', 'autostart', 'modMusic', 'modVoice', 'modMixer', 'modStats', 'modHue', 'hudArt', 'touchOnly', 'ui', 'flashSel', 'accentSel', 'bg', 'blur', 'tint', 'tone', 'wxName', 'wxLat', 'wxLon', 'clockStyle', 'agendaMode', 'photoCrop', 'fsVol', 'fsPad', 'fsBat', 'fsWa', 'fsAch', 'fsOk', 'fsFr', 'fsHeat', 'fsMus', 'fsDl', 'fsCl', 'photoOn', 'idleOn', 'idleMin', 'idleGlow', 'idleLab') -contains $k) {
                    $v = $m.value
                    if ($k -like 'share*') { $v = [double]$v } elseif ($k -match '^(updateCheck|discordSplit|autostart|modMusic|modVoice|modMixer|modStats|modHue|hudArt|touchOnly|fsVol|fsPad|fsBat|fsWa|fsAch|fsOk|fsFr|fsHeat|fsMus|fsDl|fsCl|photoOn|idleOn)$') { $v = [bool]$v } elseif ($k -eq 'idleMin') { $v = [double]$v } else { $v = [string]$v }
                    $script:Settings[$k] = $v; Save-Settings
                    if ($k -eq 'autostart') { Set-Autostart $v }
                    if ($k -eq 'bg' -or $k -eq 'blur') { Set-Backdrop }
                    if ($k -like 'dcpos*' -or $k -like 'share*' -or $k -eq 'discordSplit') { Update-Layout $true }
                }
            }
            'view' {
                if ([bool]$m.hud -ne $script:HudVisible) { Log ("HUD sichtbar: {0}" -f [bool]$m.hud) }; $script:HudVisible = [bool]$m.hud
                $pg = [string]$m.page
                if ($pg -ne $script:OsPage) {
                    $script:OsPage = $pg; $script:Hue.Active = ($pg -eq 'hue'); $script:LastMediaKey = ''
                    if ($pg -eq 'hue') { Start-HueWorker }
                    if ($pg -eq 'sys' -or $pg -eq 'cc') { Send-Bright }   # Kontrollzentrum zeigt die Edge-Helligkeit
                    if ($pg -eq 'media') { try { Send-Mixer } catch { try { [DeckErr]::L('Z1369', $_) } catch {} } }
                }
            }
            'macro' { Invoke-Macro ([string]$m.id) }
            'timers' {   # Timer des Decks ablegen, damit sie einen Neustart ueberstehen
                try {
                    $list = @($m.list | Where-Object { $_ -and $_.id } | Select-Object -First 20 | ForEach-Object { [ordered]@{ id = [int64]$_.id; label = ([string]$_.label).Substring(0, [math]::Min(40, ([string]$_.label).Length)); total = [int64]$_.total; end = [int64]$_.end; left = [int64]$_.left } })
                    if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
                    ConvertTo-Json -InputObject @($list) -Depth 3 -Compress | Set-Content -Path (Join-Path $script:UserDir 'timers.json') -Encoding UTF8
                } catch { Log "Timer speichern: $_" }
            }
            'whatsapp' { Open-WhatsApp }
            'notifclear' { Clear-Notifs }
            'claude' { Open-Claude }
            'calset' {
                $u = @($m.urls | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^(webcal|https?)://' })
                if ($u.Count) { $script:CalUrls = $u; try { if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }; ConvertTo-Json -InputObject @($u) | Set-Content -Path $script:CalFile -Encoding UTF8 } catch { Log "Kalender: speichern fehlgeschlagen" }; Log "Kalender: $($u.Count) Link(s) hinterlegt"; Start-CalFetch }
            }
            'calrefresh' { Start-CalFetch }
            'caladd' {
                $u = ([string]$m.url).Trim()
                if ($u -match '^(webcal|https?)://' -and $script:CalUrls -notcontains $u -and $script:CalUrls.Count -lt 8) { $script:CalUrls = @($script:CalUrls) + $u; Save-CalUrls; Log "Kalender: Link $($script:CalUrls.Count) hinzugefuegt"; Start-CalFetch } else { Send-Cal }
            }
            'calremove' {
                $i = [int]$m.i
                if ($i -ge 0 -and $i -lt $script:CalUrls.Count) { $nl = @(); for ($j = 0; $j -lt $script:CalUrls.Count; $j++) { if ($j -ne $i) { $nl += $script:CalUrls[$j] } }; $script:CalUrls = $nl; if ($script:CalUrls.Count) { Save-CalUrls } else { try { Remove-Item $script:CalFile -ErrorAction SilentlyContinue } catch { try { [DeckErr]::L('Z1393', $_) } catch {} } }; Log "Kalender: Link $($i + 1) entfernt"; Start-CalFetch }
            }
            'calclear' { $script:CalUrls = @(); try { Remove-Item $script:CalFile -ErrorAction SilentlyContinue } catch { try { [DeckErr]::L('Z1395', $_) } catch {} }; Log 'Kalender: Links entfernt'; Start-CalFetch }
            'tdown' { if ([bool]$script:Settings.touchOnly -and -not $script:Couch) { try { [DeckNative]::CursorFreeze() } catch { try { [DeckErr]::L('Z1396', $_) } catch {} } } }
            'tup' { if ([bool]$script:Settings.touchOnly -and -not $script:Couch) { try { [void][DeckNative]::CursorRestore() } catch { try { [DeckErr]::L('Z1397', $_) } catch {} } } }
            'kbfocus' {
                # Gaming-Tab: Tastatur (Pfeile/Enter) ins Deck holen - nur ohne laufendes Spiel und ohne "Nur Touch"
                if (-not [bool]$script:Settings.touchOnly -and -not $script:Running) { try { $script:Win.Activate(); [void]$script:Wv.Focus() } catch { Log "Tastaturfokus: $_" } }
            }
            'typing' {
                # Texteingabe: Schutz kurz aufheben, damit die Tastatur im Deck ankommt
                $script:Typing = [bool]$m.on
                if ($script:Typing) { try { [void][DeckNative]::FocusGuard($script:Hwnd, $false); $script:Win.Activate() } catch { try { [DeckErr]::L('Z1401', $_) } catch {} } }
            }
            'hue' { Start-HueWorker; $script:Hue.Active = ($script:OsPage -eq 'hue'); $script:HueCmds.Enqueue(($m | ConvertTo-Json -Compress -Depth 5)) }
            'bright' { try { $r = [DeckNative]::Brightness([string]$script:Settings.monitor, [int]$m.value); if ($r -lt 0) { Send-Bright } } catch { Log "Helligkeit: $_" } }
            'reload' { Start-LibraryRefresh; $script:Wv.CoreWebView2.Reload() }
            'photopick' { Select-HomePhoto }
            'update' { try { On-UpdMsg $m } catch { Log "Update: $_" } }
            'power' {
                # Power-Menue: Bestaetigung + Countdown passieren in der Oberflaeche; hier nur feste Befehle
                $op = [string]$m.op; Log "Power: $op"
                try {
                    switch ($op) {
                        'shutdown' { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s', '/t', '0' -WindowStyle Hidden }
                        'restart' { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r', '/t', '0' -WindowStyle Hidden }
                        'logoff' { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/l' -WindowStyle Hidden }
                        'lock' { Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,LockWorkStation' }
                        'sleep' { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false) }
                        default { Log "Power: unbekannt ($op)" }
                    }
                } catch { Log "Power: $_" }
            }
            'photoclear' { Get-ChildItem $script:UserDir -Filter 'homephoto.*' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue; Log 'Home-Foto: entfernt'; Send-HomePhoto }
            'quit' { Log 'Beenden ueber das Menue'; $script:Win.Close() }
            'log' { Log ("Oberflaeche: " + [string]$m.msg) }
            'eyedrop' {
                # Ersatz-Pipette, falls WebView2 keine EyeDropper-Schnittstelle hat: naechster Klick irgendwo
                [DeckNative]::EyeReset()
                $script:EyeUntil = (Get-Date).AddSeconds(20)
                if (-not $script:EyeTimer) {
                    $script:EyeTimer = New-Object Windows.Threading.DispatcherTimer
                    $script:EyeTimer.Interval = [TimeSpan]::FromMilliseconds(25)
                    $script:EyeTimer.add_Tick({
                        try {
                            $hex = [DeckNative]::EyePoll()
                            if ($hex) { $script:EyeTimer.Stop(); Send ([ordered]@{ type = 'eyedrop'; hex = $hex }); Log "Pipette: $hex" }
                            elseif ((Get-Date) -gt $script:EyeUntil) { $script:EyeTimer.Stop() }
                        } catch { $script:EyeTimer.Stop(); Log "Pipette: $_" }
                    })
                }
                $script:EyeTimer.Start()
            }
        }
    }

    # ------------------------------------------------------------ Aufteilung Discord / Deck
    $script:Discord = [IntPtr]::Zero
    $script:PlaceTries = 0
    $script:DiscordOn = $false
    $script:Mon = $null
    $script:LastLayoutMsg = $null
    $script:Hwnd = [IntPtr]::Zero

    # ------------------------------------------------------------ Couch-Modus (Apple TV ueber Apollo-App "Couch")
    # CouchHold.ps1 laeuft als Apollo-App und schreibt user\couch.flag alle 5 s neu; beim Beenden der App loescht Apollo die Datei.
    $script:Couch = $false; $script:CouchFront = 0; $script:CouchQuitAt = $null; $script:CouchPaused = $false
    function Test-CouchFlag {
        if (-not $script:CouchOk) { return $false }
        try {
            if (-not (Test-Path -LiteralPath $script:CouchFlag)) { return $false }
            $age = ((Get-Date) - (Get-Item -LiteralPath $script:CouchFlag).LastWriteTime).TotalSeconds
            if ($age -lt 20) { return $true }
            Log "Couch-Modus: Kennung ohne Lebenszeichen ($([int]$age) s) - entfernt"
            Remove-Item -LiteralPath $script:CouchFlag -Force -ErrorAction SilentlyContinue
        } catch { try { [DeckErr]::L('Z2001', $_) } catch {} }
        return $false
    }
    function Set-Couch([bool]$on) {
        if ($on -eq $script:Couch) { return }
        $script:Couch = $on; $script:CouchPaused = $false
        Log ("Couch-Modus {0}" -f $(if ($on) { 'an' } else { 'aus' }))
        if ($on) {
            $script:CouchFront = 12
            try { [void][DeckNative]::KeepMouseOff('', $false) } catch { try { [DeckErr]::L('Z2002', $_) } catch {} }
            try { [void][DeckNative]::FocusGuard($script:Hwnd, $false) } catch { try { [DeckErr]::L('Z2003', $_) } catch {} }
        } else {
            $script:CouchQuitAt = $null; $script:CouchFront = 0
            Remove-Item -LiteralPath $script:CouchQuit -Force -ErrorAction SilentlyContinue
        }
        Send ([ordered]@{ type = 'couch'; on = $on })
        Update-Layout $true
    }
    # "Couch-Modus beenden": Deck tritt zur Seite, der Windows-Desktop ist auf dem TV, der Stream laeuft weiter.
    # Zurueck: Menue + Ansicht gleichzeitig am Controller (oder Deck neu starten).
    function Suspend-Couch {
        if (-not $script:Couch) { return }
        $script:CouchPaused = $true
        try { $script:Win.Hide() } catch { try { [DeckErr]::L('Z2007', $_) } catch {} }
        Log 'Couch-Modus: Desktop auf dem TV (Deck ausgeblendet, zurueck mit Menue + Ansicht)'
    }
    function Resume-Couch {
        if (-not $script:Couch -or -not $script:CouchPaused) { return }
        $script:CouchPaused = $false; $script:CouchFront = 12
        Log 'Couch-Modus: Deck wieder auf dem TV'
        Send ([ordered]@{ type = 'couch'; on = $true; resumed = $true })
        Update-Layout $true
    }
    function Request-CouchQuit {
        try {
            if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }
            Set-Content -LiteralPath $script:CouchQuit -Value (Get-Date -Format o) -Encoding ASCII
            $script:CouchQuitAt = Get-Date
            Log 'Couch-Modus: Beenden angefordert (Apollo-App wird beendet)'
        } catch { Log "Couch-Modus beenden: $_" }
    }
    function Update-Couch {
        $cf = Test-CouchFlag
        if ($cf -ne $script:Couch) { Set-Couch $cf; return }
        # Sicherheitsnetz: Apollo hat die App nach 20 s nicht beendet -> Couch-Modus trotzdem verlassen
        if ($script:Couch -and $script:CouchQuitAt -and ((Get-Date) - $script:CouchQuitAt).TotalSeconds -gt 20) {
            Log 'Couch-Modus: Apollo hat nicht reagiert - Kennung selbst entfernt'
            Remove-Item -LiteralPath $script:CouchFlag -Force -ErrorAction SilentlyContinue
            Set-Couch $false
        }
    }
    function Update-CouchLayout {
        if ($script:CouchPaused) { if ($script:Win.Visibility -eq 'Visible') { $script:Win.Hide() }; return }
        $pr = $null
        try { $pr = [DeckCouch]::Primary() } catch { try { [DeckErr]::L('Z2004', $_) } catch {} }
        if (-not $pr) { return }
        if ($script:Win.Visibility -ne 'Visible') { $script:Win.Show() }
        if ($script:Hwnd -ne [IntPtr]::Zero) {
            if ([DeckNative]::MoveTo($script:Hwnd, $pr[0], $pr[1], $pr[2], $pr[3])) { Log ("Couch: Deck auf {0},{1} {2}x{3}" -f $pr[0], $pr[1], $pr[2], $pr[3]) }
            if ($script:CouchFront -gt 0 -and -not $script:Running) {
                $script:CouchFront--
                try { if ([DeckCouch]::Front($script:Hwnd)) { $script:CouchFront = 0; try { [void]$script:Wv.Focus() } catch { try { [DeckErr]::L('Z2005', $_) } catch {} } } } catch { try { [DeckErr]::L('Z2006', $_) } catch {} }
            }
        }
    }

    function Update-Idle {
        if (-not $script:IdleOk) { return }
        $now = [datetime]::UtcNow
        $sec = 0.0; try { $sec = [DeckIdle]::Seconds() } catch { try { [DeckErr]::L('Z2130', $_) } catch {} }
        $quiet = [math]::Min($sec, ($now - $script:IdlePad).TotalSeconds)
        $want = $false
        if ($script:IdlePrev) {
            $age = ($now - $script:IdlePrev).TotalSeconds
            if ($age -lt 1.5 -or $quiet -ge ($age - 1.2)) { $want = $true } else { $script:IdlePrev = $null }   # Vorschau bis zur naechsten Eingabe
        }
        $mins = [double]$script:Settings.idleMin; if ($mins -lt 1) { $mins = 5 }
        if ([bool]$script:Settings.idleOn -and $quiet -ge ($mins * 60)) { $want = $true }
        if ($script:Running -or $script:Couch) { $want = $false; $script:IdlePrev = $null }
        if ($want -eq $script:Idle) { return }
        $script:Idle = $want
        Log $(if ($want) { "Idle-Bildschirm an (seit $([int]$quiet) s keine Eingabe)" } else { 'Idle-Bildschirm aus' })
        Send ([ordered]@{ type = 'idle'; on = $want })
        Update-Layout $true
    }
    function Update-Layout([bool]$force) {
        if ($script:Couch) { Update-CouchLayout; return }
        $m = [DeckNative]::DeckMonitor([string]$script:Settings.monitor)
        if (-not $m) {
            if ($script:Win.Visibility -eq 'Visible') { Log 'Kein Zweitbildschirm - Deck ausgeblendet'; $script:Win.Hide() }
            $script:Mon = $null; return
        }
        if ($script:Win.Visibility -ne 'Visible') { $script:Win.Show() }
        $script:Mon = $m
        $h = [DeckNative]::FindDiscord()
        $on = ([DeckNative]::WindowState($h) -eq 1) -and [bool]$script:Settings.discordSplit
        if ($on -ne $script:DiscordOn) { Log ("Discord {0}" -f $(if ($on) { 'offen' } else { 'zu' })) }
        $script:Discord = $h; $script:DiscordOn = $on
        $dockOn = $on
        if ($script:Idle) { $on = $false }   # Idle-Bildschirm: Deck ueber die ganze Breite, Discord bleibt darunter liegen

        $portrait = $m.H -ge $m.W
        $scale = $m.Dpi / 96.0
        $dx = $m.X; $dy = $m.Y; $dw = $m.W; $dh = $m.H
        $cx = 0; $cy = 0; $cw = 0; $ch = 0
        if ($portrait) { $dcpos = [string]$script:Settings.dcposP; $share = [double]$script:Settings.shareP } else { $dcpos = [string]$script:Settings.dcposL; $share = [double]$script:Settings.shareL }
        if ($on) {
            $a = ($dcpos -ne 'b')
            if ($portrait) {
                $ch = [int][math]::Max([math]::Ceiling(500 * $scale), [math]::Round($m.H * $share)); $cw = $m.W
                $cx = $m.X
                if ($a) { $cy = $m.Y; $dy = $m.Y + $ch } else { $cy = $m.Y + $m.H - $ch; $dy = $m.Y }
                $dh = $m.H - $ch
            } else {
                $cw = [int][math]::Max([math]::Ceiling(940 * $scale), [math]::Round($m.W * $share)); $ch = $m.H
                $cy = $m.Y
                if ($a) { $cx = $m.X; $dx = $m.X + $cw } else { $cx = $m.X + $m.W - $cw; $dx = $m.X }
                $dw = $m.W - $cw
            }
        }
        $script:DeckX = $dx; $script:DeckW = $dw
        if ($script:Hwnd -ne [IntPtr]::Zero) {
            if ([DeckNative]::MoveTo($script:Hwnd, $dx, $dy, $dw, $dh)) { Log "Deck: $dx,$dy ${dw}x$dh" }
        }
        if (-not $on -and -not $script:Idle) { $script:PlaceTries = 0 }
        if ($script:Idle -and $dockOn -and $script:IdleOk) { [void][DeckIdle]::Raise($script:Hwnd) }
        if ($on -and -not [DeckNative]::MouseDown()) {
            # Wehrt sich das Fenster (z. B. Mindestgroesse), nur noch alle 10 s versuchen statt dauernd zu ziehen.
            if ($script:PlaceTries -lt 3 -or ($script:Tick % 40 -eq 0)) {
                if ([DeckNative]::Place($h, $cx, $cy, $cw, $ch)) { $script:PlaceTries++; if ($script:PlaceTries -le 3) { Log "Discord gesetzt: $cx,$cy ${cw}x$ch" } } else { $script:PlaceTries = 0 }
            }
        }
        # Bildschirmliste fuer die Auswahl in den Einstellungen (deckos-179): alle 5 s und bei erzwungenem Layout neu lesen
        if ($force -or (-not $script:MonList) -or ($script:Tick % 20 -eq 0)) {
            try { $script:MonList = @([DeckNative]::Monitors() | ForEach-Object { [ordered]@{ dev = [string]$_.Device; w = [int]$_.W; h = [int]$_.H; primary = [bool]$_.Primary } }) } catch { Log "Bildschirmliste: $_"; $script:MonList = @() }
            $script:MonKey = (@($script:MonList | ForEach-Object { "$($_.dev):$($_.w)x$($_.h):$($_.primary)" }) -join ',')
        }
        $msg = [ordered]@{ type = 'layout'; discordUp = ($h -ne [IntPtr]::Zero); discord = $on; portrait = $portrait; dcpos = $dcpos; share = $share; discordSplit = [bool]$script:Settings.discordSplit; autostart = [bool]$script:Settings.autostart; monitor = [string]$script:Settings.monitor; monActive = [string]$m.Device; monitors = @($script:MonList) }
        $key = "$on|$($h -ne [IntPtr]::Zero)|$portrait|$dcpos|$share|$($script:Settings.discordSplit)|$($script:Settings.autostart)|$($script:Settings.monitor)|$($m.Device)|$($script:MonKey)"
        if ($force -or $key -ne $script:LastLayoutMsg) { $script:LastLayoutMsg = $key; Send $msg }
    }

    # ------------------------------------------------------------ laufendes Spiel
    $script:Running = $null; $script:RunningName = $null; $script:RunningSince = 0; $script:LastStateMsg = $null
    $script:IgnoreProc = 'Discord|DiscordPTB|DiscordCanary|msedgewebview2|msedge|chrome|firefox|vivaldi|explorer|dwm|steamwebhelper|Steam|EpicGamesLauncher|MSIAfterburner|RTSS|powershell|Claude|Raycast|dock_64|NVIDIA.*|obs64|Spotify|Code|ui32|.*wallpaper.*|iCUE|CUETrayMenu|VSCodium|SteelSeries.*|.*Overlay.*|GameBar.*|XboxGameBar.*|Overwolf.*|lghub.*|LGHUB.*|NZXT.*|RazerCortex.*|Razer.*|Medal.*|ArmouryCrate.*|ArmourySocketServer|AMDRSServer|RadeonSoftware|ShareX|Playnite.*|GOG Galaxy|GalaxyClient|EADesktop|EABackgroundService|UbisoftConnect|upc|Battle.net|RockstarLauncher|SignalRgb.*|WhatsApp.*|Telegram|ApplicationFrameHost|SystemSettings|TextInputHost|ShellExperienceHost|StartMenuExperienceHost|SearchHost'
    function Update-Running {
        $id = $null; $name = $null
        try {
            $rid = [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Valve\Steam', 'RunningAppID', 0)
            if ($rid -and [int]$rid -gt 0) {
                # nur Spiele aus der Bibliothek: Steam-Werkzeuge wie Wallpaper Engine (431960) zaehlen nicht
                $g = $script:Games | Where-Object { $_.Id -eq "steam_$rid" } | Select-Object -First 1
                if ($g) { $id = $g.Id; $name = $g.Name }
            }
        } catch { try { [DeckErr]::L('Z1512', $_) } catch {} }
        if (-not $id) {   # Emulatoren (Eden, PokeDinner, Fritchii): alle Spiele laufen als eine exe - das zuletzt vom Deck gestartete Spiel, sonst Fenstertitel
            try {
                $anyEmu = $false
                foreach ($src in $script:EmuProc.Keys) {
                    $ep = @([Diagnostics.Process]::GetProcessesByName($script:EmuProc[$src]))
                    if ($ep.Count -eq 0) { continue }
                    $anyEmu = $true
                    if ($script:EmuRun -and $script:EmuRun.src -eq $src) { $id = $script:EmuRun.id; $name = $script:EmuRun.name; break }
                    $ti = ($ep | ForEach-Object { $_.MainWindowTitle }) -join ' '
                    $cand = @($script:Games | Where-Object { $_.Source -eq $src })
                    foreach ($g in $cand) { $n2 = [string]$g.Name; if ($g.PSObject.Properties['NameOrig'] -and $g.NameOrig) { $n2 = [string]$g.NameOrig }; if ($ti -and ($ti.IndexOf($g.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $ti.IndexOf($n2, [StringComparison]::OrdinalIgnoreCase) -ge 0)) { $id = $g.Id; $name = $g.Name; break } }
                    if (-not $id -and $cand.Count -eq 1) { $id = $cand[0].Id; $name = $cand[0].Name }
                    if ($id) { break }
                }
                if (-not $anyEmu) { $script:EmuRun = $null }
            } catch { Log "Emulator erkennen: $_" }
        }
        if (-not $id) {
            foreach ($g in $script:Games) {
                if ($g.Type -ne 'exe' -or $script:EmuProc.ContainsKey([string]$g.Source)) { continue }
                try { if ([Diagnostics.Process]::GetProcessesByName([IO.Path]::GetFileNameWithoutExtension($g.Target)).Count -gt 0) { $id = $g.Id; $name = $g.Name; break } } catch { try { [DeckErr]::L('Z1516', $_) } catch {} }
            }
        }
        if (-not $id) {
            $fps = 0.0
            $procId = [DeckNative]::RtssTop([ref]$fps)
            if ($procId -gt 0 -and $fps -gt 5) {
                try {
                    $p = [Diagnostics.Process]::GetProcessById($procId)
                    $pPath = ''; try { $pPath = [string]$p.Path } catch { try { [DeckErr]::L('Z1525', $_) } catch {} }
                    $pTi = ''; try { $pTi = [string]$p.MainWindowTitle } catch {}
                    $ignX = [string]$script:Settings.ignoreProc   # deck.json: eigene Ausschluesse, z. B. 'ToolA|ToolB'
                    if ($p.ProcessName -notmatch "^($($script:IgnoreProc))$" -and -not ($ignX -and $p.ProcessName -match "^($ignX)$") -and $pTi -notmatch 'overlay' -and $pPath -notmatch '\\steamapps\\common\\wallpaper_engine\\|\\(SteelSeries|Overwolf|Razer|Logitech|LGHUB|NZXT|ASUS|Corsair|MSI Afterburner|RivaTuner)' -and $pPath -notmatch '^[A-Z]:\\Windows\\') {
                        $id = 'proc_' + $p.ProcessName; $name = $p.MainWindowTitle; if (-not $name) { $name = $p.ProcessName }
                        foreach ($g in $script:Games) { if ($g.InstallDir) { try { if ($p.Path -and $p.Path.StartsWith($g.InstallDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $id = $g.Id; $name = $g.Name; break } } catch { try { [DeckErr]::L('Z1528', $_) } catch {} } } }
                    }
                } catch { try { [DeckErr]::L('Z1530', $_) } catch {} }
            }
        }
        if ($id -ne $script:Running) {
            if ($script:Running -match '^(eden|pdn|fch)_' -and $script:RunningSince -gt 0) {   # Emulator-Sitzung beendet oder gewechselt: Spielzeit gutschreiben
                try {
                    $m = [int][math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $script:RunningSince) / 60000)
                    if ($m -ge 1) { $h = Read-EmuPlayed; $k = $script:Running; if (-not $h.ContainsKey($k)) { $h[$k] = @{ last = 0; min = 0; s = @() } }; $h[$k].min += $m; $h[$k].last = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $h[$k].s = @(@($h[$k].s) + @(@{ t = [int64]($script:RunningSince / 1000); m = $m }) | Select-Object -Last 60); Save-EmuPlayed $h; Log "Spielzeit ${k}: +$m Min."; Start-LibraryRefresh }
                } catch { Log "Emulator-Spielzeit: $_" }
            }
            if ($id) { Log "Spiel erkannt: $name ($id)"; $script:RunningSince = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } else { if ($script:Running) { Log 'Spiel beendet'; if ($script:Couch) { $script:CouchFront = 12 } }; $script:RunningSince = 0 }
            $script:Running = $id; $script:RunningName = $name
            $script:FpsTAt = $script:Tick + 12   # FPS-Ziel neu bestimmen, sobald RTSS das Spiel sieht (Spielprofil der NVIDIA App)
        }
        $script:RunningPid = 0
        if ($id) { $f2 = 0.0; $rp = [DeckNative]::RtssTop([ref]$f2); if ($rp -gt 0 -and $f2 -gt 5) { $script:RunningPid = $rp } }
        Send-State
    }
    function Send-State {
        $key = "$($script:Running)|$($script:RunningSince)"
        if ($key -eq $script:LastStateMsg) { return }
        $script:LastStateMsg = $key
        Send ([ordered]@{ type = 'state'; running = $script:Running; runningName = $script:RunningName; since = $script:RunningSince })
    }

    # ------------------------------------------------------------ Afterburner-Werte (nur bei sichtbarem HUD)
    # Bildrate direkt aus RTSS (unabhaengig von Afterburners Framerate-Graph), Hardwarewerte aus Afterburner.
    $script:HudDiag = 0; $script:HudDiagKey = ''; $script:HudDiagAt = [datetime]::MinValue
    function Send-Hud {
        $d = [DeckNative]::ReadMahm()
        $rtss = [DeckNative]::RtssPresent()
        $rf = 0.0; $rft = 0.0
        $rpid = [DeckNative]::RtssApp([ref]$rf, [ref]$rft)
        if (-not $d) { $d = @{} }
        $gp = 'GPU'; $best = -1
        foreach ($k in @($d.Keys)) { if ($k -match '^(GPU\d*) memory usage$' -and $d[$k] -gt $best) { $best = $d[$k]; $gp = $Matches[1] } }
        function V($n) { if ($d.ContainsKey($n)) { return [math]::Round([double]$d[$n], 1) }; return 0 }
        $fps = V 'Framerate'; $ft = V 'Frametime'
        if ($fps -le 0 -and $rf -gt 0) { $fps = [math]::Round($rf, 1); $ft = [math]::Round($rft, 2) }
        if ($ft -le 0 -and $fps -gt 0) { $ft = [math]::Round(1000 / $fps, 2) }
        $low = $null
        foreach ($n in 'Framerate 1% low', 'Framerate 1%low', '1% low framerate') { if ($d.ContainsKey($n) -and $d[$n] -gt 0) { $low = [math]::Round($d[$n]); break } }
        $script:HudDiag++
        if ($script:HudDiag % 20 -eq 1) {
            $rp = @(Get-Process RTSS -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Path } catch { 'Pfad unlesbar' } })
            $fr = @($d.Keys | Where-Object { $_ -match 'frame' }) -join ', '
            # nur ins Log, wenn sich die Quellen aendern (oder alle 10 min) - vorher alle 10 s
            $dk = "$($rp.Count -gt 0)|$($rp -join ';')|$([DeckNative]::RtssStatus())|$rpid|$($d.Count)|$fr|$gp"
            if ($dk -ne $script:HudDiagKey -or ((Get-Date) - $script:HudDiagAt).TotalMinutes -ge 10) { $script:HudDiagKey = $dk; $script:HudDiagAt = Get-Date
            Log ("HUD-Quellen: RTSS-Prozess={0} [{1}] RTSS-Speicher={2} RTSS-App={3} ({4:N0} fps) MAHM={5} Quellen, Frame-Quellen=[{6}], GPU={7}" -f ($rp.Count -gt 0), ($rp -join ';'), [DeckNative]::RtssStatus(), $rpid, $rf, $d.Count, $fr, $gp) }
        }
        $cclk = 0.0; foreach ($k in @($d.Keys)) { if ($k -match '^CPU\d+ clock$' -and [double]$d[$k] -gt $cclk) { $cclk = [math]::Round([double]$d[$k]) } }
        Send ([ordered]@{ type = 'hud'; hasFps = [bool]$rtss; fps = $fps; ft = $ft; low = $low
            gpu = (V "$gp usage"); cpu = (V 'CPU usage'); gt = (V "$gp temperature"); ct = (V 'CPU temperature')
            vram = [math]::Round((V "$gp memory usage") / 1024, 1); pw = (V "$gp power"); gclk = (V "$gp core clock"); cclk = $cclk })
    }

    # ------------------------------------------------------------ Hotkeys
    $script:HotLetters = 'SADFVTR'
    if ($script:Settings.Contains('hotkeys') -and ($script:Settings.hotkeys -eq $false)) { $script:HotLetters = ''; Log 'Hotkeys abgeschaltet (deck.json: hotkeys = false)' }
    $failed = [DeckNative]::RegisterHotkeys($script:HotLetters)
    if ($failed) { Log "Hotkeys belegt (Strg+Alt+): $failed" }
    function On-Hotkey([int]$vk) {
        $ch = ([char]$vk).ToString().ToLower()
        if ($ch -eq 'r') {
            if ($script:Mon) { $r = [DeckNative]::Rotate($script:Mon.Device); Log "Drehen: Ergebnis $r" }
            return
        }
        Send ([ordered]@{ type = 'hotkey'; key = $ch })
    }

    # ------------------------------------------------------------ Takt: 250 ms
    $script:Tick = 0; $script:MonList = $null; $script:MonKey = ''; $script:MuteDiag = $null
    $timer = New-Object Windows.Threading.DispatcherTimer ([Windows.Threading.DispatcherPriority]::Background)
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        try {
            $script:Tick++
            if ($script:QuitEvent.WaitOne(0)) { Log 'Abgeloest durch neuen Start'; $script:Win.Close(); return }
            while ($true) { $k = [DeckNative]::NextHotkey(); if ($k -eq 0) { break }; On-Hotkey $k }
            Update-Idle
            if ($script:Tick % 4 -eq 0) { Update-Couch; Update-Layout $false; Update-Running }
            if ($script:Tick % 40 -eq 7) { $sl = Get-SysLight; if ($sl -ne $script:SysLight) { $script:SysLight = $sl; Send ([ordered]@{ type = 'theme'; sysLight = $sl }) } }
            $osMedia = ($script:OsPage -eq 'media')
            if (($script:HudVisible -or $script:OsPage -eq 'sys') -and ($script:Tick % 2 -eq 0)) { Send-Hud }
            elseif ($script:Tick % 8 -eq 5) { try { Send-Hud } catch { try { [DeckErr]::L('Z1606', $_) } catch {} } }   # langsam im Hintergrund: fuer die Hitzewarnung
            if (($script:HudVisible -and [bool]$script:Settings.modMusic) -or $osMedia -or $script:OsPage) {   # Mini-Player im Dock: auf allen DeckOS-Seiten
                 if (-not $script:MediaPs) { Start-MediaWorker }; if ($script:Tick % 2 -eq 1) { Send-Media } }
            if ((($script:HudVisible -and [bool]$script:Settings.modMixer) -or $osMedia) -and ($script:Tick % 8 -eq 3)) { try { Send-Mixer } catch { Log "Mixer: $_" } }
            Poll-Hue
            if ($script:Tick % 4 -eq 2) { Send-Mutes }
            if ($script:MuteDiag -and $script:Tick -ge $script:MuteDiag.at) { try { Log ('Ton-Diagnose 2 s spaeter: [' + [DeckNative]::EndpointMuteDiag([int]$script:MuteDiag.flow) + ']') } catch { }; $script:MuteDiag = $null }
            if (($script:Tick % 8 -eq 4) -or ($script:CamReqAt -and $script:Tick % 2 -eq 0)) { try { Send-Cam } catch { try { [DeckErr]::L('Z1612', $_) } catch {} } }
            if ($script:Tick % 4 -eq 1) { Send-PadBat }   # jede Sekunde: Verbinden/Trennen zuegig melden
            if (($script:Tick % 240 -eq 11) -or ($script:FpsTAt -and $script:Tick -ge $script:FpsTAt)) { $script:FpsTAt = 0; try { Send-FpsTarget } catch { try { [DeckErr]::L('Z3103', $_) } catch {} } }   # FPS-Ziel: jede Minute und 3 s nach Spielwechsel
            if ($script:Tick % 12 -eq 9) { Poll-WhatsApp }
            if ($script:Tick % 12 -eq 3) { Poll-Claude }
            if ($script:Tick % 4 -eq 3) { try { Poll-Friends } catch { Log "Steam-Freunde: $_" } }
            if ($script:Tick % 2 -eq 1) { try { Poll-HueSync } catch { try { [DeckErr]::L('Z1617a', $_) } catch {} }; try { Poll-AppIcons } catch { try { [DeckErr]::L('Z1617b', $_) } catch {} } }
            if ($script:Tick % 4 -eq 0) { try { Poll-Update } catch { Log "Update: $_" } }
            if ($script:Tick % 12 -eq 5) { try { Poll-SteamDownloads } catch { Log "Steam-Downloads: $_" } }   # nur Status (laeuft/fertig), keine Live-Prozente (31.10.)
            Poll-Cal
            if ($script:Tick % 8 -eq 6) { Poll-DevBat }
            if ($script:Tick % 3600 -eq 1800) { Start-CalFetch }   # alle 15 min
            if ($script:SgdbJob) { Poll-SgdbJob }
            if ($script:Perf) {
                if ($script:Perf.Line) { Log $script:Perf.Line; $script:Perf.Line = '' }
                if (-not $script:Perf.WvPid -and $script:Tick % 40 -eq 20) { try { $script:Perf.WvPid = [int]$script:Wv.CoreWebView2.BrowserProcessId } catch { try { [DeckErr]::L('Z1625', $_) } catch {} } }
            }
            Poll-LogoFetch
            if ($script:Tick -eq 120) { Start-LogoFetch }   # 30 s nach dem Start
            # Nur Touch: Mauszeiger vom Deck-Monitor fernhalten (Spiele mit eigener Begrenzung bleiben unangetastet)
            try {
                $km = [DeckNative]::KeepMouseOff([string]$script:Settings.monitor, ([bool]$script:Settings.touchOnly -and -not $script:Couch -and -not ($script:Mon -and $script:Mon.Primary)))   # auf dem Hauptbildschirm nie die Maus aussperren
                if ($km -ne 0 -and $km -ne $script:LastKm) { Log ("Nur Touch: {0}" -f $(switch ($km) { 1 { 'Maus vom Edge ferngehalten' } 2 { 'Spiel begrenzt Maus selbst' } 3 { 'Maus wieder frei' } })) }
                if ($km -ne 0) { $script:LastKm = $km }
            } catch { try { [DeckErr]::L('Z1634', $_) } catch {} }
            if ($script:Tick % 1200 -eq 0) { Start-LibraryRefresh }   # alle 5 min: neu installierte Spiele (alle Launcher) erscheinen von selbst
            if ($script:Tick % 40 -eq 0) {
                try { if ((Test-GamesChanged) -or ($script:Tick % 1200 -eq 600 -and (Get-PlayStamp) -ne $script:PlayStamp)) { Load-Games; Send ([ordered]@{ type = 'games'; games = $script:GamesMsg; hidden = @($script:HiddenMsg) }); if ($script:Tick -gt 120 -and -not $script:LogoPs) { $script:LogoDone = $false; Start-LogoFetch } } } catch { try { [DeckErr]::L('Z1637', $_) } catch {} }
            }
        } catch { Log "Takt: $_" }
    })

    $win.add_SourceInitialized({
        $script:Hwnd = (New-Object Windows.Interop.WindowInteropHelper $script:Win).Handle
        [DeckNative]::MakeToolNoActivate($script:Hwnd)
        Set-Backdrop
        Update-Layout $true
    })
    $win.add_Loaded({ try { [void]$script:Wv.EnsureCoreWebView2Async() } catch { Log "WebView2: $_" } })
    $win.add_Closed({
        $script:Closing = $true
        try { $timer.Stop() } catch { try { [DeckErr]::L('Z1650', $_) } catch {} }
        try { [void][DeckNative]::KeepMouseOff('', $false) } catch { try { [DeckErr]::L('Z1651', $_) } catch {} }
        try { $script:Hue.Stop = $true } catch { try { [DeckErr]::L('Z1652', $_) } catch {} }
        try { $script:PadBat.Stop = $true } catch { try { [DeckErr]::L('Z1653a', $_) } catch {} }; try { $script:DevBat.Stop = $true } catch { try { [DeckErr]::L('Z1653b', $_) } catch {} }
        try { $script:Media.Stop = $true } catch { try { [DeckErr]::L('Z1654', $_) } catch {} }
        try { $script:Perf.Stop = $true } catch { try { [DeckErr]::L('Z1655', $_) } catch {} }
        try { [DeckNative]::UnregisterHotkeys($script:HotLetters) } catch { try { [DeckErr]::L('Z1656', $_) } catch {} }
        try { $script:Wv.Dispose() } catch { try { [DeckErr]::L('Z1657', $_) } catch {} }
        Log '--- Ende'
    })

    $script:User = Get-UserInfo
    $script:VramGB = Get-VramGB
    Log ("Nutzer: {0} | Bild: {1} | VRAM: {2} GB" -f $script:User.name, $script:User.avatar, $script:VramGB)
    if ([bool]$script:Settings.autostart -ne (Test-Path $script:StartupLink)) { Set-Autostart ([bool]$script:Settings.autostart) }
    elseif ([bool]$script:Settings.autostart) { Set-Autostart $true }
    Load-Games
    Start-LibraryRefresh
    $timer.Start()

    # ------------------------------------------------------------ Leistungs-Messung: alle 10 min eine Zeile ins Log (laeuft im Hintergrund, kostet das Deck nichts)
    $script:Perf = [hashtable]::Synchronized(@{ Stop = $false; HostPid = $PID; WvPid = 0; Line = '' })
    try {
        $pps = [PowerShell]::Create()
        [void]$pps.AddScript({
            param($P)
            $cores = [Environment]::ProcessorCount; $prev = $null; $first = $true
            while (-not $P.Stop) {
                for ($i = 0; $i -lt $(if ($first) { 120 } else { 600 }) -and -not $P.Stop; $i++) { Start-Sleep -Seconds 1 }
                if ($P.Stop) { break }
                try {
                    $now = [datetime]::UtcNow
                    $hp = [Diagnostics.Process]::GetProcessById([int]$P.HostPid); $hCpu = $hp.TotalProcessorTime.TotalMilliseconds; $hRam = $hp.WorkingSet64
                    $wCpu = 0.0; $wRam = 0; $wN = 0
                    if ([int]$P.WvPid -gt 0) {
                        $all = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue)
                        $ids = @{ ([int]$P.WvPid) = $true }
                        for ($r = 0; $r -lt 3; $r++) { foreach ($x in $all) { if ($ids.ContainsKey([int]$x.ParentProcessId)) { $ids[[int]$x.ProcessId] = $true } } }
                        foreach ($x in $all) { if ($ids.ContainsKey([int]$x.ProcessId)) { $wN++; $wCpu += ([double]$x.UserModeTime + [double]$x.KernelModeTime) / 10000; $wRam += [int64]$x.WorkingSetSize } }
                    }
                    if ($prev) {
                        $ms = ($now - $prev.T).TotalMilliseconds * $cores
                        $hc = [math]::Max(0.0, [double](($hCpu - $prev.H) / $ms * 100)); $wc = [math]::Max(0.0, [double](($wCpu - $prev.W) / $ms * 100))
                        $P.Line = ("Leistung (10 min): Deck-Programm CPU {0:N2} % RAM {1:N0} MB | Oberflaeche CPU {2:N2} % RAM {3:N0} MB ({4} Prozesse)" -f $hc, ($hRam / 1MB), $wc, ($wRam / 1MB), $wN)
                    }
                    $prev = @{ T = $now; H = $hCpu; W = $wCpu }; $first = $false
                } catch { $P.Line = "Leistung: Messung fehlgeschlagen ($($_.Exception.Message))" }
            }
        }.ToString())
        [void]$pps.AddArgument($script:Perf)
        [void]$pps.BeginInvoke()
    } catch { Log "Leistung: Messung nicht gestartet ($_)" }

    # ------------------------------------------------------------ DeckOS: Xbox-Controller steuert das Deck, nur solange kein Spiel laeuft
    $script:PadPrev = 0; $script:PadRep = @{}; $script:PadNext = [datetime]::MinValue; $script:PadOk = $true
    $script:PadMap = @(@('up', 0x40001), @('down', 0x80002), @('left', 0x10004), @('right', 0x20008), @('a', 0x1000), @('b', 0x2000), @('x', 0x4000), @('y', 0x8000), @('lb', 0x100), @('rb', 0x200), @('start', 0x10), @('rup', 0x100000), @('rdown', 0x200000))
    $padTimer = New-Object Windows.Threading.DispatcherTimer ([Windows.Threading.DispatcherPriority]::Input)
    $padTimer.Interval = [TimeSpan]::FromMilliseconds(16)   # 60 Hz wie das Edge
    # Sperre: Laeuft ein Spiel (auch eins, das nicht im Deck steht) oder liegt ein Vollbild-/3D-Fenster vorn,
    # gehoert der Controller dem Spiel. Nach dem Ende bleibt das Deck noch 10 s gesperrt; danach weckt der erste Druck nur die Markierung.
    $script:PadLocked = $false; $script:PadLockUntil = [datetime]::MinValue; $script:PadLockN = 0; $script:PadResync = $false; $script:PadWhy = ''
    function Test-PadBusy {
        if ($script:Running) { return "Spiel $($script:Running)" }
        if (-not $script:PadGuardOk) { return '' }
        try {
            $fp = 0
            $k = [DeckPadGuard]::FgInfo($script:Hwnd, [ref]$fp)
            if ($k -eq 2) { return "Vollbild pid $fp ($([DeckPadGuard]::LastClass))" }
            if ($k -eq 1 -and $fp -gt 0) {
                $f3 = 0.0
                $rp = [DeckNative]::RtssTop([ref]$f3)
                if ($rp -eq $fp -and $f3 -gt 5) { return "3D-Fenster pid $fp" }
            }
        } catch { $script:PadGuardOk = $false; Log "Controller-Sperre: Vordergrund-Pruefung abgeschaltet ($_)" }
        return ''
    }
    $padTimer.add_Tick({
        if (-not $script:PadOk -or -not $script:Ready) { $script:PadPrev = 0; return }
        $now = [datetime]::UtcNow
        if ($script:Couch -and $script:CouchPaused) {
            $rb = -1
            try { $rb = [DeckNative]::PadButtons() } catch { try { [DeckErr]::L('Z2008', $_) } catch {} }
            if ($rb -ge 0 -and ($rb -band 0x30) -eq 0x30 -and ($script:PadPrev -band 0x30) -ne 0x30) { Resume-Couch }
            $script:PadPrev = [math]::Max(0, $rb); return
        }
        $script:PadLockN++
        if ($script:Running -or ($script:PadLockN % 8) -eq 0) {
            $why = Test-PadBusy
            if ($why) { $script:PadLockUntil = $now.AddSeconds(10); $script:PadWhy = $why }
            $lk = $now -lt $script:PadLockUntil
            if ($lk -ne $script:PadLocked) {
                $script:PadLocked = $lk
                if ($lk) { Log "Controller: Deck-Steuerung gesperrt ($($script:PadWhy))" } else { Log 'Controller: Deck-Steuerung wieder frei'; $script:PadResync = $true }
                Send ([ordered]@{ type = 'padLock'; on = $lk })
            }
        }
        if ($script:PadLocked) { $script:PadPrev = 0; return }
        if ($now -lt $script:PadNext) { return }
        $b = -1
        try { $b = [DeckNative]::PadButtons() } catch { $script:PadOk = $false; Log "Controller: XInput nicht verfuegbar ($_)"; return }
        if ($b -lt 0) { $script:PadPrev = 0; $script:PadNext = $now.AddSeconds(2); return }   # kein Controller: nur alle 2 s nachsehen
        if ($b -ne $script:PadPrev -and $b -ne 0) { $script:IdlePad = $now; if ($script:Idle) { $script:IdlePrev = $null; Update-Idle; $script:PadPrev = $b; return } }   # Controller weckt nur, loest nichts aus
        if ($script:PadResync) { $script:PadResync = $false; $script:PadPrev = $b; return }   # beim Freigeben gehaltene Tasten zaehlen nicht als Druck
        foreach ($m in $script:PadMap) {
            $name = $m[0]; $mask = [int]$m[1]
            $on = ($b -band $mask) -ne 0; $was = ($script:PadPrev -band $mask) -ne 0
            if ($on -and -not $was) { Send ([ordered]@{ type = 'pad'; btn = $name }); $script:PadRep[$name] = $now.AddMilliseconds(300) }
            elseif ($on -and $was -and $name -in @('up', 'down', 'left', 'right', 'rup', 'rdown') -and $now -ge $script:PadRep[$name]) { Send ([ordered]@{ type = 'pad'; btn = $name }); $script:PadRep[$name] = $now.AddMilliseconds(90) }
        }
        $script:PadPrev = $b
    })
    $padTimer.Start()

    # ------------------------------------------------------------ DeckOS: Controller-Akku (XInput-Stufe; genaue Prozent per Bluetooth, falls verfuegbar)
    $script:PadBat = [hashtable]::Synchronized(@{ Pct = -1; Stop = $false })
    $bps = [PowerShell]::Create()
    [void]$bps.AddScript({
        param($B)
        while (-not $B.Stop) {
            $pct = -1
            try {
                foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Xbox' -and $_.InstanceId -match '^BTH' })) {
                    $v = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2' -ErrorAction SilentlyContinue).Data
                    if ($null -ne $v -and [int]$v -ge 0 -and [int]$v -le 100) { $pct = [int]$v; break }
                }
            } catch { try { [DeckErr]::L('Z1737', $_) } catch {} }
            $B.Pct = $pct
            for ($i = 0; $i -lt 60 -and -not $B.Stop; $i++) { Start-Sleep -Seconds 1 }
        }
    }.ToString())
    [void]$bps.AddArgument($script:PadBat)
    [void]$bps.BeginInvoke()
    # ------------------------------------------------------------ DeckOS: Lautstaerke-Anzeige (Aenderungen ~20x pro Sekunde erkennen)
    $script:LastVol = -2; $script:VolTick = 0
    $volTimer = New-Object Windows.Threading.DispatcherTimer ([Windows.Threading.DispatcherPriority]::Input)
    $volTimer.Interval = [TimeSpan]::FromMilliseconds(50)
    $volTimer.add_Tick({
        if (-not $script:Ready) { return }
        $script:VolTick++; if ($script:VolTick % 100 -eq 0) { [DeckNative]::VolumeReset() }   # Standardgeraet gewechselt? alle 5 s neu greifen
        $v = -1; try { $v = [DeckNative]::MasterVolume() } catch { try { [DeckErr]::L('Z1751', $_) } catch {} }
        if ($v -lt 0 -or $v -eq $script:LastVol) { return }
        $first = ($script:LastVol -eq -2); $script:LastVol = $v
        Send ([ordered]@{ type = 'vol'; v = ($v % 1000); mute = ($v -ge 1000); show = (-not $first) })
    })
    $volTimer.Start()

    # ------------------------------------------------------------ Geraete-Akkus ueber Herstellersoftware (nur lesen): Logitech G Hub, Corsair iCUE, SteelSeries GG
    $script:DevBat = [hashtable]::Synchronized(@{ Stop = $false; Out = ''; Stamp = 0; Dir = $script:Root; Log = New-Object System.Collections.ArrayList })
    $dbps = [PowerShell]::Create()
    [void]$dbps.AddScript({
        param($B, $icueDll)
        function Note($t) { [void]$B.Log.Add($t) }
        $seenSs = $false; $lastErr = @{}; $cache = @{}; $fast = 0; $ssProcPorts = @(); $ssProcAt = $null; $ssBase = $null; $ssDescDone = @{}; $ssFns = @{}; $ssFnUsed = ''; $seenSsRaw = $false
        function Err($k, $t) { if ($lastErr[$k] -ne $t) { $lastErr[$k] = $t; Note "Akku $($k): $t" } }
        while (-not $B.Stop) {
            $list = New-Object System.Collections.ArrayList
            # --- Logitech G Hub: lokaler WebSocket ws://localhost:9010
            try {
                $ws = New-Object System.Net.WebSockets.ClientWebSocket
                $ws.Options.SetRequestHeader('Origin', 'file://'); $ws.Options.AddSubProtocol('json')
                $cts = New-Object System.Threading.CancellationTokenSource 6000
                if ($ws.ConnectAsync([Uri]'ws://localhost:9010', $cts.Token).Wait(3000)) {
                    $send = { param($o) $b = [Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress)); [void]$ws.SendAsync((New-Object ArraySegment[byte] (,$b)), 'Text', $true, $cts.Token).Wait(2000) }
                    $recv = {
                        $buf = New-Object byte[] 65536; $ms = New-Object IO.MemoryStream
                        do { $t = $ws.ReceiveAsync((New-Object ArraySegment[byte] (,$buf)), $cts.Token); if (-not $t.Wait(2500)) { return $null }; $ms.Write($buf, 0, $t.Result.Count) } while (-not $t.Result.EndOfMessage)
                        [Text.Encoding]::UTF8.GetString($ms.ToArray())
                    }
                    & $send @{ msgId = ''; verb = 'GET'; path = '/devices/list' }
                    $devs = @(); for ($i = 0; $i -lt 6; $i++) { $m = & $recv; if (-not $m) { break }; $j = $m | ConvertFrom-Json; if ($j.path -eq '/devices/list') { $devs = @($j.payload.deviceInfos); break } }
                    foreach ($d in $devs) {
                        & $send @{ msgId = ''; verb = 'GET'; path = "/battery/$($d.id)/state" }
                        for ($i = 0; $i -lt 4; $i++) {
                            $m = & $recv; if (-not $m) { break }; $j = $m | ConvertFrom-Json
                            if ($j.path -like "/battery/$($d.id)/state") { if ($j.payload -and $null -ne $j.payload.percentage) { [void]$list.Add([ordered]@{ src = 'logitech'; kind = ([string]$d.deviceType).ToLower(); name = [string]$d.extendedDisplayName; pct = [int][math]::Round([double]$j.payload.percentage); charging = [bool]$j.payload.charging }) }; break }
                        }
                    }
                    try { [void]$ws.CloseAsync('NormalClosure', '', $cts.Token).Wait(1000) } catch { try { [DeckErr]::L('Z1789', $_) } catch {} }
                    $lastErr['G Hub'] = ''
                } else { Err 'G Hub' 'nicht erreichbar (laeuft G Hub?)' }
                $ws.Dispose()
            } catch { Err 'G Hub' $_.Exception.Message }
            # --- Corsair iCUE SDK
            try {
                $r = [DeckNative]::IcueBatteries($icueDll)
                if ($r -eq 'WAIT' -and $fast -eq 0) { $fast = 6 }
                if ($r -like 'ERR:*') { Err 'iCUE' $r.Substring(4) }
                elseif ($r -ne 'WAIT') {
                    $lastErr['iCUE'] = ''
                    $dg = [DeckNative]::CueDiag; if ($dg -and $dg -ne $lastErr['iCUEdiag']) { $lastErr['iCUEdiag'] = $dg; Note "Akku iCUE: $dg" }
                    foreach ($e in ($r -split ';')) { if (-not $e) { continue }; $f = $e -split '\|'; [void]$list.Add([ordered]@{ src = 'corsair'; kind = $f[0]; name = $f[1]; pct = [int]$f[2]; charging = $false }) }
                }
            } catch { Err 'iCUE' $_.Exception.Message }
            # --- SteelSeries GG: lokale Engine-API (Adresse aus coreProps.json); https mit selbst signiertem Zertifikat nur fuer 127.0.0.1
            try {
                $cps = @("$env:ProgramData\SteelSeries\GG\apps\engine\coreProps.json", "$env:ProgramData\SteelSeries\SteelSeries Engine 3\coreProps.json") | Where-Object { Test-Path $_ }
                $bases = @()
                foreach ($cpf in $cps) { try { $props = Get-Content $cpf -Raw | ConvertFrom-Json; foreach ($k in 'encryptedAddress', 'address') { $a = [string]$props.$k; if ($a -match '^(127\.0\.0\.1|localhost):\d+$') { $bases += $(if ($k -eq 'encryptedAddress') { "https://$a" } else { "http://$a" }) } } } catch { try { [DeckErr]::L('Z1809', $_) } catch {} } }
                # zusaetzlich: Ports, auf denen der laufende SteelSeries-Engine-Prozess tatsaechlich lauscht
                if (-not $ssProcAt -or ([DateTime]::UtcNow - $ssProcAt).TotalMinutes -gt $(if ($ssProcPorts.Count) { 10 } else { 2 })) {
                    $ssProcAt = [DateTime]::UtcNow; $ssProcPorts = @()
                    $pr = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'SteelSeries' -and $_.ProcessName -match 'Engine|GG' })
                    if ($pr.Count) {
                        $ids = $pr.Id
                        $ssProcPorts = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.OwningProcess -and ($_.LocalAddress -eq '127.0.0.1' -or $_.LocalAddress -eq '::1' -or $_.LocalAddress -eq '0.0.0.0') } | Select-Object -ExpandProperty LocalPort -Unique)
                    }
                    $ssMsg = ("Akku SteelSeries: Prozesse " + $(if ($pr.Count) { ($pr | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ', ' } else { 'keine' }) + "; lauscht auf " + $(if ($ssProcPorts.Count) { $ssProcPorts -join ', ' } else { '-' }))
                    if ($ssMsg -ne $ssLastMsg) { $ssLastMsg = $ssMsg; Note $ssMsg }
                }
                foreach ($pt in $ssProcPorts) { $bases += "https://127.0.0.1:$pt"; $bases += "http://127.0.0.1:$pt" }
                $bases = @($bases | Select-Object -Unique)
                if ($bases.Count) {
                    function SsCall($url, $post) {
                        $rq = [Net.HttpWebRequest]::Create($url); $rq.Timeout = 4000; $rq.ReadWriteTimeout = 4000
                        if ($url -like 'https://127.0.0.1:*' -or $url -like 'https://localhost:*') { $rq.ServerCertificateValidationCallback = [DeckNative]::LoopbackCert }
                        if ($post) { $rq.Method = 'POST'; $rq.ContentType = 'application/json'; $by = [Text.Encoding]::UTF8.GetBytes('{}'); $rq.ContentLength = $by.Length; $st = $rq.GetRequestStream(); $st.Write($by, 0, $by.Length); $st.Close() }
                        $rs = $rq.GetResponse(); $rd = New-Object IO.StreamReader ($rs.GetResponseStream(), [Text.Encoding]::UTF8); $txt = $rd.ReadToEnd(); $rd.Close(); $rs.Close()
                        $txt | ConvertFrom-Json
                    }
                    $base = $null; $dl = $null; $why = ''
                    if ($ssBase) { $bases = @($ssBase) + @($bases | Where-Object { $_ -ne $ssBase }) }   # zuletzt funktionierende Adresse zuerst
                    foreach ($bu in $bases) { try { $r0 = SsCall "$bu/devices" $false; if ($null -ne $r0.devices) { $dl = $r0; $base = $bu; break } } catch { $why = $_.Exception.Message } }
                    if ($base -and $base -ne $ssBase) { $ssBase = $base; Note "Akku SteelSeries: Engine gefunden unter $base" }
                    if (-not $base) { Err 'SteelSeries' ("Engine nicht erreichbar unter " + ($bases -join ', ') + " (" + $why + ")") }
                    else {
                        $lastErr['SteelSeries'] = ''
                        if (-not $seenSsList) { $seenSsList = $true; Note ("Akku SteelSeries: Geraete " + ((@($dl.devices) | ForEach-Object { "$($_.id)=$($_.name)$(if ($_.connected) { '' } else { ' (getrennt)' })" }) -join ', ')) }
                        foreach ($d in @($dl.devices)) {
                            if (-not $d.connected) { continue }
                            try {
                                # Geraetebeschreibung einmal ins Log (welche Funktionen bietet der Dongle?)
                                if (-not $ssDescDone["$($d.id)"]) {
                                    $ssDescDone["$($d.id)"] = $true
                                    try { $desc = SsCall "$base/device/$($d.id)" $false; $dj = ($desc | ConvertTo-Json -Compress -Depth 12); try { [IO.File]::WriteAllText((Join-Path $B.Dir ("user\ss-device-" + $d.id + ".json")), ($desc | ConvertTo-Json -Depth 12)) } catch { try { [DeckErr]::L('Z1845', $_) } catch {} }; $fn = @([regex]::Matches($dj, '"(read_[a-z_]+|get_[a-z_]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
                                        Note ("Akku SteelSeries: " + $d.name + " Funktionen: " + $(if ($fn.Count) { $fn -join ', ' } else { $(if ($dj.Length -gt 600) { $dj.Substring(0, 600) } else { $dj }) })); $ssFns["$($d.id)"] = $fn } catch { Note "Akku SteelSeries: Beschreibung $($d.name): $($_.Exception.Message)" }
                                }
                                $cands = @('read_battery_status') + @($ssFns["$($d.id)"] | Where-Object { $_ -match 'batter|status' -and $_ -ne 'read_battery_status' }) + @('read_battery_level', 'read_device_status', 'read_status', 'get_battery_status')
                                $raw = ''
                                foreach ($fnm in ($cands | Select-Object -Unique)) {
                                    try { $res = SsCall "$base/device/$($d.id)/function/$fnm" $true; $raw = [string]$res.function_data; if ($raw -and $raw -match 'batter|level') { if ($ssFnUsed -ne $fnm) { $ssFnUsed = $fnm; Note "Akku SteelSeries: nutze $fnm" }; break } } catch { try { [DeckErr]::L('Z1851', $_) } catch {} }
                                }
                                if ($raw -and -not $seenSsRaw) { $seenSsRaw = $true; Note ("Akku SteelSeries: Antwort von " + $d.name + ": " + $(if ($raw.Length -gt 400) { $raw.Substring(0, 400) } else { $raw })) }
                                if (-not $raw) { continue }
                                $fd = $raw | ConvertFrom-Json
                                $lv = @(); $chg = $false
                                foreach ($pp in $fd.PSObject.Properties) {
                                    if ($pp.Name -match 'charg' -and $pp.Name -notmatch 'level') { if ([string]$pp.Value -match 'true|charging') { $chg = $true } ; continue }
                                    if ($pp.Name -match 'battery' -and $pp.Name -notmatch 'charger|case|dock|base') { $v = $pp.Value; $n = $(if ($v -is [psobject] -and $null -ne $v.level) { $v.level } else { $v }); if ([string]$n -match '^\d+$' -and [int]$n -le 100) { $lv += [int]$n } }
                                }
                                if ($lv.Count) { [void]$list.Add([ordered]@{ src = 'steelseries'; kind = 'headset'; name = [string]$d.name; pct = ($lv | Measure-Object -Minimum).Minimum; charging = $chg }) }
                            } catch { if (-not $ssFnErr) { $ssFnErr = $true; Note "Akku SteelSeries: $($d.name): $($_.Exception.Message)" } }
                        }
                    }
                } else { Err 'SteelSeries' 'GG-Engine nicht gefunden' }
            } catch { Err 'SteelSeries' $_.Exception.Message }
            # Quelle diesmal ohne Werte -> letzte Werte bis 5 min weiterzeigen (kurze Aussetzer der Herstellersoftware)
            $now = [DateTime]::UtcNow
            foreach ($srcName in 'logitech', 'corsair', 'steelseries') {
                $cur = @($list | Where-Object { $_.src -eq $srcName })
                if ($cur.Count) { $cache[$srcName] = @{ At = $now; Items = $cur } }
                elseif ($cache[$srcName] -and ($now - $cache[$srcName].At).TotalMinutes -lt 5) { foreach ($x in $cache[$srcName].Items) { [void]$list.Add($x) } }
            }
            $B.Out = (ConvertTo-Json -InputObject @($list) -Compress -Depth 4); $B.Stamp++
            $wait = $(if ($fast -gt 0) { $fast--; 8 } else { 60 })
            for ($i = 0; $i -lt $wait -and -not $B.Stop; $i++) { Start-Sleep -Seconds 1 }
        }
    }.ToString())
    [void]$dbps.AddArgument($script:DevBat).AddArgument((Join-Path $script:Root 'iCUESDK.x64_2019.dll'))
    [void]$dbps.BeginInvoke()
    $script:DevBatStamp = 0
    function Poll-DevBat {
        while ($script:DevBat.Log.Count) { $l = $script:DevBat.Log[0]; $script:DevBat.Log.RemoveAt(0); Log $l }
        if ($script:DevBat.Stamp -eq $script:DevBatStamp) { return }
        $script:DevBatStamp = $script:DevBat.Stamp
        if (-not $script:DevBat.Out) { return }
        try { $arr = @(ConvertFrom-Json $script:DevBat.Out | ForEach-Object { $_ }) } catch { return }
        Send ([ordered]@{ type = 'devbat'; devices = @($arr) })
        $s = (@($arr) | ForEach-Object { "$($_.name) $($_.pct) %" }) -join ', '
        if ($s -ne $script:LastDevBatLog) { $script:LastDevBatLog = $s; Log "Geraete-Akkus: $(if ($s) { $s } else { 'keine' })" }
    }

    # ------------------------------------------------------------ Kalender: iCloud-Abo-Links (ICS) abrufen; Links nur in user\calendar.json, nie ins Log oder in die Oberflaeche
    $script:CalFile = Join-Path $script:UserDir 'calendar.json'
    $script:CalUrls = @(); try { if (Test-Path $script:CalFile) { $script:CalUrls = @((Get-Content $script:CalFile -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { [string]$_ } | Where-Object { $_ }) } } catch { Log "Kalender: calendar.json nicht lesbar" }
    $script:Cal = [hashtable]::Synchronized(@{ Busy = $false; Done = $false; Texts = @(); Errs = @(); Err = ''; At = ''; N = 0; Ok = $false; Again = $false })
    $script:CalPs = $null
    function Send-Cal {
        Send ([ordered]@{ type = 'cal'; set = ($script:CalUrls.Count -gt 0); count = $script:CalUrls.Count; ok = [bool]$script:Cal.Ok; err = [string]$script:Cal.Err; n = [int]$script:Cal.N; at = [string]$script:Cal.At; texts = @($script:Cal.Texts); errs = @($script:Cal.Errs) })
    }
    # ---------- Steam-Freunde (Web-API, Schluessel lokal in deck.json) ----------
    $script:Fr = [hashtable]::Synchronized(@{ Busy = $false; Done = $false; List = $null; Err = ''; At = '' })
    $script:FrLastStart = [datetime]::MinValue; $script:FrLastMsg = ''
    function Get-SteamId64 {
        if (-not $script:SteamRoot) { return $null }
        $f = Join-Path $script:SteamRoot 'config\loginusers.vdf'; if (-not (Test-Path $f)) { return $null }
        $tx = [IO.File]::ReadAllText($f); $best = $null
        foreach ($m in [regex]::Matches($tx, '"(7656\d{13})"\s*\{([^{}]*)\}')) { if (-not $best) { $best = $m.Groups[1].Value }; if ($m.Groups[2].Value -match '"MostRecent"\s+"1"') { $best = $m.Groups[1].Value } }
        $best
    }
    # Online-Verlauf heute: je Freund 96 Viertelstunden ('0' offline, '1' online, '2' im Spiel), ueberlebt Neustarts per Datei
    $script:FrHist = @{}; $script:FrHistDay = ''
    function Update-FrHist {
        $day = (Get-Date).ToString('yyyy-MM-dd'); $f = Join-Path $script:UserDir 'friends-hist.json'
        if ($script:FrHistDay -ne $day) {
            $script:FrHist = @{}; $script:FrHistDay = $day
            try { if (Test-Path $f) { $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json; if ([string]$j.day -eq $day) { foreach ($pp in $j.h.PSObject.Properties) { $script:FrHist[$pp.Name] = [string]$pp.Value } } } } catch { try { [DeckErr]::L('Z1917', $_) } catch {} }
        }
        $now = Get-Date; $slot = [int][math]::Floor(($now.Hour * 60 + $now.Minute) / 15)
        foreach ($p in @($script:Fr.List)) {
            if (-not $p.sid) { continue }
            $v = if ($p.game) { '2' } elseif ($p.st -gt 0) { '1' } else { '0' }
            $h = [string]$script:FrHist[$p.sid]; if ($h.Length -ne 96) { $h = '0' * 96 }
            $ca = $h.ToCharArray(); if ([int][string]$ca[$slot] -lt [int]$v) { $ca[$slot] = [char]$v }; $script:FrHist[$p.sid] = -join $ca
        }
        try { if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }; ([ordered]@{ day = $day; h = $script:FrHist } | ConvertTo-Json -Depth 3 -Compress) | Set-Content -Path $f -Encoding UTF8 } catch { try { [DeckErr]::L('Z1926', $_) } catch {} }
        foreach ($p in @($script:Fr.List)) { if ($p.sid) { $p['hist'] = [string]$script:FrHist[$p.sid] } }
    }
    function Send-Friends {
        $key = [string]$script:Settings['steamKey']
        $msg = if (-not $key) { [ordered]@{ type = 'friends'; state = 'nokey' } } elseif ($script:Fr.Err) { [ordered]@{ type = 'friends'; state = 'err'; err = $script:Fr.Err } } elseif ($null -eq $script:Fr.List) { [ordered]@{ type = 'friends'; state = 'load' } } else { [ordered]@{ type = 'friends'; state = 'ok'; at = $script:Fr.At; list = @($script:Fr.List) } }
        $j = $msg | ConvertTo-Json -Depth 5 -Compress; if ($j -eq $script:FrLastMsg) { return }; $script:FrLastMsg = $j; Send $msg
    }
    function Start-FriendsFetch {
        $key = [string]$script:Settings['steamKey']; if (-not $key -or $script:Fr.Busy) { Send-Friends; return }
        $sid = Get-SteamId64; if (-not $sid) { $script:Fr.Err = 'Steam-Konto nicht gefunden (loginusers.vdf)'; Send-Friends; return }
        $script:Fr.Busy = $true; $script:Fr.Done = $false; $script:FrLastStart = Get-Date
        if ($script:FrPs) { try { $script:FrPs.Dispose() } catch { try { [DeckErr]::L('Z178p', $_) } catch {} } }   # vorigen, laengst fertigen Abruf freigeben (deckos-178)
        $ps = [PowerShell]::Create(); $script:FrPs = $ps
        [void]$ps.AddScript({
            param($F, $Key, $Sid)
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { try { [DeckErr]::L('Z1941', $_) } catch {} }
            try {
                $base = 'https://api.steampowered.com'
                try { $fl = Invoke-RestMethod -Uri "$base/ISteamUser/GetFriendList/v1/?key=$Key&steamid=$Sid&relationship=friend" -TimeoutSec 20 }
                catch { $c = 0; try { $c = [int]$_.Exception.Response.StatusCode } catch { try { [DeckErr]::L('Z1945', $_) } catch {} }; if ($c -eq 401) {
                        # Unterscheiden: Schluessel ok (eigenes Profil lesbar) -> Freundesliste nicht oeffentlich
                        $me = $null; try { $me = Invoke-RestMethod -Uri "$base/ISteamUser/GetPlayerSummaries/v2/?key=$Key&steamids=$Sid" -TimeoutSec 20 } catch { try { [DeckErr]::L('Z1947', $_) } catch {} }
                        $pn = ''; try { $pn = [string]$me.response.players[0].personaname } catch { try { [DeckErr]::L('Z1948', $_) } catch {} }
                        if ($pn) { throw "Schlüssel ok (Konto $pn), aber die Freundesliste ist bei Steam nicht öffentlich" } else { throw 'Schlüssel ungültig oder Steam-Konto nicht gefunden' }
                    } elseif ($c -eq 403) { throw 'Schluessel ungueltig' } else { throw ('Steam nicht erreichbar' + $(if ($c) { " ($c)" } else { '' })) } }
                $ids = @($fl.friendslist.friends | ForEach-Object { [string]$_.steamid })
                $out = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt $ids.Count; $i += 100) {
                    $chunk = ($ids[$i..([math]::Min($i + 99, $ids.Count - 1))]) -join ','
                    $ps2 = Invoke-RestMethod -Uri "$base/ISteamUser/GetPlayerSummaries/v2/?key=$Key&steamids=$chunk" -TimeoutSec 20
                    foreach ($p in $ps2.response.players) { [void]$out.Add([ordered]@{ sid = [string]$p.steamid; n = [string]$p.personaname; av = [string]$p.avatarmedium; avf = [string]$p.avatarfull; st = [int]$p.personastate; game = [string]$p.gameextrainfo; gid = [string]$p.gameid; last = [int64]$p.lastlogoff }) }
                }
                $F.List = @($out); $F.Err = ''; $F.At = (Get-Date).ToString('HH:mm')
            } catch { $F.Err = [string]$_.Exception.Message; if (-not $F.Err) { $F.Err = [string]$_ } }
            $F.Done = $true; $F.Busy = $false
        }.ToString())
        [void]$ps.AddArgument($script:Fr).AddArgument($key).AddArgument($sid)
        [void]$ps.BeginInvoke()
    }
    # ---------- Steam-Wunschliste: Rabatte melden (alle 6 Std.) ----------
    $script:FrPs = $null; $script:WlPs = $null; $script:AchPs = $null
    $script:Wl = [hashtable]::Synchronized(@{ Busy = $false; Done = $false; Deals = $null; Err = '' })
    $script:WlLastStart = (Get-Date).AddHours(-6).AddSeconds(45)   # erster Abruf ca. 45 s nach dem Start
    function Start-WishlistFetch {
        $key = [string]$script:Settings['steamKey']; $sid = Get-SteamId64; if (-not $key -or -not $sid -or $script:Wl.Busy) { return }
        $script:Wl.Busy = $true; $script:Wl.Done = $false; $script:WlLastStart = Get-Date
        if ($script:WlPs) { try { $script:WlPs.Dispose() } catch { try { [DeckErr]::L('Z178p', $_) } catch {} } }   # vorigen, laengst fertigen Abruf freigeben (deckos-178)
        $ps = [PowerShell]::Create(); $script:WlPs = $ps
        [void]$ps.AddScript({
            param($W, $Key, $Sid)
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { try { [DeckErr]::L('Z1974', $_) } catch {} }
            try {
                $wl = Invoke-RestMethod -Uri "https://api.steampowered.com/IWishlistService/GetWishlist/v1/?key=$Key&steamid=$Sid" -TimeoutSec 25
                $ids = @($wl.response.items | ForEach-Object { [string]$_.appid } | Where-Object { $_ })
                $deals = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt $ids.Count; $i += 40) {
                    $chunk = $ids[$i..([math]::Min($i + 39, $ids.Count - 1))]
                    $r = Invoke-RestMethod -Uri ("https://store.steampowered.com/api/appdetails?appids=" + ($chunk -join ',') + "&cc=de&l=german&filters=price_overview") -TimeoutSec 25
                    foreach ($id in $chunk) { $e = $r.$id; if ($e -and $e.success -and $e.data.price_overview -and [int]$e.data.price_overview.discount_percent -gt 0) { [void]$deals.Add([ordered]@{ appid = $id; pct = [int]$e.data.price_overview.discount_percent; now = [string]$e.data.price_overview.final_formatted; was = [string]$e.data.price_overview.initial_formatted; name = '' }) } }
                    Start-Sleep -Milliseconds 600
                }
                foreach ($d in ($deals | Select-Object -First 15)) { try { $r2 = Invoke-RestMethod -Uri ("https://store.steampowered.com/api/appdetails?appids=" + $d.appid + "&cc=de&l=german") -TimeoutSec 20; $d.name = [string]$r2.($d.appid).data.name } catch { try { [DeckErr]::L('Z1985', $_) } catch {} }; Start-Sleep -Milliseconds 400 }
                $W.Deals = @($deals); $W.Err = ''
            } catch { $c = 0; try { $c = [int]$_.Exception.Response.StatusCode } catch { try { [DeckErr]::L('Z1987', $_) } catch {} }; $W.Err = 'Wunschliste nicht abrufbar' + $(if ($c) { " ($c)" } else { '' }) }
            $W.Done = $true; $W.Busy = $false
        }.ToString())
        [void]$ps.AddArgument($script:Wl).AddArgument($key).AddArgument($sid)
        [void]$ps.BeginInvoke()
    }
    function Poll-Wishlist {
        if ($script:Wl.Done) {
            $script:Wl.Done = $false
            if ($script:Wl.Err) { Log "Steam-Wunschliste: $($script:Wl.Err)" }
            else {
                $f = Join-Path $script:UserDir 'wishlist-seen.json'; $seen = @{}
                try { if (Test-Path $f) { $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($pp in $j.PSObject.Properties) { $seen[$pp.Name] = [int]$pp.Value } } } catch { try { [DeckErr]::L('Z1999', $_) } catch {} }
                $new = @($script:Wl.Deals | Where-Object { $seen[[string]$_.appid] -ne $_.pct })
                $keep = @{}; foreach ($d in $script:Wl.Deals) { $keep[[string]$d.appid] = $d.pct }
                try { ($keep | ConvertTo-Json -Compress) | Set-Content -Path $f -Encoding UTF8 } catch { try { [DeckErr]::L('Z2002', $_) } catch {} }
                Log ("Steam-Wunschliste: {0} Angebote, {1} neu" -f @($script:Wl.Deals).Count, $new.Count)
                Send ([ordered]@{ type = 'wishlist'; deals = @($script:Wl.Deals); fresh = @($new | ForEach-Object { [string]$_.appid }) })
            }
        }
        if ([string]$script:Settings['steamKey'] -and -not $script:Wl.Busy -and ((Get-Date) - $script:WlLastStart).TotalHours -ge 6) { Start-WishlistFetch }
    }
    # ---------- Steam-Erfolge live: waehrend ein Steam-Spiel laeuft, alle 45 s neue Erfolge suchen ----------
    $script:Ach = [hashtable]::Synchronized(@{ Busy = $false; Done = $false; New = $null; Err = ''; Base = @{}; Schema = @{}; Pct = @{}; Total = 0; Got = 0 })
    $script:AchLast = [datetime]::MinValue; $script:AchErrShown = ''
    function Start-AchFetch([string]$app) {
        $key = [string]$script:Settings['steamKey']; $sid = Get-SteamId64; if (-not $key -or -not $sid -or $script:Ach.Busy) { return }
        $script:Ach.Busy = $true; $script:Ach.Done = $false; $script:AchLast = Get-Date
        if ($script:AchPs) { try { $script:AchPs.Dispose() } catch { try { [DeckErr]::L('Z178p', $_) } catch {} } }   # vorigen, laengst fertigen Abruf freigeben (deckos-178)
        $ps = [PowerShell]::Create(); $script:AchPs = $ps
        [void]$ps.AddScript({
            param($A, $Key, $Sid, $App)
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { try { [DeckErr]::L('Z2018', $_) } catch {} }
            $A.New = @()
            try {
                $base = 'https://api.steampowered.com/ISteamUserStats'
                try { $r = Invoke-RestMethod -Uri "$base/GetPlayerAchievements/v1/?key=$Key&steamid=$Sid&appid=$App&l=german" -TimeoutSec 20 }
                catch { $c = 0; try { $c = [int]$_.Exception.Response.StatusCode } catch { try { [DeckErr]::L('Z2023', $_) } catch {} }; if ($c -eq 400) { throw 'Spiel hat keine Steam-Erfolge' } elseif ($c -eq 403) { throw 'Spieldetails im Steam-Profil nicht oeffentlich' } else { throw ('Steam nicht erreichbar' + $(if ($c) { " ($c)" } else { '' })) } }
                $all = @($r.playerstats.achievements); $got = @($all | Where-Object { [int]$_.achieved -eq 1 })
                $A.Total = $all.Count; $A.Got = $got.Count
                $have = @{}; foreach ($x in $got) { $have[[string]$x.apiname] = [int64]$x.unlocktime }
                if (-not $A.Base.ContainsKey($App)) { $A.Base[$App] = $have }   # erster Abruf: nur merken, nichts melden
                else {
                    $old = $A.Base[$App]; $newOnes = @($got | Where-Object { -not $old.ContainsKey([string]$_.apiname) } | Sort-Object { [int64]$_.unlocktime }); $A.Base[$App] = $have
                    if ($newOnes.Count) {
                        if (-not $A.Schema.ContainsKey($App)) {
                            $sc = @{}; try { $s = Invoke-RestMethod -Uri "https://api.steampowered.com/ISteamUserStats/GetSchemaForGame/v2/?key=$Key&appid=$App&l=german" -TimeoutSec 20; foreach ($a in $s.game.availableGameStats.achievements) { $sc[[string]$a.name] = $a } } catch { try { [DeckErr]::L('Z2032', $_) } catch {} }
                            $A.Schema[$App] = $sc
                            $pc = @{}; try { $g = Invoke-RestMethod -Uri "https://api.steampowered.com/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/?gameid=$App" -TimeoutSec 20; foreach ($a in $g.achievementpercentages.achievements) { $pc[[string]$a.name] = [double]$a.percent } } catch { try { [DeckErr]::L('Z2034', $_) } catch {} }
                            $A.Pct[$App] = $pc
                        }
                        $out = New-Object System.Collections.ArrayList
                        foreach ($x in $newOnes) {
                            $sch = $A.Schema[$App][[string]$x.apiname]; $pct = $A.Pct[$App][[string]$x.apiname]
                            [void]$out.Add([ordered]@{ name = $(if ($sch -and $sch.displayName) { [string]$sch.displayName } else { [string]$x.name }); desc = $(if ($sch -and $sch.description) { [string]$sch.description } else { [string]$x.description }); icon = $(if ($sch) { [string]$sch.icon } else { '' }); pct = $(if ($null -ne $pct) { [math]::Round([double]$pct, 1) } else { -1 }) })
                        }
                        $A.New = @($out)
                    }
                }
                $A.Err = ''
            } catch { $A.Err = [string]$_.Exception.Message; if (-not $A.Err) { $A.Err = [string]$_ } }
            $A.Done = $true; $A.Busy = $false
        }.ToString())
        [void]$ps.AddArgument($script:Ach).AddArgument($key).AddArgument($sid).AddArgument($app)
        [void]$ps.BeginInvoke()
    }
    function Poll-Ach {
        if ($script:Ach.Done) {
            $script:Ach.Done = $false
            if ($script:Ach.Err) { if ($script:Ach.Err -ne $script:AchErrShown) { $script:AchErrShown = $script:Ach.Err; Log "Steam-Erfolge: $($script:Ach.Err)" } }
            foreach ($a in @($script:Ach.New)) { Log "Steam-Erfolg: $($a.name)"; Send ([ordered]@{ type = 'achv'; game = [string]$script:RunningName; name = $a.name; desc = $a.desc; icon = $a.icon; pct = $a.pct; got = $script:Ach.Got; total = $script:Ach.Total }) }
        }
        if ([string]$script:Running -like 'steam_*' -and -not $script:Ach.Busy -and ((Get-Date) - $script:AchLast).TotalSeconds -ge 45) { Start-AchFetch ([string]$script:Running).Substring(6) }
    }
    function Poll-Friends {
        if ($script:Fr.Done) { $script:Fr.Done = $false; if ($script:Fr.Err) { Log "Steam-Freunde: $($script:Fr.Err)" } else { try { Update-FrHist } catch { Log "Freunde-Verlauf: $_" } }; Send-Friends }
        Poll-Wishlist
        Poll-Ach
        if ([string]$script:Settings['steamKey'] -and -not $script:Fr.Busy -and ((Get-Date) - $script:FrLastStart).TotalSeconds -ge 60) { Start-FriendsFetch }
    }
    function Start-CalFetch {
        if ($script:Cal.Busy) { $script:Cal.Again = $true; return }
        if ($script:CalUrls.Count -eq 0) { $script:Cal.Texts = @(); $script:Cal.Errs = @(); $script:Cal.Ok = $false; $script:Cal.Err = ''; $script:Cal.N = 0; Send-Cal; return }
        $script:Cal.Busy = $true; $script:Cal.Done = $false
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({
            param($C, $Urls)
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { try { [DeckErr]::L('Z2073', $_) } catch {} }
            $texts = New-Object System.Collections.ArrayList; $errs = New-Object System.Collections.ArrayList; $i = 0
            foreach ($u in $Urls) {
                $i++
                try {
                    $url = ([string]$u) -replace '^webcal://', 'https://'
                    $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 25 -Headers @{ 'User-Agent' = 'GameShelfDeck/1.0' }
                    $ms = New-Object IO.MemoryStream; $r.RawContentStream.Position = 0; $r.RawContentStream.CopyTo($ms)
                    $t = [Text.Encoding]::UTF8.GetString($ms.ToArray())
                    if ($t -notmatch 'BEGIN:VCALENDAR') { [void]$texts.Add(''); [void]$errs.Add("Kalender $i liefert keine Termine") } else { [void]$texts.Add($t); [void]$errs.Add('') }
                } catch {
                    $code = ''; try { $code = [int]$_.Exception.Response.StatusCode } catch { try { [DeckErr]::L('Z2084', $_) } catch {} }
                    [void]$texts.Add(''); [void]$errs.Add("Kalender $i nicht erreichbar" + $(if ($code) { " ($code)" } else { '' }))
                }
            }
            $okN = @($texts | Where-Object { $_ }).Count
            $C.Texts = @($texts); $C.Errs = @($errs); $C.N = $okN; $C.Ok = ($okN -gt 0); $C.Err = (@($errs | Where-Object { $_ }) -join ' · '); $C.At = (Get-Date).ToString('HH:mm')
            $C.Done = $true; $C.Busy = $false
        }.ToString())
        [void]$ps.AddArgument($script:Cal).AddArgument([string[]]$script:CalUrls)
        $script:CalPs = $ps; [void]$ps.BeginInvoke()
    }
    function Poll-Cal {
        if (-not $script:Cal.Done) { return }
        $script:Cal.Done = $false
        try { $script:CalPs.Dispose() } catch { try { [DeckErr]::L('Z2098', $_) } catch {} }; $script:CalPs = $null
        Log ("Kalender: {0} von {1} abgerufen{2}" -f $script:Cal.N, $script:CalUrls.Count, $(if ($script:Cal.Err) { " – $($script:Cal.Err)" } else { '' }))
        Send-Cal
        if ($script:Cal.Again) { $script:Cal.Again = $false; Start-CalFetch }
    }
    function Save-CalUrls {
        try { if (-not (Test-Path $script:UserDir)) { New-Item -ItemType Directory -Path $script:UserDir | Out-Null }; ConvertTo-Json -InputObject @($script:CalUrls) | Set-Content -Path $script:CalFile -Encoding UTF8 } catch { Log "Kalender: speichern fehlgeschlagen" }
    }

    # ------------------------------------------------------------ Game-safe Touch (an "Nur Touch" gekoppelt): Fokus bleibt beim Spiel, Mauszeiger springt zurueck
    $script:Typing = $false; $script:LastGuard = 0
    $guardTimer = New-Object Windows.Threading.DispatcherTimer ([Windows.Threading.DispatcherPriority]::Input)
    $guardTimer.Interval = [TimeSpan]::FromMilliseconds(16)
    $guardTimer.add_Tick({
        if (-not $script:Ready -or $script:Hwnd -eq [IntPtr]::Zero) { return }
        $armed = ([bool]$script:Settings.touchOnly -and -not $script:Typing -and -not $script:Couch)
        try {
            if ([bool]$script:Settings.touchOnly -and -not $script:Couch) { [DeckNative]::CursorSample($script:Hwnd) }
            $g = [DeckNative]::FocusGuard($script:Hwnd, $armed)
            if ($g -eq 1 -or $g -eq 2) { Log ("Game-safe Touch: {0}" -f $(if ($g -eq 1) { 'an (Fokus bleibt beim Spiel/Vordergrund)' } else { 'aus' })) }
            elseif ($g -eq 3 -and $script:LastGuard -ne 3) { Log 'Game-safe Touch: Fokus an das vorherige Fenster zurueckgegeben' }
            if ($g -ne 0) { $script:LastGuard = $g }
        } catch { if (-not $script:GuardErr) { $script:GuardErr = $true; Log "Game-safe Touch: $_" } }
    })
    $guardTimer.Start()

    $script:LastBat = ''
    function Send-FpsTarget([switch]$Force) {
        # Ziel der FPS-Anzeige (15.11.): NVIDIA-Bildratenbegrenzung (Spielprofil, sonst global) > Wiederholrate des Hauptbildschirms > 240
        $hz = -1; try { $hz = [DeckNative]::PrimaryHz() } catch { try { [DeckErr]::L('Z3101', $_) } catch {} }
        $exe = ''
        if ($script:Running) { try { $f3 = 0.0; $rp3 = [DeckNative]::RtssTop([ref]$f3); if ($rp3 -gt 0) { $exe = [Diagnostics.Process]::GetProcessById($rp3).ProcessName + '.exe' } } catch { } }
        $cap = -1; try { $cap = [DeckNative]::NvFrameCap($exe) } catch { try { [DeckErr]::L('Z3102', $_) } catch {} }
        $t = 240; $src = 'fallback'
        if ($cap -gt 0) { $t = $cap; $src = 'nvidia' } elseif ($hz -gt 0) { $t = $hz; $src = 'monitor' }
        $msg = [ordered]@{ type = 'fpstarget'; target = [int]$t; src = $src; hz = [int]$hz; cap = [int]$cap }
        $k = ($msg | ConvertTo-Json -Compress); if (-not $Force -and $k -eq $script:LastFpsT) { return }
        $script:LastFpsT = $k; Send $msg
        $inf = ''; try { $inf = [DeckNative]::NvCapInfo } catch { }
        Log ("FPS-Ziel: {0} ({1}; Hauptbildschirm {2} Hz; NVIDIA-Begrenzung {3} [{4}])" -f $t, $src, $hz, $cap, $inf)
    }
    function Send-PadBat {
        # Controller-Steckplatz frisch ermitteln (auch waehrend eines Spiels); verbunden = sichtbar, auch wenn der Akkustand nicht lesbar ist
        $on = $false; $lv = -1
        try { if ([DeckNative]::PadButtons() -ge 0) { $on = $true; $lv = [DeckNative]::PadBattery() } } catch { if (-not $script:BatErr) { $script:BatErr = $true; Log "Controller-Akku: $_" } }
        $msg = [ordered]@{ type = 'padbat'; on = $on; wired = ($lv -eq 200); level = $(if ($lv -ge 100 -and $lv -lt 200) { $lv - 100 } else { -1 }); pct = [int]$script:PadBat.Pct }
        $k = ($msg | ConvertTo-Json -Compress); if ($k -eq $script:LastBat) { return }
        $script:LastBat = $k; Send $msg
        $raw = ''; try { $raw = [DeckNative]::PadBatteryRaw } catch { try { [DeckErr]::L('Z2132', $_) } catch {} }
        Log ("Controller-Akku: {0} ({1}; Bluetooth-Prozent {2})" -f $(if (-not $msg.on) { 'kein Controller' } elseif ($msg.wired) { 'Kabel' } elseif ($msg.pct -ge 0) { "$($msg.pct) %" } elseif ($msg.level -ge 0) { "Stufe $($msg.level)" } else { 'verbunden, Akkustand unbekannt' }), $raw, $msg.pct)
    }

    # ------------------------------------------------------------ DeckOS: WhatsApp-Hinweise (nur Anzahl neuer Benachrichtigungen, kein Absender, kein Text)
    $script:WaAckFile = Join-Path $script:UserDir 'whatsapp.ack'
    $script:WaAck = [long]0; try { if (Test-Path $script:WaAckFile) { $script:WaAck = [long]((Get-Content $script:WaAckFile -Raw).Trim()) } } catch { try { [DeckErr]::L('Z2138', $_) } catch {} }
    $script:WaMax = [long]0; $script:WaApp = ''; $script:WaLast = -1; $script:WaErr = ''
    function Poll-WhatsApp {
        $r = ''; try { $r = [DeckNative]::WaPoll($script:WaAck) } catch { $r = "ERR:$_" }
        if ($r -like 'ERR:*') { if ($r -ne $script:WaErr) { $script:WaErr = $r; Log "WhatsApp-Hinweise: $r" }; return }
        $script:WaErr = ''
        $p = $r -split '\|'; $n = [int]$p[0]; $script:WaMax = [long]$p[1]; if ($p[2]) { $script:WaApp = $p[2] }
        if ($n -ne $script:WaLast) {
            $grew = ($script:WaLast -ge 0 -and $n -gt $script:WaLast)
            $script:WaLast = $n; Send ([ordered]@{ type = 'wa'; n = $n; ping = $grew })
            Log "WhatsApp-Hinweise: $n neu"
        }
    }
    function Open-WhatsApp {
        if ($script:WaMax -gt $script:WaAck) { $script:WaAck = $script:WaMax; try { Set-Content -Path $script:WaAckFile -Value $script:WaAck -Encoding ASCII } catch { try { [DeckErr]::L('Z2152', $_) } catch {} } }
        $script:WaLast = -1
        try {
            if ($script:WaApp -match '!') { Start-Process explorer.exe ("shell:AppsFolder\" + $script:WaApp) } else { Start-Process 'whatsapp:' }
        } catch { Log "WhatsApp oeffnen: $_" }
        Poll-WhatsApp
    }

    # ------------------------------------------------------------ DeckOS: Claude-Hinweise (nur Anzahl neuer Benachrichtigungen der Claude-App, kein Inhalt)
    $script:ClAckFile = Join-Path $script:UserDir 'claude.ack'
    $script:ClAck = [long]0; try { if (Test-Path $script:ClAckFile) { $script:ClAck = [long]((Get-Content $script:ClAckFile -Raw).Trim()) } } catch { try { [DeckErr]::L('Z2162', $_) } catch {} }
    $script:ClMax = [long]0; $script:ClApp = ''; $script:ClLast = -1; $script:ClErr = ''
    function Poll-Claude {
        $r = ''; try { $r = [DeckNative]::AppPoll('Claude', $script:ClAck) } catch { $r = "ERR:$_" }
        if ($r -like 'ERR:*') { if ($r -ne $script:ClErr) { $script:ClErr = $r; Log "Claude-Hinweise: $r" }; return }
        $script:ClErr = ''
        $p = $r -split '\|'; $n = [int]$p[0]; $script:ClMax = [long]$p[1]; if ($p[2]) { $script:ClApp = $p[2] }
        if ($n -ne $script:ClLast) {
            $grew = ($script:ClLast -ge 0 -and $n -gt $script:ClLast)
            $script:ClLast = $n; Send ([ordered]@{ type = 'cl'; n = $n; ping = $grew })
            Log "Claude-Hinweise: $n neu"
        }
    }
    # Kontrollzentrum "Loeschen": WhatsApp- und Claude-Hinweise als gelesen markieren, ohne die Apps zu oeffnen (02.11.)
    function Clear-Notifs {
        if ($script:WaMax -gt $script:WaAck) { $script:WaAck = $script:WaMax; try { Set-Content -Path $script:WaAckFile -Value $script:WaAck -Encoding ASCII } catch { Log "Hinweise loeschen (WhatsApp): $_" } }
        if ($script:ClMax -gt $script:ClAck) { $script:ClAck = $script:ClMax; try { Set-Content -Path $script:ClAckFile -Value $script:ClAck -Encoding ASCII } catch { Log "Hinweise loeschen (Claude): $_" } }
        $script:WaLast = -1; $script:ClLast = -1
        Poll-WhatsApp; Poll-Claude
    }
    function Open-Claude {
        if ($script:ClMax -gt $script:ClAck) { $script:ClAck = $script:ClMax; try { Set-Content -Path $script:ClAckFile -Value $script:ClAck -Encoding ASCII } catch { try { [DeckErr]::L('Z2176', $_) } catch {} } }
        $script:ClLast = -1
        try {
            $exe = $null; foreach ($c in @((Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'), (Join-Path $env:ProgramFiles 'Claude\Claude.exe'))) { if ($c -and (Test-Path $c)) { $exe = $c; break } }
            if ($exe) { Start-Process -FilePath $exe }
            elseif ($sa = (Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Claude' } | Select-Object -First 1)) { Start-Process explorer.exe ("shell:AppsFolder\" + $sa.AppID) }
            elseif ($script:ClApp) { Start-Process explorer.exe ("shell:AppsFolder\" + $script:ClApp) }
            else { Start-Process 'claude:' }
        } catch { Log "Claude oeffnen: $_" }
        Poll-Claude
    }

    $app = New-Object Windows.Application
    $app.ShutdownMode = 'OnMainWindowClose'
    [void]$app.Run($win)
} catch {
    Log "Abbruch: $_ | $($_.InvocationInfo.PositionMessage)"
} finally {
    try { $script:Mutex.ReleaseMutex() } catch { try { [DeckErr]::L('Z2194', $_) } catch {} }
}
