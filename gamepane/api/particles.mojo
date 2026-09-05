"""Debris made of the sprite it came from.

When something dies, its own pixels become particles: each non-transparent
pixel of the frame it was showing flies outward from the centre, falls under
gravity, and fades. The colours are not chosen -- they ARE the sprite's, so
a boss's green hull scatters green and a scorpion's red shell scatters red,
with no new art and no per-explosion authoring.

**The palette is shared and the mapping is arithmetic.** Every sprite
definition has its own sixteen colours; particle colour `16 × definition +
index` puts all of them in one 256-entry table, which is exactly enough for
sixteen definitions and leaves the rest spare. A particle is therefore one
byte, the same as any other index in this package, and the plane it scatters
into is an ordinary index plane that the ordinary shader draws.

**Fading is THINNING, not alpha.** A particle whose life has run to 0.3 is
drawn on three frames in ten, chosen by a hash of its index and the frame
number. That flickers out the way a dying sprite on a C64 does, costs one
comparison in the kernel, and keeps the plane 8-bit -- where per-particle
alpha would mean an RGBA plane, a blend, and a second full-screen pass to
achieve something less in period.
"""


comptime PARTICLE_COLOURS_PER_DEF = 16
"""Sixteen colours a definition, so the shared table holds sixteen of them."""


def particle_colour(definition: Int, index: Int) -> Int:
    """Where a sprite's colour lands in the shared 256-entry table.

    Index 0 stays 0 -- transparent everywhere in this package, and a
    transparent pixel is not debris.
    """
    if index <= 0:
        return 0
    var d = definition
    if d < 0:
        d = 0
    elif d > 15:
        d = 15
    var c = index
    if c > 15:
        c = 15
    return d * PARTICLE_COLOURS_PER_DEF + c


def burst_velocity(
    dx: Float64, dy: Float64, speed: Float64, jitter: Float64
) -> Tuple[Float64, Float64]:
    """A velocity radiating from the centre of a sprite.

    `dx, dy` is the pixel's offset from the middle. Radiating from the
    centre rather than in a random direction is what makes the debris look
    like the thing coming apart instead of a puff appearing where it was:
    the top-left corner goes up and left, because that is where it was.

    The jitter is added to the SPEED, not the direction, so the shape of the
    burst survives while its edge stays ragged.
    """
    let d = (dx * dx + dy * dy) ** 0.5
    if d < 0.0001:
        return (0.0, -speed * 0.5)
    let s = speed * (1.0 + jitter)
    return (dx / d * s, dy / d * s)
