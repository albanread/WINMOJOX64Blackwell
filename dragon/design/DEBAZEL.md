# DEBAZEL — excising Bazel from the Mojo port

**Status: DESIGN ONLY, approved for planning 2026-08-19. Nothing here is
implemented.** The sprint ladder at the bottom is the implementation plan,
awaiting a go. The natural home for the work is the WINMOJO trunk (the build
is its G-ladder's subject); this repo merges the result.

## The verdict, up front

Bazel's benefits in this codebase are real — for Modular. Hermetic vendored
toolchains, remote execution, a shared cache, one tool across three languages
and four hundred engineers. Every one of those benefits accrues to an
organisation we are not, on infrastructure we cannot reach, for platforms that
do not include this one. Meanwhile every cost lands here, on one machine, one
developer, one unsupported OS. `max/docs/why-bazel.md` is not wrong; it is
somebody else's cost-benefit analysis.

The tell is that the flagship guarantee already failed for us by construction:
Bazel promises "never *why doesn't this work on my machine*" — and delivered a
build where **nothing** worked on this machine until WINMOJO hand-wrote a
`cc_toolchain`, because the hermetic toolchain Bazel insists on vendoring was
never built for Windows ARM64. Hermeticity is a moat when you're inside it and
a wall when you're not.

## What Bazel is actually doing, measured

The estate: **619 `BUILD.bazel` files** (391 of them in `max/`, irrelevant to
`mojo.exe`), **147 files / 40,897 lines** of `.bzl` machinery under `bazel/`,
and ~25 external dependencies of which the majority are CI-shaped
(`aspect_rules_js`, `aspect_rules_ts`, `gazelle`, `buildifier`, `rules_mypy`,
`opentelemetry-cpp`, `grpc` for the remote cache, `curl`). The 115 GB output
tree currently on this disk is its working set.

Strip the CI costume and the build of `mojo.exe` + stdlib + tests is **three
jobs**:

| Job | Size | Native replacement |
|---|---|---|
| 1. Build LLVM + MLIR + lld from source | the big one; rebuilt rarely | **CMake + Ninja, once**, into a frozen prefix — LLVM's own first-class build |
| 2. Generate dialect code from `.td` | **31 `gentbl` rules** in KGEN + Support | 31 `mlir-tblgen` command lines — already fully specified, verbatim, in the BUILD files |
| 3. Compile & link the compiler; package the stdlib | ~700 C++ files across KGEN/Support/AsyncRT; one `mojo-build` packaging step | **Ninja** |

Real code dependencies beyond LLVM: zlib, zstd, and little else on the
`mojo.exe` path. The rest of the dependency list exists to build things we
never build (docs sites, wheels, telemetry, the remote cache client).

Costs already paid to Bazel by these ports, from the journals: the
`tools/bazel.bat`-not-`.cmd` silent failure; MSYS mangling `//` labels; a
custom `cc_toolchain` written from scratch (WINMOJO G2); the mypy aspect
scoped off (G3); a gRPC python patch; the vendored LLVM source tree
*vanishing between two grep commands* because output bases are ephemeral; and
115 GB of disk. None of these produced an honest error message.

## The architecture

### The key insight: use Bazel once, to escape Bazel

The 619 BUILD files are not an obstacle — they are a **machine-readable
specification** of the entire build, and Bazel will disgorge it on request:
`bazel aquery` emits the complete action graph — every compile, every
`mlir-tblgen` invocation, every link, with literal command lines — as JSON.

So the escape is not a rewrite. It is an **export**:

```
bazel aquery 'deps(//KGEN/tools/mojo:mojo-full)' --output=jsonproto
        │
        ▼
  translator script (~250 lines of python we own)
        │
        ▼
  build.ninja  (checked in; daily builds never touch bazel again)
```

The first non-Bazel build is therefore **command-identical** to the Bazel
build — parity by construction, not by hope. Ninja gives millisecond no-op
builds, honest parallel clean builds, no daemon, no output-base, no 115 GB.

### Phases of independence

- **Phase 0 — freeze LLVM.** Build LLVM+MLIR+lld once with CMake/Ninja into
  `C:\llvm\<version>\` (applying `bazel/public-patches/` first — that
  directory survives as a plain patch set). LLVM is a *dependency*, not a
  daily build. This alone removes ~90% of Bazel's workload and the entire
  vanishing-externals class of failure.
- **Phase 1 — export verbatim.** Run the aquery exporter; the generated ninja
  still references Bazel's fetched trees. Prove parity (B3 below) while both
  builds exist.
- **Phase 2 — re-point.** Path-rewrite pass in the exporter: swap Bazel's
  vendored LLVM paths for the Phase-0 prefix, its zlib/zstd for locally built
  copies. Now nothing references an output base.
- **Phase 3 — own the generator.** Replace the exported ninja with a small
  manifest-driven generator (`mojo-make.py`: glob the source dirs, emit the 31
  tblgen rules from a table, emit compile/link rules). At this point `aquery`
  is never needed again.

### Excision strategy: kill the engine, keep the fossils

**Do not delete the 619 BUILD files.** They are inert text once `bazelw`,
`MODULE.bazel*`, and `bazel/` are gone — and deleting them would turn every
future upstream rebase into six hundred merge conflicts. Leave them in place
as documentation of upstream's intent (they also remain the input the
exporter can re-consume after a rebase, which is the cheap way to absorb
upstream build changes for as long as we keep merging upstream at all).

What dies: `bazelw`, `bazelw.cmd`, `tools/bazel.bat`, `MODULE.bazel`,
`MODULE.bazel.lock`, the `bazel/` directory's 40,897 lines, the remote-cache
and BuildBuddy configuration, the mypy aspect, the wheel repositories, the
hermetic sysroots, and the 115 GB output tree. What survives: the BUILD files
(fossils), `bazel/public-patches/` (reborn as a plain patch directory), and
everything we learned about `alwayslink` (encoded in the generator as
"register these objects whole").

### Design decisions, with reasons

1. **Exporter before generator.** Hand-writing the build first invites drift
   bugs; exporting guarantees the starting point matches reality. The
   generator then replaces something *known to work*.
2. **Check the generated `build.ninja` in.** Most sessions never run the
   exporter, let alone Bazel. Regeneration is an event (an upstream rebase),
   not a workflow.
3. **C++ dependency discovery via the compiler, not the graph.** The exporter
   does not reproduce Bazel's input depsets (they enumerate the world);
   ninja's `deps = msvc` / clang `-MD` depfiles give exact, cheap header
   tracking — *better* incrementality than Bazel's on this machine.
4. **Response files preserved.** Link commands use `@params` files; the
   translator materialises them beside the ninja file rather than inlining
   ten-thousand-character command lines.
5. **The stdlib bootstrap is just an action.** `mojo` builds the stdlib that
   `mojo` programs use; Bazel sequences this via `rules_mojo`. In the export
   it is simply actions with dependencies — ninja orders them like anything
   else. No special machinery.
6. **Tests via `llvm-lit` directly.** `lit` is a python tool; it never needed
   Bazel. A `tests.ninja` phony target invokes it with the same configs.

## The B-ladder (sprint plan — not started)

| Gate | Deliverable | Exit criterion | Rollback |
|---|---|---|---|
| **B0** | Ground truth | `bazel query`/`aquery` counts recorded: exact target set, action count, external files referenced by the `mojo-full` graph | none needed — read-only |
| **B1** | Frozen LLVM prefix | CMake/Ninja build of LLVM+MLIR+lld (with public-patches) installed to `C:\llvm\<ver>`; `mlir-tblgen` runs; SPIRV + AArch64 backends present | delete the prefix |
| **B2** | The exporter | `aquery → build.ninja` translator; verbatim export of the `mojo-full` graph; `ninja mojo.exe` completes | bazel build still intact |
| **B3** | **Parity gate** | ninja-built `mojo.exe` passes the same lit subset as the bazel-built one; `--print-supported-accelerators` output identical | keep shipping bazel binary |
| **B4** | Re-point + stdlib + tests | exported build references only the B1 prefix and the repo; stdlib `.mojopkg` packaged; `ninja check` runs lit | regenerate verbatim export |
| **B5** | Owned generator | `mojo-make.py` (manifests + the 31-rule tblgen table) reproduces B4's build; exporter retired to a rebase tool | keep exported ninja |
| **B6** | **Excision** | `bazelw`, `MODULE.bazel*`, `bazel/` machinery deleted (BUILD fossils remain); 115 GB reclaimed; INTEGRATEME.md updated to ninja instructions | git revert of one commit |

Sequencing note: **B1 is valuable even if the ladder stalls** — a frozen LLVM
prefix is independently useful (it is also the SDK our BCPL/FasterBASIC
offload experiments would compile against). B3 is the gate that decides
everything; nothing is deleted before it passes twice on different days.

Dependency on WINMOJO: B0/B2 need Bazel's *analysis* phase to run, which
WINMOJO achieved at its G3 ("make the windows-arm64 toolchain analysable").
The ladder can start now; it does not need a *building* KGEN, only an
analysable one.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| aquery output has Windows path-escaping surprises | medium | translator asserts every referenced file exists before emitting |
| Some action mnemonics are opaque (custom rules) | medium | B0 enumerates all mnemonics first; anything unknown is designed for before B2 starts |
| Upstream rebases change the build faster than the generator tracks | low while merging upstream | fossils + exporter remain the re-sync path until B5 confidence is earned |
| LLVM CMake build differs subtly from bazel's flags | medium | B0 records bazel's exact LLVM compile flags; B1 mirrors them; B3 catches the rest |
| Bootstrap ordering bug (stdlib ↔ compiler) | low | export captures the true action order; nothing is inferred |

## What this buys

A build one person can hold in their head: `ninja mojo.exe`, seconds of no-op
time, no daemon, no output bases, no silent wrapper protocols, no 40,897 lines
of meta-build, and a machine that stops donating 115 GB to hermeticity it
never receives. The complexity Bazel justifies at Modular's scale is, at this
scale, just complexity.
