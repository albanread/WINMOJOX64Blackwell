# ===----------------------------------------------------------------------=== #
# Buffers you blit between.
#
# The high-level concept, and the one the previous port got wrong: a game
# owns some number of INDEX BUFFERS that live on the GPU, loads them once --
# at level start, not per frame -- and then blits rectangles between them.
# One of them is the screen. That is the Amiga's model and it is the right
# one for a discrete card.
#
# The old design allocated its planes with `enqueue_create_host_buffer`,
# which is `cuMemHostAlloc` + `cuMemHostGetDevicePointer`: PINNED HOST RAM
# with a device-side address. On Apple Silicon that is free -- one pool of
# memory, the CPU and GPU both addressing it, which is exactly what the
# Metal backend was built on and why the comment in the old blitter says
# "there is no mirror and nothing to keep in step". On an NVIDIA card in a
# PCIe slot it means every single access a kernel makes to those bytes is a
# bus transaction. A full-screen blit becomes a quarter of a million
# uncached round trips.
#
# So: `GpuBuffer` is `cuMemAlloc` -- real device-local VRAM. Uploads are
# explicit and rare. Blits are GPU to GPU and touch the host not at all.
#
# The one place the host is unavoidable today is the last step, getting the
# screen buffer into the D3D11 texture, because nvptxrt has no CUDA/D3D11
# interop (no cuGraphicsD3D11RegisterResource anywhere). That costs one
# device-to-host copy of the plane per frame -- 230,400 bytes at 640x360,
# about 0.09% of the bus at 60Hz, so it is not worth contorting the design
# over. Registering the D3D11 texture with CUDA and letting a kernel write
# it directly is the upgrade that removes even that, and it is additive:
# nvptxrt already loads every CUDA entry point out of nvcuda.dll by name.
# ===----------------------------------------------------------------------=== #

from max.gpu.host import DeviceBuffer, DeviceContext, HostBuffer
from std.memory import Pointer
from .device import device_ptr_device, host_ptr


struct GpuBuffer(Movable):
    """A rectangular plane of colour INDICES, resident on the GPU.

    One byte a pixel. Rows are `stride` apart, which is the width rounded
    up so a blit's inner loop is aligned; a writer addresses
    `y * stride + x` and never `y * width + x`.

    Movable and not Copyable on purpose. It owns a device allocation, and a
    copy would be a second handle to the same VRAM with no say in when it
    is freed -- which is the shape of the bug that the old `Blitter` had
    when it was declared `Copyable` over a list of borrowed addresses.
    """

    var ctx: DeviceContext
    var width: Int
    var height: Int
    var stride: Int
    var mem: DeviceBuffer[DType.uint8]
    var addr: Int
    """The device address a kernel argument carries."""

    def __init__(
        out self, ctx: DeviceContext, width: Int, height: Int
    ) raises:
        if width <= 0 or height <= 0:
            raise Error("GpuBuffer: a plane needs a positive size")
        self.ctx = ctx
        self.width = width
        self.height = height
        self.stride = (width + 15) & ~15
        self.mem = ctx.enqueue_create_buffer[DType.uint8](
            self.stride * height
        )
        self.addr = device_ptr_device(self.mem)
        if self.addr == 0:
            raise Error("GpuBuffer: allocation has no device address")

    def upload(mut self, pixels: List[UInt8]) raises:
        """Fill the plane from host bytes, row by row into the stride.

        This is the once-a-level call. `pixels` is tightly packed at
        `width` bytes a row; the plane is `stride`, so the rows are spread
        out on the way in rather than the game having to know the stride.
        """
        if len(pixels) < self.width * self.height:
            raise Error("upload: not enough pixels for the plane")
        var staging = self.ctx.enqueue_create_host_buffer[DType.uint8](
            self.stride * self.height
        )
        self.ctx.synchronize()
        var p = host_ptr(staging)
        for y in range(self.height):
            var src = y * self.width
            var dst = y * self.stride
            for x in range(self.width):
                p[unsafe_offset = dst + x] = pixels[src + x]
        self.mem.enqueue_copy_from(staging)
        self.ctx.synchronize()

    def download(mut self, mut into: HostBuffer[DType.uint8]) raises:
        """The plane's bytes back on the host, stride intact.

        The screen buffer's per-frame trip to the swapchain, and the only
        host traffic in a steady-state frame. `into` is expected to be a
        pinned buffer the caller keeps -- allocating one per frame would
        cost more than the copy does.
        """
        self.mem.enqueue_copy_to(into)
