"""The blitter: four Mojo GPU kernels over the index bytes.

A bitblt between any two of the indexed pane's eight slots -- copy,
colour-keyed copy, a bitwise combine, a rectangular fill -- carried over
from the Metal backend VERBATIM, because these kernels never knew they
were on a Mac. They are ordinary Mojo `def`s over plain pointers; the
compiler turns them into PTX here and into AIR there, and the runtime
launches them. That is the port's whole thesis in one file.

**They write the same bytes the CPU drew through.** The pointers a blit
takes are the pane slots' DEVICE addresses -- the device-mapped half of
the pinned allocations the game draws into through their host addresses.
There is no mirror and nothing to keep in step.

**The ordering rule.** A blit is enqueued on the runtime's stream and the
frame is presented on the swap chain's own path -- two different
submission paths to the same GPU. `GamePane.begin_frame` synchronises
before anything reads pane bytes, so a game that blits and then presents
in the same frame is already correct; the rule is written here because
this is where it can be broken.
"""

from std.gpu import global_idx
from std.memory import Pointer
from max.gpu.host import DeviceContext

from gamepane.api import BlitRect, clip_blit, OP_AND, OP_OR, OP_XOR


# One thread per destination pixel, a (w, h) grid. The rectangle has
# already been clipped against both planes before launch, so the only
# bounds check left is the grid's own rounding -- a grid is whole
# threadgroups, and the last one runs off the end of a rectangle whose
# size is not a multiple of the block.

comptime BLOCK = 16


def blit_grid(rect: BlitRect) -> Tuple[Int, Int]:
    """The launch grid for a clipped rectangle: whole threadgroups, one
    thread per destination pixel."""
    var w = rect.w
    var h = rect.h
    if w <= 0 or h <= 0:
        return (1, 1)
    return ((w + BLOCK - 1) // BLOCK, (h + BLOCK - 1) // BLOCK)


def blit_copy_kernel(
    src: Pointer[UInt8, MutAnyOrigin],
    dst: Pointer[UInt8, MutAnyOrigin],
    src_stride: Int32,
    dst_stride: Int32,
    src_x: Int32,
    src_y: Int32,
    dst_x: Int32,
    dst_y: Int32,
    w: Int32,
    h: Int32,
):
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    var v = src[
        unsafe_offset = (Int(src_y) + gy) * Int(src_stride) + Int(src_x) + gx
    ]
    dst[
        unsafe_offset = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    ] = v


def blit_transparent_kernel(
    src: Pointer[UInt8, MutAnyOrigin],
    dst: Pointer[UInt8, MutAnyOrigin],
    src_stride: Int32,
    dst_stride: Int32,
    src_x: Int32,
    src_y: Int32,
    dst_x: Int32,
    dst_y: Int32,
    w: Int32,
    h: Int32,
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


def blit_minterm_kernel(
    src: Pointer[UInt8, MutAnyOrigin],
    dst: Pointer[UInt8, MutAnyOrigin],
    src_stride: Int32,
    dst_stride: Int32,
    src_x: Int32,
    src_y: Int32,
    dst_x: Int32,
    dst_y: Int32,
    w: Int32,
    h: Int32,
    op: Int32,
):
    """AND / OR / XOR against the destination -- the Amiga's minterms, the
    three of the two hundred fifty-six that retro games actually used."""
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    var s = src[
        unsafe_offset = (Int(src_y) + gy) * Int(src_stride) + Int(src_x) + gx
    ]
    var di = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    var d = dst[unsafe_offset=di]
    if op == Int32(OP_AND):
        dst[unsafe_offset=di] = s & d
    elif op == Int32(OP_OR):
        dst[unsafe_offset=di] = s | d
    else:
        dst[unsafe_offset=di] = s ^ d


def blit_fill_kernel(
    dst: Pointer[UInt8, MutAnyOrigin],
    dst_stride: Int32,
    dst_x: Int32,
    dst_y: Int32,
    w: Int32,
    h: Int32,
    index: UInt8,
):
    var gx = Int(global_idx.x)
    var gy = Int(global_idx.y)
    if gx >= Int(w) or gy >= Int(h):
        return
    dst[
        unsafe_offset = (Int(dst_y) + gy) * Int(dst_stride) + Int(dst_x) + gx
    ] = index


# ── the facade ──────────────────────────────────────────────────────────────


@fieldwise_init
struct Blitter(Copyable, Movable):
    """The kernels, with the pane's geometry wired in.

    A game asks for a blit by slot and rectangle; this clips against the
    world once -- here, on the CPU, which is why `clip_blit` lives in the
    api tier -- resolves both slots to device addresses, and launches.
    The slots list is rebuilt by the pane after every `swap_buffers`, so
    the permutation is the pane's business and the blitter never sees it.
    """

    var ctx: DeviceContext
    var slots: List[Int]
    """Device address per logical slot, in the pane's CURRENT permutation."""
    var stride: Int
    var world_w: Int
    var world_h: Int

    def warm_up(mut self) raises:
        """Compile and launch each kernel once over a tiny corner of the
        world, so the first real blit of a game is a launch, not a
        compiler."""
        var rect = clip_blit(0, 0, 0, 0, 2, 2, self.world_w, self.world_h,
                             self.world_w, self.world_h)
        self.fill(0, rect, UInt8(0))
        self.copy(0, 1, rect)
        self.transparent(0, 1, rect)
        self.minterm(0, 1, rect, Int32(OP_XOR))
        self.finish()

    def copy(mut self, src_slot: Int, dst_slot: Int, rect: BlitRect) raises:
        if rect.empty():
            return
        var grid = blit_grid(rect)
        self.ctx.enqueue_function[blit_copy_kernel](
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=self.slots[src_slot]
            ),
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=self.slots[dst_slot]
            ),
            Int32(self.stride),
            Int32(self.stride),
            Int32(rect.src_x),
            Int32(rect.src_y),
            Int32(rect.dst_x),
            Int32(rect.dst_y),
            Int32(rect.w),
            Int32(rect.h),
            grid_dim=grid[0],
            block_dim=BLOCK,
        )

    def transparent(
        mut self, src_slot: Int, dst_slot: Int, rect: BlitRect
    ) raises:
        if rect.empty():
            return
        var grid = blit_grid(rect)
        self.ctx.enqueue_function[blit_transparent_kernel](
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=self.slots[src_slot]
            ),
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=self.slots[dst_slot]
            ),
            Int32(self.stride),
            Int32(self.stride),
            Int32(rect.src_x),
            Int32(rect.src_y),
            Int32(rect.dst_x),
            Int32(rect.dst_y),
            Int32(rect.w),
            Int32(rect.h),
            grid_dim=grid[0],
            block_dim=BLOCK,
        )

    def minterm(
        mut self, src_slot: Int, dst_slot: Int, rect: BlitRect, op: Int32
    ) raises:
        if rect.empty():
            return
        var grid = blit_grid(rect)
        self.ctx.enqueue_function[blit_minterm_kernel](
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=self.slots[src_slot]
            ),
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=self.slots[dst_slot]
            ),
            Int32(self.stride),
            Int32(self.stride),
            Int32(rect.src_x),
            Int32(rect.src_y),
            Int32(rect.dst_x),
            Int32(rect.dst_y),
            Int32(rect.w),
            Int32(rect.h),
            op,
            grid_dim=grid[0],
            block_dim=BLOCK,
        )

    def fill(mut self, slot: Int, rect: BlitRect, index: UInt8) raises:
        if rect.empty():
            return
        var grid = blit_grid(rect)
        self.ctx.enqueue_function[blit_fill_kernel](
            Pointer[UInt8, MutAnyOrigin](
                unsafe_from_address=self.slots[slot]
            ),
            Int32(self.stride),
            Int32(rect.dst_x),
            Int32(rect.dst_y),
            Int32(rect.w),
            Int32(rect.h),
            index,
            grid_dim=grid[0],
            block_dim=BLOCK,
        )

    def finish(mut self) raises:
        """Every enqueued blit complete. The ordering rule, callable."""
        self.ctx.synchronize()
