# ===----------------------------------------------------------------------=== #
# Othello, as two 64-bit words.
#
# Norvig's version in "Paradigms of AI Programming" uses a 100-element array
# with a border of sentinel squares, so a walk off the edge hits a wall
# instead of wrapping. That is the right shape for a language with arrays and
# no wide integers, and it costs a bounds check per step in eight directions.
#
# A board is 64 squares and a machine word is 64 bits, so the whole position
# is two words: the squares this player holds, and the squares the opponent
# holds. Every rule becomes shifts and masks over those words -- no loops over
# directions, no bounds checks, no branches that depend on the position.
#
# That matters twice over here. It is faster on the CPU, and it is the reason
# a GPU player is possible at all: a thread that plays a whole game needs two
# registers for the board, and every thread executes the same instructions
# regardless of what its game looks like.
#
# Bit i is row i // 8, column i % 8, with row 0 at the top and column 0 on the
# left -- the order the board is drawn in, so the UI never has to flip. On the
# Mac that ordering still needed a flip at the last moment, because Cocoa's y
# axis points up; GDI's points down, so here the bit order and the pixel order
# genuinely are the same and `draw_board` reads bit i into row i // 8.
#
# This module is imported by the window, by the AI, and by the GPU kernel. One
# copy of the rules: a demo whose kernel has its own private move generator
# can pass every check on the CPU and still play a different game on the
# device, and nothing in the output would say so.
# ===----------------------------------------------------------------------=== #


comptime NOT_LEFT = UInt64(0xFEFEFEFEFEFEFEFE)  # every column but the first
comptime NOT_RIGHT = UInt64(0x7F7F7F7F7F7F7F7F)  # every column but the last

comptime DIR_E = 0
comptime DIR_W = 1
comptime DIR_S = 2
comptime DIR_N = 3
comptime DIR_SE = 4
comptime DIR_SW = 5
comptime DIR_NE = 6
comptime DIR_NW = 7


@always_inline
def shift[dir: Int](b: UInt64) -> UInt64:
    """One step in a direction, with the wrap masked off.

    Shifting east moves bit 7 (the last column) into bit 8 (the first column
    of the next row), which is a move through the edge of the board. Masking
    after the shift is what the sentinel border was for.

    The direction is a compile-time parameter rather than the Mac version's
    runtime argument, so the chain below folds to one shift and one AND at
    every call site and the eight-way loops in this file unroll into thirty
    or so straight-line instructions. The Mac spelling costs an eight-way
    branch per step; it is uniform across a warp so it never diverges, but on
    the CPU it is the inner loop of alpha-beta and it was worth removing.

    Parameters:
        dir: One of the eight DIR_ constants.

    Args:
        b: The bitboard to step.

    Returns:
        `b` moved one square in `dir`, with anything that fell off the edge
        removed.
    """
    comptime if dir == DIR_E:
        return (b << 1) & NOT_LEFT
    comptime if dir == DIR_W:
        return (b >> 1) & NOT_RIGHT
    comptime if dir == DIR_S:
        return b << 8
    comptime if dir == DIR_N:
        return b >> 8
    comptime if dir == DIR_SE:
        return (b << 9) & NOT_LEFT
    comptime if dir == DIR_SW:
        return (b << 7) & NOT_RIGHT
    comptime if dir == DIR_NE:
        return (b >> 7) & NOT_LEFT
    return (b >> 9) & NOT_RIGHT


@always_inline
def legal_moves(own: UInt64, opp: UInt64) -> UInt64:
    """Every square this player may play, as a bitboard.

    A legal move sits on an empty square, at the far end of an unbroken run
    of opponent discs that starts next to one of ours. The run is grown five
    more times because a line of eight squares can hold at most six discs
    between the two ends.

    Args:
        own: The moving player's discs.
        opp: The other player's discs.

    Returns:
        One bit set per legal move.
    """
    var empty = ~(own | opp)
    var moves = UInt64(0)
    comptime for dir in range(8):
        var run = shift[dir](own) & opp
        for _ in range(5):
            run |= shift[dir](run) & opp
        moves |= shift[dir](run) & empty
    return moves


@always_inline
def flips_for(own: UInt64, opp: UInt64, move: UInt64) -> UInt64:
    """The discs a move turns over. Empty if the move is not legal.

    Args:
        own: The moving player's discs.
        opp: The other player's discs.
        move: A single bit: the square being played.

    Returns:
        Every opponent disc the move captures.
    """
    var flipped = UInt64(0)
    comptime for dir in range(8):
        var run = shift[dir](move) & opp
        for _ in range(5):
            run |= shift[dir](run) & opp
        # The run only counts if one of ours closes it. Anything else -- an
        # empty square, or the edge -- and nothing turns over.
        if (shift[dir](run) & own) != 0:
            flipped |= run
    return flipped


@always_inline
def popcount(b: UInt64) -> Int:
    """How many discs.

    The obvious loop, not the clever one: it runs once per move on the CPU
    and once per finished game on the GPU, so its cost is invisible next to
    the search and the playout that call it.
    """
    var n = 0
    var x = b
    while x != 0:
        x &= x - 1
        n += 1
    return n


@always_inline
def bit(index: Int) -> UInt64:
    """The bitboard holding only square `index`."""
    return UInt64(1) << UInt64(index)


@always_inline
def square(row: Int, col: Int) -> UInt64:
    """The bitboard holding only (row, col), row 0 at the top."""
    return bit(row * 8 + col)


@always_inline
def lowest(b: UInt64) -> UInt64:
    """The lowest set bit on its own."""
    return b & (~b + 1)


def start_black() -> UInt64:
    # d5 and e4 in the usual notation; row 3 col 4 and row 4 col 3 here.
    return square(3, 4) | square(4, 3)


def start_white() -> UInt64:
    return square(3, 3) | square(4, 4)


def apply(own: UInt64, opp: UInt64, move: UInt64) -> Tuple[UInt64, UInt64]:
    """Play `move` and hand the position back from the OTHER player's side.

    Returning the swapped pair is what makes the search and the playout read
    as negamax: after a move, "own" is always whoever is to play next.

    Args:
        own: The moving player's discs.
        opp: The other player's discs.
        move: A single bit: the square being played.

    Returns:
        (the next player's discs, the mover's discs).
    """
    var f = flips_for(own, opp, move)
    return (opp ^ f, own | move | f)


# ===----------------------------------------------------------------------=== #
# Evidence that the rules are the rules.
#
# A move generator that is subtly wrong plays a game that looks completely
# normal -- discs go down, discs turn over, somebody wins -- so watching it is
# not a check. perft is: count every leaf of the game tree at a fixed depth
# and compare against the published numbers. One masked shift out of place and
# the count is wrong at depth 3.
# ===----------------------------------------------------------------------=== #


def perft(own: UInt64, opp: UInt64, depth: Int) -> Int:
    """Leaves of the game tree at `depth` plies from this position.

    A player with no move passes and the depth does not go down -- that is the
    convention the published numbers use. It cannot loop: a pass is only taken
    when the opponent has a move, and if neither does the game is over.

    Args:
        own: The moving player's discs.
        opp: The other player's discs.
        depth: Plies to count to.

    Returns:
        The number of positions reachable in exactly `depth` moves.
    """
    if depth == 0:
        return 1
    var moves = legal_moves(own, opp)
    if moves == 0:
        if legal_moves(opp, own) == 0:
            return 1  # game over: this leaf is where the tree stops
        return perft(opp, own, depth)
    var total = 0
    var m = moves
    while m != 0:
        var one = lowest(m)
        m &= m - 1
        var nxt = apply(own, opp, one)
        total += perft(nxt[0], nxt[1], depth - 1)
    return total


def perft_expected(depth: Int) -> Int:
    """The published leaf counts from the opening position, 1 through 7.

    Returns -1 for a depth nobody has tabulated here.
    """
    if depth == 1:
        return 4
    if depth == 2:
        return 12
    if depth == 3:
        return 56
    if depth == 4:
        return 244
    if depth == 5:
        return 1396
    if depth == 6:
        return 8200
    if depth == 7:
        return 55092
    return -1
