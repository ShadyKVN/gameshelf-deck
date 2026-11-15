using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;

// Windows-Hilfen fuer das GameShelf Deck: Monitore, Discord-Fenster, Hotkeys, Afterburner/RTSS, Drehen.
public static class DeckNative
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS { public uint style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        public string lpszMenuName; public string lpszClassName; }

    delegate bool MonEnumProc(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d);
    delegate bool WndEnumProc(IntPtr h, IntPtr l);
    delegate IntPtr WndProcD(IntPtr h, uint m, IntPtr w, IntPtr l);

    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonEnumProc cb, IntPtr d);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFOEX mi);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr h, int type, out uint x, out uint y);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettingsEx(string dev, int mode, ref DEVMODE dm, int flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr lp);
    [DllImport("user32.dll")] static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] static extern bool EnumWindows(WndEnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int idx);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int idx, IntPtr v);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassW(ref WNDCLASS c);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

    // ------------------------------------------------------------ DPI
    public static bool PerMonitorAware() { try { return SetProcessDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero; } catch { return false; } }

    // ------------------------------------------------------------ Monitore
    public class Mon { public string Device; public int X, Y, W, H, Dpi; public bool Primary; public int Orientation, Hz; }
    public static List<Mon> Monitors()
    {
        var list = new List<Mon>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate (IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) {
            var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            GetMonitorInfo(h, ref mi);
            uint dx = 96, dy = 96; try { GetDpiForMonitor(h, 0, out dx, out dy); } catch { }
            var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            EnumDisplaySettingsEx(mi.szDevice, -1, ref dm, 0);
            list.Add(new Mon { Device = mi.szDevice, X = mi.rcMonitor.L, Y = mi.rcMonitor.T, W = mi.rcMonitor.R - mi.rcMonitor.L, H = mi.rcMonitor.B - mi.rcMonitor.T,
                Dpi = (int)dx, Primary = (mi.dwFlags & 1) != 0, Orientation = dm.dmDisplayOrientation, Hz = dm.dmDisplayFrequency });
            return true;
        }, IntPtr.Zero);
        return list;
    }
    // Wiederholrate des Hauptbildschirms in Hz (-1 = nicht lesbar), fuer das FPS-Ziel (15.11.)
    public static int PrimaryHz()
    {
        try { foreach (var m in Monitors()) if (m.Primary) return m.Hz > 1 ? m.Hz : -1; } catch { }
        return -1;
    }

    // ------------------------------------------------------------ NVIDIA-Bildratenbegrenzung „Max Frame Rate“ (Treiberprofil; setzt auch die NVIDIA App), 15.11.
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr NvQI(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvInitFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvCreateFn(out IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvSessFn(IntPtr s);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvProfFn(IntPtr s, out IntPtr p);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NvGetSetFn(IntPtr s, IntPtr p, uint id, IntPtr setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Unicode)] delegate int NvFindAppFn(IntPtr s, [MarshalAs(UnmanagedType.LPWStr)] string app, out IntPtr p, IntPtr appInfo);
    static T NvFn<T>(uint id) where T : class { IntPtr f = NvQI(id); return f == IntPtr.Zero ? null : (Marshal.GetDelegateForFunctionPointer(f, typeof(T)) as T); }
    static void NvZero(IntPtr p, int n) { Marshal.Copy(new byte[n], 0, p, n); }
    public static string NvCapInfo = "";
    // >0 = Begrenzung in fps, 0 = aus, -1 = nicht lesbar (kein NVIDIA-Treiber o. ae.). exe: Spielprofil zuerst (z. B. "bf6.exe"), sonst globales Profil.
    public static int NvFrameCap(string exe)
    {
        const uint FRL = 0x10835002; const int SZ = 12320; const int CUR = 8220; const int ASZ = 16396;
        IntPtr s = IntPtr.Zero, buf = IntPtr.Zero, app = IntPtr.Zero; NvSessFn destroy = null;
        try {
            var init = NvFn<NvInitFn>(0x0150E828u); if (init == null || init() != 0) { NvCapInfo = "NVAPI nicht verfuegbar"; return -1; }
            var create = NvFn<NvCreateFn>(0x0694D52Eu); var load = NvFn<NvSessFn>(0x375DBD6Bu); destroy = NvFn<NvSessFn>(0xDAD9CFF8u);
            var glob = NvFn<NvProfFn>(0x617BFF9Fu); var get = NvFn<NvGetSetFn>(0x73BF8338u); var find = NvFn<NvFindAppFn>(0xEEE566B2u);
            if (create == null || load == null || glob == null || get == null) { NvCapInfo = "DRS nicht verfuegbar"; return -1; }
            if (create(out s) != 0) { NvCapInfo = "DRS-Sitzung"; return -1; }
            if (load(s) != 0) { NvCapInfo = "DRS laden"; return -1; }
            buf = Marshal.AllocHGlobal(SZ);
            if (find != null && !string.IsNullOrEmpty(exe)) {
                app = Marshal.AllocHGlobal(ASZ + 8192); NvZero(app, ASZ + 8192); Marshal.WriteInt32(app, 0, ASZ | (3 << 16));
                IntPtr ap;
                if (find(s, exe, out ap, app) == 0 && ap != IntPtr.Zero) {
                    NvZero(buf, SZ); Marshal.WriteInt32(buf, 0, SZ | (1 << 16));
                    if (get(s, ap, FRL, buf) == 0) { int va = Marshal.ReadInt32(buf, CUR); NvCapInfo = "Spielprofil " + exe; return va < 0 ? 0 : va; }
                }
            }
            IntPtr gp; if (glob(s, out gp) != 0) { NvCapInfo = "globales Profil"; return -1; }
            NvZero(buf, SZ); Marshal.WriteInt32(buf, 0, SZ | (1 << 16));
            int r = get(s, gp, FRL, buf);
            if (r == 0) { int vg = Marshal.ReadInt32(buf, CUR); NvCapInfo = "global"; return vg < 0 ? 0 : vg; }
            if (r == -160) { NvCapInfo = "global, nicht gesetzt"; return 0; }   // NVAPI_SETTING_NOT_FOUND
            NvCapInfo = "Lesefehler " + r; return -1;
        } catch (Exception e) { NvCapInfo = e.GetType().Name; return -1; }
        finally {
            if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf);
            if (app != IntPtr.Zero) Marshal.FreeHGlobal(app);
            if (s != IntPtr.Zero && destroy != null) { try { destroy(s); } catch { } }
        }
    }
    // Der Deck-Bildschirm: bevorzugt der genannte Monitor, sonst der erste, der nicht Hauptbildschirm ist.
    // Ohne Vorgabe: der kleinste Bildschirm, der nicht Hauptbildschirm ist (typisch: Zusatzdisplay wie CX133 oder Xeneon Edge).
    public static Mon DeckMonitor(string device)
    {
        Mon fallback = null;
        foreach (var m in Monitors()) {
            if (!string.IsNullOrEmpty(device) && string.Equals(m.Device, device, StringComparison.OrdinalIgnoreCase)) return m;
            if (!m.Primary && (fallback == null || (long)m.W * m.H < (long)fallback.W * fallback.H)) fallback = m;
        }
        return fallback;
    }

    // ------------------------------------------------------------ DeckOS: Helligkeit per DDC/CI (-1 = nicht verfuegbar)
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct PHYSMON { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string d; }
    [StructLayout(LayoutKind.Sequential)] public struct POINTL { public int X; public int Y; }
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hm, out uint n);
    [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hm, uint n, [Out] PHYSMON[] a);
    [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PHYSMON[] a);
    [DllImport("dxva2.dll")] static extern bool GetMonitorBrightness(IntPtr h, out uint mn, out uint cur, out uint mx);
    [DllImport("dxva2.dll")] static extern bool SetMonitorBrightness(IntPtr h, uint v);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINTL p, uint f);
    public static int Brightness(string device, int set)
    {
        var m = DeckMonitor(device); if (m == null) return -1;
        IntPtr hm = MonitorFromPoint(new POINTL { X = m.X + m.W / 2, Y = m.Y + m.H / 2 }, 0); if (hm == IntPtr.Zero) return -1;
        uint n; if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) || n == 0) return -1;
        var a = new PHYSMON[n]; if (!GetPhysicalMonitorsFromHMONITOR(hm, n, a)) return -1;
        try {
            uint mn, cur, mx;
            if (!GetMonitorBrightness(a[0].h, out mn, out cur, out mx) || mx <= mn) return -1;
            if (set >= 0) { uint v = mn + (uint)((mx - mn) * Math.Min(100, set) / 100); return SetMonitorBrightness(a[0].h, v) ? set : -1; }
            return (int)Math.Round(100.0 * (cur - mn) / (mx - mn));
        } finally { DestroyPhysicalMonitors(n, a); }
    }

    // ------------------------------------------------------------ DeckOS: Xbox-Controller (XInput)
    [StructLayout(LayoutKind.Sequential)] struct XPAD { public ushort wButtons; public byte bLT, bRT; public short sLX, sLY, sRX, sRY; }
    [StructLayout(LayoutKind.Sequential)] struct XSTATE { public uint dwPacket; public XPAD pad; }
    [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint i, out XSTATE s);
    static int padSlot = -1;
    // Tasten-Bitmaske des ersten verbundenen Controllers, linker Stick als Steuerkreuz (0x10000 links, 0x20000 rechts, 0x40000 oben, 0x80000 unten); -1 = keiner
    public static int PadButtons()
    {
        for (int n = 0; n < 4; n++) {
            uint i = (uint)(padSlot >= 0 ? (padSlot + n) % 4 : n);
            XSTATE st;
            if (XInputGetState(i, out st) != 0) continue;
            padSlot = (int)i;
            int b = st.pad.wButtons;
            if (st.pad.sLX < -16000) b |= 0x10000; if (st.pad.sLX > 16000) b |= 0x20000;
            if (st.pad.sLY > 16000) b |= 0x40000; if (st.pad.sLY < -16000) b |= 0x80000;
            if (st.pad.sRY > 16000) b |= 0x100000; if (st.pad.sRY < -16000) b |= 0x200000;   // rechter Stick hoch/runter
            return b;
        }
        padSlot = -1; return -1;
    }
    [StructLayout(LayoutKind.Sequential)] struct XBATT { public byte Type; public byte Level; }
    [DllImport("xinput1_4.dll")] static extern uint XInputGetBatteryInformation(uint i, byte devType, out XBATT b);
    public static string PadBatteryRaw = "";
    // Akku des verbundenen Controllers: -1 keiner, -2 verbunden aber Akkustand nicht lesbar, 100 + Stufe (0 leer .. 3 voll), 200 = per Kabel
    public static int PadBattery()
    {
        if (padSlot < 0) return -1;
        XBATT b; uint r = XInputGetBatteryInformation((uint)padSlot, 0, out b);
        PadBatteryRaw = "Slot " + padSlot + ", Rueckgabe " + r + ", Typ " + b.Type + ", Stufe " + b.Level;
        if (r != 0) return -2;
        if (b.Type == 1) return 200;           // per Kabel
        if (b.Type == 2 || b.Type == 3) return 100 + Math.Min((int)b.Level, 3);
        return -2;                             // Typ 0/unbekannt: Treiber liefert keinen Akkustand (z. B. Bluetooth)
    }

    // ------------------------------------------------------------ Game-safe Touch (an "Nur Touch" gekoppelt)
    // 1) Fokus-Schutz: Deck-Fenster samt WebView2-Kindfenstern nicht aktivierbar (WS_EX_NOACTIVATE) - Touch geht weiter,
    //    das Spiel bzw. das Vordergrundfenster behaelt den Fokus; rutscht doch eine Aktivierung durch, Fokus sofort zurueck.
    // 2) Cursor-Rueckholung: Windows setzt den Mauszeiger beim Tippen auf den Touchpunkt; nach dem Tippen zurueck an die alte Stelle.
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, WndEnumProc cb, IntPtr l);
    static IntPtr guardLastFg = IntPtr.Zero; static bool guardOn; static int guardTick;
    static bool SetNoAct(IntPtr h, IntPtr on)
    {
        long ex = GetWindowLongPtr(h, -20).ToInt64();
        long nx = on != IntPtr.Zero ? (ex | 0x08000000L) : (ex & ~0x08000000L);
        if (nx != ex) SetWindowLongPtr(h, -20, new IntPtr(nx));
        return true;
    }
    static readonly WndEnumProc noActCb = SetNoAct;
    static void ApplyNoAct(IntPtr deck, bool on) { SetNoAct(deck, on ? new IntPtr(1) : IntPtr.Zero); EnumChildWindows(deck, noActCb, on ? new IntPtr(1) : IntPtr.Zero); }
    // Rueckgabe: 0 nichts, 1 Schutz eingeschaltet, 2 ausgeschaltet, 3 Fokus an das vorherige Fenster zurueckgegeben
    public static int FocusGuard(IntPtr deck, bool armed)
    {
        if (deck == IntPtr.Zero) return 0;
        IntPtr fg = GetForegroundWindow();
        bool fgDeck = fg != IntPtr.Zero && (fg == deck || GetAncestor(fg, 2) == deck);
        if (fg != IntPtr.Zero && !fgDeck) guardLastFg = fg;
        int r = 0;
        if (armed != guardOn) { ApplyNoAct(deck, armed); guardOn = armed; guardTick = 0; r = armed ? 1 : 2; }
        else if (armed && ++guardTick % 120 == 0) ApplyNoAct(deck, true);   // spaet erzeugte WebView2-Kindfenster nachziehen
        if (armed && fgDeck && guardLastFg != IntPtr.Zero && IsWindow(guardLastFg)) { SetForegroundWindow(guardLastFg); r = 3; }
        return r;
    }
    // Cursor: letzte Positionen ausserhalb des Decks mit Zeitstempel (Ringpuffer)
    static readonly int[] curX = new int[32], curY = new int[32]; static readonly long[] curT = new long[32]; static int curN;
    static int savedX, savedY; static bool savedOk;
    public static void CursorSample(IntPtr deck)
    {
        PT p; if (!GetCursorPos(out p)) return;
        RECT r; if (deck != IntPtr.Zero && GetWindowRect(deck, out r) && p.X >= r.L && p.X < r.R && p.Y >= r.T && p.Y < r.B) return;
        int i = curN++ % 32; curX[i] = p.X; curY[i] = p.Y; curT[i] = Environment.TickCount;
    }
    // Touch beginnt: Position von vor dem Tippen merken (juengste Probe, die mind. 80 ms alt ist - der Sprung zum Touchpunkt ist juenger)
    public static void CursorFreeze()
    {
        long now = Environment.TickCount; savedOk = false;
        for (int k = 1; k <= Math.Min(curN, 32); k++) {
            int i = (curN - k) % 32; if (i < 0) i += 32;
            if (now - curT[i] >= 80) { savedX = curX[i]; savedY = curY[i]; savedOk = true; return; }
        }
    }
    // Touch endet: Zeiger zurueck, falls er sich bewegt hat
    public static bool CursorRestore()
    {
        if (!savedOk) return false;
        PT p; if (!GetCursorPos(out p)) return false;
        if (p.X == savedX && p.Y == savedY) return false;
        return SetCursorPos(savedX, savedY);
    }

    // Zertifikat nur fuer Verbindungen zum eigenen PC (127.0.0.1/localhost) akzeptieren, z. B. SteelSeries-GG-Engine mit selbst signiertem Zertifikat
    public static readonly System.Net.Security.RemoteCertificateValidationCallback LoopbackCert = delegate (object sender, System.Security.Cryptography.X509Certificates.X509Certificate c, System.Security.Cryptography.X509Certificates.X509Chain ch, System.Net.Security.SslPolicyErrors e) {
        var r = sender as System.Net.HttpWebRequest; return r != null && r.RequestUri.IsLoopback;
    };
    // ------------------------------------------------------------ Corsair iCUE SDK v4: Akkustand von Funkgeraeten (nur lesen)
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibraryW(string path);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void CueStateHandler(IntPtr ctx, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] struct CueFilter { public int mask; }
    [StructLayout(LayoutKind.Sequential)] struct CueDevInfo {
        public int type;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)] public byte[] id;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)] public byte[] serial;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)] public byte[] model;
        public int ledCount; public int channelCount;
    }
    [StructLayout(LayoutKind.Explicit, Size = 24)] struct CueProp { [FieldOffset(0)] public int type; [FieldOffset(8)] public int i32; [FieldOffset(8)] public double f64; [FieldOffset(8)] public byte b; }
    [DllImport("iCUESDK.x64_2019.dll", CallingConvention = CallingConvention.Cdecl)] static extern int CorsairConnect(CueStateHandler h, IntPtr ctx);
    [DllImport("iCUESDK.x64_2019.dll", CallingConvention = CallingConvention.Cdecl)] static extern int CorsairGetDevices(ref CueFilter f, int sizeMax, [Out] CueDevInfo[] devices, out int size);
    [DllImport("iCUESDK.x64_2019.dll", CallingConvention = CallingConvention.Cdecl)] static extern int CorsairReadDeviceProperty(byte[] deviceId, int propertyId, uint index, out CueProp prop);
    static CueStateHandler cueHandler; static volatile int cueState = -1; static bool cueStarted; static string cueErr = ""; static int cueWaits;
    public static string CueDiag = "";
    static void CueOnState(IntPtr ctx, IntPtr data) { if (data != IntPtr.Zero) cueState = Marshal.ReadInt32(data); }
    static string CStr(byte[] b) { int n = Array.IndexOf(b, (byte)0); if (n < 0) n = b.Length; return Encoding.UTF8.GetString(b, 0, n); }
    // Ergebnis: "Typ|Modell|Prozent;..." (Typ: kb, mouse, headset), "WAIT" waehrend des Verbindens, "ERR:..." bei Fehler
    public static string IcueBatteries(string dllPath)
    {
        try {
            if (!cueStarted) {
                if (!System.IO.File.Exists(dllPath)) return "ERR:iCUE-SDK-DLL fehlt";
                if (LoadLibraryW(dllPath) == IntPtr.Zero) return "ERR:iCUE-SDK nicht ladbar (" + Marshal.GetLastWin32Error() + ")";
                cueHandler = CueOnState; cueStarted = true;
                int rc = CorsairConnect(cueHandler, IntPtr.Zero);
                if (rc != 0) { cueErr = "Connect " + rc; return "ERR:" + cueErr; }
            }
            if (cueState != 6) { cueWaits++; if (cueWaits > 3) return "ERR:keine Verbindung (Status " + cueState + "; 4 = abgelehnt -> SDK in iCUE freigeben, 3 = iCUE laeuft nicht)"; return "WAIT"; }
            var f = new CueFilter { mask = 0x0001 | 0x0002 | 0x0008 | 0x1000 };
            var arr = new CueDevInfo[16]; int n;
            int r = CorsairGetDevices(ref f, arr.Length, arr, out n); if (r != 0) return "ERR:GetDevices " + r;
            var sb = new StringBuilder(); var diag = new StringBuilder();
            for (int i = 0; i < n && i < arr.Length; i++) {
                CueProp p; int pr = CorsairReadDeviceProperty(arr[i].id, 9 /* CDPI_BatteryLevel */, 0, out p);
                diag.Append(CStr(arr[i].model)).Append(" (Typ ").Append(arr[i].type).Append(", Akku-Abfrage ").Append(pr).Append(pr == 0 ? ", Datentyp " + p.type + ", Wert " + (p.type == 2 ? p.f64.ToString() : p.i32.ToString()) : "").Append("); ");
                if (pr != 0) continue;
                int pct = p.type == 1 ? p.i32 : p.type == 2 ? (int)Math.Round(p.f64) : -1; if (pct < 0 || pct > 100) continue;
                string t = arr[i].type == 1 ? "kb" : arr[i].type == 2 ? "mouse" : arr[i].type == 8 ? "headset" : "other";
                sb.Append(t).Append('|').Append(CStr(arr[i].model).Replace("|", " ").Replace(";", " ")).Append('|').Append(pct).Append(';');
            }
            CueDiag = n + " Geraet(e): " + diag.ToString();
            return sb.ToString();
        } catch (Exception e) { return "ERR:" + e.Message; }
    }

    // ------------------------------------------------------------ WhatsApp-Hinweise: Windows-Benachrichtigungsdatenbank nur lesen (nur Anzahl, kein Inhalt)
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open_v2")] static extern int SqOpen(byte[] file, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close_v2")] static extern int SqClose(IntPtr db);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_busy_timeout")] static extern int SqBusy(IntPtr db, int ms);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare_v2")] static extern int SqPrep(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step")] static extern int SqStep(IntPtr st);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize")] static extern int SqFin(IntPtr st);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_int64")] static extern long SqI64(IntPtr st, int c);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_text")] static extern IntPtr SqText(IntPtr st, int c);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_bytes")] static extern int SqBytes(IntPtr st, int c);
    static byte[] U8(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
    // Ergebnis: "neu|hoechsteId|AppId|gesamt" oder "ERR:..."; zaehlt WhatsApp-Toasts im Info-Center mit Id > ack
    public static string WaPoll(long ack) { return AppPoll("WhatsApp", ack); }
    // Anzahl neuer Windows-Benachrichtigungen einer App (nur Zaehler, kein Inhalt); name ohne Sonderzeichen
    public static string AppPoll(string name, long ack)
    {
        name = System.Text.RegularExpressions.Regex.Replace(name ?? "", "[^A-Za-z0-9 ._-]", "");
        string path = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) + "\\Microsoft\\Windows\\Notifications\\wpndatabase.db";
        if (!System.IO.File.Exists(path)) return "ERR:Datenbank fehlt";
        IntPtr db; int rc = SqOpen(U8(path), out db, 1 /* READONLY */, IntPtr.Zero);
        if (rc != 0) { if (db != IntPtr.Zero) SqClose(db); return "ERR:open " + rc; }
        try {
            SqBusy(db, 300);
            IntPtr st; rc = SqPrep(db, U8("SELECT n.Id, h.PrimaryId FROM Notification n JOIN NotificationHandler h ON n.HandlerId = h.RecordId WHERE h.PrimaryId LIKE '%" + name + "%' AND n.Type = 'toast'"), -1, out st, IntPtr.Zero);
            if (rc != 0) return "ERR:prepare " + rc;
            long max = 0; int fresh = 0, total = 0; string app = "";
            try {
                while ((rc = SqStep(st)) == 100) {
                    long id = SqI64(st, 0); total++;
                    if (id > ack) fresh++;
                    if (id > max) max = id;
                    if (app.Length == 0) { IntPtr t = SqText(st, 1); int n = SqBytes(st, 1); if (t != IntPtr.Zero && n > 0) { var bb = new byte[n]; Marshal.Copy(t, bb, 0, n); app = Encoding.UTF8.GetString(bb); } }
                }
                if (rc != 101) return "ERR:step " + rc;
            } finally { SqFin(st); }
            if (app.Length == 0) {   // keine Toasts: App-Id trotzdem ermitteln (zum Oeffnen)
                if (SqPrep(db, U8("SELECT PrimaryId FROM NotificationHandler WHERE PrimaryId LIKE '%" + name + "%' LIMIT 1"), -1, out st, IntPtr.Zero) == 0) {
                    try { if (SqStep(st) == 100) { IntPtr t = SqText(st, 0); int n = SqBytes(st, 0); if (t != IntPtr.Zero && n > 0) { var bb = new byte[n]; Marshal.Copy(t, bb, 0, n); app = Encoding.UTF8.GetString(bb); } } } finally { SqFin(st); }
                }
            }
            return fresh + "|" + max + "|" + app.Replace("|", "") + "|" + total;
        } finally { SqClose(db); }
    }

    // ------------------------------------------------------------ Nur Touch: Mauszeiger vom Deck-Monitor fernhalten
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern bool ClipCursor(ref RECT r);
    [DllImport("user32.dll", EntryPoint = "ClipCursor")] static extern bool ClipCursorOff(IntPtr p);
    [DllImport("user32.dll")] static extern bool GetClipCursor(out RECT r);
    static RECT ownClip; static bool ownActive;
    static bool Same(RECT a, RECT b) { return a.L == b.L && a.T == b.T && a.R == b.R && a.B == b.B; }
    // 0 = nichts zu tun, 1 = Begrenzung gesetzt, 2 = fremde Begrenzung (z. B. Spiel) bleibt unangetastet, 3 = aufgehoben
    public static int KeepMouseOff(string device, bool on)
    {
        RECT cur; GetClipCursor(out cur);
        bool mine = ownActive && Same(cur, ownClip);
        if (!on) { ownActive = false; if (mine) { ClipCursorOff(IntPtr.Zero); return 3; } return 0; }
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        bool free = cur.L <= vx && cur.T <= vy && cur.R >= vx + vw && cur.B >= vy + vh;
        if (!free && !mine) return 2;
        var deck = DeckMonitor(device); if (deck == null) return 0;
        var r = new RECT { L = int.MaxValue, T = int.MaxValue, R = int.MinValue, B = int.MinValue }; bool any = false;
        foreach (var m in Monitors()) {
            if (string.Equals(m.Device, deck.Device, StringComparison.OrdinalIgnoreCase)) continue;
            any = true; r.L = Math.Min(r.L, m.X); r.T = Math.Min(r.T, m.Y); r.R = Math.Max(r.R, m.X + m.W); r.B = Math.Max(r.B, m.Y + m.H);
        }
        if (!any) return 0;
        if (mine && Same(cur, r)) return 0;
        ClipCursor(ref r); ownClip = r; ownActive = true; return 1;
    }

    // ------------------------------------------------------------ Fenster
    const uint SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_NOOWNERZORDER = 0x200;
    // ------------------------------------------------------------ Durchscheinender Hintergrund (DWM-Unschaerfe)
    [StructLayout(LayoutKind.Sequential)] struct ACCENT { public int State; public int Flags; public uint Color; public int Anim; }
    [StructLayout(LayoutKind.Sequential)] struct WCADATA { public int Attr; public IntPtr Data; public int Size; }
    [StructLayout(LayoutKind.Sequential)] struct MARGINS { public int L; public int R; public int T; public int B; }
    [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr h, ref WCADATA d);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    // mode 0 = aus, 1 = leichte Unschaerfe (Blur-Behind), 2 = starke Unschaerfe (Acrylic), 3 = keine Unschaerfe
    public static int SetBackdrop(IntPtr h, int mode)
    {
        var m = new MARGINS();
        if (mode > 0) { m.L = -1; m.R = -1; m.T = -1; m.B = -1; }
        int r1 = DwmExtendFrameIntoClientArea(h, ref m);
        int dark = 1; DwmSetWindowAttribute(h, 20, ref dark, 4);
        var a = new ACCENT();
        // 3 = keine Unschaerfe: klar durchsichtig (transparenter Verlauf)
        a.State = mode == 0 ? 0 : mode == 1 ? 3 : mode == 2 ? 4 : 2;
        a.Flags = mode >= 2 ? 2 : 0;
        a.Color = mode == 2 ? 0x18000000u : mode == 3 ? 0x01000000u : 0u;
        int size = Marshal.SizeOf(typeof(ACCENT));
        IntPtr p = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(a, p, false);
            var d = new WCADATA(); d.Attr = 19; d.Data = p; d.Size = size;
            int r2 = SetWindowCompositionAttribute(h, ref d);
            return r1 == 0 && r2 != 0 ? 1 : 0;
        } finally { Marshal.FreeHGlobal(p); }
    }

    public static void MakeToolNoActivate(IntPtr h)
    {
        long ex = GetWindowLongPtr(h, -20).ToInt64();
        ex |= 0x80 | 0x08000000;           // WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
        ex &= ~0x40000L;                   // kein WS_EX_APPWINDOW
        SetWindowLongPtr(h, -20, new IntPtr(ex));
    }
    public static bool MoveTo(IntPtr h, int x, int y, int w, int hh)
    {
        RECT r; GetWindowRect(h, out r);
        if (Math.Abs(r.L - x) <= 1 && Math.Abs(r.T - y) <= 1 && Math.Abs(r.R - r.L - w) <= 1 && Math.Abs(r.B - r.T - hh) <= 1) return false;
        SetWindowPos(h, IntPtr.Zero, x, y, w, hh, SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        return true;
    }
    public static bool MouseDown() { return (GetAsyncKeyState(0x01) & 0x8000) != 0; }
    // Pipette: naechster Linksklick irgendwo auf dem Bildschirm liefert die Pixelfarbe unter dem Mauszeiger
    [StructLayout(LayoutKind.Sequential)] struct PT { public int X; public int Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out PT p);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);
    static bool eyeWasDown;
    public static void EyeReset() { eyeWasDown = MouseDown(); }
    public static string EyePoll()
    {
        bool down = MouseDown();
        if (eyeWasDown && !down) {
            eyeWasDown = false;
            PT p; GetCursorPos(out p);
            IntPtr dc = GetDC(IntPtr.Zero);
            uint c = GetPixel(dc, p.X, p.Y);
            ReleaseDC(IntPtr.Zero, dc);
            if (c == 0xFFFFFFFF) return null;
            return string.Format("#{0:X2}{1:X2}{2:X2}", c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF);
        }
        eyeWasDown = down;
        return null;
    }
    public static bool Alive(IntPtr h) { return h != IntPtr.Zero && IsWindow(h); }

    // ------------------------------------------------------------ Discord
    // Hauptfenster der Discord-App (Chromium-Fenster mit "Discord" im Titel, ohne Besitzer).
    public static IntPtr FindDiscord()
    {
        var pids = new List<uint>();
        foreach (var name in new[] { "Discord", "DiscordPTB", "DiscordCanary" })
            foreach (var p in Process.GetProcessesByName(name)) { pids.Add((uint)p.Id); p.Dispose(); }
        if (pids.Count == 0) return IntPtr.Zero;
        IntPtr best = IntPtr.Zero; long bestScore = -1;
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (!pids.Contains(pid)) return true;
            if (GetWindow(h, 4) != IntPtr.Zero) return true;
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            if (c.ToString() != "Chrome_WidgetWin_1") return true;
            var t = new StringBuilder(512); GetWindowText(h, t, 512);
            if (t.ToString().IndexOf("Discord", StringComparison.OrdinalIgnoreCase) < 0) return true;
            RECT r; GetWindowRect(h, out r);
            long score = (long)(r.R - r.L) * (r.B - r.T) + (IsWindowVisible(h) ? 1000000000L : 0);
            if (score > bestScore) { best = h; bestScore = score; }
            return true;
        }, IntPtr.Zero);
        return best;
    }
    // 0 = kein Fenster oder nur im Infobereich, 1 = offen, 2 = minimiert
    public static int WindowState(IntPtr h)
    {
        if (!Alive(h) || !IsWindowVisible(h)) return 0;
        return IsIconic(h) ? 2 : 1;
    }
    // Setzt ein fremdes Fenster so, dass sein sichtbarer Rahmen genau im Zielrechteck liegt. Holt keinen Fokus.
    public static bool Place(IntPtr h, int x, int y, int w, int hh)
    {
        if (!Alive(h)) return false;
        if (IsZoomed(h)) { ShowWindow(h, 4); }     // SW_SHOWNOACTIVATE: aus Vollbild loesen
        RECT wr, fr; GetWindowRect(h, out wr);
        if (DwmGetWindowAttribute(h, 9, out fr, Marshal.SizeOf(typeof(RECT))) != 0) fr = wr;
        int dl = fr.L - wr.L, dt = fr.T - wr.T, dr = wr.R - fr.R, db = wr.B - fr.B;
        return MoveTo(h, x - dl, y - dt, w + dl + dr, hh + dt + db);
    }
    public static string Title(IntPtr h) { var t = new StringBuilder(512); GetWindowText(h, t, 512); return t.ToString(); }

    // ------------------------------------------------------------ Hotkeys (eigenes Nachrichtenfenster, Abholung per Timer)
    static readonly ConcurrentQueue<int> Keys = new ConcurrentQueue<int>();
    static WndProcD procKeep; static IntPtr msgWnd = IntPtr.Zero;
    static IntPtr Proc(IntPtr h, uint m, IntPtr w, IntPtr l)
    {
        if (m == 0x0312) { Keys.Enqueue(w.ToInt32()); return IntPtr.Zero; }
        return DefWindowProcW(h, m, w, l);
    }
    // Registriert Strg+Alt+<Taste> fuer jede Taste; liefert die Tasten, die schon belegt waren.
    public static string RegisterHotkeys(string letters)
    {
        if (msgWnd == IntPtr.Zero) {
            procKeep = Proc;
            var wc = new WNDCLASS { lpfnWndProc = Marshal.GetFunctionPointerForDelegate(procKeep), hInstance = GetModuleHandle(null), lpszClassName = "GameShelfDeckHotkeys" };
            RegisterClassW(ref wc);
            msgWnd = CreateWindowExW(0, "GameShelfDeckHotkeys", "", 0, 0, 0, 0, 0, new IntPtr(-3), IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        }
        var failed = new StringBuilder();
        foreach (char ch in letters.ToUpperInvariant()) {
            uint vk = ch;
            if (!RegisterHotKey(msgWnd, (int)vk, 0x0001 | 0x0002 | 0x4000, vk)) failed.Append(ch);   // ALT | CTRL | NOREPEAT
        }
        return failed.ToString();
    }
    public static void UnregisterHotkeys(string letters)
    {
        if (msgWnd == IntPtr.Zero) return;
        foreach (char ch in letters.ToUpperInvariant()) UnregisterHotKey(msgWnd, ch);
        DestroyWindow(msgWnd); msgWnd = IntPtr.Zero;
    }
    public static int NextHotkey() { int v; return Keys.TryDequeue(out v) ? v : 0; }

    // ------------------------------------------------------------ Afterburner (MAHM) und RTSS
    public static Dictionary<string, double> ReadMahm()
    {
        try {
            using (var mm = MemoryMappedFile.OpenExisting("MAHMSharedMemory", MemoryMappedFileRights.Read))
            using (var a = mm.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
                if (a.ReadUInt32(0) != 0x4D41484D) return null;
                uint hdr = a.ReadUInt32(8), n = a.ReadUInt32(12), es = a.ReadUInt32(16);
                var d = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
                var buf = new byte[260];
                for (uint i = 0; i < n && i < 512; i++) {
                    long off = hdr + (long)i * es;
                    a.ReadArray(off, buf, 0, 260);
                    int z = Array.IndexOf(buf, (byte)0); if (z < 0) z = 260;
                    string name = Encoding.Default.GetString(buf, 0, z);
                    float v = a.ReadSingle(off + 1300);
                    if (!float.IsNaN(v) && v < 1e30f && !d.ContainsKey(name)) d[name] = v;
                }
                return d;
            }
        } catch { return null; }
    }
    public static int RtssTop(out double fps) { double ft; return RtssApp(out fps, out ft); }
    public static bool RtssPresent() { return RtssStatus() == "ok"; }
    // "ok", "fehlt" (RTSS laeuft nicht) oder "kein Zugriff" (RTSS laeuft mit anderen Rechten)
    public static string RtssStatus()
    {
        try { using (var mm = MemoryMappedFile.OpenExisting("RTSSSharedMemoryV2", MemoryMappedFileRights.Read)) return "ok"; }
        catch (System.IO.FileNotFoundException) { return "fehlt"; }
        catch (UnauthorizedAccessException) { return "kein Zugriff"; }
        catch (Exception e) { return e.GetType().Name; }
    }
    // Aktivste 3D-Anwendung laut RTSS: Prozess-ID, Bildrate und letzte Frametime in ms (0, wenn keine).
    public static int RtssApp(out double fps, out double frametimeMs)
    {
        fps = 0; frametimeMs = 0; int best = 0;
        try {
            using (var mm = MemoryMappedFile.OpenExisting("RTSSSharedMemoryV2", MemoryMappedFileRights.Read))
            using (var a = mm.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
                uint esz = a.ReadUInt32(8), aoff = a.ReadUInt32(12), an = a.ReadUInt32(16);
                for (uint i = 0; i < an && i < 256; i++) {
                    long off = aoff + (long)i * esz;
                    uint pid = a.ReadUInt32(off); if (pid == 0) continue;
                    uint t0 = a.ReadUInt32(off + 268), t1 = a.ReadUInt32(off + 272), fr = a.ReadUInt32(off + 276);
                    double f = t1 > t0 ? 1000.0 * fr / (t1 - t0) : 0;
                    if (f > fps) { fps = f; best = (int)pid; frametimeMs = a.ReadUInt32(off + 280) / 1000.0; }
                }
            }
        } catch { }
        return best;
    }

    // ------------------------------------------------------------ Bildschirm drehen (quer <-> hochkant)
    public static int Rotate(string device)
    {
        var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettingsEx(device, -1, ref dm, 0)) return -99;
        bool portrait = dm.dmDisplayOrientation == 1 || dm.dmDisplayOrientation == 3;
        int target = portrait ? 0 : (dm.dmDisplayOrientation == 2 ? 3 : 1);
        int w = dm.dmPelsWidth; dm.dmPelsWidth = dm.dmPelsHeight; dm.dmPelsHeight = w;
        dm.dmDisplayOrientation = target;
        dm.dmFields = 0x80 | 0x80000 | 0x100000;     // ORIENTATION | PELSWIDTH | PELSHEIGHT
        return ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, 0x01, IntPtr.Zero);  // CDS_UPDATEREGISTRY
    }
    // ------------------------------------------------------------ Lautstaerke je Anwendung (Windows-Audiositzungen)
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { [PreserveSig] int EnumAudioEndpoints(int f, int s, out IntPtr c); [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice d); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 { [PreserveSig] int GetAudioSessionControl(IntPtr g, int f, out IntPtr c); [PreserveSig] int GetSimpleAudioVolume(IntPtr g, int f, out IntPtr v); [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e); }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator { [PreserveSig] int GetCount(out int c); [PreserveSig] int GetSession(int i, out IAudioSessionControl2 s); }
    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int s); [PreserveSig] int GetDisplayName(out IntPtr n); [PreserveSig] int SetDisplayName(IntPtr v, IntPtr g);
        [PreserveSig] int GetIconPath(out IntPtr p); [PreserveSig] int SetIconPath(IntPtr v, IntPtr g); [PreserveSig] int GetGroupingParam(out Guid g); [PreserveSig] int SetGroupingParam(IntPtr o, IntPtr g);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr n); [PreserveSig] int UnregisterAudioSessionNotification(IntPtr n);
        [PreserveSig] int GetSessionIdentifier(out IntPtr s); [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr s); [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession(); [PreserveSig] int SetDuckingPreference(bool o);
    }
    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume { [PreserveSig] int SetMasterVolume(float l, ref Guid c); [PreserveSig] int GetMasterVolume(out float l); [PreserveSig] int SetMute(bool m, ref Guid c); [PreserveSig] int GetMute(out bool m); }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr n); [PreserveSig] int UnregisterControlChangeNotify(IntPtr n); [PreserveSig] int GetChannelCount(out uint c);
        [PreserveSig] int SetMasterVolumeLevel(float l, ref Guid g); [PreserveSig] int SetMasterVolumeLevelScalar(float l, ref Guid g);
        [PreserveSig] int GetMasterVolumeLevel(out float l); [PreserveSig] int GetMasterVolumeLevelScalar(out float l);
        [PreserveSig] int SetChannelVolumeLevel(uint c, float l, ref Guid g); [PreserveSig] int SetChannelVolumeLevelScalar(uint c, float l, ref Guid g);
        [PreserveSig] int GetChannelVolumeLevel(uint c, out float l); [PreserveSig] int GetChannelVolumeLevelScalar(uint c, out float l);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid g); [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
    }
    static IAudioEndpointVolume Endpoint(int flow, int role)
    {
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
        IMMDevice dev; if (en.GetDefaultAudioEndpoint(flow, role, out dev) != 0 || dev == null) return null;
        Guid iid = typeof(IAudioEndpointVolume).GUID; object o;
        if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return null;
        return o as IAudioEndpointVolume;
    }
    // DeckOS: Gesamtlautstaerke fuer die Lautstaerke-Anzeige. 0..100, +1000 wenn stumm, -1 = kein Geraet
    static IAudioEndpointVolume volEp;
    public static void VolumeReset() { volEp = null; }
    public static int MasterVolume()
    {
        try {
            if (volEp == null) volEp = Endpoint(0, 0);
            if (volEp == null) return -1;
            float l; if (volEp.GetMasterVolumeLevelScalar(out l) != 0) { volEp = null; return -1; }
            bool m; volEp.GetMute(out m);
            return (int)Math.Round(l * 100) + (m ? 1000 : 0);
        } catch { volEp = null; return -1; }
    }
    // DeckOS: systemweit stumm. flow 0 = Ausgabe (Ton), 1 = Mikrofon. set: -1 lesen, 0 aus, 1 an, 2 umschalten.
    // Rueckgabe 1 = stumm, 0 = nicht stumm, -1 = kein Geraet. Wirkt auf Standard- und Kommunikationsgeraet.
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { [PreserveSig] int GetCount(out uint n); [PreserveSig] int Item(uint i, out IMMDevice d); }
    // Alle aktiven Geraete einer Richtung (Mikrofone: auch wenn Discord/Spiel ein anderes als das Windows-Standardgeraet nutzen)
    static List<IAudioEndpointVolume> AllEndpoints(int flow)
    {
        var l = new List<IAudioEndpointVolume>();
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
        IntPtr pc; if (en.EnumAudioEndpoints(flow, 1, out pc) != 0 || pc == IntPtr.Zero) return l;
        var col = (IMMDeviceCollection)Marshal.GetObjectForIUnknown(pc); Marshal.Release(pc);
        uint n; col.GetCount(out n);
        for (uint i = 0; i < n; i++) {
            IMMDevice d; if (col.Item(i, out d) != 0 || d == null) continue;
            Guid iid = typeof(IAudioEndpointVolume).GUID; object o;
            if (d.Activate(ref iid, 23, IntPtr.Zero, out o) == 0 && o is IAudioEndpointVolume) l.Add((IAudioEndpointVolume)o);
        }
        return l;
    }
    public static int EndpointMute(int flow, int set)
    {
        try {
            // Ton: Standard-Ausgabe (Konsole + Kommunikation). Mikrofon: alle aktiven Aufnahmegeraete.
            var list = new List<IAudioEndpointVolume>();
            if (flow == 1) list = AllEndpoints(1);
            if (list.Count == 0) { var a0 = Endpoint(flow, 0); if (a0 != null) list.Add(a0); var a2 = Endpoint(flow, 2); if (a2 != null) list.Add(a2); }
            if (list.Count == 0) return -1;
            bool all = true; foreach (var e in list) { bool m; e.GetMute(out m); if (!m) all = false; }
            if (set < 0) return all ? 1 : 0;
            bool nm = set == 2 ? !all : set == 1; Guid g = Guid.Empty;
            foreach (var e in list) e.SetMute(nm, ref g);
            return nm ? 1 : 0;
        } catch { return -1; }
    }
    // Diagnose fuer das Log (deckos-179): Zustand der Standardgeraete und Zahl der aktiven Geraete
    public static string EndpointMuteDiag(int flow)
    {
        string s = "";
        try {
            for (int role = 0; role <= 2; role += 2) {
                var e = Endpoint(flow, role);
                if (e == null) { s += "Rolle" + role + "=keins "; continue; }
                bool m; int hr = e.GetMute(out m); float v; e.GetMasterVolumeLevelScalar(out v);
                s += "Rolle" + role + "=" + (m ? "stumm" : "an") + " hr" + hr + " vol" + (int)Math.Round(v * 100) + " ";
            }
            var all = AllEndpoints(flow); int mu = 0;
            foreach (var x in all) { bool m2; x.GetMute(out m2); if (m2) mu++; }
            s += "aktive=" + all.Count + " stumm=" + mu;
        } catch (Exception ex) { s += "Fehler " + ex.GetType().Name; }
        return s;
    }
    public class AudioSess { public int Pid; public string Name; public float Vol; public bool Mute; }
    static List<ISimpleAudioVolume> Volumes(Func<uint, bool> match, List<AudioSess> outList)
    {
        var res = new List<ISimpleAudioVolume>();
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
        IMMDevice dev; if (en.GetDefaultAudioEndpoint(0, 1, out dev) != 0) return res;
        Guid iid = typeof(IAudioSessionManager2).GUID; object o;
        if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return res;
        IAudioSessionEnumerator se; if (((IAudioSessionManager2)o).GetSessionEnumerator(out se) != 0) return res;
        int n; se.GetCount(out n);
        for (int i = 0; i < n; i++) {
            IAudioSessionControl2 c; if (se.GetSession(i, out c) != 0 || c == null) continue;
            uint pid; c.GetProcessId(out pid); if (pid == 0) continue;
            int state; c.GetState(out state); if (state == 2) continue;   // abgelaufene Sitzungen
            var v = c as ISimpleAudioVolume; if (v == null) continue;
            if (match != null && !match(pid)) continue;
            res.Add(v);
            if (outList != null) {
                float vol; bool mute; v.GetMasterVolume(out vol); v.GetMute(out mute);
                string name = ""; try { using (var p = Process.GetProcessById((int)pid)) name = p.ProcessName; } catch { }
                outList.Add(new AudioSess { Pid = (int)pid, Name = name, Vol = vol, Mute = mute });
            }
        }
        return res;
    }
    public static List<AudioSess> AudioSessions() { var l = new List<AudioSess>(); try { Volumes(null, l); } catch { } return l; }
    public static int SetVolume(int[] pids, float vol)
    {
        int c = 0; Guid g = Guid.Empty; var set = new HashSet<uint>(); foreach (int p in pids) set.Add((uint)p);
        try { foreach (var v in Volumes(delegate (uint pid) { return set.Contains(pid); }, null)) { v.SetMasterVolume(Math.Max(0f, Math.Min(1f, vol)), ref g); c++; } } catch { }
        return c;
    }
    public static int SetMute(int[] pids, bool mute)
    {
        int c = 0; Guid g = Guid.Empty; var set = new HashSet<uint>(); foreach (int p in pids) set.Add((uint)p);
        try { foreach (var v in Volumes(delegate (uint pid) { return set.Contains(pid); }, null)) { v.SetMute(mute, ref g); c++; } } catch { }
        return c;
    }

    // ------------------------------------------------------------ Tastenkombination senden (fuer Discords globale Kuerzel)
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    static uint Ext(int vk) { return (vk >= 0x21 && vk <= 0x2E) || vk == 0x5B || vk == 0x5C || (vk >= 0xA6 && vk <= 0xB7) ? 1u : 0u; }
    public static uint SendCombo(int[] vks)
    {
        var l = new List<INPUT>();
        // Mit Scancode und kurzer Haltezeit: Discord und andere globale Kuerzel werten Scancodes aus und verpassen sonst den Tastendruck.
        var down = new List<INPUT>(); var up = new List<INPUT>();
        foreach (int vk in vks) down.Add(new INPUT { type = 1, ki = new KEYBDINPUT { wVk = (ushort)vk, wScan = (ushort)MapVirtualKey((uint)vk, 0), dwFlags = Ext(vk) } });
        for (int i = vks.Length - 1; i >= 0; i--) up.Add(new INPUT { type = 1, ki = new KEYBDINPUT { wVk = (ushort)vks[i], wScan = (ushort)MapVirtualKey((uint)vks[i], 0), dwFlags = Ext(vks[i]) | 2 } });
        uint n = 0;
        foreach (var d in down) { n += SendInput(1, new[] { d }, Marshal.SizeOf(typeof(INPUT))); System.Threading.Thread.Sleep(15); }
        System.Threading.Thread.Sleep(60);
        foreach (var u in up) { n += SendInput(1, new[] { u }, Marshal.SizeOf(typeof(INPUT))); System.Threading.Thread.Sleep(15); }
        return n;
    }
}
