# adreno_saxpy_debug

saxpy with its working shown.

The index probe proved every work-item computes the right index and writes
the right slot. saxpy still fails verification, so the difference has to be
in what saxpy does that the probe does not: READ from device buffers that
were populated by a host-to-device copy. This prints expected against actual
for a few slots, plus what a pure passthrough kernel (dst = x) sees, which
separates "the copy never landed" from "the arithmetic is wrong".

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```
