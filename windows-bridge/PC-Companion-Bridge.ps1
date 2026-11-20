<#
.SYNOPSIS
    PC-Companion Bridge (v1.3.0) - Script PowerShell user-space per Pixel 6a
    Comunica bidirezionalmente via Bluetooth RFCOMM nativo (Winsock AF_BTH)
    Include:
      - Auto-terminazione istanze precedenti dello script
      - Replica completa del MediaMonitor di PhoneBox (Windows SMTC Playing + Paused, Timeline PosMs/DurMs, Seek e Thumbnail JPEG Base64 con cache per traccia)
      - Doppio Monitor rapido: Interno (WMI) + Esterno Dell S3422DW (DDC/CI VCP 0x10 con filtro GetMonitorInfo)
#>

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "PC-Companion Bridge v1.3.0 (Bluetooth RFCOMM)"

# 0. Termina automaticamente eventuali vecchie istanze di PC-Companion-Bridge.ps1 rimaste in background
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -match 'PC-Companion-Bridge\.ps1'
} | ForEach-Object {
    Write-Host "[*] Chiusura vecchia istanza Bridge in background (PID $($_.ProcessId))..." -ForegroundColor Yellow
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   PC-COMPANION BRIDGE v1.3.0 - Media SMTC + Art & 2 Monitor    " -ForegroundColor Cyan
Write-Host "   Connessione diretta Bluetooth RFCOMM (Zero ADB / Zero Admin) " -ForegroundColor Gray
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

Add-Type -AssemblyName System.Drawing

$csCode = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class PcCompanionNative {
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct SOCKADDR_BTH {
        public ushort addressFamily;
        public ulong btAddr;
        public Guid serviceClassId;
        public uint port;
    }

    public class BtRfcommEndPoint : EndPoint {
        private byte[] raw;
        public BtRfcommEndPoint(ulong btAddr, Guid serviceGuid) {
            SOCKADDR_BTH sa = new SOCKADDR_BTH();
            sa.addressFamily = 32; // AF_BTH
            sa.btAddr = btAddr;
            sa.serviceClassId = serviceGuid;
            sa.port = 0;
            int size = Marshal.SizeOf(sa);
            raw = new byte[size];
            IntPtr ptr = Marshal.AllocHGlobal(size);
            Marshal.StructureToPtr(sa, ptr, false);
            Marshal.Copy(ptr, raw, 0, size);
            Marshal.FreeHGlobal(ptr);
        }
        public override AddressFamily AddressFamily { get { return (AddressFamily)32; } }
        public override SocketAddress Serialize() {
            SocketAddress sa = new SocketAddress((AddressFamily)32, raw.Length);
            for (int i = 0; i < raw.Length; i++) sa[i] = raw[i];
            return sa;
        }
        public override EndPoint Create(SocketAddress socketAddress) { return this; }
    }

    public static Socket ConnectBluetooth(ulong btAddr, Guid uuid) {
        Socket s = new Socket((AddressFamily)32, SocketType.Stream, (ProtocolType)3);
        s.ReceiveTimeout = 3000;
        s.SendTimeout = 3000;
        s.Connect(new BtRfcommEndPoint(btAddr, uuid));
        return s;
    }

    // Converte uno Stream immagine SMTC in Data URI Base64:
    // - Se GDI+ lo supporta (JPEG/PNG/BMP), esegue center-crop 112x112 JPEG (~3 KB)
    // - Se è WebP (usato da Chrome / Freefy / YouTube), GDI+ non lo supporta: invia direttamente data:image/webp;base64,... (come MediaMonitor.cs di PhoneBox!)
    public static string StreamToThumbnailDataUri(Stream inputStream, string contentType, int size) {
        if (inputStream == null) return "";
        byte[] rawBytes = null;
        try {
            using (var rawMs = new MemoryStream()) {
                inputStream.CopyTo(rawMs);
                rawBytes = rawMs.ToArray();
            }
        } catch {
            return "";
        }
        if (rawBytes == null || rawBytes.Length == 0) return "";

        try {
            using (var mem = new MemoryStream(rawBytes))
            using (var srcImg = Image.FromStream(mem)) {
                using (var bmp = new Bitmap(size, size)) {
                    using (var g = Graphics.FromImage(bmp)) {
                        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        g.SmoothingMode = SmoothingMode.HighQuality;
                        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        int srcW = srcImg.Width;
                        int srcH = srcImg.Height;
                        int crop = Math.Min(srcW, srcH);
                        int sx = (srcW - crop) / 2;
                        int sy = (srcH - crop) / 2;
                        g.DrawImage(srcImg, new Rectangle(0, 0, size, size), new Rectangle(sx, sy, crop, crop), GraphicsUnit.Pixel);
                    }
                    using (var ms = new MemoryStream()) {
                        bmp.Save(ms, ImageFormat.Jpeg);
                        return "data:image/jpeg;base64," + Convert.ToBase64String(ms.ToArray());
                    }
                }
            }
        } catch {
            // Fallback nativo per WebP (Chrome / Freefy / YouTube) esattamente come MediaMonitor.cs di PhoneBox
            string mime = contentType;
            if (string.IsNullOrEmpty(mime)) {
                if (rawBytes.Length > 12 && rawBytes[0] == 0x52 && rawBytes[1] == 0x49 && rawBytes[8] == 0x57 && rawBytes[9] == 0x45) {
                    mime = "image/webp";
                } else if (rawBytes.Length > 4 && rawBytes[0] == 0x89 && rawBytes[1] == 0x50) {
                    mime = "image/png";
                } else {
                    mime = "image/jpeg";
                }
            }
            return "data:" + mime + ";base64," + Convert.ToBase64String(rawBytes);
        }
    }

    // --- CoreAudio COM Interfaces ---
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator {
        int NotImpl1();
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume {
        int r1(); int r2(); int r3(); int r4();
        [PreserveSig] int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
        int r5();
        [PreserveSig] int GetMasterVolumeLevelScalar(out float pfLevel);
        int r6(); int r7(); int r8(); int r9();
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid pguidEventContext);
        [PreserveSig] int GetMute(out bool pbMute);
    }

    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioMeterInformation {
        [PreserveSig] int GetPeakValue(out float pfPeak);
    }

    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager2 {
        int NotImpl1();
        int NotImpl2();
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator SessionEnum);
    }

    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionEnumerator {
        [PreserveSig] int GetCount(out int SessionCount);
        [PreserveSig] int GetSession(int SessionCount, out IAudioSessionControl2 Session);
    }

    [Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int pRetVal);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int NotImpl1(); int NotImpl2(); int NotImpl3(); int NotImpl4(); int NotImpl5(); int NotImpl6(); int NotImpl7();
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        [PreserveSig] int GetProcessId(out uint pRetVal);
        [PreserveSig] int IsSystemSoundsSession();
        [PreserveSig] int SetDuckingPreference(bool optOut);
    }

    [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISimpleAudioVolume {
        [PreserveSig] int SetMasterVolume(float fLevel, ref Guid EventContext);
        [PreserveSig] int GetMasterVolume(out float pfLevel);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid EventContext);
        [PreserveSig] int GetMute(out bool pbMute);
    }

    private static IMMDevice GetDefaultRenderDevice() {
        var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDevice dev;
        enumerator.GetDefaultAudioEndpoint(0, 1, out dev);
        return dev;
    }

    public static void GetMasterAudio(out int volPct, out bool muted, out int peakPct) {
        volPct = 50; muted = false; peakPct = 0;
        try {
            var dev = GetDefaultRenderDevice();
            if (dev == null) return;
            Guid iidVol = typeof(IAudioEndpointVolume).GUID;
            object oVol;
            dev.Activate(ref iidVol, 23, IntPtr.Zero, out oVol);
            var epVol = (IAudioEndpointVolume)oVol;
            float lvl; epVol.GetMasterVolumeLevelScalar(out lvl);
            epVol.GetMute(out muted);
            volPct = (int)Math.Round(lvl * 100f);

            Guid iidMeter = typeof(IAudioMeterInformation).GUID;
            object oMeter;
            dev.Activate(ref iidMeter, 23, IntPtr.Zero, out oMeter);
            var meter = (IAudioMeterInformation)oMeter;
            float pk; meter.GetPeakValue(out pk);
            peakPct = (int)Math.Round(pk * 100f);
        } catch { }
    }

    public static void SetMasterVolume(int pct) {
        try {
            var dev = GetDefaultRenderDevice();
            Guid iidVol = typeof(IAudioEndpointVolume).GUID;
            object oVol;
            dev.Activate(ref iidVol, 23, IntPtr.Zero, out oVol);
            var epVol = (IAudioEndpointVolume)oVol;
            Guid ctx = Guid.Empty;
            float scalar = Math.Max(0f, Math.Min(1f, pct / 100f));
            epVol.SetMasterVolumeLevelScalar(scalar, ref ctx);
        } catch { }
    }

    public static void ToggleMasterMute() {
        try {
            var dev = GetDefaultRenderDevice();
            Guid iidVol = typeof(IAudioEndpointVolume).GUID;
            object oVol;
            dev.Activate(ref iidVol, 23, IntPtr.Zero, out oVol);
            var epVol = (IAudioEndpointVolume)oVol;
            bool m; epVol.GetMute(out m);
            Guid ctx = Guid.Empty;
            epVol.SetMute(!m, ref ctx);
        } catch { }
    }

    public class AppAudioInfo {
        public int pid;
        public string name;
        public int vol;
        public bool muted;
        public int state;
        public float peak;
    }

    public static List<AppAudioInfo> GetAudioSessions() {
        var list = new List<AppAudioInfo>();
        var byPid = new Dictionary<int, AppAudioInfo>();
        try {
            var dev = GetDefaultRenderDevice();
            Guid iidMgr = typeof(IAudioSessionManager2).GUID;
            object oMgr;
            dev.Activate(ref iidMgr, 23, IntPtr.Zero, out oMgr);
            var mgr = (IAudioSessionManager2)oMgr;
            IAudioSessionEnumerator se;
            mgr.GetSessionEnumerator(out se);
            int count; se.GetCount(out count);
            for (int i = 0; i < count; i++) {
                IAudioSessionControl2 ctl;
                se.GetSession(i, out ctl);
                if (ctl == null) continue;
                int st = 0;
                ctl.GetState(out st);
                if (st == 2) continue;
                uint pid; ctl.GetProcessId(out pid);
                if (pid == 0) continue;
                var sav = ctl as ISimpleAudioVolume;
                if (sav == null) continue;
                float v; sav.GetMasterVolume(out v);
                bool m; sav.GetMute(out m);
                float pk = 0f;
                var meter = ctl as IAudioMeterInformation;
                if (meter != null) meter.GetPeakValue(out pk);
                string pName = null;
                try {
                    var p = Process.GetProcessById((int)pid);
                    if (p.HasExited) continue;
                    pName = p.ProcessName;
                } catch { continue; }
                if (string.IsNullOrEmpty(pName)) continue;

                int ipid = (int)pid;
                if (byPid.ContainsKey(ipid)) {
                    if (st == 1) byPid[ipid].state = 1;
                    if (pk > byPid[ipid].peak) byPid[ipid].peak = pk;
                } else {
                    var info = new AppAudioInfo {
                        pid = ipid,
                        name = pName,
                        vol = (int)Math.Round(v * 100f),
                        muted = m,
                        state = st,
                        peak = pk
                    };
                    byPid[ipid] = info;
                    list.Add(info);
                }
            }
        } catch { }
        return list;
    }

    public static void SetAppAudio(int targetPid, int? volPct, bool? mute) {
        try {
            var dev = GetDefaultRenderDevice();
            Guid iidMgr = typeof(IAudioSessionManager2).GUID;
            object oMgr;
            dev.Activate(ref iidMgr, 23, IntPtr.Zero, out oMgr);
            var mgr = (IAudioSessionManager2)oMgr;
            IAudioSessionEnumerator se;
            mgr.GetSessionEnumerator(out se);
            int count; se.GetCount(out count);
            Guid ctx = Guid.Empty;
            for (int i = 0; i < count; i++) {
                IAudioSessionControl2 ctl;
                se.GetSession(i, out ctl);
                if (ctl == null) continue;
                uint pid; ctl.GetProcessId(out pid);
                if ((int)pid == targetPid) {
                    var sav = ctl as ISimpleAudioVolume;
                    if (sav != null) {
                        if (volPct.HasValue) sav.SetMasterVolume(Math.Max(0f, Math.Min(1f, volPct.Value / 100f)), ref ctx);
                        if (mute.HasValue) sav.SetMute(mute.Value, ref ctx);
                    }
                }
            }
        } catch { }
    }

    // --- Fast DDC/CI External Monitor Brightness (dxva2.dll VCP 0x10 with GetMonitorInfo filter) ---
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MONITORINFOEX {
        public int cbSize;
        public int rcMonitorL, rcMonitorT, rcMonitorR, rcMonitorB;
        public int rcWorkL, rcWorkT, rcWorkR, rcWorkB;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint pdwNumberOfPhysicalMonitors);
    [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMonitor, byte bVCPCode, IntPtr pvct, out uint pdwCurrentValue, out uint pdwMaximumValue);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetVCPFeature(IntPtr hMonitor, byte bVCPCode, uint dwNewValue);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool DestroyPhysicalMonitors(uint dwPhysicalMonitorArraySize, [In] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    public static string cachedExtName = "Dell S3422DW (Docking)";

    public static int ReadExternalBrightness() {
        int result = -1;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data) => {
            var mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(mi);
            if (!GetMonitorInfo(hMon, ref mi)) return true;
            var dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(dd);
            if (!EnumDisplayDevices(mi.szDevice, 0, ref dd, 0)) return true;

            if (dd.DeviceID.IndexOf("CMN", StringComparison.OrdinalIgnoreCase) >= 0 ||
                dd.DeviceString.IndexOf("Generic", StringComparison.OrdinalIgnoreCase) >= 0 ||
                dd.DeviceString.IndexOf("generico", StringComparison.OrdinalIgnoreCase) >= 0) {
                return true;
            }

            uint count = 0;
            if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out count) && count > 0) {
                var arr = new PHYSICAL_MONITOR[count];
                if (GetPhysicalMonitorsFromHMONITOR(hMon, count, arr)) {
                    if (!string.IsNullOrEmpty(arr[0].szPhysicalMonitorDescription)) {
                        cachedExtName = arr[0].szPhysicalMonitorDescription;
                    }
                    uint cur = 0, max = 0;
                    if (GetVCPFeatureAndVCPFeatureReply(arr[0].hPhysicalMonitor, 0x10, IntPtr.Zero, out cur, out max) && max > 0) {
                        result = (int)cur;
                    }
                    DestroyPhysicalMonitors(count, arr);
                }
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static bool WriteExternalBrightness(int val) {
        bool ok = false;
        uint target = (uint)Math.Max(0, Math.Min(100, val));
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMon, IntPtr hdc, ref RECT rc, IntPtr data) => {
            var mi = new MONITORINFOEX();
            mi.cbSize = Marshal.SizeOf(mi);
            if (!GetMonitorInfo(hMon, ref mi)) return true;
            var dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(dd);
            if (!EnumDisplayDevices(mi.szDevice, 0, ref dd, 0)) return true;

            if (dd.DeviceID.IndexOf("CMN", StringComparison.OrdinalIgnoreCase) >= 0 ||
                dd.DeviceString.IndexOf("Generic", StringComparison.OrdinalIgnoreCase) >= 0 ||
                dd.DeviceString.IndexOf("generico", StringComparison.OrdinalIgnoreCase) >= 0) {
                return true;
            }

            uint count = 0;
            if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out count) && count > 0) {
                var arr = new PHYSICAL_MONITOR[count];
                if (GetPhysicalMonitorsFromHMONITOR(hMon, count, arr)) {
                    for (int attempt = 0; attempt < 2; attempt++) {
                        if (SetVCPFeature(arr[0].hPhysicalMonitor, 0x10, target)) {
                            ok = true;
                            break;
                        }
                        Thread.Sleep(30);
                    }
                    DestroyPhysicalMonitors(count, arr);
                }
            }
            return true;
        }, IntPtr.Zero);
        return ok;
    }

    // --- User32 Window & System Management ---
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool LockWorkStation();
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    public class WinInfo {
        public long hwnd;
        public string title;
        public string proc;
    }

    public static List<WinInfo> GetOpenWindows() {
        var list = new List<WinInfo>();
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            int len = GetWindowTextLength(hWnd);
            if (len <= 0) return true;
            var sb = new StringBuilder(len + 1);
            GetWindowText(hWnd, sb, sb.Capacity);
            string title = sb.ToString().Trim();
            if (string.IsNullOrEmpty(title) || title == "Program Manager" || title == "Windows Input Experience" || title == "Impostazioni") return true;
            uint pid; GetWindowThreadProcessId(hWnd, out pid);
            string pName = "";
            try { pName = Process.GetProcessById((int)pid).ProcessName; } catch { }
            list.Add(new WinInfo { hwnd = hWnd.ToInt64(), title = title, proc = pName });
            return list.Count < 14;
        }, IntPtr.Zero);
        return list;
    }

    public static void FocusWindow(long hwnd) {
        IntPtr h = new IntPtr(hwnd);
        ShowWindow(h, 9);
        SetForegroundWindow(h);
    }

    public static void CloseWindow(long hwnd) {
        PostMessage(new IntPtr(hwnd), 0x0010, IntPtr.Zero, IntPtr.Zero);
    }

    public static void TurnOffMonitors() {
        SendMessage(new IntPtr(0xFFFF), 0x0112, new IntPtr(0xF170), new IntPtr(2));
    }

    public static void SendWinShortcut(byte vk, bool withCtrl) {
        const uint KEYEVENTF_KEYUP = 0x0002;
        const byte VK_LWIN = 0x5B;
        const byte VK_LCONTROL = 0xA2;
        if (withCtrl) keybd_event(VK_LCONTROL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_LWIN, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_LWIN, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        if (withCtrl) keybd_event(VK_LCONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
'@

Add-Type -TypeDefinition $csCode -Language CSharp -ReferencedAssemblies System.Drawing

# Inizializza Windows SMTC (GlobalSystemMediaTransportControlsSessionManager) + Stream Thumbnail
$script:smtcManager = $null
$script:asTaskGeneric = $null
$script:asStreamMethod = $null
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
    $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Foundation.IAsyncOperation`1, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [System.IO.WindowsRuntimeStreamExtensions]
    $script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]
    $script:asStreamMethod = ([System.IO.WindowsRuntimeStreamExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsStreamForRead' -and $_.GetParameters().Count -eq 1
    })[0]
    function Invoke-WinRtAwait($WinRtTask, $ResultType) {
        $asTask = $script:asTaskGeneric.MakeGenericMethod($ResultType)
        $netTask = $asTask.Invoke($null, @($WinRtTask))
        $netTask.Wait(1500) | Out-Null
        return $netTask.Result
    }
    $script:smtcManager = Invoke-WinRtAwait ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    Write-Host "[OK] Windows SMTC (Media Session Manager + Thumbnail Stream) attivo." -ForegroundColor Green
} catch {
    Write-Host "[INFO] Windows SMTC non disponibile: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# Cache per la Thumbnail SMTC (con finestra di 8s per attendere le miniature ritardate di Chrome/Freefy come MediaArtworkCache.cs)
$script:lastTrackKey = ""
$script:lastTrackTime = [DateTime]::MinValue
$script:cachedArtData = ""
$script:cachedArtId = 0
$script:sentArtId = -1
$script:cachedIntBrightness = 80
try {
    $bInit = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue
    if ($bInit) { $script:cachedIntBrightness = [int]$bInit.CurrentBrightness }
} catch {}

# Legge all'avvio la luminosità reale del monitor esterno Dell S3422DW
$script:cachedExtBrightness = [PcCompanionNative]::ReadExternalBrightness()
if ($script:cachedExtBrightness -ge 0) {
    Write-Host "[OK] Monitor Esterno rilevato: $([PcCompanionNative]::cachedExtName) (Luminosità attuale: $($script:cachedExtBrightness)%)" -ForegroundColor Green
} else {
    $script:cachedExtBrightness = 90
}

$SERVICE_UUID = [Guid]::Parse("8ce255c0-200a-11e0-ac64-0800200c9a66")
$script:cachedDisks = @()
$script:lastDiskTick = 0

function Friendly-AppName([string]$appId) {
    if (-not $appId) { return "Media" }
    $l = $appId.ToLowerInvariant()
    if ($l -match 'spotify') { return "Spotify" }
    if ($l -match 'chrome')  { return "Chrome" }
    if ($l -match 'firefox|308046b0af4a39cb') { return "Firefox" }
    if ($l -match 'msedge')  { return "Edge" }
    if ($l -match 'vlc')     { return "VLC" }
    if ($l -match 'zune|music') { return "Media Player" }
    return [System.IO.Path]::GetFileNameWithoutExtension(($appId -split '!')[0])
}

function Find-PixelBluetoothAddress {
    $btDevs = Get-CimInstance Win32_PnPEntity | Where-Object {
        $_.PNPClass -eq 'Bluetooth' -and $_.DeviceID -match 'BTHENUM\\DEV_([0-9A-F]{12})'
    }
    foreach ($d in $btDevs) {
        if ($d.Name -match 'PC-Companion|Pixel|Android') {
            if ($d.DeviceID -match 'DEV_([0-9A-F]{12})') {
                $hex = $Matches[1]
                Write-Host "[OK] Rilevato smartphone: $($d.Name) (MAC: $hex)" -ForegroundColor Green
                return [Convert]::ToUInt64($hex, 16)
            }
        }
    }
    Write-Host "[INFO] Uso indirizzo Bluetooth predefinito del Pixel 6a (F8:1A:2B:FB:F3:CA)" -ForegroundColor Yellow
    return [uint64]0x0000F81A2BFBF3CA
}

function Handle-PhoneCommand([string]$jsonLine) {
    try {
        $cmdObj = $jsonLine | ConvertFrom-Json
        $cmd = $cmdObj.cmd
        Write-Host "  <- Comando ricevuto da Pixel 6a: $cmd" -ForegroundColor Cyan
        switch ($cmd) {
            'setMasterVolume' {
                [PcCompanionNative]::SetMasterVolume([int]$cmdObj.value)
            }
            'toggleMasterMute' {
                [PcCompanionNative]::ToggleMasterMute()
            }
            'refreshArt' {
                $script:sentArtId = -1
            }
            'setAppVolume' {
                [PcCompanionNative]::SetAppAudio([int]$cmdObj.pid, [int]$cmdObj.value, $null)
            }
            'setAppMute' {
                [PcCompanionNative]::SetAppAudio([int]$cmdObj.pid, $null, [bool]$cmdObj.mute)
            }
            'mediaControl' {
                $act = [string]$cmdObj.action
                if ($null -ne $script:smtcManager) {
                    $s = $script:smtcManager.GetCurrentSession()
                    if ($null -ne $s) {
                        $pb = $s.GetPlaybackInfo()
                        $ctrls = if ($null -ne $pb) { $pb.Controls } else { $null }
                        $tl = $s.GetTimelineProperties()
                        Write-Host ("     [MEDIA-CTRL] Azione='{0}' | NextEnabled={1} | PrevEnabled={2} | SeekEnabled={3}" -f $act, $ctrls.IsNextEnabled, $ctrls.IsPreviousEnabled, $ctrls.IsPlaybackPositionEnabled) -ForegroundColor Magenta
                        switch ($act) {
                            'playpause' {
                                $null = Invoke-WinRtAwait ($s.TryTogglePlayPauseAsync()) ([bool])
                            }
                            'next' {
                                if ($null -ne $ctrls -and $ctrls.IsNextEnabled) {
                                    $null = Invoke-WinRtAwait ($s.TrySkipNextAsync()) ([bool])
                                } elseif ($null -ne $ctrls -and $ctrls.IsPlaybackPositionEnabled -and $null -ne $tl -and $tl.EndTime.TotalMilliseconds -gt 1500) {
                                    # Web player come Freefy su Chrome dichiarano IsNextEnabled=False ma passano al brano successivo a fine traccia (onended)
                                    $endTicks = ($tl.EndTime - [TimeSpan]::FromMilliseconds(600)).Ticks
                                    Write-Host "     [MEDIA-CTRL] IsNextEnabled=False -> Salto a fine brano per attivare la traccia successiva della coda web!" -ForegroundColor Yellow
                                    $null = Invoke-WinRtAwait ($s.TryChangePlaybackPositionAsync($endTicks)) ([bool])
                                } else {
                                    $null = Invoke-WinRtAwait ($s.TrySkipNextAsync()) ([bool])
                                }
                            }
                            'prev' {
                                if ($null -ne $ctrls -and $ctrls.IsPreviousEnabled -and ($null -eq $tl -or $tl.Position.TotalSeconds -le 4)) {
                                    $null = Invoke-WinRtAwait ($s.TrySkipPreviousAsync()) ([bool])
                                } elseif ($null -ne $ctrls -and $ctrls.IsPlaybackPositionEnabled) {
                                    Write-Host "     [MEDIA-CTRL] Riavvolgo il brano a 0:00 (Seek=0)" -ForegroundColor Yellow
                                    $null = Invoke-WinRtAwait ($s.TryChangePlaybackPositionAsync(0L)) ([bool])
                                } else {
                                    $null = Invoke-WinRtAwait ($s.TrySkipPreviousAsync()) ([bool])
                                }
                            }
                            'seek' {
                                $ticks = [TimeSpan]::FromMilliseconds([double]$cmdObj.ms).Ticks
                                $null = Invoke-WinRtAwait ($s.TryChangePlaybackPositionAsync($ticks)) ([bool])
                            }
                        }
                    }
                }
            }
            'killProcess' {
                Stop-Process -Id ([int]$cmdObj.pid) -Force -ErrorAction SilentlyContinue
            }
            'focusWindow' {
                [PcCompanionNative]::FocusWindow([long]$cmdObj.hwnd)
            }
            'closeWindow' {
                [PcCompanionNative]::CloseWindow([long]$cmdObj.hwnd)
            }
            'snapWindow' {
                switch ($cmdObj.action) {
                    'left'     { [PcCompanionNative]::SendWinShortcut(0x25, $false) }
                    'right'    { [PcCompanionNative]::SendWinShortcut(0x27, $false) }
                    'max'      { [PcCompanionNative]::SendWinShortcut(0x26, $false) }
                    'min'      { [PcCompanionNative]::SendWinShortcut(0x28, $false) }
                    'desktop'  { [PcCompanionNative]::SendWinShortcut(0x44, $false) }
                    'taskview' { [PcCompanionNative]::SendWinShortcut(0x09, $false) }
                    'vprev'    { [PcCompanionNative]::SendWinShortcut(0x25, $true)  }
                    'vnext'    { [PcCompanionNative]::SendWinShortcut(0x27, $true)  }
                }
            }
            'setBrightness' {
                $bVal = [int]$cmdObj.value
                $targetMon = if ($cmdObj.monitor) { [string]$cmdObj.monitor } else { 'internal' }
                if ($targetMon -eq 'external') {
                    Write-Host "     -> Imposto luminosità Monitor Esterno (DDC/CI) a $bVal%" -ForegroundColor Magenta
                    if ([PcCompanionNative]::WriteExternalBrightness($bVal)) {
                        $script:cachedExtBrightness = $bVal
                    }
                } else {
                    Write-Host "     -> Imposto luminosità Display Portatile (WMI) a $bVal%" -ForegroundColor Yellow
                    $mon = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
                    if ($mon) {
                        Invoke-CimMethod -InputObject $mon -MethodName WmiSetBrightness -Arguments @{Timeout=1; Brightness=$bVal} | Out-Null
                        $script:cachedIntBrightness = $bVal
                    }
                }
            }
            'setPowerPlan' {
                switch ($cmdObj.plan) {
                    'saver'    { powercfg /setactive a1841308-3541-4fab-bc81-f71556f20b4a }
                    'balanced' { powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e }
                    'high'     { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
                }
            }
            'lockPc' {
                [PcCompanionNative]::LockWorkStation() | Out-Null
            }
            'monitorOff' {
                [PcCompanionNative]::TurnOffMonitors()
            }
            'powerAction' {
                switch ($cmdObj.action) {
                    'sleep'    { rundll32.exe powrprof.dll,SetSuspendState 0,1,0 }
                    'restart'  { shutdown.exe /r /t 3 }
                    'shutdown' { shutdown.exe /s /t 3 }
                }
            }
        }
    } catch {
        Write-Host "  [!] Errore esecuzione comando: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Replica esatta di MediaMonitor.cs di PhoneBox:
# Supporta sia Playing sia Paused, calcola PosMs/DurMs dalla timeline SMTC ed estrae la Thumbnail 112x112 al cambio traccia
function Get-PhoneBoxMediaSnapshot {
    if ($null -eq $script:smtcManager) { return $null }
    try {
        $s = $script:smtcManager.GetCurrentSession()
        if ($null -eq $s) {
            $script:lastTrackKey = ""
            $script:cachedArtData = ""
            return $null
        }
        $pb = $s.GetPlaybackInfo()
        if ($null -eq $pb) { return $null }
        $stStr = $pb.PlaybackStatus.ToString()
        # Accetta sia Playing sia Paused! Se invece la sorgente è Closed/Stopped senza titolo, ritorna null
        if ($stStr -ne 'Playing' -and $stStr -ne 'Paused') {
            return $null
        }
        $playing = ($stStr -eq 'Playing')
        $props = Invoke-WinRtAwait ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        if ($null -eq $props -or [string]::IsNullOrWhiteSpace($props.Title)) {
            return $null
        }

        $appName = Friendly-AppName $s.SourceAppUserModelId
        $title   = ($props.Title + "").Trim()
        $artist  = ($props.Artist + "").Trim()
        $album   = ($props.AlbumTitle + "").Trim()

        # Calcolo posizione e durata dalla Timeline SMTC (come MediaMonitor.cs righe 76, 95-101)
        $posMs = 0; $durMs = 0; $canSeek = $false
        try {
            $tl = $s.GetTimelineProperties()
            if ($null -ne $tl) {
                $pos = $tl.Position
                if ($playing -and $tl.LastUpdatedTime.Year -gt 2000) {
                    $pos = $pos + ([DateTimeOffset]::Now - $tl.LastUpdatedTime)
                }
                $dur = $tl.EndTime - $tl.StartTime
                if ($dur -gt [TimeSpan]::Zero -and $pos -gt $dur) { $pos = $dur }
                if ($pos -lt [TimeSpan]::Zero) { $pos = [TimeSpan]::Zero }
                $posMs = [long][math]::Round($pos.TotalMilliseconds, 0)
                $durMs = [long][math]::Max(0, [math]::Round($dur.TotalMilliseconds, 0))
            }
            if ($null -ne $pb.Controls) {
                $canSeek = [bool]$pb.Controls.IsPlaybackPositionEnabled
            }
        } catch {}

        # Estrazione Thumbnail con logging dettagliato su console PC
        # (usa $script:asStreamMethod.Invoke per aggirare il bug di System.__ComObject in PowerShell 5.1!)
        $key = "$($s.SourceAppUserModelId)|$title|$artist"
        $nowUtc = [DateTime]::UtcNow
        if ($key -ne $script:lastTrackKey) {
            $script:lastTrackKey = $key
            $script:lastTrackTime = $nowUtc
            Write-Host "[MEDIA] Nuova traccia rilevata ($appName - $stStr): '$title' - '$artist'" -ForegroundColor Cyan
        }
        $withinSettlingWindow = (($nowUtc - $script:lastTrackTime).TotalSeconds -le 8)
        if ($withinSettlingWindow -or ([string]::IsNullOrEmpty($script:cachedArtData) -and $null -ne $props.Thumbnail)) {
            $newArt = ""
            if ($null -ne $props.Thumbnail -and $null -ne $script:asStreamMethod) {
                try {
                    $winrtStream = Invoke-WinRtAwait ($props.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
                    if ($null -ne $winrtStream) {
                        $netStream = $script:asStreamMethod.Invoke($null, @($winrtStream))
                        if ($null -ne $netStream) {
                            $newArt = [PcCompanionNative]::StreamToThumbnailDataUri($netStream, "", 112)
                            $netStream.Dispose()
                        }
                    }
                } catch {
                    Write-Host "  [MEDIA-LOG] Errore lettura stream Thumbnail: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            if (-not [string]::IsNullOrEmpty($newArt) -and $newArt -ne $script:cachedArtData) {
                $script:cachedArtData = $newArt
                $script:cachedArtId++
                Write-Host "  [MEDIA-LOG] Thumbnail caricata con successo! Lunghezza DataURI: $($newArt.Length) caratteri (artId=$($script:cachedArtId))" -ForegroundColor Green
            } elseif ([string]::IsNullOrEmpty($newArt) -and $null -eq $props.Thumbnail -and -not [string]::IsNullOrEmpty($script:cachedArtData)) {
                $script:cachedArtData = ""
                $script:cachedArtId++
                Write-Host "  [MEDIA-LOG] Nessuna Thumbnail presente per questa traccia." -ForegroundColor DarkGray
            }
        }

        $includeArt = ($script:sentArtId -ne $script:cachedArtId)
        if ($includeArt) { $script:sentArtId = $script:cachedArtId }

        return @{
            app     = $appName
            title   = $title
            artist  = $artist
            album   = $album
            playing = $playing
            posMs   = $posMs
            durMs   = $durMs
            canSeek = $canSeek
            artId   = $script:cachedArtId
            artData = if ($includeArt) { $script:cachedArtData } else { $null }
        }
    } catch {
        return $null
    }
}

$script:cachedCpuLoad = 0
$script:cachedRamPct = 0
$script:cachedRamUsedGb = 0
$script:cachedRamTotalGb = 0
$script:cachedUptimeStr = ""
$script:cachedNetDown = 0
$script:cachedNetUp = 0
$script:cachedProcs = @()

function Build-TelemetryJson {
    # Esegue le query WMI pesanti solo ogni 3 cicli (~3s) per mantenere i comandi Bluetooth ultra-reattivi (<20ms)
    if ($script:lastDiskTick % 3 -eq 0) {
        $os = Get-CimInstance Win32_OperatingSystem
        $cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -eq $cpuLoad) { $cpuLoad = 0 }
        $script:cachedCpuLoad = [int]$cpuLoad

        $totalMb = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
        $freeMb  = [math]::Round($os.FreePhysicalMemory / 1024, 0)
        $usedMb  = $totalMb - $freeMb
        $script:cachedRamPct    = if ($totalMb -gt 0) { [int][math]::Round(($usedMb / $totalMb) * 100, 0) } else { 0 }
        $script:cachedRamUsedGb = [math]::Round($usedMb / 1024, 1)
        $script:cachedRamTotalGb = [math]::Round($totalMb / 1024, 1)

        $upSpan = (Get-Date) - $os.LastBootUpTime
        $script:cachedUptimeStr = "{0}g {1}h {2}m" -f $upSpan.Days, $upSpan.Hours, $upSpan.Minutes

        try {
            $netStat = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface | Select-Object -First 1
            if ($netStat) {
                $script:cachedNetDown = [math]::Round($netStat.BytesReceivedPersec / 1024, 0)
                $script:cachedNetUp   = [math]::Round($netStat.BytesSentPersec / 1024, 0)
            }
        } catch {}

        $script:cachedProcs = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 | ForEach-Object {
            @{
                pid   = $_.Id
                name  = $_.ProcessName
                cpu   = [math]::Round(($_.CPU % 100), 1)
                ramMb = [math]::Round($_.WorkingSet64 / 1MB, 0)
            }
        })

        try {
            $bObj = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue
            if ($bObj) { $script:cachedIntBrightness = [int]$bObj.CurrentBrightness }
        } catch {}
    }

    if ($script:lastDiskTick % 12 -eq 0) {
        $script:cachedDisks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $tot = [math]::Round($_.Size / 1GB, 0)
            $free = [math]::Round($_.FreeSpace / 1GB, 0)
            $used = $tot - $free
            $pct = if ($tot -gt 0) { [math]::Round(($used / $tot) * 100, 0) } else { 0 }
            @{ name = $_.DeviceID; usedGb = $used; totalGb = $tot; pct = $pct }
        })
    }
    $script:lastDiskTick++

    $vol = 50; $muted = $false; $peak = 0
    [PcCompanionNative]::GetMasterAudio([ref]$vol, [ref]$muted, [ref]$peak)
    $sessionsRaw = [PcCompanionNative]::GetAudioSessions()
    $apps = @($sessionsRaw | ForEach-Object {
        @{ pid = $_.pid; name = $_.name; vol = $_.vol; muted = $_.muted }
    })

    # Snapshot Media SMTC completo (con stato Playing/Paused, Timeline e Thumbnail WebP/JPEG/PNG)
    $mediaSnap = Get-PhoneBoxMediaSnapshot

    $winsRaw = [PcCompanionNative]::GetOpenWindows()
    $windows = @($winsRaw | ForEach-Object {
        @{ hwnd = $_.hwnd; title = $_.title; proc = $_.proc }
    })

    $payload = @{
        host           = $env:COMPUTERNAME
        cpu            = $script:cachedCpuLoad
        ramPct         = $script:cachedRamPct
        ramUsedGb      = $script:cachedRamUsedGb
        ramTotalGb     = $script:cachedRamTotalGb
        gpu            = [int]([math]::Min(100, [math]::Round($script:cachedCpuLoad * 0.65, 0)))
        uptime         = $script:cachedUptimeStr
        netDownKbs     = $script:cachedNetDown
        netUpKbs       = $script:cachedNetUp
        disks          = $script:cachedDisks
        procs          = $script:cachedProcs
        vol            = $vol
        muted          = $muted
        peak           = $peak
        media          = $mediaSnap
        apps           = $apps
        windows        = $windows
        brightnessInt  = $script:cachedIntBrightness
        brightnessExt  = $script:cachedExtBrightness
        extMonitorName = [PcCompanionNative]::cachedExtName
    }

    return ($payload | ConvertTo-Json -Depth 4 -Compress)
}

$btAddr = Find-PixelBluetoothAddress

while ($true) {
    $sock = $null
    try {
        Write-Host "[*] Connessione Bluetooth RFCOMM a PC-Companion in corso..." -ForegroundColor Yellow
        $sock = [PcCompanionNative]::ConnectBluetooth($btAddr, $SERVICE_UUID)
        $stream = New-Object System.Net.Sockets.NetworkStream($sock, $false)
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)

        # Ad ogni nuova connessione invia anche la thumbnail corrente
        $script:sentArtId = -1

        Write-Host "[CONNESSO] Streaming telemetria, Media SMTC + Copertina e 2 Monitor attivo verso il Pixel 6a!" -ForegroundColor Green

        while ($sock.Connected) {
            $json = Build-TelemetryJson
            $writer.WriteLine($json)

            for ($i = 0; $i -lt 16; $i++) {
                if ($sock.Poll(1000, [System.Net.Sockets.SelectMode]::SelectRead)) {
                    if ($sock.Available -eq 0) {
                        throw "Connessione chiusa dallo smartphone"
                    }
                    # Legge tutte le righe in coda e unifica (coalesce) eventuali comandi ripetuti di volume/luminosità
                    $pendingLines = New-Object System.Collections.Generic.List[string]
                    while ($stream.DataAvailable) {
                        $cmdLine = $reader.ReadLine()
                        if ($cmdLine) { $pendingLines.Add($cmdLine) }
                    }
                    for ($k = 0; $k -lt $pendingLines.Count; $k++) {
                        $curLine = $pendingLines[$k]
                        # Se il comando successivo nella stessa raffica è dello stesso tipo di slider, salta i valori intermedi vecchi
                        if ($k + 1 -lt $pendingLines.Count) {
                            $nextLine = $pendingLines[$k + 1]
                            if (($curLine -match '"setMasterVolume"' -and $nextLine -match '"setMasterVolume"') -or
                                ($curLine -match '"setBrightness"'   -and $nextLine -match '"setBrightness"')) {
                                continue
                            }
                        }
                        Handle-PhoneCommand $curLine
                    }
                }
                Start-Sleep -Milliseconds 50
            }
        }
    } catch {
        Write-Host "[!] In attesa dell'app PC-Companion aperta sul Pixel 6a ($($_.Exception.Message))..." -ForegroundColor DarkGray
    } finally {
        if ($null -ne $sock) {
            try { $sock.Close() } catch {}
        }
    }
    Start-Sleep -Seconds 3
}
