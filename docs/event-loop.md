# The window that never answered

Griddle's headless mode drove a real window for whole runs without ever
dispatching a message. Windows noticed long before we did.

## What was wrong

A window belongs to the thread that created it, and that thread has to pump.
It is not a style question: the window manager sends messages that must be
answered synchronously, and Windows watches whether they are. A thread that
has not pumped for about five seconds is declared hung — the title bar gains
*(Not Responding)*, and DWM stops compositing from the window's own surface
and draws a ghost of it instead, or white where it has no ghost.

Every path in `--cmd` mode avoided the queue, and each for a reason that
looked good on its own:

| path | what it did | why it never pumped |
| --- | --- | --- |
| a command | `SendMessageW(WM_COPYDATA)` to our own window | Windows dispatches a same-thread send **inline**, calling the procedure directly |
| `paint` | `InvalidateRect` + `UpdateWindow` | `UpdateWindow` sends `WM_PAINT` straight to the procedure, bypassing the queue |
| `frame N` | the same, N times | as above, for as long as the run lasts |
| `lsp wait`, `complete wait`, … | `Sleep(10)` in a loop, draining the language server's pipe | the pipe is not the message queue |

So from `ShowWindow` to process exit, not one queued message was dispatched.
The comment in `main` said so plainly — *"without a message loop"* — and read
as a neat trick rather than as the bug it was.

`lsp wait 25000` is twenty-five seconds of a window answering nothing.

## What it cost

Two symptoms that had been filed separately:

- **Processes left behind.** The command path `return`ed out of the middle of
  `main`, skipping `WM_DESTROY` and with it the drop target's revoke, the text
  store's deactivate and the Direct2D release. Enough runs left a live process
  to lock the build's own DLLs and make `build-ide.ps1` fail on the copy.
- **The language server timer never fired.** `SetTimer` posts `WM_TIMER` to the
  queue. Nothing read the queue, so nothing ever ticked, so every check had to
  say `lsp wait` explicitly — a workaround for a bug rather than an interface.

## What it is now

`ide/win32.mojo` grows two functions, and both are what the real message loop
already does, factored out so the headless path and the interactive one are
the same machinery rather than two shapes that can drift:

- `drain(hwnd)` — `PeekMessageW(PM_REMOVE)` / `TranslateMessage` /
  `DispatchMessageW` until the queue is empty, bounded at 512 so a procedure
  that posts to itself cannot turn the pump into the hang it prevents. A
  `WM_QUIT` taken off the queue is re-posted, so a quit arriving during a
  command is not swallowed.
- `settle(hwnd, ms)` — `MsgWaitForMultipleObjects` on the queue with
  `QS_ALLINPUT`, then drain. This is the difference between a window that is
  idle and a window that is hung; a `Sleep` of the same length is
  indistinguishable from a crash as far as the window manager is concerned.

`paint` and `frame` drain after each repaint, every `_wait` loop calls
`settle` where it used to `Sleep`, the command loop drains between steps, and
the command path now leaves through `DestroyWindow` and the real loop rather
than returning out of the middle of the program.

## The check

`tools/check-ide.ps1` grew `answers while busy`, and it is worth being clear
about how it was validated: the check was run against a build with the pump
removed from the frame loop, and it failed the way it should —

    answers while busy  FAIL  hung=True, WM_NULL answered=False -- the thread is not pumping

`IsHungAppWindow` is Windows' own opinion; `SendMessageTimeout` with
`SMTO_ABORTIFHUNG` is the question a shell asks before it draws your window.
Both are asked, seven seconds into a `frame` run, because five is when Windows
makes up its mind.

Two PowerShell traps live in that check and are commented there. `Start-Process
-ArgumentList` re-quotes an array, so `'frame 3000'` arrived as bare `frame`,
ran the default sixty frames, and was over before the check could ask anything
— which reported as "the run ended", a true statement that says nothing about
why. The argument goes as one string instead.

## What this did not fix, and what did

The pump was not what caused the bands of white. That was window placement.

`CW_USEDEFAULT` cascades, so each launch opens a little further down and
right than the last, and on a 1440-tall screen a 1200-tall window runs off the
bottom after a few of them. The off-screen part is a part DWM never composes,
so `PrintWindow` photographs it as white -- a band whose height tracked the
overhang exactly: 12, 52 and 88 pixels of white against 26, 64 and 102 pixels
hanging off the screen. `main` now fits the window to the monitor's work area
before showing it, which is also just what an editor should do, and the rate
went from about one run in four to none in eight.

Two things had to be true at once for this to stay hidden as long as it did:
the window really was hung, which is a real bug and is fixed above, and the
capture really was of a partly uncomposed window, which is a different bug in
a different place. Fixing the first improved the symptom without curing it,
which is the most misleading result an experiment can give.

## The rule

> A window that does not pump is not a window. If a code path drives a window
> without a message loop — because `SendMessage` dispatches inline, because
> `UpdateWindow` paints directly, because the wait is for something else —
> that path still has to drain the queue. Windows is measuring.
