"""Layer 0's parameters, with no idea that Metal exists.

A `ShaderPane` is a full-screen fragment shader and ten floats. The shader
is the platform's business; the ten floats are the game's, and they are all
that a game written against `gamepane.api` ever touches.

The layout is the contract. `Uniforms` on the MSL side is

    struct Uniforms { float time; float aspect; float p[8]; };

which is forty bytes with no padding, so the ten values in order ARE that
struct and the backend hands this straight to `setFragmentBytes:` without a
conversion step. Keeping them in one `List[Float32]` rather than ten fields
is what makes `set_param(i, v)` a bounds check instead of a switch.
"""


comptime SHADER_PARAM_COUNT = 8
"""`u.p[0]` through `u.p[7]`, matching `ShaderPane.mod` and the Rust."""

comptime _TIME = 0
comptime _ASPECT = 1
comptime _P0 = 2


struct ShaderParams(Copyable, Movable):
    """`Uniforms{time, aspect, p[8]}`, in the order the shader reads them."""

    var v: List[Float32]

    def __init__(out self):
        self.v = List[Float32](length=2 + SHADER_PARAM_COUNT, fill=0.0)
        self.v[_ASPECT] = 1.0

    def set_param(mut self, i: Int, value: Float32):
        """Set `u.p[i]`. Out of range is ignored, not an error -- a game
        tuning a shader it did not write should not be able to crash."""
        if i >= 0 and i < SHADER_PARAM_COUNT:
            self.v[_P0 + i] = value

    def param(self, i: Int) -> Float32:
        if i >= 0 and i < SHADER_PARAM_COUNT:
            return self.v[_P0 + i]
        return 0.0

    def set_aspect(mut self, aspect: Float32):
        self.v[_ASPECT] = aspect

    def aspect(self) -> Float32:
        return self.v[_ASPECT]

    def set_time(mut self, seconds: Float32):
        self.v[_TIME] = seconds

    def time(self) -> Float32:
        return self.v[_TIME]

    def byte_length(self) -> Int:
        """Forty. What `setFragmentBytes:length:` needs to be told."""
        return len(self.v) * 4
