# d3dwindow

A window, cleared and presented through Direct3D 11, from Mojo on Windows
ARM64. Struct layouts are checked against the Win32 metadata by the
compiler; COM vtable slots are queries against the same metadata.

Origin rules, learned the hard way (see structptr.mojo):
- variadic calls take Pointer(to=local) with its TRUE origin, no cast;
- declared COM signatures spell Mojo-owned pointers over AnyOrigin and
call sites cast to AnyOrigin, which keeps the aliasing;
- Untracked is only for pointers Windows hands us.

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```
