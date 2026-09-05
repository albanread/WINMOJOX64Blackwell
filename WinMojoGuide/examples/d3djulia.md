# d3djulia — runtime-compiled HLSL, driven from Mojo

An animated Julia set, computed in a pixel shader that the program itself
compiles at run time with `D3DCompile`, while the constant `c` orbits the
cardioid. Locked to the display's real refresh rate — read out of
`DEVMODEW`, by field offset, because a hardcoded 60 is wrong on most
displays — it runs until the window closes.

## Run it

```
mojo run main.mojo
```

Any D3D11 GPU; the Mojo side is CPU-only, the GPU work is entirely HLSL.

## The walkthrough

**The shader is a string, compiled through the metadata.** The HLSL source
sits inline (main.mojo:237); `compile_shader` (main.mojo:300) calls
`D3DCompile` out of d3dcompiler_47.dll via `Win32Module`, with the error
blob read out on failure — so a typo in the shader is a *runtime*
diagnostic with a line number, and the program prints it instead of
presenting black.

**The pipeline is the standard six objects**: device+swap chain (one
`win32[]` call, as in [d3dwindow](d3dwindow.md)), back buffer via
`GetBuffer` with the IID from the metadata, RTV, vertex and pixel shaders,
a constant buffer for `c` and the viewport — updated per frame with
`UpdateSubresource` before `Draw(3)` of a fullscreen triangle.

**The trap that cost its flicker:** the swap chain is flip-model
(`FLIP_DISCARD`), and *flip-model swap chains unbind the render target at
Present* (main.mojo:635). Rebinding once before the loop leaves every
alternate frame drawing into nothing — hard flicker with every API
reporting success. `OMSetRenderTargets` is re-issued every frame
(main.mojo:754) because it has to be.

**The refresh rate is measured, not assumed**: `display_refresh_hz`
(main.mojo:338) reads `EnumDisplaySettingsW`'s `DEVMODEW` by
`winkb_field_offset` — another entry in the file of proofs that a size
assert alone does not place a field.

## What it teaches

Runtime shader compilation from Mojo; the per-frame D3D loop reduced to
update-constant, draw, present; and two honesty rules — rebind after
Present on a flip chain, and measure the display instead of guessing 60.
