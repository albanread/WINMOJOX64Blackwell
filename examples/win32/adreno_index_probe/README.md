# adreno_index_probe

What index does each work-item think it has?

saxpy now creates, launches and returns without an OpenCL error, and most
elements are still wrong -- which points at the index each work-item computes
rather than at the arithmetic. So: write the index itself, leave the buffer
pre-filled with a sentinel, and read back what actually landed where.

Each of the three terms is written separately, so a wrong one is identifiable
rather than merely visible in the sum.

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```
