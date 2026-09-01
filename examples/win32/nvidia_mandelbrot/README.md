# nvidia_mandelbrot

===----------------------------------------------------------------------=== #
Mandelbrot on an NVIDIA Blackwell GPU, in a window, zooming.

./bazelw.cmd build //examples/win32:nvidia_mandelbrot
./bazel-bin/examples/win32/nvidia_mandelbrot.exe

The Julia demo was honest about cheating: the picture came out of a pixel
shader, so the GPU was doing the work but Mojo was only describing it in
HLSL. This is the other way round. Every pixel is computed by a Mojo kernel
compiled to PTX and executed through the NVIDIA CUDA driver; Direct3D is
reduced to a texture upload and a fullscreen triangle, and the only HLSL
left is a colour ramp.

saxpy proved the pipeline but almost nothing about the compiler: no branch,
no loop, every work-item identical. Mandelbrot is the opposite shape -- a
data-dependent loop whose trip count runs from 1 to MAX_ITER per work-item,
which is where threads in a warp diverge and where NVPTX control flow has to
hold up.

Before the window opens the same computation runs on the CPU and the two are
compared. A picture that looks right is not evidence: a Mandelbrot set is
recognisable long before it is correct.
===----------------------------------------------------------------------=== #

Run it from the IDE with Build > Run Without Debugging, or from a
terminal:

```
mojo run main.mojo
```
