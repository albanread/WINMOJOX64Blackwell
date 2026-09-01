# adreno_saxpy

===----------------------------------------------------------------------=== #
The DragonMax GPU acceptance test, ported to this compiler's dialect.

Passes when:
mojo build --target-accelerator adreno-x1 adreno_saxpy.mojo && ./adreno_saxpy
runs the kernel on the Adreno X1-45 and every element verifies on the host.

Deliberately contains nothing DragonMax-specific: the objective is that Mojo
code stays standard Mojo -- the same program you would write for an NVIDIA
card. Ported from dragon/mojo-tests/adreno_saxpy.mojo, whose HANDOFF caveat
said the SHAPE is the contract, not the spellings: `fn` became `def` (removed
from the language) and the pointer spelling moved with the stdlib. Nothing
else changed.
===----------------------------------------------------------------------=== #

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```
