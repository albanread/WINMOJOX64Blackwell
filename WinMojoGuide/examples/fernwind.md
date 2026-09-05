# fernwind — a GPU meadow, atomics, and proof before pixels

[ferns](ferns.md)' meadow, moved onto the GPU: 24,576 threads each run a
short chaos game — 12 burn-in iterations, 140 plotted — and land their hits
by **atomic adds into four density buffers**; wind rotates one affine map
of each fern by a per-plant phase, so the bend compounds up the stem. Same
controls as ferns: click, space, `r`, `q`/Esc; `FERNWIND_FRAMES` and
`FERNWIND_DUMP` for unattended runs.

## Run it

```
mojo run main.mojo
```

(`run.sh` adds `--target-accelerator` automatically for sources that
mention `max.gpu`.) NVIDIA GPU required.

## The walkthrough

**The atomics are proven before the window opens.** `atomics_hold(ctx)`
(main.mojo:975) runs a probe kernel — one thread per slot,
`Atomic.fetch_add` ×4 (main.mojo:553) — and checks the counts *exactly*
before a single fern is grown. The README's version of why: *if the backend
lowered `fetch_add` as a load-add-store, the picture would still look like
a fern — just quietly, undetectably thin.* A fern is not evidence; a count
is.

**The frame is four kernels' worth of pipeline, D3D as a blitter.**
Per frame (main.mojo:1413): the host writes wind-bent parameters (the wind
is a 2×2 rotation of one affine map, main.mojo:1449), copies them to the
device, clears the four density buffers, launches `chaos_kernel`, launches
`shade_kernel` to tone-map density into BGRA, reads back to pinned host
memory, `UpdateSubresource` into a B8G8R8A8 texture, rebinds the render
target (the flip-model rule from [d3djulia](d3djulia.md)), `Draw(3)`,
`Present` — with occlusion counted, since a hidden window's Present
reports `DXGI_STATUS_OCCLUDED` and the signed HRESULT matters.

**The D3D setup is the full handshake** — `D3D11CreateDeviceAndSwapChain`
through `win32[]`, GetBuffer with the IID from
`winkb_interface_iid["ID3D11Texture2D"]`, RTV, SRV, shaders via
`D3DCompile` (main.mojo:1051–1201) — the same skeleton as the D3D samples,
in service of a kernel.

## What it teaches

GPU atomics with the verification they require; per-frame parameter
traffic (small, copied, device-resident); and the division of labour this
tree keeps to: Mojo kernels compute, D3D presents, and the metadata names
every DLL, structure and IID between them.
