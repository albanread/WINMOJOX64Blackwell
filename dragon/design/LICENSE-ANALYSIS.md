# MAX licensing analysis — the trap, located and dated

Analysed 2026-08-19 against three instruments. Not legal advice; a close
reading by engineers, for engineering decisions. For a real commercial
deployment, pay a lawyer to read the same three documents.

## The three instruments, and which one governs what

| Instrument | Governs | Binds when |
|---|---|---|
| **Apache 2.0 + LLVM Exceptions** (per-file headers) | the source code — all 4,566 files under `max/`, plus `mojo/`, `KGEN/`, `AsyncRT/`, `Support/` | never needs assent; irrevocable grant attached to the files |
| **Modular Community License** (modular.com/legal/community) | "MAX software development kits" — **their binary distributions** | downloading/using their SDK |
| **Modular Terms of Use** (modular.com/legal/terms) | the "Modular Platform" — *"Modular's proprietary, **hosted** software platform you use to access your Account"* | "accessing any Modular Offerings" |

Decisive fact #1: **every file in `max/` carries the Apache header.** Verified
by count: 4,566 of 4,566 `.mojo`/`.py` files.

Decisive fact #2: the current Community License contains a supremacy clause in
the code's favour:

> "Portions of MAX have been made available under the Apache License, Version
> 2.0... Those terms govern those components, **and control over these Terms
> in the event of any conflict**."

## The trap was real — and it is sitting in this repo, dated

`Licenses/LICENSE` in this tree (inherited from upstream `f66d4d5`) is the
Community License **as of August 17, 2026**. It contains, verbatim:

- **A language-wide dragnet in the preamble:** the Terms bind anyone
  *"otherwise developing software using Modular's MAX Framework, Magic tooling
  **or Mojo programming language**"* — i.e., writing Mojo at all.
- **A non-compete attached to a programming language** (§2(c)): Licensee shall
  not *"use the SDK in an Application or standalone, **or otherwise develop an
  Application in Mojo, for any Competitive Activity**"*.
- **The commercial hardware trap** (§2.2): production/commercial use is
  unlimited on x86/ARM **CPUs** and **NVIDIA** hardware, but *"for other
  device types... no more than eight (8) other discrete physical accelerator
  devices"*. The Adreno GPU and Hexagon NPU are neither CPUs nor NVIDIA:
  **Snapdragon accelerators are exactly the monetised class.**
- **A hardware permission gate** (§3(h)): distributed applications *"must only
  be run on hardware expressly supported by MAX"*; custom hardware requires
  written approval *"in its sole discretion"*. A Snapdragon port would need
  Modular's permission.
- Mandatory **logo rights** for commercial users (§2.3), a reserved right to
  **start charging** (§6), and mandatory telemetry (§2).

So the suspicion is confirmed: free-on-NVIDIA, gated-everywhere-else, with a
language non-compete stapled on. That is a commercial-use trap by any
engineering definition.

## Then it changed — on August 18, one day later

The website version (Last Modified **August 18, 2026**) removed all of it. The
FAQ admits the old shape plainly: *"The old license capped free production use
at eight accelerators outside x86, ARM and NVIDIA... Both requirements are now
gone."* The Mojo non-compete and the "developing software using Mojo" preamble
are gone too. This has the unmistakable rhythm of a backlash correction.

Consequence for this tree: **`Licenses/LICENSE` here is the stale, harsher
Aug 17 text.** A future rebase onto upstream will presumably refresh it.

## The trap did not die. It moved — and it is aimed at projects like this one

The Aug 18 license adds §1.3:

> "You shall not use MAX, or any portion of it, as training data, fine-tuning
> data, or input to any AI system **in order to produce software that
> reimplements or substitutes for MAX**... This does not restrict using AI
> tools to read, analyze, improve, or explain MAX, **or to develop Your own
> software that runs on or interoperates with MAX**."

And the Terms of Use add a defined term, **"AI-Derived Work"**: any work based
on Modular IP produced through an AI system, expressly including
*"translations, ports, transpilations, refactorings"* — with language that
**clean-room separation does not exempt** a work if Modular IP was used as
*"input, reference, or inspiration"*. Its operative clause (ToU §3.1(iv))
prohibits reverse-engineering *"the Modular Platform or Modular IP including
through the use of AI Technologies to create any AI-Derived Works"*. §3.1(ii)
separately prohibits using the Platform *"or any insights derived from your
use"* to develop competing products.

An AI-assisted port that reimplements MAX's device ABI is, of course, a fair
description of DragonMax. The clause is aimed at this genus of project.

## Why it does not reach this project — the load-bearing facts

1. **Formation.** The ToU binds on "accessing Modular Offerings" — their
   hosted platform and account services. The Community License binds on
   downloading their SDK. **Neither event has ever occurred in this project**:
   no Modular account, no wheel, no prebuilt toolchain (the `prebuilt-mojo`
   path is impossible on Windows — a fact that is now legally convenient).
   Everything came from a public GitHub repository whose every file offers
   itself under Apache.
2. **The Apache grant.** Apache 2.0 permits derivative works, commercial use,
   any hardware, with no field-of-use or AI restrictions — and the Community
   License's own supremacy clause concedes Apache controls for those
   components. A side document cannot retroactively encumber an irrevocable
   grant attached to the files.
3. **What was actually consulted.** `dragonrt` was specified from ABI
   *declarations* in Apache-licensed `.mojo` files (the journal records the
   provenance day by day). Modular's implementation was never accessed,
   decompiled, or possessed — it does not exist for this platform.
4. **The carve-out.** Even the new §1.3 explicitly blesses developing
   *"Your own software that runs on or interoperates with MAX"*. An
   ABI-compatible runtime is interoperation by definition.

## The bright-line rule this imposes (adopted)

> **Never introduce Modular's binary distributions, wheels, hosted services,
> or an account into this project or WINMOJO.** The moment one is used, the
> ToU/Community License attach to the user, and their AI-Derived-Work and
> "insights" clauses become live against a project that is, in fact, an
> AI-assisted reimplementation. Staying binary-free keeps the whole stack on
> the Apache grant, where none of those clauses exist.

Everything measured this week was achieved without them, so the rule costs
nothing.

## Residual notes

- **Trademarks are a separate axis from licensing.** "MAX" and "Mojo" are
  Modular marks. "MAX-compatible"/"MAX-class" as used in our docs is
  nominative use (naming the thing interoperated with) — the defensible form.
  The GitHub repo name `maxdragon` leads with their mark; if this ever grows
  commercial weight, renaming toward `dragonmax` is a cheap de-risking.
- **The other license in this stack is Qualcomm's.** QAIRT ships
  `LICENSE.pdf`; it governs redistribution of the Qnn DLLs. Irrelevant to the
  GPU line (dragonrt uses the system OpenCL driver, nothing redistributed),
  relevant the day the NPU line ships Qnn DLLs alongside a product. Read
  before shipping.
- Governing law California; disputes to arbitration in San Mateo County —
  standard, noted for completeness.
