# ============================================================
#  WASD-камера для Dawn of War (classic / Anniversary Edition)
#
#  В движке DoW1 клавиши камеры не переназначаются (в keydefaults.lua
#  camera-действий нет — стрелки зашиты). Этот хелпер вешает
#  низкоуровневый хук клавиатуры и, ПОКА ВКЛЮЧЁН SCROLL LOCK и активно
#  окно игры, превращает W/A/S/D в стрелки (панорамирование камеры).
#
#  Scroll Lock ВЫКЛ -> WASD работают как обычные хоткеи игры
#                      (A = attack-move и т.д.)
#  Scroll Lock ВКЛ  -> WASD двигают камеру (светодиод на клавиатуре
#                      показывает, что режим камеры активен)
#
#  Запускается лаунчером вместе с игрой; сам завершается, когда игра
#  закрыта. Можно запустить и вручную:
#      powershell -ExecutionPolicy Bypass -File tools\WasdCamera.ps1
# ============================================================

param(
    [string[]]$ProcessNames = @('W40k', 'W40kWA')
)

$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class WasdHook {
    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    const uint LLKHF_INJECTED = 0x10;
    const int VK_SCROLL = 0x91;
    const uint KEYEVENTF_KEYUP = 0x0002;

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError=true)]
    static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")]
    static extern short GetKeyState(int vk);
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")]
    static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    static IntPtr _hook = IntPtr.Zero;
    static HookProc _proc;                       // держим делегат от GC
    static string[] _names = new string[0];
    static HashSet<uint> _gamePids = new HashSet<uint>();
    static int _lastRefresh = 0;

    public static void Start(string[] processNames) {
        _names = processNames;
        RefreshPids();
        _proc = Callback;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
        if (_hook == IntPtr.Zero)
            throw new Exception("SetWindowsHookEx failed: " + Marshal.GetLastWin32Error());
    }
    public static void Stop() {
        if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
    }
    public static bool AnyGameRunning() {
        RefreshPids();
        return _gamePids.Count > 0;
    }

    static void RefreshPids() {
        if (Environment.TickCount - _lastRefresh < 2000 && _gamePids.Count > 0) return;
        _lastRefresh = Environment.TickCount;
        var pids = new HashSet<uint>();
        foreach (string n in _names)
            foreach (Process p in Process.GetProcessesByName(n))
                pids.Add((uint)p.Id);
        _gamePids = pids;
    }

    static bool GameIsForeground() {
        RefreshPids();
        if (_gamePids.Count == 0) return false;
        uint pid;
        GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        return _gamePids.Contains(pid);
    }

    static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            var k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            if ((k.flags & LLKHF_INJECTED) == 0 && (GetKeyState(VK_SCROLL) & 1) != 0) {
                byte arrow = 0;
                switch (k.vkCode) {
                    case 0x57: arrow = 0x26; break; // W -> Up
                    case 0x53: arrow = 0x28; break; // S -> Down
                    case 0x41: arrow = 0x25; break; // A -> Left
                    case 0x44: arrow = 0x27; break; // D -> Right
                }
                if (arrow != 0 && GameIsForeground()) {
                    int m = wParam.ToInt32();
                    if (m == WM_KEYDOWN || m == WM_SYSKEYDOWN)
                        keybd_event(arrow, 0, 0, UIntPtr.Zero);
                    else if (m == WM_KEYUP || m == WM_SYSKEYUP)
                        keybd_event(arrow, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                    return (IntPtr)1; // гасим исходную клавишу
                }
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }
}
"@

Write-Host "WASD-камера: Scroll Lock ВКЛ = WASD двигают камеру; ВЫКЛ = обычные хоткеи." -ForegroundColor Cyan
Write-Host "Жду игру ($($ProcessNames -join ', '))..." -ForegroundColor DarkGray

# ждём появления игры до 3 минут
$deadline = (Get-Date).AddMinutes(3)
while (-not [WasdHook]::AnyGameRunning()) {
    if ((Get-Date) -gt $deadline) {
        Write-Host "Игра не запустилась за 3 минуты — выходим." -ForegroundColor Yellow
        exit 0
    }
    Start-Sleep -Milliseconds 700
}

[WasdHook]::Start($ProcessNames)
Write-Host "Хук активен. Завершусь автоматически, когда игра закроется." -ForegroundColor Green

# таймер-сторож: игра закрылась -> выходим
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    if (-not [WasdHook]::AnyGameRunning()) {
        [WasdHook]::Stop()
        [System.Windows.Forms.Application]::Exit()
    }
})
$timer.Start()
try {
    [System.Windows.Forms.Application]::Run()   # цикл сообщений для LL-хука
} finally {
    [WasdHook]::Stop()
}
Write-Host "Игра закрыта — WASD-камера отключена." -ForegroundColor Cyan
