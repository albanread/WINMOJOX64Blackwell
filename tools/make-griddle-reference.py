"""Write reference/03-griddle.md from the running program.

Both tables are read out of Griddle rather than typed here, so the reference
cannot drift from the thing it documents. Regenerate it by running this again.
"""
import os
import re
import subprocess

REPO = r"E:\Mojo\WINMOJOX64Blackwell"
OUT = os.path.join(REPO, "WinMojoGuide", "reference", "03-griddle.md")

def ask(command):
    """One command, through the built editor, with its chatter removed."""
    exe = os.path.join(REPO, "build", "griddle.exe")
    if not os.path.exists(exe):
        raise SystemExit("build griddle first: tools" + os.sep + "build-ide.ps1")
    out = subprocess.run([exe, "--no-lsp", "--cmd", command],
                         capture_output=True, text=True, timeout=300).stdout
    keep = [l for l in out.splitlines() if not l.startswith("griddle: ")]
    return chr(10).join(keep)


help_text = ask("help").rstrip()
menu_text = ask("menu list")

# The accelerators, from the menu source: the live menu strips them off the
# name, which is what makes an item nameable, so the source is where they are.
BS = chr(92)
src = open(os.path.join(REPO, "ide", "menu.mojo"), encoding="utf-8").read()
accel = re.findall(r'"([^"]*?)' + BS + BS + r't([^"]*)"', src)

# The menu, as the program reports it, grouped by its top-level name.
menus = {}
order = []
for line in menu_text.splitlines():
    m = re.match(r"\s+(.+?) > (.+?) \((\d+)\)\s*$", line)
    if not m:
        continue
    top, item = m.group(1), m.group(2)
    if top not in menus:
        menus[top] = []
        order.append(top)
    menus[top].append(item)

by_name = dict(accel)

parts = []
parts.append("""# Griddle reference

Every command Griddle answers to and every key it listens for. Both tables
below are read out of the running program rather than written by hand, so
this page cannot drift from the program it documents.

## Keyboard

""")
parts.append("| Key | Command |\n|:---|:---|\n")
for name, key in accel:
    parts.append("| `%s` | %s |\n" % (key, name))
parts.append("""
Two keys are not in the menus and belong here anyway:

| Key | Command |
|:---|:---|
| `Ctrl+G` | go to a line |
| `Ctrl+Space` | completions |

""")

parts.append("## The menu bar\n\nRead from the live menu, which is built "
             "from what the installation actually has — the Examples entries "
             "are whatever example projects are on disk.\n\n")
for top in order:
    parts.append("**%s** — %s\n\n" % (top, " · ".join(menus[top])))

parts.append("""## The command surface

Every feature has a name, and the names are how Griddle is scripted and
tested. They reach the same functions the menus and keys reach, so a thing
done one way and the same thing done another are the same code.

    griddle.exe --cmd "build;;build wait 60000;;output"

Commands are separated by `;;`. `run-script <path>` replays a file of them,
one per line, `#` for a comment.

```
""")
parts.append(help_text)
parts.append("""
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
| `<project>\\.griddle-session.json` | where you were: open files, current tab, expanded folders |
| `%LOCALAPPDATA%\\Griddle\\settings.json` | preferences, which are per-person rather than per-project |
| `%LOCALAPPDATA%\\Griddle\\Python\\Environments\\` | one virtual environment per project |
| `%TEMP%\\griddle-linkbin\\link.exe` | the linker, staged under the name the compiler looks for |

The session file is one developer's window state rather than a fact about the
project, so it does not want to be committed.
""")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w", encoding="utf-8", newline="\r\n").write("".join(parts))
print("wrote", OUT)
print("shortcuts:", len(accel), " menus:", len(order),
      " menu items:", sum(len(v) for v in menus.values()))
