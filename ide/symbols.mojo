"""The shape of a file, from the language server: its outline, flattened.

Griddle could already jump to a definition and could not tell you what was in
the file under the caret. The server has advertised `documentSymbolProvider`
since the first handshake -- `tools/lsp-navigation.py` prints it -- and
nothing had ever asked. This asks, and holds the answer.

WHAT THIS SERVER SENDS. Probed against
`bazel-bin/KGEN/tools/mojo-lsp-server/mojo-lsp-server.exe` with
`textDocument/documentSymbol` for `ide/tree.mojo`: twenty-five top-level
entries, every one of them a `DocumentSymbol` -- `name`, `detail`, `kind`,
`range`, `selectionRange`, and `children` on the struct. Not one carried
`location`, so this server never sends `SymbolInformation`. Both shapes are
legal answers to the same request and a client that reads only one shows an
empty outline for a server that sends the other, which looks exactly like a
file with no symbols in it. `SymbolInformation` is read here too, on the
strength of one probe against one build being a thin thing to bet a feature
on.

HOW THE REPLY GETS BACK HERE. `ide/lsp.mojo` owns the connection and this
module does not edit it. Sending needs nothing new: `lsp.request` is public,
takes a method and params and returns the id it assigned, which is exactly
what `request_symbols` wants. Receiving is the other half, and `lsp._handle`
matches a reply's id against its own list of outstanding requests -- one per
feature it implements -- and drops anything it does not recognise. There is
no callback, no unclaimed-reply queue, and no shape of reply that can be
routed here by any existing branch: setting `lsp.g_ren_request` to our id
hands a `DocumentSymbol[]` to `_take_rename`, which finds neither `changes`
nor `documentChanges` and throws it away, and the completion and reference
branches read `label` and `uri`, which a `DocumentSymbol` has neither of.

So the outstanding id lives here, in `symbols_request_id`, and `take_symbols`
takes a parsed `result` from whoever has one. Until `lsp._handle` learns to
call it, the caller supplies the reply; the addition that would finish it is
two lines in `_handle`, written out in the report beside this file.
"""

from ide.json import JSON
from ide.lsp import request
from std.sys._globals import named_global


@fieldwise_init
struct Symbol(ImplicitlyCopyable, Movable):
    """One line of the outline.

    Flat, with the nesting carried as a number, because the thing being drawn
    is an indented list. A tree of these would be walked back into exactly
    this list on every paint, and the paint happens far more often than the
    reply does.
    """

    var name: String
    """What it is called."""
    var detail: String
    """The signature, when the server gives one -- this one gives
    `def toggle(i: Int) -> String` for a function and `struct Entry` for a
    struct. Empty when it does not."""
    var kind: Int
    """The LSP SymbolKind number, 1..26. See `symbol_kind_name`."""
    var line: Int
    """Zero-based, where the name starts."""
    var column: Int
    """Zero-based, in UTF-16 code units.

    This is the one boundary in `ide/` that converts nothing, and it is said
    out loud here because every other one does: the rope counts bytes, the
    tree counts UTF-16 units out of Win32, and a reader who has been through
    those will come looking for the conversion. LSP columns are UTF-16 units
    and the editor's caret is a UTF-16 column, so the number the server sent
    is the number the caret wants. Converting it to bytes here and back in
    the caller would be two chances to be wrong about a file with an accented
    identifier in it, in exchange for nothing.
    """
    var depth: Int
    """Nesting, zero at the top level. A struct's fields are one deeper."""


# ── State ───────────────────────────────────────────────────────────────────
# The outline, already sorted and already flat, so a draw reads it as it is.
comptime g_symbols = named_global["symbols.list", List[Symbol]]
comptime g_serial = named_global["symbols.serial", Int]

# The one outstanding request. One at a time, for the reason hover and
# definition are: an outline answers "what is in the file I am looking at",
# so an older reply is about a file that is no longer on screen, and keeping
# several would only make it harder to say which one is stale.
comptime g_request = named_global["symbols.request", Int]

# Which document that request was about. A one-element list rather than a
# bare slot, for the reason `ide/lsp.mojo` gives for its own: a
# zero-initialised global String is not a valid String, and a zero-initialised
# List is a valid empty one.
comptime g_uri = named_global["symbols.uri", List[String]]


# ── Asking ──────────────────────────────────────────────────────────────────
def request_symbols(uri: String) -> Int:
    """Ask the server what is in a file.

    Sent through `lsp.request`, which is this client's public way to put a
    request on the wire and get back the id it was given. Nothing about
    `documentSymbol` needs a position: the question is about the whole file.

    Args:
        uri: The document, as the `file:///` uri the server was told about.

    Returns:
        The request id, which is also left in `symbols_request_id` so a
        dispatcher can match the reply without the caller holding it.
    """
    var doc = JSON.object()
    doc.set(String("uri"), JSON(uri))
    var params = JSON.object()
    params.set(String("textDocument"), doc^)
    var id = request(String("textDocument/documentSymbol"), params^)
    g_request()[] = id
    _remember_uri(uri)
    return id


def symbols_request_id() -> Int:
    """The id of the outstanding request, or zero when none is.

    This is the hook. Whoever reads replies -- `lsp._handle`, once it has the
    two lines described in this module's docstring, or the editor in the
    meantime -- compares an incoming id against this and hands the matching
    `result` to `take_symbols`. Zero never matches, so a reply that arrives
    after `clear_symbols` is ignored rather than mistaken for a live answer.

    Returns:
        The id, or zero.
    """
    return g_request()[]


def symbols_uri() -> String:
    """Which document the outline is about.

    Exposed rather than checked here, because only the caller knows which tab
    is on screen. `ide/lsp.mojo` makes the same check for completions and
    explains it at length: a reply to a live request can still be about a file
    the user has switched away from, and drawing its outline over the file
    they are looking at is worse than drawing none.

    Returns:
        The uri last passed to `request_symbols`, or empty.
    """
    var slot = g_uri()
    return slot[][0] if len(slot[]) > 0 else String()


def _remember_uri(uri: String):
    """Record the document a request was made for."""
    var slot = g_uri()
    if len(slot[]) == 0:
        slot[].append(uri)
    else:
        slot[][0] = uri


# ── Reading the answer ──────────────────────────────────────────────────────
def take_symbols(result: JSON):
    """Turn a `documentSymbol` reply into the flat, sorted list.

    Both legal shapes are read. `DocumentSymbol[]` is nested and carries
    `range`, `selectionRange` and `children`; `SymbolInformation[]` is flat
    and carries `location` instead. The shapes are told apart per node rather
    than for the array as a whole, which costs nothing and means a server that
    mixes them -- or a `null` reply, which is also legal and arrives here as
    an empty array -- produces a short list rather than no list.

    This server sends `DocumentSymbol[]`; see the module docstring for the
    probe that established it.

    Args:
        result: The `result` member of the reply, already parsed.
    """
    # Collected into a local and moved in at the end. Building in place would
    # leave the global holding a half-flattened outline for the duration, and
    # the draw callback reads that global.
    var found = List[Symbol]()
    _collect(result, 0, found)
    _sort_by_position(found)
    g_symbols()[] = found^
    # Answered: leaving the id live would let the next reply-shaped message
    # with that id be taken for this one.
    g_request()[] = 0
    g_serial()[] += 1


def _collect(nodes: JSON, depth: Int, mut out: List[Symbol]):
    """Flatten one array of symbols, depth first, into the display order.

    Depth first and in place, because the order a file reads in is the order
    its symbols were declared in, and a breadth-first walk would put every
    struct's fields after every function in the file.

    Args:
        nodes: An array of `DocumentSymbol` or `SymbolInformation`.
        depth: The nesting to record for these, zero at the top level.
        out: Where the flattened symbols go.
    """
    var i = 0
    while i < nodes.count():
        var node = nodes.at(i)
        var kept = False
        var name = node[].get("name")[].as_string()
        var where = _start_of(node[])
        # A symbol with no name or no position is dropped, not repaired. The
        # obvious repair is to report it at line zero, and a go-to-symbol list
        # that silently sends you to the top of the file is worse than a
        # shorter list: the short list is missing something, the repaired one
        # is lying, and only one of those is noticed.
        if name != "" and where[0] >= 0:
            out.append(
                Symbol(
                    name^,
                    node[].get("detail")[].as_string(),
                    node[].get("kind")[].as_int(),
                    where[0],
                    where[1],
                    depth,
                )
            )
            kept = True
        if node[].has("children"):
            # Children of a symbol that was dropped are drawn at the dropped
            # symbol's level, not one in from it. Indenting them under a row
            # that is not there would leave the outline with a hanging step in
            # it that nothing explains.
            var inner = depth + 1 if kept else depth
            _collect(node[].get("children")[], inner, out)
        i += 1


def _start_of(node: JSON) -> Tuple[Int, Int]:
    """Where a symbol's name begins, in whichever shape the node is.

    `selectionRange` is the name alone and `range` is the whole declaration
    including its body, so `selectionRange` is preferred: an outline row is a
    place to jump to, and jumping to the start of a hundred-line function is
    right where jumping to the start of its docstring is not. A
    `SymbolInformation` has neither and keeps its position under
    `location.range`.

    Args:
        node: One symbol from the reply.

    Returns:
        Line and column, or (-1, -1) when the reply does not place it.
    """
    if node.has("selectionRange"):
        return _start_in(node.get("selectionRange")[])
    if node.has("range"):
        return _start_in(node.get("range")[])
    if node.has("location"):
        var location = node.get("location")
        if location[].has("range"):
            return _start_in(location[].get("range")[])
    return (-1, -1)


def _start_in(rng: JSON) -> Tuple[Int, Int]:
    """The start of a range, or (-1, -1) if it does not have one.

    Every member is tested with `has` rather than read and checked for zero.
    `JSON.as_int` answers zero for a member that is not there, and zero is a
    real line and a real column -- the first symbol in a file genuinely is at
    0:0 sometimes -- so the value cannot tell the two apart and `has` is the
    only honest test.

    Args:
        rng: An LSP Range.

    Returns:
        Line and column, or (-1, -1).
    """
    if not rng.has("start"):
        return (-1, -1)
    var start = rng.get("start")
    if not start[].has("line") or not start[].has("character"):
        return (-1, -1)
    var line = start[].get("line")[].as_int()
    var column = start[].get("character")[].as_int()
    if line < 0 or column < 0:
        return (-1, -1)
    return (line, column)


def _sort_by_position(mut rows: List[Symbol]):
    """Put the outline back in file order.

    By position and never by name. An outline sorted by name is a different
    document from the one on screen: scrolling the editor no longer walks down
    the outline, the row under the caret is nowhere near the middle, and the
    reader has to search a list they are looking at to find where they are.
    Nothing in the protocol promises the server sends them in order, and this
    one happens to -- which is the worst case for finding out later.

    Insertion sort, and stable because it only ever swaps a strictly greater
    neighbour down. Stability is what keeps a parent above its own first child
    when the two share a line, which is where the depth-first order is the
    only thing that says which came first. A file's worth of symbols is tens,
    occasionally hundreds; an insertion sort on that is faster to run than a
    better one is to write.

    Args:
        rows: The flattened symbols, reordered in place.
    """
    var i = 1
    while i < len(rows):
        var j = i
        while j > 0 and _is_after(rows[j - 1], rows[j]):
            rows.swap_elements(j - 1, j)
            j -= 1
        i += 1


def _is_after(a: Symbol, b: Symbol) -> Bool:
    """Does `a` start strictly later in the file than `b`?"""
    if a.line != b.line:
        return a.line > b.line
    return a.column > b.column


# ── Reading it back ─────────────────────────────────────────────────────────
def symbol_count() -> Int:
    """How many symbols the outline has.

    Returns:
        The count.
    """
    return len(g_symbols()[])


def symbol_at(i: Int) raises -> Symbol:
    """One symbol.

    Args:
        i: Its index, in file order.

    Returns:
        The symbol.

    Raises:
        If the index is out of range.
    """
    var symbols = g_symbols()
    if i < 0 or i >= len(symbols[]):
        raise Error("no such symbol")
    return symbols[][i]


def symbols_serial() -> Int:
    """How many times the outline has changed.

    The counter a draw compares against what it last drew, the same way the
    rest of the client does it: comparing the list itself would mean copying
    it, and comparing its length would miss a reply that replaced one file's
    symbols with the same number of another's.

    Returns:
        The serial.
    """
    return g_serial()[]


def clear_symbols():
    """Forget the outline, and any request that was going to fill it.

    The outstanding id goes too. A reply that arrives after this is about a
    file that is no longer being shown, and `symbols_request_id` answering
    zero is what makes the dispatcher drop it instead of drawing it.
    """
    var empty = List[Symbol]()
    g_symbols()[] = empty^
    g_request()[] = 0
    var slot = g_uri()
    if len(slot[]) > 0:
        slot[][0] = String()
    g_serial()[] += 1


def symbol_kind_name(kind: Int) -> String:
    """The LSP SymbolKind number as a word.

    The numbers are 1..26 and fixed by the protocol. This server uses a small
    part of the range -- 7 Property for a `comptime` alias, 8 Field, 12
    Function, 23 Struct -- but all of them are named, because the alternative
    is a table that has to be extended the first time a server is pointed at
    a file with an enum in it.

    Args:
        kind: The number.

    Returns:
        The name, or "symbol" for anything outside 1..26.
    """
    if kind == 1:
        return String("File")
    if kind == 2:
        return String("Module")
    if kind == 3:
        return String("Namespace")
    if kind == 4:
        return String("Package")
    if kind == 5:
        return String("Class")
    if kind == 6:
        return String("Method")
    if kind == 7:
        return String("Property")
    if kind == 8:
        return String("Field")
    if kind == 9:
        return String("Constructor")
    if kind == 10:
        return String("Enum")
    if kind == 11:
        return String("Interface")
    if kind == 12:
        return String("Function")
    if kind == 13:
        return String("Variable")
    if kind == 14:
        return String("Constant")
    if kind == 15:
        return String("String")
    if kind == 16:
        return String("Number")
    if kind == 17:
        return String("Boolean")
    if kind == 18:
        return String("Array")
    if kind == 19:
        return String("Object")
    if kind == 20:
        return String("Key")
    if kind == 21:
        return String("Null")
    if kind == 22:
        return String("EnumMember")
    if kind == 23:
        return String("Struct")
    if kind == 24:
        return String("Event")
    if kind == 25:
        return String("Operator")
    if kind == 26:
        return String("TypeParameter")
    return String("symbol")


def matching_symbols(query: String) raises -> List[Int]:
    """Which symbols a go-to-symbol box should show for what has been typed.

    Substring rather than prefix, and case-insensitive, because the name
    someone half-remembers is usually the middle of the identifier -- `dir`
    finds `list_dir` -- and because nobody types the capital in `FindFirstFileW`
    while they are looking for it.

    Indices, not symbols, so the caller can hold a filtered view without
    copying the strings and can hand the chosen index straight back to
    `symbol_at`.

    Args:
        query: What has been typed. Empty matches everything.

    Returns:
        Indices into the outline, in file order.

    Raises:
        Never in practice; declared so a caller inside a `raises` context
        needs no wrapper.
    """
    var out = List[Int]()
    var needle = query.lower()
    var symbols = g_symbols()
    var i = 0
    while i < len(symbols[]):
        # In file order because the list is already in file order and this
        # only ever skips: a filtered outline that reshuffles as you type is
        # a different list on every keystroke.
        if needle == "":
            out.append(i)
        else:
            var folded = symbols[][i].name.lower()
            if folded.find(needle) >= 0:
                out.append(i)
        i += 1
    return out^


def symbols_report() raises -> String:
    """The outline as text, indented the way it is drawn.

    The same shape as `tree.tree_report`, and for the same reason: a feature
    whose whole output is a list needs one way to print that list that is not
    the window, or every check of it is a screenshot.

    Returns:
        `symbols N` and a line each.

    Raises:
        If the outline changes underneath the walk, which it cannot here.
    """
    var out = String("symbols ") + String(symbol_count()) + "\n"
    for i in range(symbol_count()):
        var s = symbol_at(i)
        out += " " * (s.depth * 2) + s.name
        out += " [" + symbol_kind_name(s.kind) + "] "
        out += String(s.line) + ":" + String(s.column)
        if s.detail != "":
            out += "  " + s.detail
        out += "\n"
    return out^
