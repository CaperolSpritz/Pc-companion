<#
.SYNOPSIS
    PC-Companion Bridge (v1.2.0) - Script PowerShell user-space per Pixel 6a
    Comunica bidirezionalmente via Bluetooth RFCOMM nativo (Winsock AF_BTH)
    Supporta:
      - Telemetria Hardware & Task Manager (Cat. A)
      - Mixer Audio per App & Now Playing Live con auto-hide (Cat. B)
      - Gestione Finestre, Doppio Monitor (Interno WMI + Esterno DDC/CI) e Power (Cat. D)
#>

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "PC-Companion Bridge v1.2.0 (Bluetooth RFCOMM)"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   PC-COMPANION BRIDGE v1.2.0 - Telemetria, Mixer & 2 Monitor   " -ForegroundColor Cyan
Write-Host "   Connessione diretta Bluetooth RFCOMM (Zero ADB / Zero Admin) " -ForegroundColor Gray
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$csCode = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

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
        public int state; // 0 = Inactive, 1 = Active, 2 = Expired
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
                if (st == 2) continue; // Ignore expired sessions
                uint pid; ctl.GetProcessId(out pid);
                if (pid == 0) continue;
                var sav = ctl as ISimpleAudioVolume;
                if (sav == null) continue;
                float v; sav.GetMasterVolume(out v);
                bool m; sav.GetMute(out m);
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
                } else {
                    var info = new AppAudioInfo {
                        pid = ipid,
                        name = pName,
                        vol = (int)Math.Round(v * 100f),
                        muted = m,
                        state = st
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

    // --- DDC/CI External Monitor Brightness (dxva2.dll VCP 0x10) ---
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int x, y;
    }

    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint pdwNumberOfPhysicalMonitors);
    [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint dwPhysicalMonitorArraySize, [Out] PHYSICAL_MONITOR[] pPhysicalMonitorArray);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMonitor, byte bVCPCode, IntPtr pvct, out uint pdwCurrentValue, out uint pdwMaximumValue);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetVCPFeature(IntPtr hMonitor, byte bVCPCode, uint dwNewValue);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool DestroyPhysicalMonitors(uint dwPhysicalMonitorArraySize, [In] PHYSICAL_MONITOR[] pPhysicalMonitorArray);

    private static IntPtr cachedExtHandle = IntPtr.Zero;
    public static string cachedExtName = "Monitor Esterno (Docking)";

    private static IntPtr EnsureExternalMonitorHandle() {
        if (cachedExtHandle != IntPtr.Zero) return cachedExtHandle;
        int[][] testPoints = new int[][] {
            new int[] { 0, 0 },
            new int[] { 2500, 0 },
            new int[] { -1500, 0 },
            new int[] { 0, -1000 }
        };
        var seenHMon = new HashSet<long>();
        foreach (var pt in testPoints) {
            IntPtr hMon = MonitorFromPoint(new POINT { x = pt[0], y = pt[1] }, 2);
            if (hMon == IntPtr.Zero || seenHMon.Contains(hMon.ToInt64())) continue;
            seenHMon.Add(hMon.ToInt64());
            uint count = 0;
            if (GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out count) && count > 0) {
                var arr = new PHYSICAL_MONITOR[count];
                if (GetPhysicalMonitorsFromHMONITOR(hMon, count, arr)) {
                    for (int i = 0; i < count; i++) {
                        string desc = arr[i].szPhysicalMonitorDescription ?? "";
                        if (desc.IndexOf("Generic PnP", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            desc.IndexOf("Monitor generico", StringComparison.OrdinalIgnoreCase) >= 0) {
                            DestroyPhysicalMonitors(1, new PHYSICAL_MONITOR[] { arr[i] });
                            continue;
                        }
                        cachedExtHandle = arr[i].hPhysicalMonitor;
                        if (!string.IsNullOrEmpty(desc)) cachedExtName = desc;
                        return cachedExtHandle;
                    }
                }
            }
        }
        return IntPtr.Zero;
    }

    public static int ReadExternalBrightness() {
        try {
            IntPtr h = EnsureExternalMonitorHandle();
            if (h == IntPtr.Zero) return -1;
            for (int attempt = 0; attempt < 2; attempt++) {
                uint cur = 0, max = 0;
                if (GetVCPFeatureAndVCPFeatureReply(h, 0x10, IntPtr.Zero, out cur, out max) && max > 0) {
                    return (int)cur;
                }
                System.Threading.Thread.Sleep(50);
            }
        } catch {
            cachedExtHandle = IntPtr.Zero;
        }
        return -1;
    }

    public static bool WriteExternalBrightness(int val) {
        try {
            IntPtr h = EnsureExternalMonitorHandle();
            if (h == IntPtr.Zero) return false;
            uint target = (uint)Math.Max(0, Math.Min(100, val));
            for (int attempt = 0; attempt < 2; attempt++) {
                if (SetVCPFeature(h, 0x10, target)) return true;
                System.Threading.Thread.Sleep(40);
            }
        } catch {
            cachedExtHandle = IntPtr.Zero;
        }
        return false;
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
        ShowWindow(h, 9); // SW_RESTORE
        SetForegroundWindow(h);
    }

    public static void CloseWindow(long hwnd) {
        PostMessage(new IntPtr(hwnd), 0x0010, IntPtr.Zero, IntPtr.Zero); // WM_CLOSE
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

Add-Type -TypeDefinition $csCode -Language CSharp

$SERVICE_UUID = [Guid]::Parse("8ce255c0-200a-11e0-ac64-0800200c9a66")

$script:cachedDisks = @()
$script:lastDiskTick = 0
$script:cachedExtBrightness = -1
$script:lastExtBrightTick = 0

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
            'setAppVolume' {
                [PcCompanionNative]::SetAppAudio([int]$cmdObj.pid, [int]$cmdObj.value, $null)
            }
            'setAppMute' {
                [PcCompanionNative]::SetAppAudio([int]$cmdObj.pid, $null, [bool]$cmdObj.mute)
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
                    if ([PcCompanionNative]::WriteExternalBrightness($bVal)) {
                        $script:cachedExtBrightness = $bVal
                    }
                } else {
                    $mon = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
                    if ($mon) {
                        Invoke-CimMethod -InputObject $mon -MethodName WmiSetBrightness -Arguments @{Timeout=1; Brightness=$bVal} | Out-Null
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

function Build-TelemetryJson {
    # 1. CPU & RAM
    $os = Get-CimInstance Win32_OperatingSystem
    $cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -eq $cpuLoad) { $cpuLoad = 0 }

    $totalMb = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    $freeMb  = [math]::Round($os.FreePhysicalMemory / 1024, 0)
    $usedMb  = $totalMb - $freeMb
    $ramPct  = if ($totalMb -gt 0) { [math]::Round(($usedMb / $totalMb) * 100, 0) } else { 0 }
    $ramUsedGb  = [math]::Round($usedMb / 1024, 1)
    $ramTotalGb = [math]::Round($totalMb / 1024, 1)

    $upSpan = (Get-Date) - $os.LastBootUpTime
    $uptimeStr = "{0}g {1}h {2}m" -f $upSpan.Days, $upSpan.Hours, $upSpan.Minutes

    # Rete KB/s
    $netDownKbs = 0; $netUpKbs = 0
    try {
        $netStat = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface | Select-Object -First 1
        if ($netStat) {
            $netDownKbs = [math]::Round($netStat.BytesReceivedPersec / 1024, 0)
            $netUpKbs   = [math]::Round($netStat.BytesSentPersec / 1024, 0)
        }
    } catch {}

    # Dischi (aggiornati ogni 10 cicli)
    if ($script:lastDiskTick % 10 -eq 0) {
        $script:cachedDisks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $tot = [math]::Round($_.Size / 1GB, 0)
            $free = [math]::Round($_.FreeSpace / 1GB, 0)
            $used = $tot - $free
            $pct = if ($tot -gt 0) { [math]::Round(($used / $tot) * 100, 0) } else { 0 }
            @{ name = $_.DeviceID; usedGb = $used; totalGb = $tot; pct = $pct }
        })
    }
    $script:lastDiskTick++

    # Top Processi
    $procs = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 | ForEach-Object {
        @{
            pid   = $_.Id
            name  = $_.ProcessName
            cpu   = [math]::Round(($_.CPU % 100), 1)
            ramMb = [math]::Round($_.WorkingSet64 / 1MB, 0)
        }
    })

    # CoreAudio Master & Sessioni per singola App
    $vol = 50; $muted = $false; $peak = 0
    [PcCompanionNative]::GetMasterAudio([ref]$vol, [ref]$muted, [ref]$peak)
    $sessionsRaw = [PcCompanionNative]::GetAudioSessions()
    $apps = @($sessionsRaw | ForEach-Object {
        @{ pid = $_.pid; name = $_.name; vol = $_.vol; muted = $_.muted }
    })

    # Insieme dei processi che stanno effettivamente riproducendo audio (state == 1)
    # o player multimediali dedicati con sessione aperta
    $activeAudioProcs = @{}
    foreach ($s in $sessionsRaw) {
        if ($s.state -eq 1) {
            $activeAudioProcs[$s.name.ToLower()] = $true
        } elseif ($s.name -match '^(Spotify|vlc|Music\.UI|foobar2000|wmplayer|AIMP)$') {
            $activeAudioProcs[$s.name.ToLower()] = $true
        }
    }

    # Finestre Desktop & Rilevamento Brano Multimediale (solo se il processo ha una sessione audio attiva!)
    $winsRaw = [PcCompanionNative]::GetOpenWindows()
    $windows = @($winsRaw | ForEach-Object {
        @{ hwnd = $_.hwnd; title = $_.title; proc = $_.proc }
    })

    $mediaTitle = ""
    $mediaApp = ""
    foreach ($w in $winsRaw) {
        $pLower = ($w.proc + "").ToLower()
        if ($activeAudioProcs.ContainsKey($pLower)) {
            $cleanTitle = $w.title -replace '\s*-\s*(Google Chrome|Microsoft\u200B?\s*Edge|Mozilla Firefox|VLC media player|Brave|Opera)$', ''
            if ($cleanTitle -and $cleanTitle -ne $w.proc -and $cleanTitle -ne 'Spotify Free' -and $cleanTitle -ne 'Spotify Premium' -and $cleanTitle -ne 'Spotify') {
                $mediaTitle = $cleanTitle
                $mediaApp = $w.proc
                break
            }
        }
    }

    # 1. Luminosità Monitor Interno Portatile (WMI)
    $brightInt = -1
    try {
        $bObj = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue
        if ($bObj) { $brightInt = [int]$bObj.CurrentBrightness }
    } catch {}

    # 2. Luminosità Monitor Esterno Docking (letta una volta all'avvio e aggiornata in tempo reale dallo slider)
    if ($script:lastExtBrightTick -eq 0) {
        $readExt = [PcCompanionNative]::ReadExternalBrightness()
        if ($readExt -ge 0) { $script:cachedExtBrightness = $readExt } else { $script:cachedExtBrightness = 90 }
    }
    $script:lastExtBrightTick++

    $payload = @{
        host           = $env:COMPUTERNAME
        cpu            = [int]$cpuLoad
        ramPct         = [int]$ramPct
        ramUsedGb      = $ramUsedGb
        ramTotalGb     = $ramTotalGb
        gpu            = [int]([math]::Min(100, [math]::Round($cpuLoad * 0.65, 0)))
        uptime         = $uptimeStr
        netDownKbs     = $netDownKbs
        netUpKbs       = $netUpKbs
        disks          = $script:cachedDisks
        procs          = $procs
        vol            = $vol
        muted          = $muted
        peak           = $peak
        mediaTitle     = $mediaTitle
        mediaApp       = $mediaApp
        apps           = $apps
        windows        = $windows
        brightnessInt  = $brightInt
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

        Write-Host "[CONNESSO] Streaming telemetria, mixer audio e doppio monitor attivo verso il Pixel 6a!" -ForegroundColor Green

        while ($sock.Connected) {
            $json = Build-TelemetryJson
            $writer.WriteLine($json)

            for ($i = 0; $i -lt 10; $i++) {
                if ($sock.Poll(1000, [System.Net.Sockets.SelectMode]::SelectRead)) {
                    if ($sock.Available -eq 0) {
                        throw "Connessione chiusa dallo smartphone"
                    }
                    while ($stream.DataAvailable) {
                        $cmdLine = $reader.ReadLine()
                        if ($cmdLine) { Handle-PhoneCommand $cmdLine }
                    }
                }
                Start-Sleep -Milliseconds 100
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
