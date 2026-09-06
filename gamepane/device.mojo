"""Direct3D 11 creation and dispatch, in the spellings this tree has
already proven, plus the game pane's bridge to `max.gpu`.

The Windows answer to the Metal backend's `device.mojo`, and the shape of
the port in one file: Metal's "one memory, three readers" is unified
memory; here it is a **device-mapped pinned allocation**. The CPU stores
through the host pointer, Mojo kernels read and write through the device
pointer of the same bytes (the runtime maps game-pane host buffers with
CU_MEMHOSTALLOC_DEVICEMAP), and Direct3D reads the host side through
`UpdateSubresource` at present time. Three readers, one allocation, no
mirror, no dirty flags -- the same structural property, reached by a
different road.

The D3D11 spellings are d3dwindow's and fernwind's, already proven
against this metadata: a flattened `DXGI_SWAP_CHAIN_DESC` whose field
offsets are asserted, `win32[]` for `D3D11CreateDeviceAndSwapChain`, and
`com_method_of` for every interface call with the IID or the vtable slot
resolved from the database. Nothing here is a hand-written GUID or a
transcribed slot number.

**The lifetime rule, which is the whole hazard.** `device_ptr` returns an
address that is only as alive as the buffer that owns it, and Mojo
destroys a value at its LAST USE rather than at the end of the scope.
Every pane keeps its buffers as fields, which is where they belong anyway.
"""

from std.ffi import external_call, c_int
from max.gpu.host import DeviceBuffer, HostBuffer
from std.windows import get_environment
from std.windows.gui import win32
from std.memory import Pointer, OpaquePointer
from std.sys._com import com_addr, com_method_of, _guid_bytes
from std.sys._winkb import winkb_constant, winkb_interface_iid, winkb_struct_size, winkb_field_offset
from std.sys._win32 import Win32Module


def device_ptr(buf: HostBuffer[DType.uint8]) -> Int:
    return Int(
        external_call["AsyncRT_DeviceBuffer_devicePtr", UInt64](buf._handle)
    )


def device_ptr_device[dtype: DType](buf: DeviceBuffer[dtype]) -> Int:
    """The GPU-visible address of a device-mapped host buffer.

    This is what a kernel argument carries: the GPU dereferences it and
    lands on the same bytes the CPU writes through the host pointer. Zero
    means the allocation is not device-mapped -- report that, never pass a
    null through a launch.
    """
    return Int(
        external_call["AsyncRT_DeviceBuffer_devicePtr", UInt64](buf._handle)
    )


def host_ptr[dtype: DType](buf: HostBuffer[dtype]) -> Pointer[UInt8, MutUntrackedOrigin]:
    """The CPU address of a host buffer's bytes -- the drawing surface."""
    return Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )


# ── D3D11 structures ────────────────────────────────────────────────────────


@fieldwise_init
struct DXGI_SWAP_CHAIN_DESC(Defaultable, Copyable, Movable):
    def __init__(out self):
        self.Width = 0
        self.Height = 0
        self.RefreshRateNumerator = 0
        self.RefreshRateDenominator = 0
        self.Format = 0
        self.ScanlineOrdering = 0
        self.Scaling = 0
        self.SampleCount = 0
        self.SampleQuality = 0
        self.BufferUsage = 0
        self.BufferCount = 0
        self.OutputWindow = 0
        self.Windowed = 0
        self.SwapEffect = 0
        self.Flags = 0

    var Width: UInt32
    var Height: UInt32
    var RefreshRateNumerator: UInt32
    var RefreshRateDenominator: UInt32
    var Format: UInt32
    var ScanlineOrdering: UInt32
    var Scaling: UInt32
    var SampleCount: UInt32
    var SampleQuality: UInt32
    var BufferUsage: UInt32
    var BufferCount: UInt32
    var OutputWindow: Int  # at 48, after 4 bytes of padding
    var Windowed: Int32
    var SwapEffect: UInt32
    var Flags: UInt32


@fieldwise_init
struct D3D11_TEXTURE2D_DESC(Defaultable, Copyable, Movable):
    def __init__(out self):
        self.Width = 0
        self.Height = 0
        self.MipLevels = 0
        self.ArraySize = 0
        self.Format = 0
        self.SampleCount = 0
        self.SampleQuality = 0
        self.Usage = 0
        self.BindFlags = 0
        self.CPUAccessFlags = 0
        self.MiscFlags = 0

    var Width: UInt32
    var Height: UInt32
    var MipLevels: UInt32
    var ArraySize: UInt32
    var Format: UInt32
    var SampleCount: UInt32
    var SampleQuality: UInt32
    var Usage: UInt32
    var BindFlags: UInt32
    var CPUAccessFlags: UInt32
    var MiscFlags: UInt32


@fieldwise_init
struct D3D11_MAPPED_SUBRESOURCE(Defaultable, Copyable, Movable):
    def __init__(out self):
        self.data = 0
        self.row_pitch = 0
        self.depth_pitch = 0

    var data: Int
    var row_pitch: UInt32
    var depth_pitch: UInt32


def check_layouts():
    """The layout assertions, run once at pane creation. In this dialect a
    `comptime assert` lives in a function, and abcplayer's `check_layouts`
    is where the same set already lives."""
    comptime assert (
        size_of[DXGI_SWAP_CHAIN_DESC]()
        == winkb_struct_size["DXGI_SWAP_CHAIN_DESC"]()
    ), "DXGI_SWAP_CHAIN_DESC has drifted from the SDK"
    comptime assert (
        size_of[D3D11_TEXTURE2D_DESC]()
        == winkb_struct_size["D3D11_TEXTURE2D_DESC"]()
    ), "D3D11_TEXTURE2D_DESC has drifted from the SDK"
    comptime assert (
        winkb_field_offset["DXGI_SWAP_CHAIN_DESC", "OutputWindow"]() == 48
    ), "OutputWindow must sit at 48: an HWND read from the wrong offset binds a swap chain to nothing, and it fails silently"


# ── typed dispatches, resolved once ─────────────────────────────────────────


comptime SIG_CREATE = def (
    Int,  # pAdapter
    UInt32,  # DriverType
    Int,  # Software
    UInt32,  # Flags
    Int,  # pFeatureLevels
    UInt32,  # FeatureLevels
    UInt32,  # SDKVersion
    Pointer[DXGI_SWAP_CHAIN_DESC, MutAnyOrigin],
    Pointer[Int, MutAnyOrigin],  # ppSwapChain
    Pointer[Int, MutAnyOrigin],  # ppDevice
    Pointer[UInt32, MutAnyOrigin],  # pFeatureLevel
    Pointer[Int, MutAnyOrigin],  # ppImmediateContext
) thin abi("C") -> c_int


def create_device_and_swapchain(
    hwnd: Int, width: Int, height: Int, debug: Bool = False
) raises -> Tuple[Int, Int, Int]:
    """The device, its immediate context, and a flip-model swap chain sized
    to the pane. Returns (swapchain, device, context) as raw addresses."""
    
    var desc = DXGI_SWAP_CHAIN_DESC()
    desc.Width = UInt32(width)
    desc.Height = UInt32(height)
    desc.RefreshRateNumerator = 60
    desc.RefreshRateDenominator = 1
    desc.Format = UInt32(winkb_constant["DXGI_FORMAT_B8G8R8A8_UNORM"]())
    desc.SampleCount = 1
    desc.BufferUsage = UInt32(winkb_constant["DXGI_USAGE_RENDER_TARGET_OUTPUT"]())
    # FLIP_DISCARD needs two buffers or more; one is a validation failure.
    desc.BufferCount = 2
    desc.OutputWindow = hwnd
    desc.Windowed = 1
    desc.SwapEffect = UInt32(winkb_constant["DXGI_SWAP_EFFECT_FLIP_DISCARD"]())

    var create = win32[SIG_CREATE, "D3D11CreateDeviceAndSwapChain"]()
    var flags = UInt32(1 if debug else 0)  # D3D11_CREATE_DEVICE_DEBUG

    var swapchain_addr: Int = 0
    var device_addr: Int = 0
    var level: UInt32 = 0
    var context_addr: Int = 0

    var hr = create(
        Int(0),
        UInt32(winkb_constant["D3D_DRIVER_TYPE_HARDWARE"]()),
        Int(0),
        UInt32(0),
        Int(0),
        UInt32(0),
        UInt32(winkb_constant["D3D11_SDK_VERSION"]()),
        Pointer(to=desc).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=swapchain_addr).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=device_addr).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=level).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=context_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or swapchain_addr == 0:
        raise Error("Direct3D device creation failed, hr = " + String(hr))
    return (swapchain_addr, device_addr, context_addr)


def _iface(addr: Int) -> OpaquePointer[MutUntrackedOrigin]:
    """Wrap an interface pointer Windows handed us. Untracked is their
    documented origin: they alias no value the compiler manages."""
    return OpaquePointer[MutUntrackedOrigin](unsafe_from_address=addr)


def get_back_buffer(swapchain: Int) raises -> Int:
    """Back buffer texture, via GetBuffer with the IID from the metadata."""
    var iid = _guid_bytes(winkb_interface_iid["ID3D11Texture2D"]())
    var get_buffer = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[UInt8, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "IDXGISwapChain",
        "GetBuffer",
    ](_iface(swapchain))
    var backbuf: Int = 0
    var hr = get_buffer(
        _iface(swapchain),
        UInt32(0),
        iid.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=backbuf).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0:
        raise Error("GetBuffer failed, hr = " + String(hr))
    return backbuf


def create_render_target_view(device: Int, resource: Int) raises -> Int:
    var create_rtv = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateRenderTargetView",
    ](_iface(device))
    var rtv: Int = 0
    var hr = create_rtv(
        _iface(device), resource, 0,
        Pointer(to=rtv).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0:
        raise Error("CreateRenderTargetView failed, hr = " + String(hr))
    return rtv


def create_texture2d(
    device: Int, width: Int, height: Int, format: Int, bind: Int,
    usage: Int, cpu_access: Int,
) raises -> Int:
    """A texture of the pane's own: the index plane the compositor samples,
    the palette the shader loads, the staging copy a dump reads."""
    var desc = D3D11_TEXTURE2D_DESC()
    desc.Width = UInt32(width)
    desc.Height = UInt32(height)
    desc.MipLevels = 1
    desc.ArraySize = 1
    desc.Format = UInt32(format)
    desc.SampleCount = 1
    desc.SampleQuality = 0
    desc.Usage = UInt32(usage)
    desc.BindFlags = UInt32(bind)
    desc.CPUAccessFlags = UInt32(cpu_access)
    desc.MiscFlags = 0

    var create_tex = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D3D11_TEXTURE2D_DESC, MutAnyOrigin],
            Int,  # pInitialData
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateTexture2D",
    ](_iface(device))
    var tex: Int = 0
    var hr = create_tex(
        _iface(device),
        Pointer(to=desc).unsafe_origin_cast[MutAnyOrigin](),
        Int(0),
        Pointer(to=tex).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or tex == 0:
        raise Error("CreateTexture2D failed, hr = " + String(hr))
    return tex


def update_subresource(
    context: Int, resource: Int, src: Pointer[UInt8, MutUntrackedOrigin],
    row_pitch: Int,
):
    """One texture's worth of pane bytes, host to GPU.

    This is the compositor's read of the shared allocation: the same bytes
    the CPU drew through and the kernels wrote through, read from the host
    side after the ordering rule has synchronised everything. The parameter
    list is fernwind's, proven: SEVEN parameters, box included -- an
    omitted pDstBox shifts every later argument and hands the runtime a
    garbage source pointer."""
    var update = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,                            # pDstResource
            UInt32,                         # DstSubresource
            Int,                            # pDstBox (NULL)
            Pointer[UInt8, MutAnyOrigin],   # pSrcData
            UInt32,                         # SrcRowPitch, in BYTES
            UInt32,                         # SrcDepthPitch
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "UpdateSubresource",
    ](_iface(context))
    update(
        _iface(context), resource, UInt32(0), 0,
        src.unsafe_origin_cast[MutAnyOrigin](),
        UInt32(row_pitch), UInt32(0),
    )


def set_viewport(context: Int, width: Int, height: Int):
    """The rasteriser's window. D3D11's default viewport is EMPTY -- zero
    size at the origin -- so a pipeline without this call rasterises
    nothing at all: the clear shows, the draw vanishes, and no error is
    reported anywhere."""
    var set_vp = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,  # NumViewports
            Pointer[Float32, MutAnyOrigin],  # pViewports (6 floats each)
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "RSSetViewports",
    ](OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context))
    var vp = List[Float32](length=6, fill=0.0)
    vp[2] = Float32(width)
    vp[3] = Float32(height)
    vp[5] = 1.0
    set_vp(
        OpaquePointer[MutUntrackedOrigin](unsafe_from_address=context),
        UInt32(1),
        vp.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
    )




def dump_info_queue(device: Int) raises:
    """Every stored debug-layer message, to stdout. Requires the device to
    have been created with the DEBUG flag; silent when there are no
    messages."""
    var qi = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[UInt8, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "IUnknown",
        "QueryInterface",
    ](_iface(device))
    var iid = _guid_bytes(winkb_interface_iid["ID3D11InfoQueue"]())
    var iq: Int = 0
    var hr = qi(
        _iface(device),
        iid.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=iq).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or iq == 0:
        return
    var get_num = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32,
        "ID3D11InfoQueue",
        "GetNumStoredMessages",
    ](_iface(iq))
    var count = Int(get_num(_iface(iq)))
    if count == 0:
        _ = iq
        return
    var get_msg = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Int,   # pMessage -- null on the sizing pass
            Pointer[Int, MutAnyOrigin],  # pMessageByteLength
        ) thin abi("C") -> c_int,
        "ID3D11InfoQueue",
        "GetMessage",
    ](_iface(iq))
    for i in range(count):
        var length: Int = 0
        _ = get_msg(
            _iface(iq), UInt32(i), 0,
            Pointer(to=length).unsafe_origin_cast[MutAnyOrigin](),
        )
        if length == 0:
            continue
        var buf = List[UInt8](length=length, fill=0)
        var hr2 = get_msg(
            _iface(iq),
            UInt32(i),
            Int(buf.unsafe_ptr()),
            Pointer(to=length).unsafe_origin_cast[MutAnyOrigin](),
        )
        if hr2 != 0:
            continue
        # D3D11_MESSAGE: pDescription at 0, DescriptionByteLength at 8.
        var base = buf.unsafe_ptr()
        var desc_addr = Int(base.unsafe_bitcast[Int]().unsafe_offset(0)[])
        var text_len = Int(
            base.unsafe_bitcast[Int]().unsafe_offset(1)[]
        )
        var text_ptr = Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=desc_addr
        )
        var out = String("")
        for k in range(text_len):
            out += chr(Int(text_ptr[unsafe_offset=k]))
    _ = iq


def draw(context: Int, vertex_count: Int):
    var draw_fn = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin], UInt32, UInt32) thin abi(
            "C"
        ) -> NoneType,
        "ID3D11DeviceContext",
        "Draw",
    ](_iface(context))
    draw_fn(_iface(context), UInt32(vertex_count), UInt32(0))


@fieldwise_init
struct D3D11_RASTERIZER_DESC(Copyable, Movable):
    """The fields in their ABI order. Only two of them matter here and the
    rest are the documented defaults."""

    var FillMode: UInt32
    var CullMode: UInt32
    var FrontCounterClockwise: Int32
    var DepthBias: Int32
    var DepthBiasClamp: Float32
    var SlopeScaledDepthBias: Float32
    var DepthClipEnable: Int32
    var ScissorEnable: Int32
    var MultisampleEnable: Int32
    var AntialiasedLineEnable: Int32


def create_rasterizer_state(device: Int) raises -> Int:
    """Solid fill, no culling -- the reference's own rasterizer state.

    RASM's canvas (gpu/canvas.was:238-241) sets FILL_SOLID + CULL_NONE and
    binds it every frame. A compositor draws full-screen triangles and
    screen-aligned quads; none of them has a back face worth culling, and
    leaving D3D11's default (CULL_BACK) in place makes whether anything is
    drawn at all depend on a vertex winding nobody states. The old port set
    no rasterizer state and drew black windows.
    """
    var desc = D3D11_RASTERIZER_DESC(
        UInt32(3),   # D3D11_FILL_SOLID
        UInt32(1),   # D3D11_CULL_NONE
        Int32(0), Int32(0), Float32(0.0), Float32(0.0),
        Int32(1),    # DepthClipEnable: the default
        Int32(0), Int32(0), Int32(0),
    )
    var create = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D3D11_RASTERIZER_DESC, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateRasterizerState",
    ](_iface(device))
    var state: Int = 0
    var hr = create(
        _iface(device),
        Pointer(to=desc).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=state).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or state == 0:
        raise Error("CreateRasterizerState failed, hr = " + String(hr))
    return state


def rs_set_state(context: Int, state: Int):
    """Bind the rasterizer state. Cheap, and the reference does it once a
    frame rather than trusting whatever the last pass left behind."""
    var set_state = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "RSSetState",
    ](_iface(context))
    set_state(_iface(context), state)


@fieldwise_init
struct D3D11_SHADER_RESOURCE_VIEW_DESC(Copyable, Movable):
    """Format, dimension, and the TEXTURE2D arm of the union: four UINTs.

    The reference writes this out rather than passing null (gpu/canvas.was
    :207-219). A null description asks D3D11 to infer the view from the
    resource, which is usually the same thing -- but "usually" is how the
    old port ended up with a Texture1D declared in HLSL over a Texture2D
    resource and no error anywhere.
    """

    var Format: UInt32
    var ViewDimension: UInt32
    var MostDetailedMip: UInt32
    var MipLevels: UInt32


def create_srv(device: Int, resource: Int, format: Int) raises -> Int:
    """A whole-resource view over a 2D texture, described explicitly.

    Built once, where the texture is. The reference has nine of these in
    seven thousand lines and every one is in an init path; a view created
    at bind time is the bug that emptied a driver's memory.
    """
    var desc = D3D11_SHADER_RESOURCE_VIEW_DESC(
        UInt32(format),
        UInt32(4),  # D3D11_SRV_DIMENSION_TEXTURE2D
        UInt32(0),
        UInt32(1),
    )
    var make_view = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Pointer[D3D11_SHADER_RESOURCE_VIEW_DESC, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateShaderResourceView",
    ](_iface(device))
    var view: Int = 0
    var hr = make_view(
        _iface(device),
        resource,
        Pointer(to=desc).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=view).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or view == 0:
        raise Error("CreateShaderResourceView failed, hr = " + String(hr))
    return view


def ps_set_shader_resources(context: Int, mut views: List[Int]):
    """Bind every view the shader declares, in one call.

    One call for all of them, as the reference does -- PSSetShaderResources
    (0, 3, srvArray) at gpu/canvas.was:457. Binding a subset leaves the
    rest holding whatever the previous pass put there, and sampling an
    unbound slot returns zero, which reads as black and reports nothing.
    """
    var set_srvs = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetShaderResources",
    ](_iface(context))
    set_srvs(
        _iface(context), UInt32(0), UInt32(len(views)),
        views.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
    )


def vs_set_shader(context: Int, shader: Int):
    var set_vs = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "VSSetShader",
    ](_iface(context))
    set_vs(_iface(context), shader, 0, UInt32(0))


def ps_set_shader(context: Int, shader: Int):
    var set_ps = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetShader",
    ](_iface(context))
    set_ps(_iface(context), shader, 0, UInt32(0))


def ia_set_topology(context: Int, topology: Int):
    """4 is D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST. D3D11's default is
    TRIANGLESTRIP, which renders a fullscreen triangle as three
    disconnected lines and reports nothing."""
    var set_topology = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "IASetPrimitiveTopology",
    ](_iface(context))
    set_topology(_iface(context), UInt32(topology))


def om_set_render_targets(context: Int, rtv: Int):
    var set_targets = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[Int, MutAnyOrigin],
            Int,
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "OMSetRenderTargets",
    ](_iface(context))
    var slot = rtv
    set_targets(
        _iface(context),
        UInt32(1),
        Pointer(to=slot).unsafe_origin_cast[MutAnyOrigin](),
        Int(0),
    )


def clear_render_target(context: Int, rtv: Int, r: Float32, g: Float32, b: Float32):
    var clear = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Pointer[Float32, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "ClearRenderTargetView",
    ](_iface(context))
    var color = List[Float32](length=4, fill=1.0)
    color[0] = r
    color[1] = g
    color[2] = b
    clear(
        _iface(context), rtv,
        color.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
    )


def create_buffer(device: Int, bytes: Int, bind: Int, usage: Int) raises -> Int:
    """A D3D buffer -- the palette's, and the shaders' constants."""
    # D3D11_BUFFER_DESC: 4 x UInt32 + ByteWidth first -- Width, Usage,
    # BindFlags, CPUAccessFlags, MiscFlags, StructureByteStride = 24 bytes.
    var create_buf = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[UInt32, MutAnyOrigin],  # pDesc
            Int,  # pInitialData
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateBuffer",
    ](_iface(device))
    var desc = List[UInt32](length=6, fill=0)
    desc[0] = UInt32(bytes)
    desc[1] = UInt32(usage)
    desc[2] = UInt32(bind)
    var buf: Int = 0
    var hr = create_buf(
        _iface(device),
        desc.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Int(0),
        Pointer(to=buf).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or buf == 0:
        raise Error("CreateBuffer failed, hr = " + String(hr))
    return buf


def create_buffer_dynamic(device: Int, bytes: Int, bind: Int) raises -> Int:
    """A DYNAMIC buffer the CPU writes every frame through Map.

    D3D11_USAGE_DYNAMIC (2) + D3D11_CPU_ACCESS_WRITE (0x10000). The sprite
    pass refills one of these per frame with WRITE_DISCARD and draws every
    instance out of it; the alternative the old port took -- a DEFAULT
    buffer updated per instance with UpdateSubresource -- is a round trip
    per sprite.
    """
    var create_buf = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[UInt32, MutAnyOrigin],
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateBuffer",
    ](_iface(device))
    var desc = List[UInt32](length=6, fill=0)
    desc[0] = UInt32(bytes)
    desc[1] = UInt32(2)         # D3D11_USAGE_DYNAMIC
    desc[2] = UInt32(bind)
    desc[3] = UInt32(0x10000)   # D3D11_CPU_ACCESS_WRITE
    var buf: Int = 0
    var hr = create_buf(
        _iface(device),
        desc.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Int(0),
        Pointer(to=buf).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or buf == 0:
        raise Error("CreateBuffer(dynamic) failed, hr = " + String(hr))
    return buf


def map_write_discard(
    context: Int, resource: Int
) raises -> Pointer[UInt8, MutUntrackedOrigin]:
    """Open a dynamic resource for a whole-buffer rewrite.

    WRITE_DISCARD (4) tells the driver the old contents are dead, so it can
    hand back a fresh region rather than waiting for the GPU to finish with
    the last one. That is what makes a per-frame refill free of a stall.
    """
    var map_fn = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, UInt32, UInt32, UInt32,
            Pointer[D3D11_MAPPED_SUBRESOURCE, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11DeviceContext",
        "Map",
    ](_iface(context))
    var mapped = D3D11_MAPPED_SUBRESOURCE()
    var hr = map_fn(
        _iface(context), resource, UInt32(0), UInt32(4), UInt32(0),
        Pointer(to=mapped).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or mapped.data == 0:
        raise Error("Map failed, hr = " + String(hr))
    return Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=mapped.data
    )


def unmap(context: Int, resource: Int):
    var unmap_fn = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "Unmap",
    ](_iface(context))
    unmap_fn(_iface(context), resource, UInt32(0))


def create_blend_state(device: Int, alpha: Bool) raises -> Int:
    """One of the reference's two blend states (gpu/blit.was:151-173).

    Opaque: BlendEnable FALSE, write mask ALL -- the blend fields are
    ignored. Alpha-over: SRC_ALPHA / INV_SRC_ALPHA with ADD, and
    ONE / INV_SRC_ALPHA for the alpha channel so a sprite drawn over
    another composites rather than replacing it.

    D3D11_BLEND_DESC is AlphaToCoverageEnable, IndependentBlendEnable, then
    eight RenderTarget entries of 32 bytes: BlendEnable, SrcBlend,
    DestBlend, BlendOp, SrcBlendAlpha, DestBlendAlpha, BlendOpAlpha, and a
    one-byte write mask with three bytes of padding. 8 + 8 * 32 = 264.
    """
    var desc = List[UInt32](length=66, fill=0)
    if alpha:
        desc[2] = UInt32(1)   # BlendEnable
        desc[3] = UInt32(5)   # D3D11_BLEND_SRC_ALPHA
        desc[4] = UInt32(6)   # D3D11_BLEND_INV_SRC_ALPHA
        desc[5] = UInt32(1)   # D3D11_BLEND_OP_ADD
        desc[6] = UInt32(2)   # D3D11_BLEND_ONE
        desc[7] = UInt32(6)   # D3D11_BLEND_INV_SRC_ALPHA
        desc[8] = UInt32(1)   # D3D11_BLEND_OP_ADD
    desc[9] = UInt32(15)      # RenderTargetWriteMask = ALL

    var create = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[UInt32, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateBlendState",
    ](_iface(device))
    var state: Int = 0
    var hr = create(
        _iface(device),
        desc.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=state).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or state == 0:
        raise Error("CreateBlendState failed, hr = " + String(hr))
    return state


def om_set_blend_state(context: Int, state: Int):
    """Bind a blend state. A null factor and a full sample mask, which is
    what both of the reference's states are bound with."""
    var set_blend = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int,
            Pointer[Float32, MutAnyOrigin], UInt32,
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "OMSetBlendState",
    ](_iface(context))
    var factor = List[Float32](length=4, fill=1.0)
    set_blend(
        _iface(context), state,
        factor.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(0xFFFFFFFF),
    )


@fieldwise_init
struct D3D11_INPUT_ELEMENT_DESC(Copyable, Movable):
    """32 bytes. The four bytes of padding after SemanticIndex are real:
    the semantic name is a pointer at +0 and has to stay 8-aligned, so the
    u32 index at +8 is followed by Format at +12, InputSlot at +16,
    AlignedByteOffset at +20, InputSlotClass at +24, InstanceDataStepRate
    at +28. The reference spells this out because a hand-counted struct
    here is the classic silent corruption."""

    var SemanticName: Int
    var SemanticIndex: UInt32
    var Format: UInt32
    var InputSlot: UInt32
    var AlignedByteOffset: UInt32
    var InputSlotClass: UInt32
    var InstanceDataStepRate: UInt32


def create_input_layout(
    device: Int, mut elements: List[D3D11_INPUT_ELEMENT_DESC],
    vs_ptr: Int, vs_size: Int,
) raises -> Int:
    """The per-instance attribute layout, validated against the vertex
    shader's signature -- which is why the bytecode is passed in."""
    var create = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D3D11_INPUT_ELEMENT_DESC, MutAnyOrigin],
            UInt32, Int, Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateInputLayout",
    ](_iface(device))
    var layout: Int = 0
    var hr = create(
        _iface(device),
        elements.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        UInt32(len(elements)), vs_ptr, vs_size,
        Pointer(to=layout).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or layout == 0:
        raise Error("CreateInputLayout failed, hr = " + String(hr))
    return layout


def ia_set_input_layout(context: Int, layout: Int):
    var set_layout = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "IASetInputLayout",
    ](_iface(context))
    set_layout(_iface(context), layout)


def ia_set_vertex_buffer(context: Int, buffer: Int, stride: Int):
    var set_vb = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32,
            Pointer[Int, MutAnyOrigin],
            Pointer[UInt32, MutAnyOrigin],
            Pointer[UInt32, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "IASetVertexBuffers",
    ](_iface(context))
    var slot = buffer
    var strides = List[UInt32](length=1, fill=UInt32(stride))
    var offsets = List[UInt32](length=1, fill=0)
    set_vb(
        _iface(context), UInt32(0), UInt32(1),
        Pointer(to=slot).unsafe_origin_cast[MutAnyOrigin](),
        strides.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        offsets.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
    )


def vs_set_constant_buffers(context: Int, buffer: Int):
    """One constant buffer at VERTEX slot b0.

    The text layer's transform lives here and only here -- the reference
    binds it VS-side and never touches PSSetConstantBuffers, because the
    transform moves the glyph quad and the pixel shader has no opinion about
    where the quad ended up.

    Both of these take a POINTER TO AN ARRAY of interface pointers, not an
    interface pointer, which is the mistake to make once: passing the buffer
    itself compiles, binds whatever the buffer's first eight bytes happen to
    be, and produces a shader reading garbage constants with no error
    anywhere. A one-element `List[Int]` is the array."""
    var setter = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,                        # StartSlot
            UInt32,                        # NumBuffers
            Pointer[Int, MutAnyOrigin],    # ppConstantBuffers
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "VSSetConstantBuffers",
    ](_iface(context))
    var arr = List[Int](length=1, fill=buffer)
    setter(
        _iface(context), UInt32(0), UInt32(1),
        arr.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
    )
    _ = arr


def ps_set_constant_buffers(context: Int, buffer: Int):
    """One constant buffer at PIXEL slot b0.

    The tile layer's scroll offsets and the compositor's colour key both
    arrive this way. Every pass in the reference re-binds its own buffer at
    b0 immediately before drawing rather than sharing slots by convention --
    which is why four layers can all claim b0 and none of them collide."""
    var setter = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            UInt32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetConstantBuffers",
    ](_iface(context))
    var arr = List[Int](length=1, fill=buffer)
    setter(
        _iface(context), UInt32(0), UInt32(1),
        arr.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
    )
    _ = arr


def draw_instanced(context: Int, per_instance: Int, instances: Int):
    """Every sprite in one call. The reference draws three thousand this
    way; the old port issued one Draw per sprite."""
    var draw_fn = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32, UInt32, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "DrawInstanced",
    ](_iface(context))
    draw_fn(
        _iface(context), UInt32(per_instance), UInt32(instances),
        UInt32(0), UInt32(0),
    )


def resolve_compiler() raises -> def (
    Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
    Pointer[Int, MutAnyOrigin],
    Pointer[Int, MutAnyOrigin],
) thin abi("C") -> Int32:
    """D3DCompile, resolved once and passed around -- the d3julia shape."""
    var d3dcompiler = Win32Module("d3dcompiler_47.dll")
    return d3dcompiler.function[
        def (
            Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32,
    ]("D3DCompile")


def compile_shader_blob(
    compile: def (
        Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
        Pointer[Int, MutAnyOrigin],
        Pointer[Int, MutAnyOrigin],
    ) thin abi("C") -> Int32,
    a: List[UInt8], b: List[UInt8], c: List[UInt8], entry: List[UInt8],
    target: List[UInt8],
) raises -> Tuple[Int, Int]:
    """HLSL text through D3DCompile, returned as (bytecode pointer, size).

    The three source pieces are copied into one heap list rather than
    concatenated first: a comptime String on the left of `+` has been
    observed to leave the result pointing at a temporary that dies before
    a callee reads it, and the list is the stable address the compiler
    reads anyway. NUL-terminated the way d3djulia's cstr does it.
    """
    # The source crosses as a heap copy: a stable address for the
    # compiler to read, NUL-terminated the way d3djulia's cstr does it.
    var src_bytes = List[UInt8]()
    for byte in a:
        src_bytes.append(byte)
    for byte in b:
        src_bytes.append(byte)
    for byte in c:
        src_bytes.append(byte)
    src_bytes.append(0)
    if get_environment("GAMEPANE_DUMP_SHADER") != "":
        var dump = get_environment("GAMEPANE_DUMP_SHADER")
        var f = List[UInt16]()
        for byte in dump.as_bytes():
            f.append(UInt16(byte))
        f.append(0)
        var create_file = win32[
            def (Pointer[UInt16, MutAnyOrigin], UInt32, UInt32, Int, UInt32, UInt32, Int) thin abi("C") -> Int,
            "CreateFileW",
        ]()
        var handle = create_file(
            f.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(0x40000000), 0, 0, UInt32(2), UInt32(0x80), 0
        )
        var write_file = win32[
            def (Int, Pointer[UInt8, MutAnyOrigin], UInt32, Pointer[UInt32, MutAnyOrigin], Int) thin abi("C") -> c_int,
            "WriteFile",
        ]()
        var written = UInt32(0)
        _ = write_file(
            handle,
            src_bytes.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(len(src_bytes)),
            com_addr(written),
            0,
        )
        var close_handle = win32[
            def (Int) thin abi("C") -> c_int, "CloseHandle"
        ]()
        _ = close_handle(handle)
    var entry_bytes = List[UInt8]()
    for byte in entry:
        entry_bytes.append(byte)
    entry_bytes.append(0)
    var target_bytes = List[UInt8]()
    for byte in target:
        target_bytes.append(byte)
    target_bytes.append(0)
    var blob: Int = 0
    var error_blob: Int = 0
    var hr = compile(
        Int(src_bytes.unsafe_ptr()),
        Int(len(src_bytes) - 1),
        Int(0),
        Int(0),
        Int(0),
        Int(entry_bytes.unsafe_ptr()),
        Int(target_bytes.unsafe_ptr()),
        UInt32(0),
        UInt32(0),
        Pointer(to=blob).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=error_blob).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0 or blob == 0:
        # The message is a fixed sentence plus the hr: the error blob is
        # read on demand by GamePane's caller-facing path if it exists.
        # Concatenated diagnostics built here have crashed on the raise,
        # and a refusal that crashes is worse than a refusal that is terse.
        raise Error("shader compile failed, hr = " + String(hr))

    return _blob_bytes(blob)


def _blob_bytes(blob: Int) raises -> Tuple[Int, Int]:
    # GetBufferPointer RETURNS the pointer -- it takes no arguments at all.
    # An out-param invented here reads as slot garbage: a real-looking size
    # beside a null pointer, which is exactly the shape this bug made.
    var get_buf = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> Int,
        "ID3DBlob",
        "GetBufferPointer",
    ](_iface(blob))
    var p = get_buf(_iface(blob))
    var get_size = com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> Int,
        "ID3DBlob",
        "GetBufferSize",
    ](_iface(blob))
    var n = get_size(_iface(blob))
    return (p, Int(n))


def create_vertex_shader(device: Int, ptr: Int, size: Int) raises -> Int:
    """Bytecode to a vertex shader. A separate helper because the method
    name in a parameter list has to be a literal."""
    var create = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[UInt8, MutAnyOrigin],
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateVertexShader",
    ](_iface(device))
    var code = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=ptr)
    var shader: Int = 0
    var hr = create(
        _iface(device),
        code.unsafe_origin_cast[MutAnyOrigin](),
        size,
        Int(0),
        Pointer(to=shader).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0:
        raise Error("CreateVertexShader failed, hr = " + String(hr))
    return shader


def create_pixel_shader(device: Int, ptr: Int, size: Int) raises -> Int:
    """Bytecode to a pixel shader; see create_vertex_shader."""
    var create = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[UInt8, MutAnyOrigin],
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreatePixelShader",
    ](_iface(device))
    var code = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=ptr)
    var shader: Int = 0
    var hr = create(
        _iface(device),
        code.unsafe_origin_cast[MutAnyOrigin](),
        size,
        Int(0),
        Pointer(to=shader).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr != 0:
        raise Error("CreatePixelShader failed, hr = " + String(hr))
    return shader
