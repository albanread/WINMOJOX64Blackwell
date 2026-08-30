"""What the window holds: a document, a view onto it, and its history.

Pure state. Nothing here draws, and nothing here calls Windows -- which is
what lets `gridview` (drawing), `edit` (changing) and `find` (searching) all
depend on it without depending on each other.

The history is the part worth reading twice. Undo is not a log of operations
to invert; it is a list of *previous documents*. That is only affordable
because the rope is persistent: an edit builds a new root that shares every
untouched node with the old one, so keeping the old root costs one reference
and the handful of nodes along the edited path. There is no inverse operation
to write, no "undo of a replace inside a selection spanning three lines" to
get subtly wrong, and undo of anything -- however complicated -- is one
assignment.

The caret is a line and a UTF-16 code-unit offset within it. Code units
rather than characters or bytes because that is what DirectWrite hit tests
in, and what the text services framework wants in sprint 1.5; having one unit
throughout is worth more than having a tidy one.
"""

from ide.rope import Rope


@fieldwise_init
struct Grid(Movable):
    """The editor's view onto a rope: what is visible, and what is cached."""

    var top_line: Int
    var line_height: Float32
    var capacity: Int
    # Direct-mapped cache: slot `line % capacity` holds this line's layout.
    var cached_line: List[Int]
    var cached_rev: List[Int]
    var cached_layout: List[Int]
    # Inspectable, because the claim needs to be checkable.
    var hits: Int
    var misses: Int
    var drawn: Int
    # One character's width in the editor face, asked of DirectWrite once and
    # then used as arithmetic. Zero until measured; see `advance_of`.
    var advance: Float32

    def __init__(out self, capacity: Int = 128):
        """An empty grid, scrolled to the top.

        Args:
            capacity: How many line layouts to keep. A little over a
                screenful, so scrolling reuses rather than thrashes.
        """
        self.top_line = 0
        self.line_height = 16.0
        self.capacity = capacity
        self.cached_line = List[Int]()
        self.cached_rev = List[Int]()
        self.cached_layout = List[Int]()
        for _ in range(capacity):
            self.cached_line.append(-1)
            self.cached_rev.append(-1)
            self.cached_layout.append(0)
        self.hits = 0
        self.misses = 0
        self.drawn = 0
        self.advance = 0

    def visible_lines(self, height: Float32) -> Int:
        """How many lines fit in a region this tall, partial one included."""
        return Int(height / self.line_height) + 1


@fieldwise_init
struct Snapshot(Movable, Copyable):
    """The document as it was, and where the caret was in it.

    Five integers and one rope root. The root is an `ArcPointer`, so keeping
    it retains the tree it names -- which is almost entirely the *same* tree
    the current document is using, because an edit rebuilds only the path
    from the root to the leaf it touched. A thousand of these is a thousand
    references and a thousand edited paths, not a thousand documents.

    The caret travels with the text because undo that restores the words but
    not the cursor makes a person hunt for where they were, which is most of
    the value of undo gone.
    """

    var rope: Rope
    var caret_line: Int
    var caret_col: Int
    var anchor_line: Int
    var anchor_col: Int


@fieldwise_init
struct Doc(Movable):
    """A document, the view onto it, and everywhere it has been.

    The window keeps one of these. It is separate from `Chrome` -- which is
    Direct2D's business -- because the text outlives any particular render
    target, and because a lost device would otherwise take the file with it.
    """

    var rope: Rope
    var grid: Grid
    # Bumped by every edit. Layouts are keyed on it, so an edit invalidates
    # the cache without anyone having to remember to clear it.
    var revision: Int
    # The caret, and the other end of the selection. They are equal when
    # nothing is selected, which is why there is no separate "has a selection"
    # flag to keep in step with anything.
    var caret_line: Int
    var caret_col: Int
    var anchor_line: Int
    var anchor_col: Int
    # Changed since it was opened or last saved.
    var dirty: Bool
    # Where the document has been, and where it was going before someone
    # changed their mind. A new edit clears the redo stack, because a history
    # that forks is a history nobody can reason about.
    var past: List[Snapshot]
    var future: List[Snapshot]
    # The high half of a surrogate pair, waiting for its low half. Windows
    # delivers an astral character as two WM_CHAR messages and there is
    # nowhere else for the first one to live: the window procedure is
    # captureless, so state between two of its calls belongs here.
    var pending: Int
    # What F3 repeats. Kept on the document rather than in the find bar,
    # because there is no find bar yet and because a person expects the same
    # needle after switching away and back.
    var needle: String

    def __init__(out self, var rope: Rope):
        """A document scrolled to the top, caret at the start, no history."""
        self.rope = rope^
        self.grid = Grid()
        self.revision = 0
        self.caret_line = 0
        self.caret_col = 0
        self.anchor_line = 0
        self.anchor_col = 0
        self.dirty = False
        self.past = List[Snapshot]()
        self.future = List[Snapshot]()
        self.pending = 0
        self.needle = String("")

    def has_selection(self) -> Bool:
        """Whether the caret and the anchor are anywhere different."""
        return (
            self.caret_line != self.anchor_line
            or self.caret_col != self.anchor_col
        )

    def snapshot(self) -> Snapshot:
        """The document as it stands, for the history."""
        return Snapshot(
            self.rope.copy(),
            self.caret_line,
            self.caret_col,
            self.anchor_line,
            self.anchor_col,
        )
