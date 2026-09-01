# d3djulia

An animated Julia set in a pixel shader, from Mojo on Windows ARM64 -- now
with a real window procedure written in Mojo and a real message loop.

The flicker the first versions had turned out to be flip-model Present
unbinding the render target: bound once before the loop, every alternate
Draw went into an unbound pipeline, and the display ping-ponged between the
image and undefined buffer contents. The binding is reissued per frame.
The Mojo window procedure below ALSO keeps GDI off the window (refusing
WM_ERASEBKGND, validating WM_PAINT without painting) -- correct and
necessary, but it was not the flicker; the diagnosis took two passes.

Frame rate is locked to ~60 by syncing to the display's actual refresh rate
(read from DEVMODEW -- by field offset, without declaring the 272-byte
struct) and presenting every refresh/60 vblanks.

Everything Windows-shaped is queried from the metadata: struct sizes and
field offsets, all vtable slots, the GetBuffer IID, which DLLs export
D3DCompile and EnumDisplaySettingsW. No hardcoded slots, sizes, or GUIDs.

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```
