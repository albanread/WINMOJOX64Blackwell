# The blank window, and why nothing reported it

Sprint 2.4 lost most of an afternoon to a Griddle window that drew nothing.
This is what it looked like, what it actually was, and the two real defects
found on the way to finding out.

## The symptom

The window opened. The title bar was there, dark, correct. The menu bar was
there. The client area was white — not the dark ground colour, *white*, the
colour of a surface nothing has ever been drawn to.

Everything the program could be asked said it was fine:

    CreateHwndRenderTarget   hr = 0        target non-zero
    Resize                   hr = 0        pixel size 1184 x 741
    BeginDraw / Clear / DrawTextLayout     issued, 36 layouts
    EndDraw                  hr = 0

Thirty-six lines laid out, thirty-six drawn, every HRESULT `S_OK`, and a blank
window. Screenshots were 9 KB where a rendered one is 160 KB.

## The false trails, and what each one cost

Worth recording, because each was a plausible reading of the evidence and each
was wrong:

- **"It's the 2.4 work."** Building the last commit produced the same blank
  window. Not the new code.
- **"It's the compiler rebuild from 2.3."** The compiler binary was older than
  the last *good* screenshot. Not the compiler.
- **"It's the optimizer."** `griddle-opt.exe` was blank — but an optimized
  build is *known* blank for an unrelated reason
  ([addresses-and-optimization.md](addresses-and-optimization.md)), so that
  test proved nothing. A control that is already broken is not a control.
- **"The metadata slots shifted."** Every D2D slot in `windows_api.db` matches
  the canonical vtable: `FillRectangle` 17, `DrawTextLayout` 28, `Clear` 47,
  `BeginDraw` 48, `EndDraw` 49. The database is dated months before any of
  this.
- **"The colours are transparent."** `GROUND` came out
  `r 0.086 g 0.094 b 0.114 a 1.0`. Opaque, dark, correct.
- **"The display slept / the session locked."** No `LogonUI`, no screensaver,
  not a remote session, DWM composing, and a plain desktop capture worked.

## The measurement that ended it

Direct2D will tell you, if you ask, and only if you ask:

```mojo
var state = com_method_of[
    def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
    "ID2D1HwndRenderTarget",
    "CheckWindowState",
](this)(this)      # 1 == D2D1_WINDOW_STATE_OCCLUDED
```

It returned 1. Every frame.

When an `ID2D1HwndRenderTarget` believes its window is occluded it **skips the
present and returns `S_OK` from `EndDraw`**. Not an error code, not a warning,
not `D2DERR_RECREATE_TARGET`. The drawing all happens, into a back buffer
nobody ever shows. There is no HRESULT anywhere in the frame that differs from
a frame that worked.

That is the whole lesson of this document. **A Direct2D frame that reports
complete success may not have been presented.** `CheckWindowState` is the only
thing that says so, and nothing calls it unless you write the call.

Confirming it took one more measurement: a GDI `FillRect` of the client area
in bright red, issued in `WM_PAINT` just before the Direct2D work. The red
appeared, and the capture of it was pixel-perfect. So the window composed, the
window was visible, and `PrintWindow` worked — and the Direct2D content that
was drawn immediately afterwards did not overwrite the red. Present skipped,
proven from the outside.

## The two real defects

### 1. The render target was created against a window that was not yet shown

`main` did this:

    build_menu(hwnd)
    GetClientRect(hwnd)          <-- window still hidden
    bring_up(hwnd, w, h)         <-- swap chain made here
    ... document, OLE, drop target, text services ...
    ShowWindow(hwnd, SW_SHOW)

A DXGI swap chain made for a window that is not visible is **born occluded**.
The comment on that line said Direct2D came first "so the first paint has
something to draw with", which is a real concern and is satisfied just as well
by showing the window one step earlier. The titlebar is darkened before the
show, so nothing flashes.

The fix is the two lines moved up, and it is load-bearing rather than
cosmetic.

### 2. The render target was sized from a rectangle the window never had

The same reorder fixed a second thing nobody had noticed. The window is
created with `CW_USEDEFAULT`, and with `CW_USEDEFAULT` **the final position
and size are not settled until `ShowWindow`** — Windows fits the window to the
monitor's work area, which on this display means it loses the height under the
taskbar.

So `GetClientRect` before the show returned the *requested* size, the render
target was created at that size, and the window then became smaller. The
visible line count went from a confident 36 to an honest 26 the moment the
measurement moved after the show.

## What was *not* fixed, because it is not ours

With both defects fixed the window was still blank, so the last question was
whether any of it was Griddle's fault at all. It was not:
[`spikes/d2d/minimal.mojo`](../spikes/d2d/minimal.mojo) is about 150 lines —
register a class, show a window, make an `ID2D1HwndRenderTarget`, clear it to
red, ask `CheckWindowState`. No menu, no DWM attributes, no TSF, no document,
no rope. It reports `OCCLUDED` on every frame too.

So on this machine, in this state, Direct2D cannot present to *any* window,
while GDI can. Ruled out, each by measurement: DPI virtualization (the display
is 4K at 150%; making the process per-monitor-aware changed `HORZRES` from
1707 to 2560 and changed nothing else), hardware versus software render target
type, window style, the menu, the dark-titlebar DWM attribute, a full-screen
exclusive application, another window covering ours, a session or window
station mismatch, and a graphics driver reset (Win+Ctrl+Shift+B), which it
survives. It is not this tool chain's process tree either: launched by
`explorer.exe`, so that its parent is the shell rather than anything of ours,
the spike still photographs a white window. DWM cannot be restarted without
elevation.

The spike is checked in so the same question takes one command next time
instead of an afternoon:

```bash
./build/minimal.exe
```

If it prints `state 1 (1=OCCLUDED)`, the machine cannot present and no amount
of reading Griddle's source will change that.

## It cleared on its own

About an hour later, without a reboot, the same spike began reporting
`state 0` and Griddle drew. Nothing in this repository caused that and nothing
in it can prevent a recurrence, which is the reason the spike and the
`screenshot content` check both exist.

One thing worth stating plainly, because the timing invites the wrong
conclusion: Griddle was made DPI-aware in the same hour, and **that is not
what fixed it**. The test is direct — build the spike with the awareness call
removed and it presents too:

    with SetProcessDpiAwarenessContext     state 0
    without it                             state 0

Both draw. The variable was time, not DPI. The awareness work is a real
improvement for a different reason (crisp text on a high-DPI display) and is
described in IDE-DESIGN.md; it is not a fix for this.

## The check that should have caught it

`tools/check-ide.ps1` had a `screenshot` check. It asserted the PNG existed
and had the right dimensions — which a blank window satisfies perfectly. A
screenshot check that cannot tell a rendered window from an empty one is not
checking the thing it is named after.

It now asserts the image has content. Sampling a grid of pixels below the
menu, a drawn frame must show several distinct colours *and* be mostly dark,
because the editor's chrome is a dark theme and an unpresented surface is
white. Either test alone is too easy to pass by accident. Measured on the
screenshots this sprint already had:

| image                     | colours | dark | verdict |
| ------------------------- | ------: | ---: | ------- |
| `sprint-2.3.png` (drawn)  |     117 |  97% | PASS    |
| a blank window            |       2 |   1% | FAIL    |
| the GDI red-fill probe    |       2 |   1% | FAIL    |

A blank window fails it in the same second it appears.

## A second cause, found afterwards

Some of the white in this story was not Direct2D at all. Griddle's headless
mode never dispatched a Windows message, so the window was hung by Windows'
own definition and DWM composited a ghost of it. That is written up in
[event-loop.md](event-loop.md), and it accounts for the bands of white through
unattended screenshots — though not for the hour in which nothing could
present at all, which a 150-line spike that exits in under a second reproduced
too.

Fixing the pump took the partially-blank rate from about forty per cent to
about twenty-five. The remainder is still unexplained.

## The rule

Adding to the one in
[addresses-and-optimization.md](addresses-and-optimization.md):

> An API that reports success has told you the call succeeded, not that the
> effect happened. When the effect is invisible and the call says `S_OK`, find
> the query that reports the *state* — `CheckWindowState` here — and put it in
> the check suite, not just in the debugging session.
