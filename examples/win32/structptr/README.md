# structptr

The minimal struct-by-pointer test. One struct, one API, three idioms, so
the passing and failing spellings sit side by side.

GlobalMemoryStatusEx is the ideal probe: it reads a field the caller must
set (dwLength -- the WNDCLASSEXW cbSize pattern), rejects the call with
ERROR_INVALID_PARAMETER if the pointer or layout is wrong, and writes 64
bytes back on success. Both directions of the ABI in one call.

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```
