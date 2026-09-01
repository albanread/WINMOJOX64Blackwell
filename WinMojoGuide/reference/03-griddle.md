# Griddle reference

Every command Griddle answers to and every key it listens for. Both tables
below are read out of the running program rather than written by hand, so
this page cannot drift from the program it documents.

## Keyboard

| Key | Command |
|:---|:---|
| `Ctrl+O` | Open... |
| `Ctrl+S` | Save |
| `Ctrl+Shift+S` | Save As... |
| `Ctrl+N` | New |
| `Ctrl+W` | Close Tab |
| `Ctrl+Z` | Undo |
| `Ctrl+Y` | Redo |
| `Ctrl+X` | Cut |
| `Ctrl+C` | Copy |
| `Ctrl+V` | Paste |
| `Ctrl+A` | Select All |
| `Ctrl+F` | Find |
| `F3` | Find Next |
| `Shift+F3` | Find Previous |
| `Ctrl+H` | Replace |
| `Ctrl+Shift+F` | Find in Project |
| `F12` | Definition |
| `Shift+F12` | References |
| `Ctrl+Shift+O` | Symbol in File |
| `Alt+Left` | Back |
| `Ctrl+Tab` | Next Tab |
| `Ctrl+Shift+Tab` | Previous Tab |
| `Ctrl++` | Zoom In |
| `Ctrl+-` | Zoom Out |
| `Ctrl+0` | Reset Zoom |
| `Ctrl+F5` | Run Without Debugging |
| `Ctrl+B` | Build |
| `F5` | Debug |
| `F10` | Step Over |
| `F11` | Step Into |
| `Shift+F11` | Step Out |
| `Ctrl+F10` | Run to Cursor |
| `Ctrl+I` | Evaluate |
| `F9` | Toggle Breakpoint |
| `Shift+F5` | Stop |

Two keys are not in the menus and belong here anyway:

| Key | Command |
|:---|:---|
| `Ctrl+G` | go to a line |
| `Ctrl+Space` | completions |

## The menu bar

Read from the live menu, which is built from what the installation actually has — the Examples entries are whatever example projects are on disk.

**File** — Open... · Save · Save As... · New · Close Tab · Exit

**Edit** — Undo · Redo · Cut · Copy · Paste · Select All · Find · Find Next · Find Previous · Replace · Find in Project

**Go** — Definition · References · Symbol in File · Back · Next Tab · Previous Tab

**View** — Zoom In · Zoom Out · Reset Zoom · Outline · Problems · Toolchain · Python

**Build** — Run Without Debugging · Build · Debug · Step Over · Step Into · Step Out · Run to Cursor · Evaluate · Toggle Breakpoint · Clear All Breakpoints · Stop

**Python** — Create or Repair Environment · Install Project Dependencies · Install Package... · Show Environment

**Examples** — adreno_index_probe · adreno_saxpy · adreno_saxpy_debug · bifurcation · comptr · d3djulia · d3dwindow · ferns · fernwind · fluid · life · nvidia_mandelbrot · structptr · windows_tour · winkb_queries · winstr_smoke

**Help** — About

## The command surface

Every feature has a name, and the names are how Griddle is scripted and
tested. They reach the same functions the menus and keys reach, so a thing
done one way and the same thing done another are the same code.

    griddle.exe --cmd "build;;build wait 60000;;output"

Commands are separated by `;;`. `run-script <path>` replays a file of them,
one per line, `#` for a comment.

```
status            what Griddle is and which window it is
help              this list
echo <text>       answer with <text>, for round-trip checks
screenshot [path] photograph this window to a PNG
views             where every region of the chrome sits
menu T > I        invoke a menu item by its visible name
drops             the paths from the most recent drop
drop-test         drive the drop target through its own vtable
paint             force one frame, synchronously
frame [N]         time N scroll-and-paint frames
grid [reset]      the layout cache counters
scroll N | to N | top | end | page    move the editor
caret [L C]       report or move the caret
click X Y         put the caret where a click landed
hittest L         every caret stop on line L, round-tripped
type <text>       insert text; \n and \t are a newline and a tab
enter             split the line at the caret
backspace         delete backwards, or the selection
delete            delete forwards, or the selection
move D [select]   left|right|up|down|home|end|all
undo | redo       step through the history
sel               what is selected
state             dirty flag, history depth, size
text [L]          one line, or the whole document
goto L[:C]        put the caret there, one-based
mem               what this process is holding
repeat N <cmd>    run one command N times
tsf               drive the text store, as an IME would
find <text>       search, and select the next match
findnext | findprev   repeat the search, F3 and Shift+F3
find-bench <text>     time one search of the whole document
storm [N]         N keystrokes through the real message path
latency [reset]   keystroke to presented frame
issues [N]        the language server's complaints, or jump to one
lsp wait [ms]     wait for the server to have something to say
complete [wait|show|up|down|accept|close]   the completion popup
definition [wait ms]             where the thing under the caret is defined
hover [wait ms|show|close]       what the thing under the caret is
references [wait ms|N]           who uses it, and jump to one
outline [wait ms|<name>]         the file's symbols, or go to one
tree [N|root <path>]             the project tree; expand a row or move it
search <text>                    every match in the project
open <path>                      open a file, or switch to it if it is open
save                             write the document to its file
back                             where the caret was before the last jump
dirty                            whether there is unsaved work
output                           what the output pane holds
file                             the path of what is on screen
tabs [N|next|prev|close]         the open documents
tab <n>                          switch to one
watch | reload                   notice the disk changing, and take the change
session [save|restore]           where you were last time
setting <key> [value]            read or write a preference
zoom [in|out|reset]              make the text bigger
copy | cut | paste               the Windows clipboard
replace <a> -> <b>               replace one match, or every one
build [wait ms]                  compile the document
run [wait ms]                    compile it and run it
stop                             kill what is running
console [<command>]              the output pane, or run a command in it
debug [launch|wait|step|stop]    the debugger
break [N|list|clear]             breakpoints
toolchain [refresh|gaps|<part>]  which compiler this is
samples [<name>]                 the shipped examples; open one as a project
python [create|install|clear]    this project's Python environment
prompt [find|goto|symbol|package|open|type <t>|accept|cancel]
                                 the line at the bottom to type into
unit <n>                         one UTF-16 code unit, as WM_CHAR sends it
about                            which build this is, and what it runs on
run-script <path>                replay a file of these commands
```

## Environment

| Variable | What it does |
|:---|:---|
| `WINMOJO_ROOT` | the toolchain to use, overriding the lookup |
| `WINMOJO_MOJO` | the compiler, overriding the toolchain's |
| `WINMOJO_LSP` | the language server, likewise |
| `WINMOJO_STDLIB` | the standard library to pass with `-I` |
| `MODULAR_MOJO_MAX_WINKB_PATH` | the Windows metadata database |
| `GRIDDLE_EXAMPLES` | where the Examples menu reads from |
| `GRIDDLE_SETTINGS` | the preferences file, so a check touches no profile |
| `GRIDDLE_PYTHON_ENV_ROOT` | where per-project Python environments live |
| `GRIDDLE_PYTHON_HOME` | the CPython to build environments from |

## Files it writes

| Path | What it is |
|:---|:---|
| `<project>\.griddle-session.json` | where you were: open files, current tab, expanded folders |
| `%LOCALAPPDATA%\Griddle\settings.json` | preferences, which are per-person rather than per-project |
| `%LOCALAPPDATA%\Griddle\Python\Environments\` | one virtual environment per project |
| `%TEMP%\griddle-linkbin\link.exe` | the linker, staged under the name the compiler looks for |

The session file is one developer's window state rather than a fact about the
project, so it does not want to be committed.
