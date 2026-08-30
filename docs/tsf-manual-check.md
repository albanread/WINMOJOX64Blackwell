# Typing Chinese into Griddle

**The manual half of sprint 1.5. Everything else about the text store is
checked automatically by `tools/check-ide.ps1`; this is the part that needs a
person, an input method, and five minutes.**

The automated checks drive the store through its own vtable with a real sink
advised, at the slots the metadata records — the lock protocol, `GetText`,
`SetText`, `GetSelection`. What they cannot do is make a real input method
*choose* to call those methods, in the order it chooses, with a composition in
flight. Microsoft's IMEs are the only thing that exercises that, and no
harness substitutes for them.

## What to install

Windows Settings → Time & Language → Language & region → Add a language →
**中文 (简体, 中国)**. Then under its Language options add the **Microsoft
Pinyin** keyboard. No reboot needed. `Win`+`Space` switches between input
methods once it is installed.

## What to do

```bash
tools/build-ide.ps1
build/griddle.exe --open README.md
```

The console prints `griddle: text services active, client N` at startup. If it
prints `griddle: no text services (...)` instead, TSF did not activate and
nothing below will work — that message says why.

Click into the editor, switch to Pinyin with `Win`+`Space`, and type `nihao`.

## What should happen

1. **A candidate window appears**, listing 你好 and other choices. It should
   sit directly under the text being composed, not in a corner of the screen —
   that placement comes from `GetTextExt` and `GetScreenExt`, and a candidate
   list in the wrong place is the tell of an application that implemented TSF
   halfway.
2. **The composition is visible in the document** as you type, and the caret
   sits after it.
3. **Pressing space or a number commits**, the candidate window closes, and
   你好 is in the document at the caret.
4. **The status bar** reports the caret at the right column — 你好 is two
   characters and two UTF-16 code units, so the column advances by two.
5. **`Ctrl`+`Z` undoes the commit in one step**, not character by character: a
   commit arrives as a single `SetText`, which is a single edit, which is a
   single entry in the history.

## Also worth trying

- **Dead keys.** Add a US-International keyboard, type `'` then `e`, and get
  `é`. This goes through the same store — dead keys are an input method too,
  which is why an editor that handles only `WM_CHAR` gets them wrong.
- **AltGr.** On the same layout, `AltGr`+`e` gives `€`.
- **Japanese.** Microsoft IME with `konnichiha` and space; the same path, a
  different composition model, and a good check that nothing was tuned to
  Pinyin specifically.
- **The emoji panel.** `Win`+`.` inserts through TSF as well, and an emoji is
  a surrogate pair — so it exercises the UTF-16 conversion in `SetText` rather
  than the ASCII path.

## What is known not to work yet

**Composition underline.** The text being composed appears as ordinary text,
without the dotted underline every other Windows editor draws under it. That
needs `ITfContextOwnerServices::OnAttributeChange` and a display-attribute
provider, and this store answers "no attributes supported" to every attribute
request. Typing and committing work; the composition simply is not visually
distinguished from committed text.

**Deferred locks.** The store grants every lock synchronously. An input
method that asks for an asynchronous lock gets a synchronous one, which is
allowed but not always what it expects. Answering `TS_S_ASYNC` needs a method
that can return an HRESULT other than S_OK or E_FAIL, which the `class`
surface cannot express — see the note at the top of `ide/tsf.mojo`.

**Reconversion.** Selecting committed text and asking the IME to reconvert it
is not wired up.

## If nothing happens at all

The most common cause is focus: TSF associates the document manager with the
window, so the editor window must actually have the keyboard focus, not just
be visible. Click in the editor field first.

The second most common is that the process is running without OLE
initialised on that thread. Griddle calls `OleInitialize` before activation
and prints the failure if it does not; check the console.
