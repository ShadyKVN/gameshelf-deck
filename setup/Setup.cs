// GameShelf Deck - Setup mit Einrichtungsassistent (deckos-187, OTA: Setup.exe /update <Ordner>)
// Baut ohne Admin-Rechte pro Benutzer nach %LOCALAPPDATA%\Programs\GameShelf Deck.
// Programmdateien kommen aus payload.zip (feste Dateiliste); Einstellungen und Daten werden nie ueberschrieben.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

static class App
{
    public const string Name = "GameShelf Deck";
    public const string Version = "deckos-187";
    public const string UninstKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\GameShelfDeck";
    public const string UrlWebView2 = "https://developer.microsoft.com/microsoft-edge/webview2/";
    public const string UrlAfterburner = "https://www.msi.com/Landing/afterburner/graphics-cards";
    public const string UrlSgdb = "https://www.steamgriddb.com/profile/preferences/api";
    public const string UrlSteamKey = "https://steamcommunity.com/dev/apikey";
    public const string UrlDiscord = "https://discord.com/download";
    public const string UrlSteam = "https://store.steampowered.com/about/";
    public static bool IsWindows { get { return Environment.OSVersion.Platform == PlatformID.Win32NT; } }

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    static int Main(string[] args)
    {
        try { if (IsWindows) SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        string a0 = args.Length > 0 ? args[0].ToLowerInvariant() : "";
        if (a0 == "/selftest") return SelfTest.Run(args[1]);
        if (a0 == "/shots") return SelfTest.Shots(args[1]);
        if (a0 == "/uninstall" || a0 == "-uninstall") { Installer.UninstallInteractive(); return 0; }
        if (a0 == "/update" && args.Length > 1) return SilentUpdate.Run(args[1]);
        bool created;
        using (var m = new Mutex(true, "GameShelfDeck_Setup_Running", out created))
        {
            if (!created) { MessageBox.Show("Das Setup läuft bereits.", Name); return 1; }
            Application.Run(new Wizard());
        }
        return 0;
    }

    public static string DefaultDir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", Name); } }

    public static string ExistingDir()
    {
        try
        {
            using (var k = Registry.CurrentUser.OpenSubKey(UninstKey))
            {
                if (k != null)
                {
                    string d = k.GetValue("InstallLocation") as string;
                    if (!string.IsNullOrEmpty(d) && File.Exists(Path.Combine(d, "Deck.ps1"))) return d;
                }
            }
        }
        catch { }
        if (File.Exists(Path.Combine(DefaultDir, "Deck.ps1"))) return DefaultDir;
        return null;
    }

    public static void Open(string url) { try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch (Exception e) { MessageBox.Show("Der Link ließ sich nicht öffnen:\n" + url + "\n\n" + e.Message, Name); } }
}

// Alles, was der Assistent abfragt
class Cfg
{
    public string Dir = App.DefaultDir;
    public bool Update;            // vorhandene Installation: nur Programmdateien tauschen
    public bool Reconfigure = true; // Einstellungen aus dem Assistenten schreiben
    public string Monitor = "";    // "" = automatisch
    public bool DiscordSplit = true;
    public string DiscordSide = "b"; // a = links, b = rechts
    public string SgdbKey = "";
    public string SteamKey = "";
    public string EdenExe = "", EdenRoms = "";
    public string PdnExe = "", PdnGame = "", PdnName = "";
    public string FchExe = "", FchGame = "", FchName = "";
    public bool Autostart = true, Hotkeys = true, DesktopLink = false, StartNow = true;
}

static class Json
{
    public static Dictionary<string, object> Load(string file)
    {
        try
        {
            if (!File.Exists(file)) return null;
            string t = File.ReadAllText(file, Encoding.UTF8).Trim('\uFEFF', ' ', '\r', '\n', '\t');
            if (t.Length == 0) return null;
            var o = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(t);
            return o;
        }
        catch { return null; }
    }
    public static void Save(string file, Dictionary<string, object> d)
    {
        string tmp = file + ".tmp";
        File.WriteAllText(tmp, new JavaScriptSerializer().Serialize(d), new UTF8Encoding(true));
        if (File.Exists(file)) { File.Copy(file, file + ".bak", true); File.Delete(file); }
        File.Move(tmp, file);
    }
    public static string Str(Dictionary<string, object> d, string k) { object v; return d != null && d.TryGetValue(k, out v) && v != null ? Convert.ToString(v) : ""; }
    public static bool Bool(Dictionary<string, object> d, string k, bool def) { object v; if (d != null && d.TryGetValue(k, out v) && v is bool) return (bool)v; return def; }
}

static class Checks
{
    public class Item { public string Title, Detail, Url, LinkText; public int State; /* 0 ok, 1 Hinweis, 2 fehlt (Pflicht) */ }

    static string Reg(RegistryHive hive, RegistryView view, string key, string name)
    {
        try { using (var b = RegistryKey.OpenBaseKey(hive, view)) using (var k = b.OpenSubKey(key)) { return k == null ? null : Convert.ToString(k.GetValue(name)); } } catch { return null; }
    }
    static string PF86 { get { return Environment.GetEnvironmentVariable("ProgramFiles(x86)") ?? Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles); } }

    public static bool WebView2()
    {
        const string id = @"Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        foreach (var v in new[] { Reg(RegistryHive.LocalMachine, RegistryView.Registry32, @"SOFTWARE\" + id, "pv"), Reg(RegistryHive.LocalMachine, RegistryView.Registry64, @"SOFTWARE\" + id, "pv"), Reg(RegistryHive.CurrentUser, RegistryView.Default, @"Software\" + id, "pv") })
            if (!string.IsNullOrEmpty(v) && v != "0.0.0.0") return true;
        try { return Directory.Exists(Path.Combine(PF86, @"Microsoft\EdgeWebView\Application")); } catch { return false; }
    }
    public static bool Steam() { return !string.IsNullOrEmpty(Reg(RegistryHive.CurrentUser, RegistryView.Default, @"Software\Valve\Steam", "SteamPath")); }
    public static bool Afterburner()
    {
        string p = Reg(RegistryHive.LocalMachine, RegistryView.Registry32, @"SOFTWARE\MSI\Afterburner", "InstallPath");
        return (!string.IsNullOrEmpty(p) && File.Exists(p)) || File.Exists(Path.Combine(PF86, @"MSI Afterburner\MSIAfterburner.exe"));
    }
    public static bool Rtss()
    {
        string d = Reg(RegistryHive.LocalMachine, RegistryView.Registry32, @"SOFTWARE\Unwinder\RTSS", "InstallDir");
        return (!string.IsNullOrEmpty(d) && Directory.Exists(d)) || File.Exists(Path.Combine(PF86, @"RivaTuner Statistics Server\RTSS.exe"));
    }
    public static bool Discord() { try { return Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Discord")); } catch { return false; } }
    public static bool PowerShell() { try { return File.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe")); } catch { return false; } }

    public static List<Item> All()
    {
        var l = new List<Item>();
        bool win = Environment.OSVersion.Version.Major >= 10 && Environment.Is64BitOperatingSystem;
        l.Add(new Item { Title = "Windows 10 oder 11 (64 Bit)", State = win ? 0 : 2, Detail = win ? "Vorhanden." : "Das Deck braucht Windows 10 oder 11 in der 64-Bit-Ausgabe." });
        bool ps = PowerShell();
        l.Add(new Item { Title = "Windows PowerShell 5.1", State = ps ? 0 : 2, Detail = ps ? "Vorhanden." : "Gehört zu Windows; ohne sie startet das Deck nicht." });
        bool wv = WebView2();
        l.Add(new Item { Title = "Microsoft Edge WebView2-Laufzeit (Pflicht)", State = wv ? 0 : 2, Detail = wv ? "Vorhanden." : "Zeichnet die Oberfläche des Decks. Bitte den „Evergreen Bootstrapper“ laden und installieren.", Url = wv ? null : App.UrlWebView2, LinkText = "Zur Microsoft-Seite" });
        int n = Screen.AllScreens.Length;
        l.Add(new Item { Title = "Zweiter Bildschirm", State = n >= 2 ? 0 : 1, Detail = n >= 2 ? n + " Bildschirme erkannt." : "Nur ein Bildschirm erkannt. Das Deck zeigt sich erst, wenn ein zweiter Bildschirm (quer) angeschlossen ist." });
        bool st = Steam();
        l.Add(new Item { Title = "Steam (empfohlen)", State = st ? 0 : 1, Detail = st ? "Gefunden. Spiele, Spielzeiten und Cover kommen automatisch." : "Nicht gefunden. Epic, Xbox, GOG, Ubisoft, EA und Battle.net erkennt das Deck ebenfalls.", Url = st ? null : App.UrlSteam, LinkText = "Steam laden" });
        bool ab = Afterburner(), rt = Rtss();
        l.Add(new Item { Title = "MSI Afterburner + RivaTuner (für den Performance-Tab)", State = ab && rt ? 0 : 1, Detail = ab && rt ? "Gefunden. Beide müssen laufen, damit FPS, Temperaturen und Auslastung erscheinen." : (ab ? "Afterburner gefunden, RivaTuner fehlt (im Afterburner-Setup mit ankreuzen)." : "Nicht gefunden. Ohne beide bleibt der Performance-Tab leer. Nur von msi.com laden, RivaTuner ankreuzen."), Url = ab && rt ? null : App.UrlAfterburner, LinkText = "Zur MSI-Seite" });
        bool dc = Discord();
        l.Add(new Item { Title = "Discord (optional)", State = dc ? 0 : 1, Detail = dc ? "Gefunden. Kann neben dem Deck angedockt werden." : "Nicht gefunden. Das Deck nutzt dann die ganze Bildschirmbreite.", Url = dc ? null : App.UrlDiscord, LinkText = "Discord laden" });
        return l;
    }
}

static class Installer
{
    static string StartMenuLink { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), App.Name + ".lnk"); } }
    static string DesktopLink { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), App.Name + ".lnk"); } }
    static string StartupLink { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), App.Name + ".lnk"); } }
    static string Conhost { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "conhost.exe"); } }
    static string DeckArgs(string dir) { return "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File \"" + Path.Combine(dir, "Deck.ps1") + "\""; }

    public static Stream Payload() { return Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"); }

    public static List<string> PayloadFiles()
    {
        var l = new List<string>();
        using (var s = Payload()) using (var z = new ZipArchive(s, ZipArchiveMode.Read))
            foreach (var e in z.Entries) if (!e.FullName.EndsWith("/")) l.Add(e.FullName.Replace('/', '\\'));
        return l;
    }

    public static void StopDeck(Action<string> log)
    {
        try
        {
            EventWaitHandle ev;
            if (!EventWaitHandle.TryOpenExisting("GameShelfDeck_Quit", out ev)) return;
            Mutex mx; bool had = Mutex.TryOpenExisting("GameShelfDeck_SingleInstance", out mx);
            if (!had) { ev.Dispose(); return; }
            log("Laufendes Deck wird beendet …");
            ev.Set();
            bool got = false;
            try { got = mx.WaitOne(12000); } catch (AbandonedMutexException) { got = true; }
            if (got) { try { mx.ReleaseMutex(); } catch { } }
            try { ev.Reset(); } catch { }
            mx.Dispose(); ev.Dispose();
            Thread.Sleep(600);
        }
        catch (Exception e) { log("Hinweis: laufendes Deck ließ sich nicht prüfen (" + e.Message + ")"); }
    }

    public static void Install(Cfg c, Action<string> log)
    {
        Directory.CreateDirectory(c.Dir);
        if (App.IsWindows) StopDeck(log);

        // 1) Programmdateien (feste Liste aus dem Paket) - Einstellungen und Daten sind nie im Paket
        int n = 0;
        using (var s = Payload()) using (var z = new ZipArchive(s, ZipArchiveMode.Read))
        {
            foreach (var e in z.Entries)
            {
                if (e.FullName.EndsWith("/")) continue;
                string dst = Path.Combine(c.Dir, e.FullName.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(dst));
                for (int tries = 0; ; tries++)
                {
                    try { using (var i = e.Open()) using (var o = File.Create(dst)) i.CopyTo(o); break; }
                    catch (IOException) { if (tries >= 10) throw; Thread.Sleep(500); }
                }
                n++;
            }
        }
        // Die vorab gebaute Hilfs-DLL muss juenger sein als ihr Quelltext, sonst uebersetzt das Deck sie beim Start neu
        // deckos-179: Die Hilfs-DLL wird nicht mehr mitgeliefert; das Deck uebersetzt DeckNative.cs beim ersten Start selbst. Eine alte DLL muss weg.
        try { File.Delete(Path.Combine(c.Dir, "DeckNative1.dll")); } catch { }
        try { File.SetLastWriteTime(Path.Combine(c.Dir, "DeckNative.cs"), DateTime.Now); } catch { }
        log(n + " Programmdateien nach " + c.Dir + " kopiert.");

        // 2) Einstellungen: neu anlegen oder nur die abgefragten Werte aendern
        string deckFile = Path.Combine(c.Dir, "deck.json"), confFile = Path.Combine(c.Dir, "config.json");
        bool fresh = !File.Exists(deckFile);
        if (fresh || c.Reconfigure)
        {
            var d = Json.Load(deckFile);
            if (d == null)
            {
                d = new Dictionary<string, object> {
                    { "form", "reel" }, { "style", "oled" }, { "dtheme", "dark" }, { "mode", "auto" }, { "ui", "os" },
                    { "dcposP", "b" }, { "shareP", 0.5 }, { "shareL", 0.4 }, { "vramGB", 0 },
                    { "modMusic", false }, { "modVoice", false }, { "modMixer", false }, { "modStats", true }, { "hudArt", true }, { "touchOnly", false },
                    { "idleOn", true }, { "idleMin", 5 }, { "idleGlow", "accent" }, { "idleLab", "accent" },
                    { "bg", "clear" }, { "blur", "none" }, { "tint", "high" }, { "tone", "dark" }, { "accentSel", "accent" }, { "flashSel", "accent" },
                    { "clockStyle", "analog" }, { "agendaMode", "stack" }, { "macroCustom", "" }, { "hueIp", "" }, { "hueUser", "" },
                    { "voiceMicKeys", "Ctrl+Shift+F9" }, { "voiceDeafKeys", "Ctrl+Shift+F10" }
                };
            }
            d["monitor"] = c.Monitor; d["discordSplit"] = c.DiscordSplit; d["dcposL"] = c.DiscordSide;
            d["autostart"] = c.Autostart; d["hotkeys"] = c.Hotkeys;
            if (c.SteamKey.Length > 0) d["steamKey"] = c.SteamKey;
            Json.Save(deckFile, d);

            var g = Json.Load(confFile) ?? new Dictionary<string, object>();
            if (c.SgdbKey.Length > 0) g["steamGridDbKey"] = c.SgdbKey; else if (!g.ContainsKey("steamGridDbKey")) g["steamGridDbKey"] = "";
            g["edenExe"] = c.EdenExe; g["edenRoms"] = c.EdenRoms;
            g["pdnExe"] = c.PdnExe; g["pdnGame"] = c.PdnGame; g["pdnName"] = c.PdnName;
            g["fchExe"] = c.FchExe; g["fchGame"] = c.FchGame; g["fchName"] = c.FchName;
            Json.Save(confFile, g);
            log(fresh ? "Einstellungen angelegt." : "Einstellungen aktualisiert (vorige Fassung liegt als .bak daneben).");
        }
        else log("Einstellungen unverändert übernommen.");

        if (!App.IsWindows) return;

        // 3) Setup fuer Deinstallation und spaetere Aenderungen mitkopieren
        string self = Assembly.GetExecutingAssembly().Location, selfDst = Path.Combine(c.Dir, App.Name + " Setup.exe");
        try { if (!string.Equals(Path.GetFullPath(self), Path.GetFullPath(selfDst), StringComparison.OrdinalIgnoreCase)) File.Copy(self, selfDst, true); } catch (Exception e) { log("Hinweis: Setup-Kopie nicht möglich (" + e.Message + ")"); }

        // 4) Verknuepfungen und Eintrag unter "Installierte Apps"
        try
        {
            MakeLink(StartMenuLink, Conhost, DeckArgs(c.Dir), c.Dir, Path.Combine(c.Dir, "deck.ico"), App.Name);
            if (c.DesktopLink) MakeLink(DesktopLink, Conhost, DeckArgs(c.Dir), c.Dir, Path.Combine(c.Dir, "deck.ico"), App.Name);
            if (!c.Autostart && File.Exists(StartupLink)) File.Delete(StartupLink);
            log("Startmenü-Eintrag angelegt.");
        }
        catch (Exception e) { log("Hinweis: Verknüpfung nicht angelegt (" + e.Message + ")"); }
        try
        {
            using (var k = Registry.CurrentUser.CreateSubKey(App.UninstKey))
            {
                k.SetValue("DisplayName", App.Name); k.SetValue("DisplayVersion", App.Version); k.SetValue("Publisher", "GameShelf Deck");
                k.SetValue("InstallLocation", c.Dir); k.SetValue("DisplayIcon", Path.Combine(c.Dir, "deck.ico"));
                k.SetValue("UninstallString", "\"" + selfDst + "\" /uninstall");
                k.SetValue("NoModify", 1, RegistryValueKind.DWord); k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                k.SetValue("EstimatedSize", 3000, RegistryValueKind.DWord);
            }
        }
        catch (Exception e) { log("Hinweis: Eintrag unter „Installierte Apps“ nicht angelegt (" + e.Message + ")"); }
    }

    public static void StartDeck(string dir)
    {
        Process.Start(new ProcessStartInfo(Conhost, DeckArgs(dir)) { WorkingDirectory = dir, UseShellExecute = false, CreateNoWindow = true });
    }

    static void MakeLink(string lnk, string target, string args, string workDir, string icon, string desc)
    {
        Type t = Type.GetTypeFromProgID("WScript.Shell");
        object sh = Activator.CreateInstance(t);
        object l = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { lnk });
        Type lt = l.GetType();
        Action<string, object> set = (n, v) => lt.InvokeMember(n, BindingFlags.SetProperty, null, l, new object[] { v });
        set("TargetPath", target); set("Arguments", args); set("WorkingDirectory", workDir); set("IconLocation", icon); set("Description", desc); set("WindowStyle", 7);
        lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, l, null);
        Marshal.FinalReleaseComObject(l); Marshal.FinalReleaseComObject(sh);
    }

    public static void UninstallInteractive()
    {
        string dir = App.ExistingDir();
        if (dir == null) { MessageBox.Show(App.Name + " ist auf diesem PC nicht installiert.", App.Name); return; }
        if (MessageBox.Show(App.Name + " von diesem PC entfernen?\n\n" + dir, App.Name + " entfernen", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        bool dev = Directory.Exists(Path.Combine(dir, "Sicherung")) || Directory.Exists(Path.Combine(dir, "Entwurf"));
        bool data = false;
        if (dev) MessageBox.Show("In diesem Ordner liegen Sicherungen oder Entwürfe. Es werden nur die Programmdateien entfernt; Einstellungen, Bilder und Sicherungen bleiben liegen.", App.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
        else data = MessageBox.Show("Auch Einstellungen, Schlüssel, Cover und Protokolle löschen?\n\n„Nein“ behält sie für eine spätere Neuinstallation.", App.Name + " entfernen", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) == DialogResult.Yes;
        var sb = new StringBuilder();
        StopDeck(s => sb.AppendLine(s));
        foreach (string f in PayloadFiles()) Try(() => File.Delete(Path.Combine(dir, f)));
        Try(() => Directory.Delete(Path.Combine(dir, "lib"), false));
        if (data)
        {
            foreach (string f in new[] { "deck.json", "deck.json.bak", "deck.json.tmp", "config.json", "config.json.bak", "cache.json", "deck.log", "deck.log.old", "deck-fehler.log", "deck-fehler.log.old" }) Try(() => File.Delete(Path.Combine(dir, f)));
            foreach (string d in new[] { "covers", "user" }) Try(() => Directory.Delete(Path.Combine(dir, d), true));
            Try(() => Directory.Delete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"GameShelfDeck\WebView2"), true));
        }
        foreach (string l in new[] { StartMenuLink, DesktopLink, StartupLink }) Try(() => File.Delete(l));
        Try(() => Registry.CurrentUser.DeleteSubKeyTree(App.UninstKey, false));
        // Das Setup kann sich nicht selbst loeschen, solange es laeuft: kurz warten, dann aufraeumen
        string self = Assembly.GetExecutingAssembly().Location;
        if (self.StartsWith(dir, StringComparison.OrdinalIgnoreCase))
            Try(() => Process.Start(new ProcessStartInfo("cmd.exe", "/c ping -n 3 127.0.0.1 >nul & del \"" + self + "\" & rmdir \"" + dir + "\"") { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden }));
        MessageBox.Show(App.Name + " wurde entfernt." + (data || dev ? "" : "\n\nEinstellungen und Bilder liegen weiter in:\n" + dir), App.Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
    }
    static void Try(Action a) { try { a(); } catch { } }
}

static class Th
{
    public static readonly Color Bg = Color.FromArgb(15, 17, 21), Side = Color.FromArgb(10, 11, 15), Card = Color.FromArgb(23, 26, 33), CardHi = Color.FromArgb(30, 34, 43), Line = Color.FromArgb(42, 46, 56),
        Text = Color.FromArgb(242, 244, 248), Soft = Color.FromArgb(154, 163, 178), Dim = Color.FromArgb(96, 104, 118), Accent = Color.FromArgb(76, 141, 255), AccentHi = Color.FromArgb(110, 164, 255),
        Ok = Color.FromArgb(63, 191, 114), Warn = Color.FromArgb(245, 165, 36), Bad = Color.FromArgb(229, 72, 77);
    public static Font F(float size, FontStyle st = FontStyle.Regular) { return new Font("Segoe UI", size, st); }
    public static Font FS(float size) { try { var f = new Font("Segoe UI Semibold", size); if (f.Name.StartsWith("Segoe UI Semibold")) return f; } catch { } return new Font("Segoe UI", size, FontStyle.Bold); }
    public static System.Drawing.Drawing2D.GraphicsPath Round(RectangleF r, float rad)
    {
        var p = new System.Drawing.Drawing2D.GraphicsPath(); float d = rad * 2;
        if (d > r.Height) d = r.Height; if (d > r.Width) d = r.Width;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90); p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90); p.CloseFigure(); return p;
    }
    public static void Smooth(Graphics g) { g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit; }
    static float scale; public static float S(Control c) { if (scale <= 0) { try { using (var g = Graphics.FromHwnd(IntPtr.Zero)) scale = g.DpiX / 96f; } catch { scale = 1; } if (scale < 0.5f) scale = 1; } return scale; }
}

// Abgerundete Schaltflaeche: Primary = gefuellt in Akzentfarbe, sonst dezent umrandet
class RButton : Button
{
    public bool Primary; bool hot, down;
    public RButton() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand; Font = Th.FS(9.5f); }
    protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Th.Smooth(g);
        using (var b = new SolidBrush(Parent != null ? Parent.BackColor : Th.Bg)) g.FillRectangle(b, ClientRectangle);
        var r = new RectangleF(1f, 1f, Width - 3, Height - 3);
        Color fill, text, line;
        if (!Enabled) { fill = Primary ? Color.FromArgb(38, 48, 68) : Th.Bg; text = Th.Dim; line = Th.Line; }
        else if (Primary) { fill = down ? Color.FromArgb(58, 118, 226) : hot ? Th.AccentHi : Th.Accent; text = Color.White; line = fill; }
        else { fill = down ? Th.CardHi : hot ? Th.CardHi : Th.Card; text = Th.Text; line = hot ? Color.FromArgb(70, 76, 90) : Th.Line; }
        using (var p = Th.Round(r, Height / 2f)) { using (var b = new SolidBrush(fill)) g.FillPath(b, p); using (var pen = new Pen(line)) g.DrawPath(pen, p); }
        if (Focused && Enabled && ShowFocusCues) using (var p = Th.Round(new RectangleF(2.5f, 2.5f, Width - 5, Height - 5), Height / 2f)) using (var pen = new Pen(Color.FromArgb(120, 255, 255, 255))) g.DrawPath(pen, p);
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, text, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }
}

class Card : Panel
{
    public Color Fill = Th.Card, Border = Th.Line; public float Radius = 12;
    public Card() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); BackColor = Th.Card; }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Th.Smooth(g);
        using (var b = new SolidBrush(Parent != null ? Parent.BackColor : Th.Bg)) g.FillRectangle(b, ClientRectangle);
        using (var p = Th.Round(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), Radius * Th.S(this))) { using (var b = new SolidBrush(Fill)) g.FillPath(b, p); using (var pen = new Pen(Border)) g.DrawPath(pen, p); }
    }
}

// Eingabefeld mit abgerundetem Rahmen; der Rahmen leuchtet bei Fokus in der Akzentfarbe
class Field : Card
{
    public readonly TextBox Box = new TextBox();
    public Field(string val)
    {
        Fill = Color.FromArgb(18, 20, 26); Radius = 9; BackColor = Fill;
        Box.BorderStyle = BorderStyle.None; Box.BackColor = Fill; Box.ForeColor = Th.Text; Box.Font = Th.F(10f); Box.Text = val ?? "";
        Box.Enter += (s, e) => { Border = Th.Accent; Invalidate(); }; Box.Leave += (s, e) => { Border = Th.Line; Invalidate(); };
        Controls.Add(Box); Click += (s, e) => Box.Focus(); Cursor = Cursors.IBeam;
    }
    protected override void OnLayout(LayoutEventArgs e) { base.OnLayout(e); int pad = (int)(12 * Th.S(this)); Box.SetBounds(pad, Math.Max(1, (Height - Box.PreferredHeight) / 2), Math.Max(10, Width - 2 * pad), Box.PreferredHeight); }
}

// Schalter statt Haekchen
class Toggle : CheckBox
{
    public Toggle() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); Cursor = Cursors.Hand; ForeColor = Th.Text; }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Th.Smooth(g); float s = Th.S(this);
        using (var b = new SolidBrush(Parent != null ? Parent.BackColor : Th.Bg)) g.FillRectangle(b, ClientRectangle);
        float w = 38 * s, h = 20 * s, y = (Height - h) / 2f;
        var r = new RectangleF(0.5f, y, w, h);
        using (var p = Th.Round(r, h / 2)) { using (var b = new SolidBrush(!Enabled ? Th.Line : Checked ? Th.Accent : Color.FromArgb(52, 57, 69))) g.FillPath(b, p); }
        float d = h - 6 * s, x = Checked ? r.Right - d - 3 * s : r.X + 3 * s;
        using (var b = new SolidBrush(Enabled ? Color.White : Th.Dim)) g.FillEllipse(b, x, y + 3 * s, d, d);
        TextRenderer.DrawText(g, Text, Font, new Rectangle((int)(w + 12 * s), 0, Width - (int)(w + 12 * s), Height), Enabled ? Th.Text : Th.Dim, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
    }
}

class Radio : RadioButton
{
    public Radio() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); Cursor = Cursors.Hand; }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Th.Smooth(g); float s = Th.S(this);
        using (var b = new SolidBrush(Parent != null ? Parent.BackColor : Th.Bg)) g.FillRectangle(b, ClientRectangle);
        float d = 18 * s, y = (Height - d) / 2f;
        using (var pen = new Pen(!Enabled ? Th.Line : Checked ? Th.Accent : Color.FromArgb(92, 100, 116), 1.6f * s)) g.DrawEllipse(pen, 1, y, d, d);
        if (Checked) using (var b = new SolidBrush(Enabled ? Th.Accent : Th.Dim)) g.FillEllipse(b, 1 + 4.5f * s, y + 4.5f * s, d - 9 * s, d - 9 * s);
        TextRenderer.DrawText(g, Text, Font, new Rectangle((int)(d + 10 * s), 0, Width - (int)(d + 10 * s), Height), Enabled ? Th.Text : Th.Dim, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }
}

// Statuspunkt: 0 = Haken (gruen), 1 = Hinweis (gelb), 2 = fehlt (rot)
class Dot : Control
{
    public int State;
    public Dot() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Th.Smooth(g);
        using (var b = new SolidBrush(Parent != null ? Parent.BackColor : Th.Card)) g.FillRectangle(b, ClientRectangle);
        Color c = State == 0 ? Th.Ok : State == 1 ? Th.Warn : Th.Bad; float w = Width - 1, u = w / 22f;
        using (var b = new SolidBrush(Color.FromArgb(46, c))) g.FillEllipse(b, 0, 0, w, w);
        using (var pen = new Pen(c, 2f * u) { StartCap = System.Drawing.Drawing2D.LineCap.Round, EndCap = System.Drawing.Drawing2D.LineCap.Round, LineJoin = System.Drawing.Drawing2D.LineJoin.Round })
        {
            if (State == 0) g.DrawLines(pen, new[] { new PointF(6.5f * u, 11.5f * u), new PointF(9.8f * u, 14.6f * u), new PointF(15.6f * u, 7.8f * u) });
            else if (State == 1) { g.DrawLine(pen, 11 * u, 6.2f * u, 11 * u, 12.2f * u); g.DrawLine(pen, 11 * u, 15.6f * u, 11 * u, 15.7f * u); }
            else { g.DrawLine(pen, 7.4f * u, 7.4f * u, 14.6f * u, 14.6f * u); g.DrawLine(pen, 14.6f * u, 7.4f * u, 7.4f * u, 14.6f * u); }
        }
    }
}

// Linke Leiste mit den Schritten
class StepBar : Control
{
    public string[] Steps = new string[0]; public int Current; public Func<int, bool> Skipped = i => false; public Image Logo;
    public StepBar() { SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Th.Smooth(g); float s = Th.S(this);
        using (var b = new System.Drawing.Drawing2D.LinearGradientBrush(ClientRectangle, Color.FromArgb(16, 19, 28), Th.Side, 90f)) g.FillRectangle(b, ClientRectangle);
        using (var b = new System.Drawing.Drawing2D.GraphicsPath()) { b.AddEllipse(-160 * s, -200 * s, 420 * s, 420 * s); using (var pb = new System.Drawing.Drawing2D.PathGradientBrush(b) { CenterColor = Color.FromArgb(60, Th.Accent), SurroundColors = new[] { Color.FromArgb(0, Th.Accent) } }) g.FillPath(pb, b); }
        using (var pen = new Pen(Color.FromArgb(30, 34, 42))) g.DrawLine(pen, Width - 1, 0, Width - 1, Height);
        float x = 28 * s, y = 30 * s;
        { var lr = new RectangleF(x, y, 40 * s, 40 * s);
          using (var lp = Th.Round(lr, 11 * s)) { using (var lb = new System.Drawing.Drawing2D.LinearGradientBrush(lr, Color.FromArgb(96, 156, 255), Color.FromArgb(52, 98, 214), 60f)) g.FillPath(lb, lp); using (var pen = new Pen(Color.FromArgb(70, 255, 255, 255))) g.DrawPath(pen, lp); }
          float[] hs = { 15, 21, 12, 18 }; for (int k = 0; k < 4; k++) using (var bb = new SolidBrush(Color.FromArgb(k == 1 ? 255 : 205, 255, 255, 255))) using (var bp = Th.Round(new RectangleF(x + (9 + k * 6) * s, y + (30 - hs[k]) * s, 4 * s, hs[k] * s), 1.6f * s)) g.FillPath(bb, bp); }
        using (var f = Th.FS(12.5f)) TextRenderer.DrawText(g, "GameShelf Deck", f, new Point((int)(x + 50 * s), (int)(y + 2 * s)), Th.Text);
        using (var f = Th.F(8.5f)) TextRenderer.DrawText(g, "Einrichtung", f, new Point((int)(x + 51 * s), (int)(y + 23 * s)), Th.Soft);
        y = 112 * s;
        using (var f = Th.F(9.5f)) using (var fb = Th.FS(9.5f))
            for (int i = 0; i < Steps.Length; i++)
            {
                bool cur = i == Current, done = i < Current, skip = Skipped(i);
                float cy = y + i * 42 * s, d = 22 * s;
                if (i < Steps.Length - 1) using (var pen = new Pen(done ? Color.FromArgb(120, Th.Accent) : Th.Line, 1.4f * s)) g.DrawLine(pen, x + d / 2, cy + d + 3 * s, x + d / 2, cy + 42 * s - 3 * s);
                if (cur) { using (var b = new SolidBrush(Color.FromArgb(50, Th.Accent))) g.FillEllipse(b, x - 4 * s, cy - 4 * s, d + 8 * s, d + 8 * s); using (var b = new SolidBrush(Th.Accent)) g.FillEllipse(b, x, cy, d, d); }
                else if (done && !skip) { using (var b = new SolidBrush(Color.FromArgb(40, Th.Accent))) g.FillEllipse(b, x, cy, d, d); using (var pen = new Pen(Th.Accent, 1.8f * s) { StartCap = System.Drawing.Drawing2D.LineCap.Round, EndCap = System.Drawing.Drawing2D.LineCap.Round, LineJoin = System.Drawing.Drawing2D.LineJoin.Round }) g.DrawLines(pen, new[] { new PointF(x + 6.5f * s, cy + 11.5f * s), new PointF(x + 9.8f * s, cy + 14.6f * s), new PointF(x + 15.6f * s, cy + 7.8f * s) }); }
                else using (var pen = new Pen(skip ? Color.FromArgb(34, 38, 47) : Th.Line, 1.4f * s)) g.DrawEllipse(pen, x, cy, d, d);
                if (cur || (!done && !skip)) TextRenderer.DrawText(g, (i + 1).ToString(), fb, new Rectangle((int)x, (int)cy, (int)d + 1, (int)d), cur ? Color.White : Th.Dim, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                TextRenderer.DrawText(g, Steps[i], cur ? fb : f, new Point((int)(x + d + 12 * s), (int)(cy + 2 * s)), cur ? Th.Text : skip ? Color.FromArgb(70, 76, 88) : done ? Th.Soft : Th.Dim);
            }
        using (var f = Th.F(8.5f)) TextRenderer.DrawText(g, "Version " + App.Version, f, new Point((int)x, Height - (int)(34 * s)), Th.Dim);
    }
}

class Wizard : Form
{
    readonly Cfg cfg = new Cfg();
    readonly Panel body = new Panel();
    readonly Label title = new Label(), sub = new Label();
    readonly RButton back = new RButton(), next = new RButton { Primary = true }, cancel = new RButton();
    readonly StepBar bar = new StepBar();
    readonly List<Func<Control>> pages = new List<Func<Control>>();
    readonly List<Func<bool>> leave = new List<Func<bool>>();
    readonly List<string[]> heads = new List<string[]>();
    int idx; bool installed, busy;
    const int SideW = 236, Pad = 40, W = 684; // W = nutzbare Breite im Inhaltsbereich

    ListBox monList; Toggle dcSplit, autostart, hotkeys, desktop, startNow, reconf; Radio dcLeft, dcRight;
    TextBox sgdb, steam, edenExe, edenRoms, pdnExe, pdnGame, pdnName, fchExe, fchGame, fchName, dirBox, logBox;

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        if (App.IsWindows) { try { int on = 1; if (DwmSetWindowAttribute(Handle, 20, ref on, 4) != 0) DwmSetWindowAttribute(Handle, 19, ref on, 4); int col = 0x00150F0A + 0; col = (21 << 16) | (17 << 8) | 15; DwmSetWindowAttribute(Handle, 35, ref col, 4); } catch { } }
    }

    public Wizard()
    {
        Text = App.Name + " – Einrichtung"; Font = Th.F(9.5f); ForeColor = Th.Text; BackColor = Th.Bg;
        AutoScaleMode = AutoScaleMode.Dpi; ClientSize = new Size(1000, 680); FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
        try { using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("deck.ico")) if (s != null) { Icon = new Icon(s, 256, 256); bar.Logo = new Icon(Icon, 64, 64).ToBitmap(); } } catch { }

        bar.SetBounds(0, 0, SideW, 680); Controls.Add(bar);
        title.SetBounds(SideW + Pad - 2, 34, W, 36); title.Font = Th.FS(17f); title.ForeColor = Th.Text; title.BackColor = Th.Bg;
        sub.SetBounds(SideW + Pad, 72, W, 22); sub.ForeColor = Th.Soft; sub.BackColor = Th.Bg; sub.Font = Th.F(10f);
        Controls.Add(title); Controls.Add(sub);
        body.SetBounds(SideW + Pad, 116, W + 4, 478); body.BackColor = Th.Bg; Controls.Add(body);
        cancel.SetBounds(SideW + Pad, 620, 118, 38); cancel.Text = "Abbrechen"; cancel.Click += (s, e) => Close();
        back.SetBounds(1000 - Pad - 118 - 12 - 150, 620, 118, 38); back.Text = "Zurück"; back.Click += (s, e) => Go(idx - 1);
        next.SetBounds(1000 - Pad - 150, 620, 150, 38); next.Text = "Weiter"; next.Click += (s, e) => Next();
        Controls.Add(cancel); Controls.Add(back); Controls.Add(next);
        AcceptButton = next;

        string ex = App.ExistingDir();
        if (ex != null) { cfg.Dir = ex; cfg.Update = true; cfg.Reconfigure = false; Prefill(ex); }

        Add("Willkommen", cfg.Update ? "Vorhandene Installation aktualisieren" : "Spieleregal, Leistungsanzeige und Discord-Dock für den Zweitbildschirm", PageWelcome, null);
        Add("Voraussetzungen", "Was auf diesem PC vorhanden ist und was noch fehlt", PageChecks, null);
        Add("Bildschirm und Discord", "Wo das Deck erscheint", PageMonitor, LeaveMonitor);
        Add("Cover und Steam-Daten", "Zwei kostenlose Schlüssel, beide freiwillig", PageKeys, LeaveKeys);
        Add("Emulatoren", "Nur ausfüllen, wenn Sie Emulatoren nutzen", PageEmu, LeaveEmu);
        Add("Start und Bedienung", "Letzte Angaben vor der Installation", PageOptions, LeaveOptions);
        Add("Installation", "Programmdateien kopieren und Einstellungen schreiben", PageInstall, null);
        Add("Fertig", "Das Deck ist eingerichtet", PageDone, null);
        bar.Steps = new[] { "Willkommen", "Voraussetzungen", "Bildschirm", "Schlüssel", "Emulatoren", "Start", "Installation", "Fertig" };
        bar.Skipped = i => cfg.Update && !cfg.Reconfigure && i >= 2 && i <= 5;
        Go(0);
        FormClosing += (s, e) => { if (busy) e.Cancel = true; else if (!installed && idx > 0 && idx < pages.Count - 1 && MessageBox.Show("Einrichtung abbrechen? Es wurde noch nichts installiert.", App.Name, MessageBoxButtons.YesNo) != DialogResult.Yes) e.Cancel = true; };
    }

    void Add(string t, string s, Func<Control> build, Func<bool> onLeave) { heads.Add(new[] { t, s }); pages.Add(build); leave.Add(onLeave); }

    void Prefill(string dir)
    {
        var d = Json.Load(Path.Combine(dir, "deck.json")); var g = Json.Load(Path.Combine(dir, "config.json"));
        if (d != null)
        {
            cfg.Monitor = Json.Str(d, "monitor"); cfg.DiscordSplit = Json.Bool(d, "discordSplit", true); string side = Json.Str(d, "dcposL"); if (side == "a" || side == "b") cfg.DiscordSide = side;
            cfg.Autostart = Json.Bool(d, "autostart", true); cfg.Hotkeys = Json.Bool(d, "hotkeys", true);
        }
        if (g != null)
        {
            cfg.EdenExe = Json.Str(g, "edenExe"); cfg.EdenRoms = Json.Str(g, "edenRoms");
            cfg.PdnExe = Json.Str(g, "pdnExe"); cfg.PdnGame = Json.Str(g, "pdnGame"); cfg.PdnName = Json.Str(g, "pdnName");
            cfg.FchExe = Json.Str(g, "fchExe"); cfg.FchGame = Json.Str(g, "fchGame"); cfg.FchName = Json.Str(g, "fchName");
        }
    }

    public int PageCount { get { return pages.Count; } }
    public void Go(int i)
    {
        if (i < 0 || i >= pages.Count) return;
        if (cfg.Update && !cfg.Reconfigure && i >= 2 && i <= 5) i = i > idx ? 6 : 1; // Aktualisierung ohne neue Einrichtung
        idx = i;
        body.SuspendLayout(); body.Controls.Clear();
        var c = pages[i](); c.Dock = DockStyle.Fill; body.Controls.Add(c);
        body.ResumeLayout();
        title.Text = heads[i][0]; sub.Text = heads[i][1]; bar.Current = i; bar.Invalidate();
        back.Enabled = i > 0 && i < 6; back.Visible = i > 0 && i < 7;
        cancel.Visible = i < 6;
        next.Text = i == 5 ? (cfg.Update ? "Aktualisieren" : "Installieren") : i == 7 ? "Schließen" : "Weiter";
        if (i == 1 && cfg.Update && !cfg.Reconfigure) next.Text = "Aktualisieren";
        next.Enabled = i != 6;
        if (i == 6) BeginInvoke((Action)RunInstall);
    }
    void Next()
    {
        if (idx == pages.Count - 1) { if (startNow != null && startNow.Checked) { try { Installer.StartDeck(cfg.Dir); } catch (Exception e) { MessageBox.Show("Das Deck ließ sich nicht starten:\n" + e.Message, App.Name); } } installed = true; Close(); return; }
        if (leave[idx] != null && !leave[idx]()) return;
        Go(idx + 1);
    }

    // ---------- Bausteine
    Panel Page() { return new Panel { BackColor = Th.Bg }; }
    Label Text_(Control p, string t, int x, int y, int w, int h, Color? col = null, Font f = null) { var l = new Label { Text = t, ForeColor = col ?? Th.Text, Font = f ?? Font, BackColor = p.BackColor, UseMnemonic = false }; l.SetBounds(x, y, w, h); p.Controls.Add(l); return l; }
    Label Head(Control p, string t, int x, int y) { return Text_(p, t, x, y, W - x, 22, null, Th.FS(10.5f)); }
    LinkLabel Link(Control p, string t, string url, int x, int y, int w) { var l = new LinkLabel { Text = t, LinkColor = Th.AccentHi, ActiveLinkColor = Color.White, VisitedLinkColor = Th.AccentHi, LinkBehavior = LinkBehavior.HoverUnderline, BackColor = p.BackColor, Font = Th.FS(9.5f) }; l.AutoSize = true; l.Location = new Point(x, y); l.LinkClicked += (s, e) => App.Open(url); p.Controls.Add(l); if (w < 0) l.Left = -w - l.PreferredWidth; return l; }
    TextBox Box(Control p, string val, int x, int y, int w) { var f = new Field(val); f.SetBounds(x, y, w, 34); p.Controls.Add(f); return f.Box; }
    RButton Btn(Control p, string t, int x, int y, int w, EventHandler h) { var b = new RButton { Text = t }; b.SetBounds(x, y, w, 34); b.Click += h; p.Controls.Add(b); return b; }
    Toggle Tog(Control p, string t, bool on, int x, int y, int w) { var c = new Toggle { Text = t, Checked = on, BackColor = p.BackColor, Font = Th.F(10f) }; c.SetBounds(x, y, w, 26); p.Controls.Add(c); return c; }
    Card Box_(Control p, int x, int y, int w, int h) { var c = new Card(); c.SetBounds(x, y, w, h); p.Controls.Add(c); return c; }
    void PickFile(TextBox t, string filter) { using (var d = new OpenFileDialog { Filter = filter, CheckFileExists = true }) { try { if (t.Text.Length > 0) d.InitialDirectory = Path.GetDirectoryName(t.Text); } catch { } if (d.ShowDialog(this) == DialogResult.OK) t.Text = d.FileName; } }
    void PickDir(TextBox t, string desc) { using (var d = new FolderBrowserDialog { Description = desc, ShowNewFolderButton = false }) { if (Directory.Exists(t.Text)) d.SelectedPath = t.Text; if (d.ShowDialog(this) == DialogResult.OK) t.Text = d.SelectedPath; } }

    // ---------- Seiten
    Control PageWelcome()
    {
        var p = Page();
        if (cfg.Update)
        {
            var c = Box_(p, 0, 0, W, 132);
            Text_(c, "Auf diesem PC ist bereits ein Deck installiert.", 22, 18, W - 44, 24, null, Th.FS(11.5f));
            Text_(c, "Das Setup tauscht nur die Programmdateien gegen Version " + App.Version + ". Einstellungen, Schlüssel, Cover und Spielzeiten bleiben unverändert.", 22, 46, W - 44, 40, Th.Soft);
            Text_(c, cfg.Dir, 22, 94, W - 44, 20, Th.Dim);
            reconf = Tog(p, "Einrichtung erneut durchlaufen (Bildschirm, Schlüssel, Emulatoren, Autostart)", cfg.Reconfigure, 2, 156, W - 4); reconf.CheckedChanged += (s, e) => { cfg.Reconfigure = reconf.Checked; bar.Invalidate(); Go(0); };
            return p;
        }
        string[][] tiles = { new[] { "Bibliothek", "Alle Spiele mit Covern: Steam, Epic, Xbox, GOG, Emulatoren" }, new[] { "Leistung", "FPS, Temperaturen und Auslastung live neben dem Spiel" }, new[] { "Steuerung", "Makro-Tasten, Philips Hue, Medien und Lautstärke-Mixer" } };
        int tw = (W - 24) / 3;
        for (int i = 0; i < 3; i++)
        {
            var c = Box_(p, i * (tw + 12), 0, tw, 126);
            var bar2 = new Panel { BackColor = i == 0 ? Th.Accent : i == 1 ? Th.Ok : Color.FromArgb(214, 122, 255) }; bar2.SetBounds(20, 20, 26, 4); c.Controls.Add(bar2);
            Text_(c, tiles[i][0], 20, 34, tw - 40, 22, null, Th.FS(11f));
            Text_(c, tiles[i][1], 20, 60, tw - 34, 54, Th.Soft, Th.F(9f));
        }
        Text_(p, "Der Assistent prüft zuerst, was auf Ihrem PC vorhanden ist, und fragt dann Schritt für Schritt alles ab. Fehlende Programme nennt er mit Link zur Herstellerseite. Jede Angabe lässt sich später ändern, indem Sie dieses Setup erneut starten.", 2, 150, W - 4, 60, Th.Soft, Th.F(10f));
        Text_(p, "Es werden keine Administratorrechte gebraucht. Installiert wird nur für Ihr Benutzerkonto.", 2, 212, W - 4, 22, Th.Soft, Th.F(10f));
        Head(p, "Installationsordner", 2, 262);
        dirBox = Box(p, cfg.Dir, 0, 290, W - 132); dirBox.TextChanged += (s, e) => cfg.Dir = dirBox.Text.Trim();
        Btn(p, "Ändern …", W - 120, 290, 120, (s, e) => PickDirNew());
        Text_(p, "Einstellungen, Cover und Protokolle liegen im selben Ordner. Ein Update überschreibt sie nicht.", 2, 334, W - 4, 20, Th.Dim, Th.F(9f));
        return p;
    }
    void PickDirNew() { using (var d = new FolderBrowserDialog { Description = "Übergeordneten Ordner wählen; das Setup legt darin „" + App.Name + "“ an.", ShowNewFolderButton = true }) { if (d.ShowDialog(this) == DialogResult.OK) dirBox.Text = Path.Combine(d.SelectedPath, App.Name); } }

    Control PageChecks()
    {
        var p = Page(); int y = 0;
        foreach (var it in Checks.All())
        {
            var c = Box_(p, 0, y, W, 56); c.Radius = 11;
            var d = new Dot { State = it.State, BackColor = Th.Card }; d.SetBounds(16, 17, 23, 23); c.Controls.Add(d);
            Text_(c, it.Title, 52, 8, 420, 20, null, Th.FS(10f));
            Text_(c, it.Detail, 52, 29, W - 70, 18, Th.Soft, Th.F(9f)).AutoEllipsis = true;
            if (it.Url != null) Link(c, it.LinkText + "  ↗", it.Url, 0, 9, -(W - 20));
            y += 62;
        }
        Btn(p, "Erneut prüfen", 0, y + 6, 140, (s, e) => Go(1));
        Text_(p, "Fehlendes lässt sich jetzt oder später nachinstallieren. Rot braucht das Deck zum Start.", 156, y + 14, W - 160, 20, Th.Dim, Th.F(9f));
        return p;
    }

    Control PageMonitor()
    {
        var p = Page();
        Head(p, "Auf welchem Bildschirm soll das Deck laufen?", 2, 0);
        var c = Box_(p, 0, 30, W, 150);
        monList = new ListBox { IntegralHeight = false, BorderStyle = BorderStyle.None, BackColor = Th.Card, ForeColor = Th.Text, DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = 34, Font = Th.F(10f) }; monList.SetBounds(8, 8, W - 16, 134);
        monList.DrawItem += (s, e) =>
        {
            if (e.Index < 0) return; var g = e.Graphics; Th.Smooth(g);
            bool sel = (e.State & DrawItemState.Selected) != 0;
            using (var b = new SolidBrush(Th.Card)) g.FillRectangle(b, e.Bounds);
            var r = new RectangleF(e.Bounds.X + 1, e.Bounds.Y + 2, e.Bounds.Width - 3, e.Bounds.Height - 4);
            if (sel) using (var path = Th.Round(r, 8)) { using (var b = new SolidBrush(Color.FromArgb(44, Th.Accent))) g.FillPath(b, path); using (var pen = new Pen(Color.FromArgb(150, Th.Accent))) g.DrawPath(pen, path); }
            float dd = 10; using (var b = new SolidBrush(sel ? Th.Accent : Color.FromArgb(60, 66, 78))) g.FillEllipse(b, r.X + 12, r.Y + (r.Height - dd) / 2, dd, dd);
            TextRenderer.DrawText(g, monList.Items[e.Index].ToString(), monList.Font, new Rectangle((int)r.X + 32, (int)r.Y, (int)r.Width - 36, (int)r.Height), sel ? Th.Text : Th.Soft, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
        };
        monList.Items.Add("Automatisch: der kleinste Bildschirm, der nicht Hauptbildschirm ist (empfohlen)");
        int sel0 = 0, n = 1;
        foreach (var s in Screen.AllScreens)
        {
            monList.Items.Add(new MonItem { Device = s.DeviceName, Portrait = s.Bounds.Height > s.Bounds.Width, Primary = s.Primary, Text = "Bildschirm " + n + "   ·   " + s.Bounds.Width + " × " + s.Bounds.Height + (s.Primary ? "   ·   Hauptbildschirm" : "") + (s.Bounds.Height > s.Bounds.Width ? "   ·   hochkant" : "") });
            if (cfg.Monitor.Length > 0 && string.Equals(cfg.Monitor, s.DeviceName, StringComparison.OrdinalIgnoreCase)) sel0 = n;
            n++;
        }
        monList.SelectedIndex = sel0; c.Controls.Add(monList);
        Text_(p, "Das Deck ist für das Querformat gebaut (z. B. 2560 × 720, 1920 × 1080, 2560 × 1440). Hochkant wird nicht unterstützt.", 2, 188, W - 4, 20, Th.Dim, Th.F(9f));

        Head(p, "Discord", 2, 236);
        dcSplit = Tog(p, "Discord neben dem Deck andocken, sobald Discord geöffnet ist", cfg.DiscordSplit, 2, 266, W - 4);
        dcLeft = new Radio { Text = "Discord links, Deck rechts", Checked = cfg.DiscordSide == "a", BackColor = Th.Bg, Font = Th.F(10f) }; dcLeft.SetBounds(52, 302, 250, 26); p.Controls.Add(dcLeft);
        dcRight = new Radio { Text = "Discord rechts, Deck links", Checked = cfg.DiscordSide != "a", BackColor = Th.Bg, Font = Th.F(10f) }; dcRight.SetBounds(312, 302, 250, 26); p.Controls.Add(dcRight);
        dcSplit.CheckedChanged += (s, e) => { dcLeft.Enabled = dcRight.Enabled = dcSplit.Checked; }; dcLeft.Enabled = dcRight.Enabled = dcSplit.Checked;
        Text_(p, "Ist Discord geschlossen, nutzt das Deck die ganze Breite. Die Knöpfe für Mikro und Ton im Deck schalten systemweit; in Discord ist dafür nichts einzustellen.", 2, 340, W - 4, 40, Th.Dim, Th.F(9f));
        return p;
    }
    class MonItem { public string Device, Text; public bool Portrait, Primary; public override string ToString() { return Text; } }
    bool LeaveMonitor()
    {
        var m = monList.SelectedItem as MonItem;
        if (m != null && m.Portrait && MessageBox.Show("Dieser Bildschirm steht hochkant. Das Deck ist nur für das Querformat gebaut und wird dort nicht brauchbar aussehen.\n\nTrotzdem wählen?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return false;
        if (m != null && m.Primary && MessageBox.Show("Das ist Ihr Hauptbildschirm. Das Deck belegt dann den ganzen Hauptbildschirm.\n\nTrotzdem wählen?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return false;
        cfg.Monitor = m == null ? "" : m.Device; cfg.DiscordSplit = dcSplit.Checked; cfg.DiscordSide = dcLeft.Checked ? "a" : "b";
        return true;
    }

    Control PageKeys()
    {
        var p = Page();
        var a = Box_(p, 0, 0, W, 160);
        Text_(a, "SteamGridDB-Schlüssel", 22, 16, 360, 22, null, Th.FS(11f));
        Link(a, "Schlüssel holen  ↗", App.UrlSgdb, 0, 18, -(W - 22));
        Text_(a, "Für Cover, Titelbilder und Logos von Spielen, die nicht von Steam kommen (Epic, Xbox, GOG, Emulatoren). Auf steamgriddb.com mit dem Steam-Konto anmelden, unter Preferences › API den Schlüssel erzeugen.", 22, 44, W - 44, 54, Th.Soft, Th.F(9f));
        sgdb = Box(a, cfg.SgdbKey, 22, 106, W - 44);

        var b = Box_(p, 0, 174, W, 160);
        Text_(b, "Steam-Web-API-Schlüssel", 22, 16, 360, 22, null, Th.FS(11f));
        Link(b, "Schlüssel holen  ↗", App.UrlSteamKey, 0, 18, -(W - 22));
        Text_(b, "Für Freunde online, Wunschlisten-Angebote und Erfolge. Auf der Steam-Seite anmelden, als Domain etwas Beliebiges eintragen (z. B. localhost), Schlüssel kopieren.", 22, 44, W - 44, 54, Th.Soft, Th.F(9f));
        steam = Box(b, cfg.SteamKey, 22, 106, W - 44);

        Text_(p, "Beide Schlüssel bleiben auf diesem PC und gehen ausschließlich an SteamGridDB bzw. Steam. Leer lassen heißt: später nachtragen über dieses Setup; den Steam-Schlüssel auch im Deck unter Einstellungen › Gaming & Discord."
            + (cfg.Update ? " Leere Felder behalten den bereits gespeicherten Schlüssel." : ""), 2, 350, W - 4, 60, Th.Dim, Th.F(9f));
        return p;
    }
    static readonly Regex Hex32 = new Regex("^[0-9a-fA-F]{32}$");
    bool LeaveKeys()
    {
        string a = sgdb.Text.Trim(), b = steam.Text.Trim();
        if (a.Length > 0 && !Hex32.IsMatch(a)) { MessageBox.Show("Der SteamGridDB-Schlüssel besteht aus 32 Zeichen (0–9, a–f). Bitte prüfen oder das Feld leeren.", App.Name); sgdb.Focus(); return false; }
        if (b.Length > 0 && !Hex32.IsMatch(b)) { MessageBox.Show("Der Steam-Schlüssel besteht aus 32 Zeichen (0–9, A–F). Bitte prüfen oder das Feld leeren.", App.Name); steam.Focus(); return false; }
        cfg.SgdbKey = a; cfg.SteamKey = b.ToUpperInvariant(); return true;
    }

    TextBox Row(Control p, string label, string val, int y, Action<TextBox> pick)
    {
        Text_(p, label, 22, y + 8, 104, 20, Th.Soft, Th.F(9.5f));
        var t = Box(p, val, 130, y, pick == null ? 260 : W - 130 - 22 - 108);
        if (pick != null) Btn(p, "Suchen …", W - 22 - 98, y, 98, (s, e) => pick(t));
        return t;
    }
    Control PageEmu()
    {
        var p = Page();
        Text_(p, "Steam, Epic, Xbox/Game Pass, GOG, Ubisoft Connect, EA und Battle.net findet das Deck von selbst. Emulatoren liegen überall anders, deshalb hier die Pfade. Alles leer lassen ist in Ordnung.", 2, 0, W - 4, 40, Th.Soft, Th.F(9.5f));
        var a = Box_(p, 0, 48, W, 142);
        Text_(a, "Eden (Switch-Emulator)", 22, 14, 400, 22, null, Th.FS(10.5f));
        edenExe = Row(a, "eden.exe", cfg.EdenExe, 46, t => PickFile(t, "eden.exe|eden.exe|Programme|*.exe"));
        edenRoms = Row(a, "Spiele-Ordner", cfg.EdenRoms, 88, t => PickDir(t, "Ordner mit den Spieldateien (.nsp, .xci, .nsz, .xcz)"));
        var b = Box_(p, 0, 202, W, 274);
        Text_(b, "Für Fortgeschrittene: Emulatoren mit genau einem Spiel", 22, 14, 500, 22, null, Th.FS(10.5f));
        pdnExe = Row(b, "PokeDinner", cfg.PdnExe, 44, t => PickFile(t, "Programme|*.exe"));
        pdnGame = Row(b, "Spielordner", cfg.PdnGame, 82, t => PickDir(t, "Entpackter Spielordner (enthält die Datei „main“)"));
        pdnName = Row(b, "Anzeigename", cfg.PdnName, 120, null);
        fchExe = Row(b, "Fritchii", cfg.FchExe, 158, t => PickFile(t, "Programme|*.exe"));
        fchGame = Row(b, "Spieldatei", cfg.FchGame, 196, t => PickFile(t, "Spielpakete|*.nup;*.nsp;*.xci|Alle Dateien|*.*"));
        fchName = Row(b, "Anzeigename", cfg.FchName, 234, null);
        return p;
    }
    bool LeaveEmu()
    {
        Func<TextBox, string> v = t => t.Text.Trim().Trim(new[] { '"', ' ' });
        string[][] chk = { new[] { v(edenExe), "f", "eden.exe" }, new[] { v(edenRoms), "d", "Eden-Spiele-Ordner" }, new[] { v(pdnExe), "f", "PokeDinner-Programm" }, new[] { v(pdnGame), "e", "PokeDinner-Spielordner" }, new[] { v(fchExe), "f", "Fritchii-Programm" }, new[] { v(fchGame), "f", "Fritchii-Spieldatei" } };
        foreach (var c in chk)
        {
            if (c[0].Length == 0) continue;
            bool ok = c[1] == "f" ? File.Exists(c[0]) : c[1] == "d" ? Directory.Exists(c[0]) : (File.Exists(c[0]) || Directory.Exists(c[0]));
            if (!ok && MessageBox.Show(c[2] + " wurde nicht gefunden:\n" + c[0] + "\n\nTrotzdem übernehmen?", App.Name, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return false;
        }
        if ((v(edenExe).Length > 0) != (v(edenRoms).Length > 0)) { MessageBox.Show("Für Eden braucht das Deck beides: eden.exe und den Spiele-Ordner.", App.Name); return false; }
        cfg.EdenExe = v(edenExe); cfg.EdenRoms = v(edenRoms); cfg.PdnExe = v(pdnExe); cfg.PdnGame = v(pdnGame); cfg.PdnName = v(pdnName); cfg.FchExe = v(fchExe); cfg.FchGame = v(fchGame); cfg.FchName = v(fchName);
        return true;
    }

    Control PageOptions()
    {
        var p = Page();
        var a = Box_(p, 0, 0, W, 148);
        autostart = Tog(a, "Deck automatisch mit Windows starten", cfg.Autostart, 22, 18, W - 44);
        hotkeys = Tog(a, "Systemweite Tastenkürzel (Strg + Alt + S, A, D, F, V, T, R)", cfg.Hotkeys, 22, 54, W - 44);
        Text_(a, "Ausschalten, falls ein anderes Programm dieselben Kürzel nutzt.", 72, 80, W - 100, 18, Th.Dim, Th.F(9f));
        desktop = Tog(a, "Verknüpfung auf dem Desktop anlegen", cfg.DesktopLink, 22, 106, W - 44);

        Head(p, "Was Sie danach im Deck selbst einstellen", 2, 170);
        string[][] rows = { new[] { "Ort für Wetter", "Einstellungen (Zahnrad) › Home › Wetter" }, new[] { "Kalender", "Einstellungen › Home › Kalender, Abo-Link (ICS/webcal) einfügen" }, new[] { "Philips Hue", "Tab „Hue“ öffnen und den Knopf an der Bridge drücken" }, new[] { "Aussehen", "Akzentfarbe, Glas, Idle-Bildschirm und Startseiten-Foto in den Einstellungen" }, new[] { "Makro-Kacheln", "Hue Sync, Claude, RHI, DLSS Swapper, NordVPN erscheinen, sobald installiert" } };
        for (int i = 0; i < rows.Length; i++) { Text_(p, rows[i][0], 2, 202 + i * 26, 130, 20, Th.Text, Th.F(9.5f)); Text_(p, rows[i][1], 136, 202 + i * 26, W - 140, 20, Th.Soft, Th.F(9.5f)); }
        Text_(p, "Geräte-Akkus zeigt das Deck, wenn Logitech G HUB, Corsair iCUE oder SteelSeries GG laufen. Der Couch-Modus (Streaming per Apollo) ist eine Expertenfunktion und in LIESMICH.txt beschrieben.", 2, 346, W - 4, 40, Th.Dim, Th.F(9f));
        return p;
    }
    bool LeaveOptions()
    {
        cfg.Autostart = autostart.Checked; cfg.Hotkeys = hotkeys.Checked; cfg.DesktopLink = desktop.Checked;
        if (!cfg.Update)
        {
            try { cfg.Dir = Path.GetFullPath(cfg.Dir); } catch { MessageBox.Show("Der Installationsordner ist ungültig.", App.Name); Go(0); return false; }
        }
        return true;
    }

    Control PageInstall()
    {
        var p = Page();
        var c = Box_(p, 0, 0, W, 440);
        logBox = new TextBox { Multiline = true, ReadOnly = true, BackColor = Th.Card, ForeColor = Th.Soft, BorderStyle = BorderStyle.None, Font = Th.F(10f), TabStop = false }; logBox.SetBounds(22, 20, W - 44, 400); c.Controls.Add(logBox);
        return p;
    }
    void Log(string s) { if (logBox != null) { logBox.AppendText(s + "\r\n"); Application.DoEvents(); } }
    void RunInstall()
    {
        busy = true; back.Enabled = false; cancel.Enabled = false; Cursor = Cursors.WaitCursor;
        try
        {
            Log(cfg.Update ? "Aktualisiere " + cfg.Dir + " …" : "Installiere nach " + cfg.Dir + " …");
            Installer.Install(cfg, Log);
            installed = true; Log(""); Log("Fertig.");
            Cursor = Cursors.Default; busy = false; next.Enabled = true;
            Go(7);
        }
        catch (Exception e)
        {
            Cursor = Cursors.Default; busy = false;
            Log(""); Log("FEHLER: " + e.Message);
            Log("Nichts davon ist endgültig: Setup erneut starten behebt eine halbe Installation.");
            cancel.Enabled = true; cancel.Visible = true; cancel.Text = "Schließen"; back.Enabled = true; back.Visible = true; idx = 5;
        }
    }

    Control PageDone()
    {
        var p = Page();
        var c = Box_(p, 0, 0, W, 96);
        var d = new Dot { State = 0, BackColor = Th.Card }; d.SetBounds(22, 26, 43, 43); c.Controls.Add(d);
        Text_(c, cfg.Update ? "Das Deck ist auf Version " + App.Version + " aktualisiert." : "Das Deck ist installiert.", 84, 22, W - 110, 26, null, Th.FS(13f));
        Text_(c, cfg.Dir, 85, 52, W - 110, 20, Th.Dim, Th.F(9f)).AutoEllipsis = true;
        string[][] rows = { new[] { "Starten", "Startmenü › " + App.Name + (cfg.Autostart ? " (startet künftig von selbst mit Windows)" : "") }, new[] { "Beenden", "Power-Symbol im Deck oder „Deck beenden.cmd“ im Ordner" }, new[] { "Ändern", "Dieses Setup erneut starten; es liegt auch im Installationsordner" }, new[] { "Entfernen", "Windows-Einstellungen › Apps › Installierte Apps › " + App.Name } };
        for (int i = 0; i < rows.Length; i++) { Text_(p, rows[i][0], 2, 122 + i * 28, 110, 20, Th.Text, Th.FS(9.5f)); Text_(p, rows[i][1], 116, 122 + i * 28, W - 120, 20, Th.Soft, Th.F(9.5f)); }
        int y = 246;
        Text_(p, "Beim ersten Start sucht das Deck Ihre Spiele und lädt Cover. Das dauert ein bis zwei Minuten.", 2, y, W - 4, 20, Th.Dim, Th.F(9f)); y += 30;
        if (!Checks.WebView2()) { var w1 = Box_(p, 0, y, W, 44); w1.Border = Color.FromArgb(120, Th.Bad); var d1 = new Dot { State = 2, BackColor = Th.Card }; d1.SetBounds(14, 11, 23, 23); w1.Controls.Add(d1); Text_(w1, "Die WebView2-Laufzeit fehlt noch. Ohne sie bleibt das Deck leer.", 48, 12, W - 250, 20, null, Th.F(9.5f)); Link(w1, "Zur Microsoft-Seite  ↗", App.UrlWebView2, 0, 12, -(W - 18)); y += 52; }
        if (Screen.AllScreens.Length < 2) { var w2 = Box_(p, 0, y, W, 44); var d2 = new Dot { State = 1, BackColor = Th.Card }; d2.SetBounds(14, 11, 23, 23); w2.Controls.Add(d2); Text_(w2, "Nur ein Bildschirm angeschlossen. Das Deck erscheint, sobald ein zweiter da ist.", 48, 12, W - 70, 20, null, Th.F(9.5f)); y += 52; }
        startNow = Tog(p, "Deck jetzt starten", cfg.StartNow, 2, Math.Max(y + 12, 400), 400);
        return p;
    }

    public Cfg C { get { return cfg; } }
}

static class SelfTest
{
    // Schreibt eine Probe-Installation in einen Ordner (ohne Verknuepfungen/Registry ausserhalb von Windows)
    public static int Run(string dir)
    {
        var c = new Cfg { Dir = dir, Monitor = @"\\.\DISPLAY2", DiscordSplit = true, DiscordSide = "a", SgdbKey = "0123456789abcdef0123456789abcdef", SteamKey = "", EdenExe = @"E:\Emu\Eden\eden.exe", EdenRoms = @"E:\Emu\Roms", Autostart = false, Hotkeys = false };
        Installer.Install(c, s => Console.WriteLine("  " + s));
        // zweiter Lauf als Aktualisierung ohne neue Einrichtung: Einstellungen muessen unveraendert bleiben
        string before = File.ReadAllText(Path.Combine(dir, "deck.json")) + File.ReadAllText(Path.Combine(dir, "config.json"));
        var u = new Cfg { Dir = dir, Update = true, Reconfigure = false, SgdbKey = "ffffffffffffffffffffffffffffffff", Monitor = "x" };
        Installer.Install(u, s => Console.WriteLine("  " + s));
        string after = File.ReadAllText(Path.Combine(dir, "deck.json")) + File.ReadAllText(Path.Combine(dir, "config.json"));
        Console.WriteLine("Update laesst Einstellungen unveraendert: " + (before == after));
        // dritter Lauf: neu einrichten, Schluesselfeld leer -> gespeicherter Schluessel bleibt
        var r = new Cfg { Dir = dir, Update = true, Reconfigure = true, SgdbKey = "", Monitor = "", Hotkeys = true };
        Installer.Install(r, s => Console.WriteLine("  " + s));
        var g = Json.Load(Path.Combine(dir, "config.json")); var d = Json.Load(Path.Combine(dir, "deck.json"));
        Console.WriteLine("Schluessel bleibt bei leerem Feld: " + (Json.Str(g, "steamGridDbKey") == "0123456789abcdef0123456789abcdef") + " | hotkeys=" + Json.Bool(d, "hotkeys", false) + " | monitor='" + Json.Str(d, "monitor") + "'");
        return before == after ? 0 : 2;
    }

    public static int Shots(string dir)
    {
        Directory.CreateDirectory(dir);
        var w = new Wizard(); w.StartPosition = FormStartPosition.Manual; w.Location = new Point(0, 0); w.Show(); Application.DoEvents();
        Action<int> pump = ms => { for (int k = 0; k < ms / 50; k++) { Application.DoEvents(); Thread.Sleep(50); } };
        for (int i = 0; i < w.PageCount; i++)
        {
            if (i == 6) continue; // Installationsseite wuerde installieren
            w.Go(i); pump(1200);
            File.WriteAllText(Path.Combine(dir, "seite" + (i + 1) + ".ready"), "x");
            pump(1800);
        }
        w.Dispose();
        return 0;
    }
}


// OTA-Update aus dem Deck heraus (deckos-181): ohne Fenster, nur Programmdateien tauschen, Einstellungen bleiben.
// Vor dem Tausch landen die bisherigen Programmdateien in update\rollback; scheitert der Tausch, werden sie zurueckkopiert.
static class SilentUpdate
{
    static string logFile;
    static void Log(string s)
    {
        try { File.AppendAllText(logFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + s + "\r\n", Encoding.UTF8); } catch { }
    }
    public static int Run(string dirArg)
    {
        string dir;
        try { dir = Path.GetFullPath(dirArg.Trim().Trim('"')).TrimEnd('\\', '/'); } catch { return 2; }
        if (!File.Exists(Path.Combine(dir, "Deck.ps1"))) return 2;
        logFile = Path.Combine(dir, "update.log");
        Log("Update auf " + App.Version + " in " + dir);
        if (Directory.Exists(Path.Combine(dir, "Sicherung")) || Directory.Exists(Path.Combine(dir, "Entwurf"))) { Log("Abbruch: Entwicklerordner"); return 3; }
        bool created;
        using (var m = new Mutex(true, "GameShelfDeck_Setup_Running", out created))
        {
            if (!created) { Log("Abbruch: Setup laeuft bereits"); return 1; }
            string rb = Path.Combine(dir, "update", "rollback");
            var files = Installer.PayloadFiles();
            try
            {
                if (Directory.Exists(rb)) Directory.Delete(rb, true);
                foreach (var rel in files)
                {
                    string src = Path.Combine(dir, rel);
                    if (!File.Exists(src)) continue;
                    string dst = Path.Combine(rb, rel);
                    Directory.CreateDirectory(Path.GetDirectoryName(dst));
                    File.Copy(src, dst, true);
                }
                Log("Rueckfall gesichert: " + rb);
            }
            catch (Exception e) { Log("Abbruch: Rueckfall nicht sicherbar (" + e.Message + ")"); return 4; }

            var c = new Cfg { Dir = dir, Update = true, Reconfigure = false, Autostart = true, DesktopLink = false };
            bool ok = false;
            try { Installer.Install(c, Log); ok = true; Log("Update fertig."); }
            catch (Exception e)
            {
                Log("FEHLER: " + e.Message + " - stelle vorigen Stand wieder her");
                foreach (var rel in files)
                {
                    string src = Path.Combine(rb, rel);
                    if (!File.Exists(src)) continue;
                    for (int t = 0; t < 10; t++) { try { File.Copy(src, Path.Combine(dir, rel), true); break; } catch { Thread.Sleep(500); } }
                }
                Log("Vorheriger Stand wiederhergestellt.");
            }
            try { Thread.Sleep(800); Installer.StartDeck(dir); Log("Deck gestartet."); } catch (Exception e) { Log("Deck nicht startbar: " + e.Message); }
            return ok ? 0 : 5;
        }
    }
}
