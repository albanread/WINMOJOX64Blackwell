# HTP runtime pairings — what works, and the failure that faked a wedge

## The correction

On 2026-08-19 I reported that the Hexagon DSP had **wedged** and needed a
reboot. **That was wrong.** The DSP never wedged. The device was healthy the
whole time, and a *different* QNN runtime on the same machine kept working
throughout.

What actually happened: the QAIRT **2.42** runtime stopped being able to open
DSP sessions, while GenieX's bundled QAIRT **2.45** ran the identical model on
the identical device without complaint.

The evidence that settled it:

| Runtime | Skels | 4 MiB model | 128 MiB model |
|---|---|---|---|
| SDK QAIRT 2.42 | SDK `hexagon-v81/unsigned` | ran, then **stopped** | **fails** |
| GenieX QAIRT 2.45 | GenieX `htp-files` | **ok** (395 ms) | **ok** (555 ms) |

So the "128 MiB ceiling" was also fiction — 128 MiB runs fine. Two false
conclusions in one afternoon, both from the same root cause.

## Why the control discipline was still not enough

The rule I put in place was "after any HTP failure, re-run a known-good small
model as a control". That control failed, which looked like proof of a wedge.

**It wasn't proof, because the control used the same runtime as the failing
run.** A control has to vary the thing you suspect. The correct control is *a
different QNN runtime against the same device* — that immediately separates
"the hardware is broken" from "this software stack is broken".

Recorded because it generalises: a control that shares the suspected fault with
the test is not a control.

## The pairing rule

Runtime and skel are strictly version-matched, and mismatching them gives an
honest error rather than a mysterious one:

```
Skel lib id mismatch: expected (v2.42.0.251225135753_193295),
                      detected (v2.45.0.260326154327)
```

Note what that reveals: **GenieX ships QAIRT 2.45.0.260326, newer than the
2.42.0.251225 available from the public SDK URL.** The package number confusion
from earlier resolves too — the 2.42 package declares `QNN_API_VERSION 2.32.0`,
while GenieX's reports core 2.34.0, exactly because it is a later package.

## Current working configuration

```powershell
$G = "C:\Program Files (x86)\GenieX CLI\qairt\htp-files"
$env:PATH = "$G;" + $env:PATH
$env:ADSP_LIBRARY_PATH = $G
qnn-net-run.exe --backend "$G\QnnHtp.dll" --model <model.dll> ...
```

The model DLL is runtime-agnostic — it is built against the 2.42 headers and
runs fine on the 2.45 runtime, because it only uses the stable
`QnnModel_composeGraphs` entry point.

## Open question: why did 2.42 stop working?

Unresolved, and worth resolving because we would rather build on the SDK than
on a runtime bundled inside someone's CLI tool.

The leading hypothesis is **unsigned process domains**. The SDK ships *only*
`lib/hexagon-v81/unsigned/`, and `qnn-platform-validator` volunteered "Please
use testsig if using unsigned images" on its first failure. Unsigned PDs are a
restricted resource; if their session slots leak or exhaust, you would see
exactly this — works a few times, then refuses to open a session, while a
signed stack is unaffected.

`QnnHtpDevice.h` exposes `QnnHtpDevice_UseSignedProcessDomain_t` as a device
config, which is the lever to test that with.

Not yet established. Do not write it up as the cause until it is.

## Next actions

1. Download QAIRT **2.45** so headers, runtime and skels all match, instead of
   borrowing GenieX's runtime. Same public URL pattern, version string
   `2.45.0.260326`.
2. Test the signed/unsigned PD hypothesis via `QnnHtpDevice_UseSignedProcessDomain_t`.
3. Resume the ceiling sweep on a known-good pairing — 128 MiB is now a floor,
   not a ceiling.
