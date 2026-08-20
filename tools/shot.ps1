# Runs a program in a real console window and photographs the result.
#
#     powershell -File tools/shot.ps1 -Exe bazel-bin/examples/win32/windows_tour.exe -Out shot.png
#
# Redirected output is not the same thing as console output: a program whose
# stdout is a pipe has no console, so GetConsoleMode fails, ANSI colour never
# turns on, and GetConsoleScreenBufferInfo has nothing to measure. Anything
# that touches the console has to be looked at in one to be believed.
#
# Two Windows-specific details make this work:
#
#   * conhost.exe is launched explicitly. Left to itself, cmd.exe on Windows 11
#     opens inside Windows Terminal, whose window belongs to a different
#     process -- so the launched process's MainWindowHandle is zero and there
#     is nothing to capture.
#
#   * The capture lives in the C# helper rather than in PowerShell. Marshalling
#     a RECT out through [ref] across the PowerShell boundary silently yields
#     zeroes, and a 0x0 bitmap is the symptom.

# -Rows sets the screen BUFFER height, and conhost's window ends up a few rows
# shorter than the buffer it was given. Anything past the window's last row is
# in the buffer but not in the photograph, which looks exactly like a program
# that stopped early. To capture the tail of a long run, set -Rows to roughly
# the number of lines you want to see and let the rest scroll away.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Out = "shot.png",
    [int]$Columns = 100,
    [int]$Rows = 46,
    [int]$WaitMs = 3000
)

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class Shot {
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    // CharSet.Unicode, or the default ANSI marshalling hands a W entry point
    // an ANSI string and the lookup silently finds nothing.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowW(string cls, string title);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

    public static IntPtr ByTitle(string title) { return FindWindowW(null, title); }

    public static string Capture(IntPtr h, string path) {
        RECT r;
        if (!GetWindowRect(h, out r)) return "GetWindowRect failed";
        int w = r.R - r.L, ht = r.B - r.T;
        if (w <= 0 || ht <= 0) return "window has no area (" + w + "x" + ht + ")";
        SetForegroundWindow(h);
        System.Threading.Thread.Sleep(400);
        using (Bitmap bmp = new Bitmap(w, ht))
        using (Graphics g = Graphics.FromImage(bmp)) {
            IntPtr dc = g.GetHdc();
            bool ok = PrintWindow(h, dc, 2);   // PW_RENDERFULLCONTENT
            g.ReleaseHdc(dc);
            if (!ok) return "PrintWindow failed";
            bmp.Save(path, ImageFormat.Png);
        }
        return "ok " + w + "x" + ht;
    }
}
"@

$exePath = (Resolve-Path $Exe).Path
$title = "mojo-shot-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)

# `cmd /k` keeps the window open after the program exits so there is something
# left to photograph; `mode` sizes the buffer so nothing wraps.
# No space before the `&`: cmd's `title` takes the rest of the command
# verbatim, so `title foo & ...` names the window "foo " and an exact-match
# FindWindow never sees it.
$inner = "title $title&mode con: cols=$Columns lines=$Rows & `"$exePath`""
$proc = Start-Process conhost.exe -ArgumentList "cmd.exe", "/k", $inner -PassThru
Start-Sleep -Milliseconds $WaitMs

$handle = [Shot]::ByTitle($title)
if ($handle -eq [IntPtr]::Zero) {
    $proc.Refresh()
    $handle = $proc.MainWindowHandle
}
if ($handle -eq [IntPtr]::Zero) {
    Write-Error "no console window appeared for $Exe"
    try { $proc.Kill() } catch {}
    exit 1
}

$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Get-Location) $Out }
$result = [Shot]::Capture($handle, $outPath)
try { $proc.Kill() } catch {}
"$result -> $outPath"
