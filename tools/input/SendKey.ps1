<#
SendKey.ps1 - synthetic keyboard input for driving Thumper while Claude observes.

Uses SendInput with hardware scan codes (KEYEVENTF_SCANCODE). Thumper is SDL2, which
reads keyboard via the window message queue; PostMessage-style fakes are ignored by
many SDL/DirectInput paths, real scan-code injection is not.

Usage:
  .\SendKey.ps1 -Keys down                      # one press
  .\SendKey.ps1 -Keys down,down,enter           # sequence
  .\SendKey.ps1 -Keys down -Repeat 3 -Gap 700   # 3x with 700ms between
  .\SendKey.ps1 -Keys space -HoldMs 250         # hold a key down longer
  .\SendKey.ps1 -Focus THUMPER_win8 -Keys down  # focus that process first

Key names: up down left right enter esc space tab backspace a-z 0-9 f1-f12
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Keys,
    [string]$Focus = "",
    [int]$HoldMs = 60,
    [int]$Gap = 400,
    [int]$Repeat = 1,
    [int]$DelaySeconds = 0
)

$sig = @'
using System;
using System.Runtime.InteropServices;
public class Kbd {
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

    const uint KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_SCANCODE = 0x0008, KEYEVENTF_EXTENDEDKEY = 0x0001;

    public static void Send(ushort scan, bool extended, bool up) {
        INPUT[] inp = new INPUT[1];
        inp[0].type = 1;
        inp[0].ki.wVk = 0;
        inp[0].ki.wScan = scan;
        inp[0].ki.dwFlags = KEYEVENTF_SCANCODE | (extended ? KEYEVENTF_EXTENDEDKEY : 0) | (up ? KEYEVENTF_KEYUP : 0);
        inp[0].ki.time = 0;
        inp[0].ki.dwExtraInfo = IntPtr.Zero;
        SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
    }

    // SetForegroundWindow is refused unless we share input state with the current foreground thread.
    public static void ForceForeground(IntPtr hWnd) {
        uint fg = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        uint me = GetCurrentThreadId();
        AttachThreadInput(me, fg, true);
        ShowWindow(hWnd, 9); // SW_RESTORE
        SetForegroundWindow(hWnd);
        AttachThreadInput(me, fg, false);
    }
}
'@
if (-not ("Kbd" -as [type])) { Add-Type -TypeDefinition $sig }

# scan code table: name -> @(scanCode, isExtended)
$SC = @{
    'esc' = @(0x01, $false); '1' = @(0x02, $false); '2' = @(0x03, $false); '3' = @(0x04, $false)
    '4' = @(0x05, $false); '5' = @(0x06, $false); '6' = @(0x07, $false); '7' = @(0x08, $false)
    '8' = @(0x09, $false); '9' = @(0x0A, $false); '0' = @(0x0B, $false)
    'backspace' = @(0x0E, $false); 'tab' = @(0x0F, $false)
    'q' = @(0x10, $false); 'w' = @(0x11, $false); 'e' = @(0x12, $false); 'r' = @(0x13, $false)
    't' = @(0x14, $false); 'y' = @(0x15, $false); 'u' = @(0x16, $false); 'i' = @(0x17, $false)
    'o' = @(0x18, $false); 'p' = @(0x19, $false)
    'enter' = @(0x1C, $false); 'ctrl' = @(0x1D, $false)
    'a' = @(0x1E, $false); 's' = @(0x1F, $false); 'd' = @(0x20, $false); 'f' = @(0x21, $false)
    'g' = @(0x22, $false); 'h' = @(0x23, $false); 'j' = @(0x24, $false); 'k' = @(0x25, $false)
    'l' = @(0x26, $false)
    'shift' = @(0x2A, $false)
    'z' = @(0x2C, $false); 'x' = @(0x2D, $false); 'c' = @(0x2E, $false); 'v' = @(0x2F, $false)
    'b' = @(0x30, $false); 'n' = @(0x31, $false); 'm' = @(0x32, $false)
    'alt' = @(0x38, $false); 'space' = @(0x39, $false)
    'f1' = @(0x3B, $false); 'f2' = @(0x3C, $false); 'f3' = @(0x3D, $false); 'f4' = @(0x3E, $false)
    'f5' = @(0x3F, $false); 'f6' = @(0x40, $false); 'f7' = @(0x41, $false); 'f8' = @(0x42, $false)
    'f9' = @(0x43, $false); 'f10' = @(0x44, $false); 'f11' = @(0x57, $false); 'f12' = @(0x58, $false)
    'up' = @(0x48, $true); 'left' = @(0x4B, $true); 'right' = @(0x4D, $true); 'down' = @(0x50, $true)
    'home' = @(0x47, $true); 'end' = @(0x4F, $true); 'pgup' = @(0x49, $true); 'pgdn' = @(0x51, $true)
    'insert' = @(0x52, $true); 'delete' = @(0x53, $true)
}

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

if ($Focus) {
    $proc = Get-Process -Name $Focus -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) { Write-Error "No window found for process '$Focus'"; exit 1 }
    [Kbd]::ForceForeground($proc.MainWindowHandle)
    Start-Sleep -Milliseconds 400
    Write-Output "FOCUSED=$Focus"
}

$log = @()
for ($r = 0; $r -lt $Repeat; $r++) {
    foreach ($k in $Keys) {
        $key = $k.ToLower()
        if (-not $SC.ContainsKey($key)) { Write-Error "Unknown key '$k'"; exit 1 }
        $scan = [uint16]$SC[$key][0]
        $ext = [bool]$SC[$key][1]
        [Kbd]::Send($scan, $ext, $false)
        Start-Sleep -Milliseconds $HoldMs
        [Kbd]::Send($scan, $ext, $true)
        $log += ("{0}@{1}" -f $key, (Get-Date -Format "HH:mm:ss.fff"))
        Start-Sleep -Milliseconds $Gap
    }
}

Write-Output ("SENT=" + ($log -join " "))
