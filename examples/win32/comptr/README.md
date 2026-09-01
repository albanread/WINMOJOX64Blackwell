# comptr

ComPtr's ownership claims, asserted against a live COM object rather than
stated. AddRef returns the new count, so every transition is observable:

adopt   -> count unchanged (the out-param's reference is the one adopted)
copy    -> +1
move    -> +0   (the elision C++ cannot prove)
deinit  -> -1
QI      -> +1 on the same underlying object, adopted exactly

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```
