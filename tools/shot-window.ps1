# Photographs a GPU window -- the game pane's, or anything else that presents
# through a swap chain.
#
#     powershell -File tools/shot-window.ps1 -Exe build/gamepane-blit.exe `
#         -Title "Game pane" -Out build/blit.png
#
# The sibling `shot.ps1` photographs a CONSOLE, which is a different problem:
# it has to launch conhost so there is a window at all. This one has a window
# from the start and the difficulty is elsewhere.
#
# Why BitBlt from the screen rather than PrintWindow: PrintWindow asks the
# window to redraw itself into a device context, and a Direct3D window has
# nothing to redraw with -- its pixels were put on the screen by the
# compositor out of a swap chain the GDI path cannot see. It returns a black
# rectangle, which looks exactly like the bug you would be trying to rule out.
# Copying from the screen device context gets the composited result, at the
# cost of needing the window genuinely visible and in front.
#
# So the window is raised first, and given a moment to actually render: a
# capture taken the instant the window appears catches the frame before the
# first Present and is black for an honest reason.

param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Title = "",
    [string]$Out = "window.png",
    [int]$SettleMs = 2500,
    [int]$TimeoutMs = 20000
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class WinShot {
    [StructLayout(LayoutKind.Sequential)] public struct RECT {
        public int Left, Top, Right, Bottom;
    }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(
        IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // Per-monitor DPI aware, so a client rect in physical pixels is not
    // scaled behind our back on a display that is not at 100%.
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    public static void Raise(IntPtr h) {
        ShowWindow(h, 9);                 // SW_RESTORE
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0003);  // TOPMOST|NOMOVE|NOSIZE
        SetForegroundWindow(h);
    }

    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }

    public static string Capture(IntPtr h, string path) {
        SetProcessDPIAware();
        RECT rc;
        if (!GetClientRect(h, out rc)) return "GetClientRect failed";
        int w = rc.Right - rc.Left, ht = rc.Bottom - rc.Top;
        if (w <= 0 || ht <= 0) return "client rect is empty";
        POINT o = new POINT(); o.X = rc.Left; o.Y = rc.Top;
        if (!ClientToScreen(h, ref o)) return "ClientToScreen failed";

        using (Bitmap bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb))
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(o.X, o.Y, 0, 0, new Size(w, ht),
                             CopyPixelOperation.SourceCopy);
            bmp.Save(path, ImageFormat.Png);
            // A quick census, so the caller can tell "it drew" from "it is
            // a black rectangle" without opening the file.
            long black = 0, total = (long)w * ht;
            for (int y = 0; y < ht; y += 4)
                for (int x = 0; x < w; x += 4) {
                    Color c = bmp.GetPixel(x, y);
                    if (c.R < 8 && c.G < 8 && c.B < 8) black++;
                }
            long sampled = ((ht + 3) / 4) * (long)((w + 3) / 4);
            return string.Format("{0}x{1}, {2:0.0}% black", w, ht,
                                 100.0 * black / sampled);
        }
    }
}
'@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

$exePath = (Resolve-Path $Exe).Path
$proc = Start-Process -FilePath $exePath -WorkingDirectory (Split-Path $exePath) -PassThru

$deadline = (Get-Date).AddMilliseconds($TimeoutMs)
$hwnd = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    $proc.Refresh()
    if ($proc.HasExited) { throw "the process exited before a window appeared (exit $($proc.ExitCode))" }
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero -and [WinShot]::Visible($proc.MainWindowHandle)) {
        if ($Title -eq "" -or $proc.MainWindowTitle -like "*$Title*") {
            $hwnd = $proc.MainWindowHandle
            break
        }
    }
    Start-Sleep -Milliseconds 150
}
if ($hwnd -eq [IntPtr]::Zero) { $proc.Kill(); throw "no window within ${TimeoutMs}ms" }

[WinShot]::Raise($hwnd)
Start-Sleep -Milliseconds $SettleMs

$report = [WinShot]::Capture($hwnd, (Join-Path (Get-Location) $Out))
Write-Output "title : $($proc.MainWindowTitle)"
Write-Output "shot  : $Out -- $report"

$proc.Refresh()
if (-not $proc.HasExited) { $proc.Kill() }
