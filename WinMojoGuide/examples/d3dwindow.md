# d3dwindow — the smallest Direct3D program that could be

One 800×600 window, cleared teal-to-green by D3D11, 180 frames, done. No
interaction, no shaders, no textures — 320 lines whose entire purpose is to
show the *shape* of driving Direct3D 11 from Mojo: one create call, two
interfaces, one clear, one present, per frame.

## Run it

```
mojo run main.mojo
```

Any D3D11 machine; the exit after frame 180 is success, not a crash.

## The walkthrough

**The swap chain description is asserted field by field.** The struct is
flattened Mojo with a size check — and, the important half, a *field
offset* check: `DXGI_SWAP_CHAIN_DESC.OutputWindow` must sit at 48
(main.mojo:117). The comment is the lesson: *a size assert does not prove a
field is in the right PLACE... an HWND read from the wrong offset is a
swap chain bound to nothing, and it fails silently.*

**The create call is a fully-spelled `win32[]` signature** (main.mojo:162):
`D3D11CreateDeviceAndSwapChain` with all eleven arguments declared and its
four out-parameters taken separately — no variadic guesswork anywhere near
a driver entry point. The interfaces come back as addresses and are wrapped
once as `OpaquePointer[MutUntrackedOrigin]` — the origin rules applied
honestly: Untracked is for memory Windows handed us, never for locals.

**The backend is metadata dispatch.** The back-buffer is fetched with
`com_method_of[..., "IDXGISwapChain", "GetBuffer"]` and an IID read from
the metadata — `_guid_bytes(winkb_interface_iid["ID3D11Texture2D"]())` —
then the render target view is created, and the loop is three metadata-
resolved calls: `ClearRenderTargetView`, `Present(1)`, pump (main.mojo:288).

## What it teaches

The complete D3D11 handshake in miniature: create-with-swap-chain, GetBuffer
through a metadata IID, an RTV, clear/present — each step a named call with
a checked layout behind it. Read this one before [d3djulia](d3djulia.md);
everything there is this plus shaders and timing.
