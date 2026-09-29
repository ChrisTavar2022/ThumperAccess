# Simple Cheat-Engine-style memory scanner, driven from the terminal (no GUI needed).
# Scans 4-byte-aligned Int32 values in the target process's private read/write memory.
#
# Modes:
#   Init              - take a full baseline snapshot of scannable memory
#   Filter -Filter X  - compare current memory to the last snapshot/candidates and narrow down
#                        X = changed | unchanged | increased | decreased | eq (needs -EqValue)
#   List              - print current candidates
#   Watch -Address 0x... -WatchSeconds N - poll one address and log every value change

param(
    [Parameter(Mandatory=$true)][ValidateSet("Init","Filter","List","Watch","WatchAll","Reset")]
    [string]$Mode,
    [string]$ProcessName = "THUMPER_win8",
    [ValidateSet("changed","unchanged","increased","decreased","eq")]
    [string]$Filter = "changed",
    [Int64]$EqValue = 0,
    [string]$StateDir = "",
    [UInt64]$Address = 0,
    [int]$WatchSeconds = 10
)

$ErrorActionPreference = "Stop"

# $PSScriptRoot can be blank while param() defaults are evaluated under Windows PowerShell
# 5.1's `-File` invocation, so resolve this here instead of in the param block.
if ([string]::IsNullOrEmpty($StateDir)) {
    $StateDir = Join-Path (Split-Path -Parent $PSCommandPath) "state"
}

Add-Type -Namespace MemScan -Name Native -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, IntPtr dwSize, out IntPtr lpNumberOfBytesRead);

[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(IntPtr hObject);

[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr VirtualQueryEx(IntPtr hProcess, IntPtr lpAddress, out MEMORY_BASIC_INFORMATION lpBuffer, IntPtr dwLength);

[StructLayout(LayoutKind.Sequential)]
public struct MEMORY_BASIC_INFORMATION
{
    public IntPtr BaseAddress;
    public IntPtr AllocationBase;
    public int AllocationProtect;
    public int __alignment1;
    public IntPtr RegionSize;
    public int State;
    public int Protect;
    public int Type;
    public int __alignment2;
}
"@

Add-Type -Namespace MemScan -Name Diff -MemberDefinition @"
// Fast compiled comparison of two equal-length buffers, 4-byte aligned Int32 lattice.
// Does the diff AND the string formatting here, in compiled code - doing either in an
// interpreted PowerShell loop is too slow once match counts run into the hundreds of
// thousands (which happens easily on a first, unfiltered 'changed' pass).
// filterMode: 0=changed 1=unchanged 2=increased 3=decreased 4=eq
public static System.Collections.Generic.List<string> CompareToStrings(byte[] oldBuf, byte[] newBuf, long baseAddr, int filterMode, int eqValue)
{
    var results = new System.Collections.Generic.List<string>();
    int len = oldBuf.Length - 3;
    for (int i = 0; i < len; i += 4)
    {
        int oldVal = System.BitConverter.ToInt32(oldBuf, i);
        int newVal = System.BitConverter.ToInt32(newBuf, i);
        bool keep;
        switch (filterMode)
        {
            case 0: keep = newVal != oldVal; break;
            case 1: keep = newVal == oldVal; break;
            case 2: keep = newVal > oldVal; break;
            case 3: keep = newVal < oldVal; break;
            case 4: keep = newVal == eqValue; break;
            default: keep = false; break;
        }
        if (keep)
        {
            long addr = baseAddr + i;
            results.Add("0x" + addr.ToString("X") + "," + newVal.ToString());
        }
    }
    return results;
}

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
static extern bool ReadProcessMemory(System.IntPtr hProcess, System.IntPtr lpBaseAddress, byte[] lpBuffer, System.IntPtr dwSize, out System.IntPtr lpNumberOfBytesRead);

// Fast path re-check entirely in compiled code: reads candidates.csv, re-reads each
// address from the target process, applies the filter, writes the surviving candidates
// back, and returns the survivor count. Millions of candidates are feasible this way;
// a per-candidate PowerShell loop is not.
public static int RecheckCandidates(System.IntPtr hProcess, string csvPath, int filterMode, int eqValue)
{
    var lines = System.IO.File.ReadAllLines(csvPath);
    var outLines = new System.Collections.Generic.List<string>();
    outLines.Add("Address,Value");
    byte[] buf = new byte[4];
    for (int n = 1; n < lines.Length; n++)
    {
        string line = lines[n];
        int comma = line.IndexOf(',');
        if (comma < 3) continue;
        long addr = System.Convert.ToInt64(line.Substring(2, comma - 2), 16);
        int oldVal = int.Parse(line.Substring(comma + 1));
        System.IntPtr read;
        if (!ReadProcessMemory(hProcess, (System.IntPtr)addr, buf, (System.IntPtr)4, out read)) continue;
        int newVal = System.BitConverter.ToInt32(buf, 0);
        bool keep;
        switch (filterMode)
        {
            case 0: keep = newVal != oldVal; break;
            case 1: keep = newVal == oldVal; break;
            case 2: keep = newVal > oldVal; break;
            case 3: keep = newVal < oldVal; break;
            case 4: keep = newVal == eqValue; break;
            default: keep = false; break;
        }
        if (keep) outLines.Add("0x" + addr.ToString("X") + "," + newVal.ToString());
    }
    System.IO.File.WriteAllLines(csvPath, outLines);
    return outLines.Count - 1;
}
"@

$PROCESS_QUERY_INFORMATION = 0x0400
$PROCESS_VM_READ = 0x0010
$MEM_COMMIT = 0x1000
$MEM_PRIVATE = 0x20000
$PAGE_READWRITE = 0x04
$PAGE_EXECUTE_READWRITE = 0x40
$PAGE_GUARD = 0x100
$PAGE_NOACCESS = 0x01

function Get-TargetHandle {
    $proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if (-not $proc) { throw "Process '$ProcessName' not found. Is Thumper running?" }
    $h = [MemScan.Native]::OpenProcess($PROCESS_QUERY_INFORMATION -bor $PROCESS_VM_READ, $false, $proc.Id)
    if ($h -eq [IntPtr]::Zero) { throw "OpenProcess failed (error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
    return $h
}

function Get-ScannableRegions([IntPtr]$h) {
    $regions = @()
    $addr = [UInt64]0
    $maxAddr = [UInt64]0x7FFFFFFEFFFF
    while ($addr -lt $maxAddr) {
        $mbi = New-Object MemScan.Native+MEMORY_BASIC_INFORMATION
        $sz = [MemScan.Native]::VirtualQueryEx($h, [IntPtr][Int64]$addr, [ref]$mbi, [IntPtr]([System.Runtime.InteropServices.Marshal]::SizeOf($mbi)))
        if ($sz -eq [IntPtr]::Zero) { break }
        $regionSize = [UInt64][Int64]$mbi.RegionSize
        if ($regionSize -eq 0) { break }
        $isRW = (($mbi.Protect -band $PAGE_READWRITE) -ne 0) -or (($mbi.Protect -band $PAGE_EXECUTE_READWRITE) -ne 0)
        $noAccess = (($mbi.Protect -band $PAGE_GUARD) -ne 0) -or (($mbi.Protect -band $PAGE_NOACCESS) -ne 0)
        if ($mbi.State -eq $MEM_COMMIT -and $mbi.Type -eq $MEM_PRIVATE -and $isRW -and -not $noAccess -and $regionSize -le 0x4000000) {
            $regions += [PSCustomObject]@{ Base = [UInt64][Int64]$mbi.BaseAddress; Size = $regionSize }
        }
        $addr = [UInt64][Int64]$mbi.BaseAddress + $regionSize
    }
    return $regions
}

function Read-Region([IntPtr]$h, [UInt64]$base, [UInt64]$size) {
    $buf = New-Object byte[] ($size)
    $read = [IntPtr]::Zero
    $ok = [MemScan.Native]::ReadProcessMemory($h, [IntPtr][Int64]$base, $buf, [IntPtr][Int64]$size, [ref]$read)
    if (-not $ok) { return $null }
    return $buf
}

function Read-Int32([IntPtr]$h, [UInt64]$addr) {
    $buf = New-Object byte[] 4
    $read = [IntPtr]::Zero
    $ok = [MemScan.Native]::ReadProcessMemory($h, [IntPtr][Int64]$addr, $buf, [IntPtr]4, [ref]$read)
    if (-not $ok) { return $null }
    return [BitConverter]::ToInt32($buf, 0)
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$candidatesFile = Join-Path $StateDir "candidates.csv"
$snapshotDir = Join-Path $StateDir "snapshot"

switch ($Mode) {
    "Reset" {
        Remove-Item -Recurse -Force $StateDir -ErrorAction SilentlyContinue
        Write-Output "State cleared."
    }

    "Init" {
        $h = Get-TargetHandle
        Remove-Item -Recurse -Force $StateDir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null
        $regions = Get-ScannableRegions $h
        $manifest = @()
        $totalBytes = [UInt64]0
        foreach ($r in $regions) {
            $buf = Read-Region $h $r.Base $r.Size
            if ($null -eq $buf) { continue }
            $fname = Join-Path $snapshotDir ("{0:X}.bin" -f $r.Base)
            [System.IO.File]::WriteAllBytes($fname, $buf)
            $manifest += "$($r.Base),$($r.Size)"
            $totalBytes += $r.Size
        }
        $manifest | Set-Content (Join-Path $StateDir "manifest.csv")
        [MemScan.Native]::CloseHandle($h) | Out-Null
        Write-Output "Baseline captured: $($regions.Count) regions, $([math]::Round($totalBytes/1MB,1)) MB total."
    }

    "Filter" {
        $h = Get-TargetHandle
        $results = New-Object System.Collections.Generic.List[string]

        $filterModeMap = @{ changed = 0; unchanged = 1; increased = 2; decreased = 3; eq = 4 }

        if (Test-Path $candidatesFile) {
            # Fast path: re-check existing candidates entirely in compiled code
            $count = [MemScan.Diff]::RecheckCandidates($h, $candidatesFile, $filterModeMap[$Filter], [int]$EqValue)
            [MemScan.Native]::CloseHandle($h) | Out-Null
            Write-Output "Candidates remaining: $count"
            if ($count -le 50 -and $count -gt 0) {
                Get-Content $candidatesFile | Select-Object -Skip 1 | ForEach-Object { Write-Output $_ }
            }
            break
        } else {
            # Slow path: first filter, diff against Init baseline snapshot files
            if (-not (Test-Path (Join-Path $StateDir "manifest.csv"))) { throw "No baseline found. Run -Mode Init first." }
            $manifest = Import-Csv (Join-Path $StateDir "manifest.csv") -Header Base,Size
            foreach ($row in $manifest) {
                $base = [UInt64]$row.Base
                $size = [UInt64]$row.Size
                $fname = Join-Path $snapshotDir ("{0:X}.bin" -f $base)
                if (-not (Test-Path $fname)) { continue }
                $oldBuf = [System.IO.File]::ReadAllBytes($fname)
                $newBuf = Read-Region $h $base $size
                if ($null -eq $newBuf -or $newBuf.Length -ne $oldBuf.Length) { continue }
                $filterMode = switch ($Filter) {
                    "changed"   { 0 }
                    "unchanged" { 1 }
                    "increased" { 2 }
                    "decreased" { 3 }
                    "eq"        { 4 }
                }
                $matches = [MemScan.Diff]::CompareToStrings($oldBuf, $newBuf, [Int64]$base, $filterMode, [int]$EqValue)
                $results.AddRange($matches)
            }
        }

        [MemScan.Native]::CloseHandle($h) | Out-Null
        "Address,Value" | Set-Content $candidatesFile
        $results | Add-Content $candidatesFile
        Write-Output "Candidates remaining: $($results.Count)"
        if ($results.Count -le 50) {
            $results | ForEach-Object { Write-Output $_ }
        }
    }

    "List" {
        if (-not (Test-Path $candidatesFile)) { Write-Output "No candidates yet."; break }
        $rows = Import-Csv $candidatesFile
        Write-Output "Candidates: $($rows.Count)"
        $rows | ForEach-Object { Write-Output "$($_.Address) = $($_.Value)" }
    }

    "WatchAll" {
        # Poll every candidate address and log any value change with its address.
        # Used to spot which candidate steps in lockstep with the user's paced keypresses.
        if (-not (Test-Path $candidatesFile)) { throw "No candidates to watch." }
        $h = Get-TargetHandle
        $rows = Import-Csv $candidatesFile
        $tracked = @{}
        foreach ($row in $rows) { $tracked[[UInt64]$row.Address] = [Int32]$row.Value }
        Write-Output "Watching $($tracked.Count) addresses for $WatchSeconds seconds..."
        # First sweep silently refreshes stored values (the CSV's values may be stale),
        # so the log only contains changes that happen during the watch itself.
        foreach ($addr in @($tracked.Keys)) {
            $v = Read-Int32 $h $addr
            if ($null -ne $v) { $tracked[$addr] = $v }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $WatchSeconds) {
            foreach ($addr in @($tracked.Keys)) {
                $v = Read-Int32 $h $addr
                if ($null -ne $v -and $v -ne $tracked[$addr]) {
                    Write-Output ("[{0}s] 0x{1:X} : {2} -> {3}" -f [math]::Round($sw.Elapsed.TotalSeconds,2), $addr, $tracked[$addr], $v)
                    $tracked[$addr] = $v
                }
            }
            Start-Sleep -Milliseconds 100
        }
        [MemScan.Native]::CloseHandle($h) | Out-Null
        Write-Output "Watch finished."
    }

    "Watch" {
        if ($Address -eq 0) { throw "Provide -Address 0x... for Watch mode." }
        $h = Get-TargetHandle
        $last = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $WatchSeconds) {
            $v = Read-Int32 $h $Address
            if ($v -ne $last) {
                Write-Output "[$([math]::Round($sw.Elapsed.TotalSeconds,2))s] $v"
                $last = $v
            }
            Start-Sleep -Milliseconds 100
        }
        [MemScan.Native]::CloseHandle($h) | Out-Null
    }
}
