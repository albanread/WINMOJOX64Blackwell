# `dragon/` — DragonMax's own code

Everything Snapdragon-specific that is *not* an edit to Modular's tree lives
here, so the fork's diff against `winmojo/main` stays legible.

| Path | Contents |
|---|---|
| `recon/` | Measured facts about the hardware and about MAX's structure |
| `design/` | Our architecture, porting plan, and annotated upstream reading |
| `probe/` | Standalone harnesses that drive each compute surface directly |

Start with `recon/MAX-ANATOMY.md`, then `design/ARCHITECTURE.md`, then
`design/PORTING-PLAN.md`. `design/UPSTREAM-DOCS.md` says which of Modular's own
documents are worth your time and which are NVIDIA-specific dead ends.

Edits that *must* live in Modular's tree — new targets in
`mojo/stdlib/std/gpu/host/info.mojo`, Snapdragon kernel variants under
`max/kernels/src/` — stay in place there rather than being mirrored here.
