# griddle-cmd.ps1 -- send one command to a running Griddle, print the reply.
#
#   .\tools\griddle-cmd.ps1 status
#   .\tools\griddle-cmd.ps1 echo hello there
#
# The transport is WM_COPYDATA, which exists to hand bytes to another
# process and needs no registration, no permission and no COM. What it does
# not offer is a way to hand bytes back, so the request names a file for its
# answer; SendMessage is synchronous, so the answer is on disk by the time
# the call returns. That is what lets this script -- and a CI step, and any
# other caller -- drive the IDE without owning a window or pumping messages.
[CmdletBinding()]
param(
    # Position 0 plus ValueFromRemainingArguments: every bare word on the
    # line collects here, so `griddle-cmd echo hello there` sends all three
    # rather than binding "hello" to the next parameter.
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Command,

    # Where Griddle published its window handle. Defaults to the same place
    # Griddle writes it.
    [string]$HandleFile = (Join-Path $env:TEMP 'griddle.hwnd'),

    # How long to wait for the window to appear, in seconds.
    [int]$WaitSeconds = 10
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class GriddleIpc {
    [StructLayout(LayoutKind.Sequential)]
    public struct COPYDATASTRUCT { public IntPtr dwData; public int cbData; public IntPtr lpData; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, IntPtr wParam, ref COPYDATASTRUCT lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    public const uint WM_COPYDATA = 0x004A;

    public static long Send(IntPtr hwnd, byte[] payload) {
        IntPtr buffer = Marshal.AllocHGlobal(payload.Length);
        try {
            Marshal.Copy(payload, 0, buffer, payload.Length);
            var cds = new COPYDATASTRUCT { dwData = IntPtr.Zero, cbData = payload.Length, lpData = buffer };
            return SendMessageW(hwnd, WM_COPYDATA, IntPtr.Zero, ref cds).ToInt64();
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
"@

# ---- find the window -------------------------------------------------------
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$hwnd = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    if (Test-Path $HandleFile) {
        $raw = (Get-Content $HandleFile -Raw).Trim()
        if ($raw -match '^\d+$') {
            $candidate = [IntPtr][long]$raw
            if ([GriddleIpc]::IsWindow($candidate)) { $hwnd = $candidate; break }
        }
    }
    Start-Sleep -Milliseconds 100
}
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Error "no running Griddle found (looked in $HandleFile)"
    exit 2
}

# ---- ask --------------------------------------------------------------------
# The reply file is per-call, so two callers cannot read each other's answer.
$replyFile = Join-Path $env:TEMP ("griddle-reply-{0}.txt" -f [guid]::NewGuid())
$text = "$replyFile`n" + ($Command -join ' ')
$payload = [System.Text.Encoding]::UTF8.GetBytes($text)

Remove-Item $replyFile -ErrorAction SilentlyContinue
$result = [GriddleIpc]::Send($hwnd, $payload)

if ($result -ne 1) {
    Write-Error "Griddle did not accept the command (returned $result)"
    exit 3
}
if (-not (Test-Path $replyFile)) {
    Write-Error "Griddle accepted the command but wrote no reply"
    exit 4
}

Get-Content $replyFile -Raw
Remove-Item $replyFile -ErrorAction SilentlyContinue
exit 0
