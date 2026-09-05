"""The layered retro game pane (`gamepane_design.md`).

Two tiers. `gamepane.api` is platform-neutral -- it imports no `win32`, no
`max.gpu` and no Direct3D, so a game written against it is a game that can
be re-hosted. `gamepane.d3d11` is the one backend that touches a window, a
GPU or a display.

Ported from the Cocoa port's `gamepane` package (G0-G4 of its sprints),
whose design this tree shares: the neutral tier is carried over byte for
byte, and what differs is the backend -- Metal's unified memory becomes
device-mapped pinned memory, MSL becomes HLSL, and CAMetalLayer becomes a
flip-model swap chain.
"""
