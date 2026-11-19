<#
.SYNOPSIS
    PC-Companion Bridge (v1.1.0) - Script PowerShell user-space per Pixel 6a
    Comunica bidirezionalmente via Bluetooth RFCOMM nativo (Winsock AF_BTH)
    Zero ADB, Zero privilegi di amministratore, Zero porte firewall, Zero .exe esterni.
#>

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "PC-Companion Bridge v1.1.0 (Bluetooth RFCOMM)"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   PC-COMPANION BRIDGE v1.1.0 - Telemetria, Mixer & Finestre    " -ForegroundColor Cyan
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
    }

    public static List<AppAudioInfo> GetAudioSessions() {
        var list = new List<AppAudioInfo>();
        var seenPids = new HashSet<int>();
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
                uint pid; ctl.GetProcessId(out pid);
                if (pid == 0 || seenPids.Contains((int)pid)) continue;
                var sav = ctl as ISimpleAudioVolume;
                if (sav == null) continue;
                float v; sav.GetMasterVolume(out v);
                bool m; sav.GetMute(out m);
                string pName = null;
                try {
                    var p = Process.GetProcessById((int)pid);
                    pName = p.ProcessName;
                } catch { continue; }
                if (string.IsNullOrEmpty(pName)) continue;
                seenPids.Add((int)pid);
                list.Add(new AppAudioInfo {
                    pid = (int)pid,
                    name = pName,
                    vol = (int)Math.Round(v * 100f),
                    muted = m
                });
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

# UUID del servizio Bluetooth RFCOMM esposto da PC-Companion sul Pixel 6a
$SERVICE_UUID = [Guid]::Parse("8ce255c0-200a-11e0-ac64-0800200c9a66")

function Find-PixelBluetoothAddress {
    # 1. Cerca dispositivo Bluetooth associato chiamato PC-Companion, Pixel 6a o Android-8182
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
    # Fallback al MAC noto del Pixel 6a (F8:1A:2B:FB:F3:CA)
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
                    'left'     { [PcCompanionNative]::SendWinShortcut(0x25, $false) } # Win + Left
                    'right'    { [PcCompanionNative]::SendWinShortcut(0x27, $false) } # Win + Right
                    'max'      { [PcCompanionNative]::SendWinShortcut(0x26, $false) } # Win + Up
                    'min'      { [PcCompanionNative]::SendWinShortcut(0x28, $false) } # Win + Down
                    'desktop'  { [PcCompanionNative]::SendWinShortcut(0x44, $false) } # Win + D
                    'taskview' { [PcCompanionNative]::SendWinShortcut(0x09, $false) } # Win + Tab
                    'vprev'    { [PcCompanionNative]::SendWinShortcut(0x25, $true)  } # Ctrl + Win + Left
                    'vnext'    { [PcCompanionNative]::SendWinShortcut(0x27, $true)  } # Ctrl + Win + Right
                }
            }
            'setBrightness' {
                $bVal = [int]$cmdObj.value
                $mon = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
                if ($mon) {
                    Invoke-CimMethod -InputObject $mon -MethodName WmiSetBrightness -Arguments @{Timeout=1; Brightness=$bVal} | Out-Null
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

$script:lastNetRx = 0
$script:lastNetTx = 0
$script:lastNetTime = [DateTime]::UtcNow
$script:cachedDisks = @()
$script:lastDiskTick = 0

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

    # Uptime
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

    # Dischi (aggiornati ogni 10 cicli per leggerezza)
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
    $apps = @([PcCompanionNative]::GetAudioSessions() | ForEach-Object {
        @{ pid = $_.pid; name = $_.name; vol = $_.vol; muted = $_.muted }
    })

    # Finestre Desktop & Rilevamento Brano Multimediale
    $winsRaw = [PcCompanionNative]::GetOpenWindows()
    $windows = @($winsRaw | ForEach-Object {
        @{ hwnd = $_.hwnd; title = $_.title; proc = $_.proc }
    })

    $mediaTitle = ""
    $mediaApp = ""
    foreach ($w in $winsRaw) {
        if ($w.proc -match 'Spotify|vlc|msedge|chrome|firefox|Music') {
            if ($w.title -match ' - ') {
                $mediaTitle = $w.title
                $mediaApp = $w.proc
                break
            }
        }
    }

    # Luminosità monitor (se supportata via WMI)
    $bright = -1
    try {
        $bObj = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue
        if ($bObj) { $bright = [int]$bObj.CurrentBrightness }
    } catch {}

    $payload = @{
        host       = $env:COMPUTERNAME
        cpu        = [int]$cpuLoad
        ramPct     = [int]$ramPct
        ramUsedGb  = $ramUsedGb
        ramTotalGb = $ramTotalGb
        gpu        = [int]([math]::Min(100, [math]::Round($cpuLoad * 0.65, 0)))
        uptime     = $uptimeStr
        netDownKbs = $netDownKbs
        netUpKbs   = $netUpKbs
        disks      = $script:cachedDisks
        procs      = $procs
        vol        = $vol
        muted      = $muted
        peak       = $peak
        mediaTitle = $mediaTitle
        mediaApp   = $mediaApp
        apps       = $apps
        windows    = $windows
        brightness = $bright
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

        Write-Host "[CONNESSO] Streaming telemetria, mixer audio e finestre attivo verso il Pixel 6a!" -ForegroundColor Green

        while ($sock.Connected) {
            # 1. Invia pacchetto JSON di stato al Pixel 6a
            $json = Build-TelemetryJson
            $writer.WriteLine($json)

            # 2. Controlla per 1000ms (in step da 100ms) se il telefono ha inviato comandi
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
