"""Canonical 16-bit PCM WAV out, 8/16/24/32-bit in.

Here for one reason: the chip is integer arithmetic with a fixed LFSR seed,
so a rendered effect is byte-identical every run. That makes a `.wav` a
regression test -- render `zap`, hash it, and any change to the oscillator,
the envelope or the filter shows up as a different hash rather than as
someone eventually noticing it sounds wrong.

Writing rounds HALF AWAY FROM ZERO rather than truncating, because
truncation biases every sample towards zero and a quiet passage picks up a
DC offset that a scope shows and an ear does not.
"""


comptime WAV_HEADER_BYTES = 44


def _u32(v: Int) -> List[UInt8]:
    return [
        UInt8(v & 255), UInt8((v >> 8) & 255),
        UInt8((v >> 16) & 255), UInt8((v >> 24) & 255),
    ]


def _u16(v: Int) -> List[UInt8]:
    return [UInt8(v & 255), UInt8((v >> 8) & 255)]


def wav_bytes(
    samples: Span[Float32, _], sample_rate: Int, channels: Int = 1
) raises -> List[UInt8]:
    """A complete 16-bit PCM WAV file, header and all."""
    if len(samples) == 0:
        raise Error("wav: refusing to write an empty sound")
    let n = len(samples)
    let data_bytes = n * 2 * channels
    var out = List[UInt8]()

    for c in String("RIFF").as_bytes():
        out.append(c)
    for b in _u32(36 + data_bytes):
        out.append(b)
    for c in String("WAVEfmt ").as_bytes():
        out.append(c)
    for b in _u32(16):              # fmt chunk size
        out.append(b)
    for b in _u16(1):               # PCM
        out.append(b)
    for b in _u16(channels):
        out.append(b)
    for b in _u32(sample_rate):
        out.append(b)
    for b in _u32(sample_rate * channels * 2):   # byte rate
        out.append(b)
    for b in _u16(channels * 2):    # block align
        out.append(b)
    for b in _u16(16):              # bits per sample
        out.append(b)
    for c in String("data").as_bytes():
        out.append(c)
    for b in _u32(data_bytes):
        out.append(b)

    for i in range(n):
        var v = Float64(samples[i])
        if v > 1.0:
            v = 1.0
        elif v < -1.0:
            v = -1.0
        # Half away from zero: truncation pulls every sample towards zero
        # and gives a quiet passage a DC offset.
        var scaled = v * 32767.0
        if scaled >= 0.0:
            scaled += 0.5
        else:
            scaled -= 0.5
        var s = Int(scaled)
        if s > 32767:
            s = 32767
        elif s < -32768:
            s = -32768
        let u = s if s >= 0 else s + 65536
        out.append(UInt8(u & 255))
        out.append(UInt8((u >> 8) & 255))
    return out^


def write_wav(
    path: String, samples: Span[Float32, _], sample_rate: Int
) raises:
    let bytes = wav_bytes(samples, sample_rate)
    with open(path, "w") as f:
        f.write_bytes(Span(bytes))


def _read_u32(b: Span[UInt8, _], at: Int) -> Int:
    return (
        Int(b[at]) | (Int(b[at + 1]) << 8)
        | (Int(b[at + 2]) << 16) | (Int(b[at + 3]) << 24)
    )


def _read_u16(b: Span[UInt8, _], at: Int) -> Int:
    return Int(b[at]) | (Int(b[at + 1]) << 8)


def read_wav(bytes: Span[UInt8, _]) raises -> List[Float32]:
    """Samples from a PCM WAV: 8-bit unsigned, or 16/24/32-bit signed.

    Chunks are walked rather than assumed at fixed offsets -- plenty of
    writers put a LIST chunk between `fmt ` and `data`, and a reader that
    assumes byte 44 reads metadata as audio.
    """
    if len(bytes) < WAV_HEADER_BYTES:
        raise Error("wav: too short to be a wav")
    var bits = 16
    var channels = 1
    var pos = 12
    var data_at = -1
    var data_len = 0
    while pos + 8 <= len(bytes):
        let size = _read_u32(bytes, pos + 4)
        let is_fmt = (
            bytes[pos] == UInt8(ord("f")) and bytes[pos + 1] == UInt8(ord("m"))
            and bytes[pos + 2] == UInt8(ord("t"))
        )
        let is_data = (
            bytes[pos] == UInt8(ord("d")) and bytes[pos + 1] == UInt8(ord("a"))
            and bytes[pos + 2] == UInt8(ord("t"))
            and bytes[pos + 3] == UInt8(ord("a"))
        )
        if is_fmt:
            channels = _read_u16(bytes, pos + 10)
            bits = _read_u16(bytes, pos + 22)
        elif is_data:
            data_at = pos + 8
            data_len = size
            break
        pos += 8 + size + (size & 1)   # chunks are word-aligned
    if data_at < 0:
        raise Error("wav: no data chunk")

    let stride = bits // 8
    if stride < 1 or stride > 4:
        raise Error("wav: unsupported bit depth")
    var out = List[Float32]()
    var i = data_at
    let end = data_at + data_len
    while i + stride <= end and i + stride <= len(bytes):
        var v = 0.0
        if bits == 8:
            # 8-bit wav is UNSIGNED, centred on 128 -- the one depth that is.
            v = (Float64(Int(bytes[i])) - 128.0) / 128.0
        elif bits == 16:
            var s = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            if s >= 32768:
                s -= 65536
            # 32767, matching the writer above -- NOT 32768.
            #
            # Both conventions are in the wild and they differ by one part
            # in 32768, which nobody can hear. But mixing them means a
            # round trip is off by a whole step at full amplitude rather
            # than the half step the rounding costs, and a test that says
            # "within half a step" then has to be loosened to hide it.
            # Reading -32768 gives slightly under -1, so the result is
            # clamped.
            v = Float64(s) / 32767.0
            if v < -1.0:
                v = -1.0
        elif bits == 24:
            var s3 = (
                Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
                | (Int(bytes[i + 2]) << 16)
            )
            if s3 >= 8388608:
                s3 -= 16777216
            v = Float64(s3) / 8388608.0
        else:
            var s4 = _read_u32(bytes, i)
            if s4 >= 2147483648:
                s4 -= 4294967296
            v = Float64(s4) / 2147483648.0
        out.append(Float32(v))
        i += stride * channels
    return out^
