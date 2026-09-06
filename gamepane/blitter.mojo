# ===----------------------------------------------------------------------=== #
# The blitter: a small bank of GPU planes, and four kernels between them.
#
# The model, and it is deliberately small:
#
#   slot 0, 1   FRONT and BACK -- the display pair, screen sized
#   slot 2..7   DATA -- sprite sheets, tile maps, whatever the level needs
#
# Eight slots, all resident in VRAM, all the same kind of thing: a plane of
# colour indices. A game loads slots 2..7 ONCE, when a level starts, and
# then spends the level blitting rectangles out of them into the back
# buffer. Swap, present, repeat. Nothing goes near the host in a frame.
#
# That is the Amiga's blitter and it is the right shape for a discrete
# card, which is the correction that matters here: the previous port put
# its planes in PINNED HOST memory, because on the Apple Silicon machine it
# was ported from, host and device memory are the same memory. On a card in
# a PCIe slot they are emphatically not, and every byte a kernel touched
# would have crossed the bus. See buffers.mojo.
#
# This layer is what the assembly reference does not have and is the reason
# to do the port in Mojo. RASM blits with a PIXEL SHADER over RGBA layer
# textures -- compositing things already drawn. These are COMPUTE kernels
# over the index bytes themselves: below the palette, before any
# rasterisation. Same idea, one level down, and the kernels are ordinary
# Mojo `def`s with no platform in them -- PTX here, AIR on a Mac.
#
# One correction to the old kernels, which would have been invisible: every
# launch there passed `grid_dim=grid[0], block_dim=BLOCK` -- a 1-D grid of
# 1-D blocks -- while the kernels all read `global_idx.y` and guarded on it.
# Under a 1-D launch `global_idx.y` is always zero, so every blit would have
# copied ROW ZERO and nothing else. The row count was computed and thrown
# away at all four call sites. Nothing ever constructed a Blitter, so it
# never showed.
# ===----------------------------------------------------------------------=== #

from max.gpu.host import DeviceContext, HostBuffer
from std.gpu import global_idx
from std.memory import Pointer
from .buffers import GpuBuffer

comptime OP_AND = 0
comptime OP_OR = 1
comptime OP_XOR = 2

comptime SLOT_COUNT = 8
comptime SLOT_DATA_FIRST = 2
"""Slots 0 and 1 are the display pair; 2..7 are the game's own."""

comptime BLOCK = 16
"""A 16x16 threadgroup: 256 threads, one per destination pixel."""


@fieldwise_init
struct BlitRect(ImplicitlyCopyable, Copyable, Movable):
    """A clipped blit: where from, where to, and how much.

    `empty` rather than an error, because clipping a rectangle to nothing
    is the ordinary outcome of moving a sprite off the edge of the world,
    not a mistake anybody made.
    """

    var src_x: Int
    var src_y: Int
    var dst_x: Int
    var dst_y: Int
    var w: Int
    var h: Int

    def empty(self) -> Bool:
        return self.w <= 0 or self.h <= 0


def clip_blit(
    src_x: Int, src_y: Int, dst_x: Int, dst_y: Int, w: Int, h: Int,
    src_w: Int, src_h: Int, dst_w: Int, dst_h: Int,
) -> BlitRect:
    """Trim a requested blit until it is inside BOTH planes.

    Pure arithmetic, no GPU, which is why it is testable on its own. Both
    origins move together when an edge trims: shrinking the source without
    shifting the destination is how a sprite smears at a screen edge.
    """
    var sx = src_x
    var sy = src_y
    var dx = dst_x
    var dy = dst_y
    var rw = w
    var rh = h

    if sx < 0:
        rw += sx
        dx -= sx
        sx = 0
    if sy < 0:
        rh += sy
        dy -= sy
        sy = 0
    if dx < 0:
        rw += dx
        sx -= dx
        dx = 0
    if dy < 0:
        rh += dy
        sy -= dy
        dy = 0

    if sx + rw > src_w:
        rw = src_w - sx
    if sy + rh > src_h:
        rh = src_h - sy
    if dx + rw > dst_w:
        rw = dst_w - dx
    if dy + rh > dst_h:
        rh = dst_h - dy

    if rw < 0:
        rw = 0
    if rh < 0:
        rh = 0
    return BlitRect(sx, sy, dx, dy, rw, rh)


# ── the kernels ─────────────────────────────────────────────────────────────
#
# One thread per destination pixel over a (w, h) grid. The rectangle is
# clipped against both planes before launch, so the only bounds test left is
# the grid's own rounding: a grid is whole threadgroups, and the last one in
# each direction runs off the end of a rectangle whose size is not a
# multiple of the block.


def blit_copy_kernel(
    src: Pointer[UInt8, MutAnyOrigin],
    dst: Pointer[UInt8, MutAnyOrigin],
    src_stride: Int32, dst_stride: Int32,
    src_x: Int32, src_y: Int32, dst_x: Int32, dst_y: Int32,
    w: Int32, h: Int32,
):
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    dst[
        unsafe_offset = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    ] = src[
        unsafe_offset = (Int(src_y) + gy) * Int(src_stride) + Int(src_x) + gx
    ]


def blit_keyed_kernel(
    src: Pointer[UInt8, MutAnyOrigin],
    dst: Pointer[UInt8, MutAnyOrigin],
    src_stride: Int32, dst_stride: Int32,
    src_x: Int32, src_y: Int32, dst_x: Int32, dst_y: Int32,
    w: Int32, h: Int32,
):
    """Copy, except that source index 0 leaves the destination alone -- the
    sprite-shaped blit, decades before anyone called one that."""
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    var v = src[
        unsafe_offset = (Int(src_y) + gy) * Int(src_stride) + Int(src_x) + gx
    ]
    if v != 0:
        dst[
            unsafe_offset = (Int(dst_y) + gy) * Int(dst_stride)
            + Int(dst_x) + gx
        ] = v


def blit_op_kernel(
    src: Pointer[UInt8, MutAnyOrigin],
    dst: Pointer[UInt8, MutAnyOrigin],
    src_stride: Int32, dst_stride: Int32,
    src_x: Int32, src_y: Int32, dst_x: Int32, dst_y: Int32,
    w: Int32, h: Int32, op: Int32,
):
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    var s = src[
        unsafe_offset = (Int(src_y) + gy) * Int(src_stride) + Int(src_x) + gx
    ]
    var o = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    var d = dst[unsafe_offset=o]
    if op == Int32(OP_AND):
        dst[unsafe_offset=o] = s & d
    elif op == Int32(OP_OR):
        dst[unsafe_offset=o] = s | d
    else:
        dst[unsafe_offset=o] = s ^ d


def blit_fill_kernel(
    dst: Pointer[UInt8, MutAnyOrigin],
    dst_stride: Int32,
    dst_x: Int32, dst_y: Int32, w: Int32, h: Int32, index: UInt8,
):
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    dst[
        unsafe_offset = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    ] = index


struct Planes(Movable):
    """The bank: eight GPU planes and the blits between them.

    Slots are addressed by number because that is how a game thinks about
    them -- "blit the ship out of 2 into the back buffer" -- and because it
    keeps every device address inside this one owner. The old blitter held
    a `List[Int]` of addresses borrowed from a pane that rebuilt them on
    every buffer swap, and was declared Copyable on top of that.
    """

    var ctx: DeviceContext
    var width: Int
    var height: Int
    var slots: List[GpuBuffer]
    var front: Int
    """0 or 1. The other one is the back buffer."""

    def __init__(
        out self, ctx: DeviceContext, width: Int, height: Int
    ) raises:
        self.ctx = ctx
        self.width = width
        self.height = height
        self.front = 0
        self.slots = List[GpuBuffer]()
        # The display pair, screen sized.
        self.slots.append(GpuBuffer(ctx, width, height))
        self.slots.append(GpuBuffer(ctx, width, height))
        # The data slots start as placeholders; `load` gives them their
        # real size. A slot nobody loads costs one byte of VRAM.
        for _ in range(SLOT_DATA_FIRST, SLOT_COUNT):
            self.slots.append(GpuBuffer(ctx, 1, 1))

    def back(self) -> Int:
        """The slot a game draws into this frame."""
        return 1 - self.front

    def swap(mut self):
        """The back buffer becomes the front. Nothing moves: the slots
        exchange roles, which is the whole point of having two."""
        self.front = 1 - self.front

    def load(
        mut self, slot: Int, width: Int, height: Int, pixels: List[UInt8]
    ) raises:
        """Give a data slot its contents. Once, when a level starts.

        This is the only host-to-device traffic a game does after startup.
        Slots 0 and 1 are the display pair and are not loadable.
        """
        if slot < SLOT_DATA_FIRST or slot >= SLOT_COUNT:
            raise Error("load: data slots are 2..7")
        var buf = GpuBuffer(self.ctx, width, height)
        buf.upload(pixels)
        self.slots[slot] = buf^

    def size(self, slot: Int) -> Tuple[Int, Int]:
        return (self.slots[slot].width, self.slots[slot].height)

    # ── the blits ───────────────────────────────────────────────────────
    def _grid(self, rect: BlitRect) -> Tuple[Int, Int]:
        """Whole threadgroups in BOTH directions."""
        return (
            (rect.w + BLOCK - 1) // BLOCK,
            (rect.h + BLOCK - 1) // BLOCK,
        )

    def _clip(
        self, src: Int, dst: Int, sx: Int, sy: Int, dx: Int, dy: Int,
        w: Int, h: Int,
    ) -> BlitRect:
        return clip_blit(
            sx, sy, dx, dy, w, h,
            self.slots[src].width, self.slots[src].height,
            self.slots[dst].width, self.slots[dst].height,
        )

    def copy(
        mut self, src: Int, dst: Int, sx: Int, sy: Int, dx: Int, dy: Int,
        w: Int, h: Int,
    ) raises:
        """Every source byte lands."""
        var rect = self._clip(src, dst, sx, sy, dx, dy, w, h)
        if rect.empty():
            return
        var g = self._grid(rect)
        var sa = self.slots[src].addr
        var da = self.slots[dst].addr
        var ss = self.slots[src].stride
        var ds = self.slots[dst].stride
        self.ctx.enqueue_function[blit_copy_kernel](
            Pointer[UInt8, MutAnyOrigin](unsafe_from_address=sa),
            Pointer[UInt8, MutAnyOrigin](unsafe_from_address=da),
            Int32(ss), Int32(ds),
            Int32(rect.src_x), Int32(rect.src_y),
            Int32(rect.dst_x), Int32(rect.dst_y),
            Int32(rect.w), Int32(rect.h),
            grid_dim=(g[0], g[1]), block_dim=(BLOCK, BLOCK),
        )

    def keyed(
        mut self, src: Int, dst: Int, sx: Int, sy: Int, dx: Int, dy: Int,
        w: Int, h: Int,
    ) raises:
        """Source index 0 leaves the destination alone."""
        var rect = self._clip(src, dst, sx, sy, dx, dy, w, h)
        if rect.empty():
            return
        var g = self._grid(rect)
        var sa = self.slots[src].addr
        var da = self.slots[dst].addr
        var ss = self.slots[src].stride
        var ds = self.slots[dst].stride
        self.ctx.enqueue_function[blit_keyed_kernel](
            Pointer[UInt8, MutAnyOrigin](unsafe_from_address=sa),
            Pointer[UInt8, MutAnyOrigin](unsafe_from_address=da),
            Int32(ss), Int32(ds),
            Int32(rect.src_x), Int32(rect.src_y),
            Int32(rect.dst_x), Int32(rect.dst_y),
            Int32(rect.w), Int32(rect.h),
            grid_dim=(g[0], g[1]), block_dim=(BLOCK, BLOCK),
        )

    def op(
        mut self, src: Int, dst: Int, sx: Int, sy: Int, dx: Int, dy: Int,
        w: Int, h: Int, which: Int,
    ) raises:
        """AND, OR or XOR with what is already there."""
        var rect = self._clip(src, dst, sx, sy, dx, dy, w, h)
        if rect.empty():
            return
        var g = self._grid(rect)
        var sa = self.slots[src].addr
        var da = self.slots[dst].addr
        var ss = self.slots[src].stride
        var ds = self.slots[dst].stride
        self.ctx.enqueue_function[blit_op_kernel](
            Pointer[UInt8, MutAnyOrigin](unsafe_from_address=sa),
            Pointer[UInt8, MutAnyOrigin](unsafe_from_address=da),
            Int32(ss), Int32(ds),
            Int32(rect.src_x), Int32(rect.src_y),
            Int32(rect.dst_x), Int32(rect.dst_y),
            Int32(rect.w), Int32(rect.h), Int32(which),
            grid_dim=(g[0], g[1]), block_dim=(BLOCK, BLOCK),
        )

    def fill(
        mut self, dst: Int, dx: Int, dy: Int, w: Int, h: Int, index: UInt8
    ) raises:
        """A constant, no source. Clearing the back buffer is this."""
        var rect = self._clip(dst, dst, 0, 0, dx, dy, w, h)
        if rect.empty():
            return
        var g = self._grid(rect)
        var da = self.slots[dst].addr
        var ds = self.slots[dst].stride
        self.ctx.enqueue_function[blit_fill_kernel](
            Pointer[UInt8, MutAnyOrigin](unsafe_from_address=da),
            Int32(ds),
            Int32(rect.dst_x), Int32(rect.dst_y),
            Int32(rect.w), Int32(rect.h), index,
            grid_dim=(g[0], g[1]), block_dim=(BLOCK, BLOCK),
        )

    def finish(mut self) raises:
        """Every enqueued blit complete.

        Blits go on the runtime's stream and the frame is presented on the
        swap chain's own path -- two submission routes to one GPU with
        nothing implicitly ordering them. Anything that reads blitted bytes
        calls this first.
        """
        self.ctx.synchronize()

    def read_front(mut self, mut into: HostBuffer[DType.uint8]) raises:
        """The front buffer's bytes on the host, for the swapchain.

        The only device-to-host traffic in a steady frame, and the only
        place the design touches the bus at all: 230,400 bytes at 640x360,
        about 0.09% of PCIe at 60Hz. It exists because nvptxrt has no
        CUDA/D3D11 interop -- registering the D3D11 texture with CUDA and
        letting a kernel write it directly is the upgrade that removes it.
        """
        self.slots[self.front].download(into)
