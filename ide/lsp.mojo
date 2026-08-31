# The language server client.
#
# Roast does not parse Mojo. mojo-lsp-server does -- diagnostics, completion
# (the Cocoa database included), definition, semantic tokens -- and this speaks
# to it over a pipe. IDE-EMBEDDING.md is explicit that for an editor not written
# in C++ the LSP boundary is the one to use, and Roast is written in Mojo.
#
# The transport is JSON-RPC with Content-Length framing, which is the whole
# protocol at this level: a header, a blank line, and that many bytes of JSON.
# Reads are non-blocking and drained from a timer, the same shape the playground
# uses for compiler output, because a blocking read on the main thread is an
# editor that stops responding whenever the server thinks.
# Ported from MojoCocoa's `ide/lsp.mojo`, which is where the protocol half of
# this file was written and where it should keep being written. About sixty of
# its eleven hundred lines are the platform: spawning the server, reading a
# pipe without blocking, writing to one. Those are in `ide/pipes.mojo` here and
# in NSTask over there; everything between the two -- the framing, the
# dispatch, the diagnostics, the completions -- is the same code.
from ide.json import JSON, parse
from ide.symbols import clear_symbols, symbols_request_id, take_symbols
from ide.pipeutf8 import take_chunk
from ide.pipes import Child, kill, read_some, set_env, spawn, write_all
from std.memory import OpaquePointer, Pointer, alloc
from std.sys._globals import named_global

comptime P = OpaquePointer[MutUntrackedOrigin]


# Reading without blocking is `ide/pipes.waiting`, which asks PeekNamedPipe
# how many bytes are there. The Mac port uses poll(2) with a zero timeout and
# writes down at length why it does not use fcntl(O_NONBLOCK); Windows has the
# same trap in a different shape, and pipes.mojo says so there.


# ── State ───────────────────────────────────────────────────────────────────
# The child, as Win32 handles. The names are the Mac port's, so that the
# code between here and there stays comparable: g_in is the end we write
# to and g_read_fd the end we read from -- a handle rather than a file
# descriptor, in the same place doing the same job.
comptime g_task = named_global["lsp.task", Int]        # process handle
comptime g_thread = named_global["lsp.thread", Int]    # its main thread
comptime g_in = named_global["lsp.in", Int]            # we write here
comptime MAX_MESSAGE = 64 * 1024 * 1024
comptime MAX_INBOX = 96 * 1024 * 1024

comptime g_pending = named_global["lsp.inbox.pending", List[UInt8]]
comptime g_read_fd = named_global["lsp.readfd", Int]   # we read here
comptime g_next_id = named_global["lsp.nextid", Int]
comptime g_ready = named_global["lsp.ready", Int]
# Bumped each time a server finishes its handshake. The app watches this to
# know when to announce the documents that are already open -- a server that
# just became ready knows about none of them, whether this is startup or a
# project-change restart handing us a brand-new process.
comptime g_ready_serial = named_global["lsp.ready.serial", Int]

# Bytes that arrived but do not yet make a whole message. A one-element list,
# for the same reason every other buffer here is: a zero-initialised global
# String is not a valid String, and a zero-initialised List is a valid empty one.
comptime g_inbox = named_global["lsp.inbox", List[String]]

# Diagnostics for the open document, as (line, character, end_character,
# severity) plus the message. Flat lists rather than a struct list because they
# are read from a draw callback, which wants no allocation.
comptime g_diag_line = named_global["lsp.diag.line", List[Int]]
comptime g_diag_col = named_global["lsp.diag.col", List[Int]]
comptime g_diag_end = named_global["lsp.diag.end", List[Int]]
comptime g_diag_sev = named_global["lsp.diag.sev", List[Int]]
comptime g_diag_msg = named_global["lsp.diag.msg", List[String]]
# Which file each diagnostic belongs to, and which file is on screen.
#
# The server publishes for every document it has been told about, and it has
# been told about every open tab. Without the uri these were one global set
# that the newest publish overwrote, so the squiggles under your cursor could
# belong to another file entirely -- drawn at those coordinates in this
# buffer, which is worse than showing nothing.
comptime g_diag_uri = named_global["lsp.diag.uri", List[String]]
comptime g_shown_uri = named_global["lsp.shown.uri", List[String]]

# Completion results, and the id of the request they answer. A reply that is
# not the newest request is dropped: typing fast outruns the server, and a late
# answer for a prefix the user has moved past is worse than no answer.
comptime g_comp_label = named_global["lsp.comp.label", List[String]]
comptime g_comp_detail = named_global["lsp.comp.detail", List[String]]
comptime g_comp_insert = named_global["lsp.comp.insert", List[String]]
comptime g_comp_request = named_global["lsp.comp.request", Int]
comptime g_comp_serial = named_global["lsp.comp.serial", Int]
# Which document the outstanding completion request was made for. The id match
# below already rejects a reply to a superseded request; this rejects a reply
# to a live one that is no longer about the file on screen, which is what
# happens when the user asks for completions and switches tab before the
# server answers.
comptime g_comp_uri = named_global["lsp.comp.uri", List[String]]

# Go to definition, and hover. Both are one outstanding request at a time:
# they answer a place the caret IS, so an older answer is about a place the
# caret has left, and holding several would only make it harder to say which
# one is stale.
comptime g_def_request = named_global["lsp.def.request", Int]
comptime g_def_uri = named_global["lsp.def.uri", List[String]]
comptime g_def_line = named_global["lsp.def.line", Int]
comptime g_def_char = named_global["lsp.def.char", Int]
comptime g_def_serial = named_global["lsp.def.serial", Int]

comptime g_hover_request = named_global["lsp.hover.request", Int]
comptime g_hover_text = named_global["lsp.hover.text", List[String]]
comptime g_hover_serial = named_global["lsp.hover.serial", Int]

# References: a list rather than one place, so flat parallel lists like the
# diagnostics -- they are read from a draw loop, which wants no allocation.
comptime g_ref_request = named_global["lsp.ref.request", Int]
comptime g_ref_uri = named_global["lsp.ref.uri", List[String]]
comptime g_ref_line = named_global["lsp.ref.line", List[Int]]
comptime g_ref_char = named_global["lsp.ref.char", List[Int]]
comptime g_ref_serial = named_global["lsp.ref.serial", Int]

# Signature help: the one signature being shown, its documentation, and
# which parameter the caret is inside. The active parameter is the whole
# point -- a signature with nothing highlighted is a docstring, and you
# already had one of those.
comptime g_sig_request = named_global["lsp.sig.request", Int]
comptime g_sig_label = named_global["lsp.sig.label", List[String]]
comptime g_sig_param = named_global["lsp.sig.param", List[String]]
comptime g_sig_active = named_global["lsp.sig.active", Int]
comptime g_sig_serial = named_global["lsp.sig.serial", Int]

# Rename. A reply is a WorkspaceEdit -- edits in several files at once -- so
# this is a flat list of (uri, start, end, text) with the positions already
# taken apart. Flat parallel lists again, for the same reason as everywhere
# else here: no allocation to read one.
comptime g_ren_request = named_global["lsp.ren.request", Int]
comptime g_ren_uri = named_global["lsp.ren.uri", List[String]]
comptime g_ren_l0 = named_global["lsp.ren.l0", List[Int]]
comptime g_ren_c0 = named_global["lsp.ren.c0", List[Int]]
comptime g_ren_l1 = named_global["lsp.ren.l1", List[Int]]
comptime g_ren_c1 = named_global["lsp.ren.c1", List[Int]]
comptime g_ren_text = named_global["lsp.ren.text", List[String]]
comptime g_ren_serial = named_global["lsp.ren.serial", Int]


def inbox() -> String:
    if len(g_inbox()[]) == 0:
        return String()
    return g_inbox()[][0]


def set_inbox(var s: String):
    let slot = g_inbox()
    if len(slot[]) == 0:
        slot[].append(s^)
    else:
        slot[][0] = s^


def is_running() -> Bool:
    return g_task()[] != 0


def is_ready() -> Bool:
    return g_ready()[] != 0


def ready_serial() -> Int:
    """How many times a server has completed its handshake."""
    return g_ready_serial()[]


def diagnostic_count() -> Int:
    return len(g_diag_line()[])


def completion_count() -> Int:
    return len(g_comp_label()[])


def clear_completions():
    let a = g_comp_label()
    let b = g_comp_detail()
    let c = g_comp_insert()
    while len(a[]) > 0:
        _ = a[].pop()
    while len(b[]) > 0:
        _ = b[].pop()
    while len(c[]) > 0:
        _ = c[].pop()


def request_completion(uri: String, line: Int, character: Int) -> Int:
    """Ask what could go here. Line and character are LSP's: zero-based, and
    character counts UTF-16 units, which is why the editor converts."""
    var pos = JSON.object()
    pos.set(String("line"), JSON(line))
    pos.set(String("character"), JSON(character))
    var doc = JSON.object()
    doc.set(String("uri"), JSON(uri))
    var params = JSON.object()
    params.set(String("textDocument"), doc^)
    params.set(String("position"), pos^)
    let id = request(String("textDocument/completion"), params^)
    g_comp_request()[] = id
    let slot = g_comp_uri()
    if len(slot[]) == 0:
        slot[].append(uri)
    else:
        slot[][0] = uri
    return id


def _position_params(uri: String, line: Int, character: Int) -> JSON:
    """textDocument/position, which is the shape of every request that asks
    about a place rather than about a file."""
    var pos = JSON.object()
    pos.set(String("line"), JSON(line))
    pos.set(String("character"), JSON(character))
    var doc = JSON.object()
    doc.set(String("uri"), JSON(uri))
    var params = JSON.object()
    params.set(String("textDocument"), doc^)
    params.set(String("position"), pos^)
    return params^


def request_definition(uri: String, line: Int, character: Int) -> Int:
    """Where is this defined? The server advertises definitionProvider and
    has since the first handshake; nothing had ever asked."""
    let id = request(
        String("textDocument/definition"),
        _position_params(uri, line, character),
    )
    g_def_request()[] = id
    return id


def request_hover(uri: String, line: Int, character: Int) -> Int:
    """What IS this? Type and signature, for the status bar."""
    let id = request(
        String("textDocument/hover"), _position_params(uri, line, character)
    )
    g_hover_request()[] = id
    return id


def request_references(uri: String, line: Int, character: Int) -> Int:
    """Everywhere this is used. `includeDeclaration` is true because the
    question someone asks is "where does this appear", and the definition is
    an appearance -- an editor that hides it makes you look twice."""
    var params = _position_params(uri, line, character)
    var context = JSON.object()
    context.set(String("includeDeclaration"), JSON(True))
    params.set(String("context"), context^)
    let id = request(String("textDocument/references"), params^)
    g_ref_request()[] = id
    return id


def request_signature(uri: String, line: Int, character: Int) -> Int:
    let id = request(
        String("textDocument/signatureHelp"),
        _position_params(uri, line, character),
    )
    g_sig_request()[] = id
    return id


def request_rename(
    uri: String, line: Int, character: Int, new_name: String
) -> Int:
    var params = _position_params(uri, line, character)
    params.set(String("newName"), JSON(new_name))
    let id = request(String("textDocument/rename"), params^)
    g_ren_request()[] = id
    return id


def rename_count() -> Int:
    return len(g_ren_l0()[])


def rename_uri(i: Int) -> String:
    return g_ren_uri()[][i] if i >= 0 and i < rename_count() else String()


def rename_start_line(i: Int) -> Int:
    return g_ren_l0()[][i] if i >= 0 and i < rename_count() else 0


def rename_start_char(i: Int) -> Int:
    return g_ren_c0()[][i] if i >= 0 and i < rename_count() else 0


def rename_end_line(i: Int) -> Int:
    return g_ren_l1()[][i] if i >= 0 and i < rename_count() else 0


def rename_end_char(i: Int) -> Int:
    return g_ren_c1()[][i] if i >= 0 and i < rename_count() else 0


def rename_text(i: Int) -> String:
    return g_ren_text()[][i] if i >= 0 and i < rename_count() else String()


def rename_serial() -> Int:
    return g_ren_serial()[]


def clear_rename():
    let u = g_ren_uri()
    let a = g_ren_l0()
    let b = g_ren_c0()
    let c = g_ren_l1()
    let d = g_ren_c1()
    let t = g_ren_text()
    while len(a[]) > 0:
        _ = u[].pop()
        _ = a[].pop()
        _ = b[].pop()
        _ = c[].pop()
        _ = d[].pop()
        _ = t[].pop()


def _add_edit(uri: String, edit: JSON):
    let rng = edit.get("range")[]
    let start = rng.get("start")[]
    let end = rng.get("end")[]
    g_ren_uri()[].append(uri)
    g_ren_l0()[].append(start.get("line")[].as_int())
    g_ren_c0()[].append(start.get("character")[].as_int())
    g_ren_l1()[].append(end.get("line")[].as_int())
    g_ren_c1()[].append(end.get("character")[].as_int())
    g_ren_text()[].append(edit.get("newText")[].as_string())


def _take_rename(result: JSON):
    """A WorkspaceEdit, in either of the two shapes the protocol defines.

    `changes` is an object keyed by uri; `documentChanges` is an array of
    {textDocument, edits}. Servers pick one, clients must read both, and a
    rename that silently edits nothing because the reply came in the other
    shape is the worst possible failure for this feature -- it looks like
    "no occurrences" and it means "I did not look".
    """
    clear_rename()
    if result.has("changes"):
        let changes = result.get("changes")[]
        # `keys` is parallel to `items` for an object, so the members are
        # walked by index rather than by a lookup per key.
        var k = 0
        while k < len(changes.keys):
            let uri = changes.keys[k]
            let edits = changes.items[k][]
            var i = 0
            while i < edits.count():
                _add_edit(uri, edits.at(i)[])
                i += 1
            k += 1
    if result.has("documentChanges"):
        let docs = result.get("documentChanges")[]
        var d = 0
        while d < docs.count():
            let one = docs.at(d)[]
            let uri = one.get("textDocument")[].get("uri")[].as_string()
            let edits = one.get("edits")[]
            var i = 0
            while i < edits.count():
                _add_edit(uri, edits.at(i)[])
                i += 1
            d += 1
    g_ren_serial()[] += 1


def reference_count() -> Int:
    return len(g_ref_line()[])


def reference_uri(i: Int) -> String:
    return g_ref_uri()[][i] if i >= 0 and i < reference_count() else String()


def reference_line(i: Int) -> Int:
    return g_ref_line()[][i] if i >= 0 and i < reference_count() else 0


def reference_character(i: Int) -> Int:
    return g_ref_char()[][i] if i >= 0 and i < reference_count() else 0


def references_serial() -> Int:
    return g_ref_serial()[]


def clear_references():
    let u = g_ref_uri()
    let l = g_ref_line()
    let c = g_ref_char()
    while len(l[]) > 0:
        _ = u[].pop()
        _ = l[].pop()
        _ = c[].pop()


def signature_serial() -> Int:
    return g_sig_serial()[]


def signature_label() -> String:
    let slot = g_sig_label()
    return slot[][0] if len(slot[]) > 0 else String()


def signature_parameter() -> String:
    """The parameter the caret is inside, or empty. Kept apart from the label
    so a caller can emphasise it without parsing the label back apart."""
    let slot = g_sig_param()
    return slot[][0] if len(slot[]) > 0 else String()


def _take_references(result: JSON):
    clear_references()
    var i = 0
    while i < result.count():
        let one = result.at(i)[]
        let uri = one.get("uri")[].as_string()
        if uri != "":
            let start = one.get("range")[].get("start")[]
            g_ref_uri()[].append(uri)
            g_ref_line()[].append(start.get("line")[].as_int())
            g_ref_char()[].append(start.get("character")[].as_int())
        i += 1
    g_ref_serial()[] += 1


def _take_signature(result: JSON):
    """One signature and the parameter the caret is in.

    `activeSignature` picks which overload the server thinks is meant, and
    `activeParameter` which argument the caret sits in -- and the parameter
    index can live on the signature OR on the reply, with the signature's
    taking precedence. Servers differ, the specification allows both, and
    getting it wrong highlights the wrong argument, which is worse than
    highlighting none.
    """
    let sigs = result.get("signatures")[]
    if sigs.count() == 0:
        _put_sig(String(), String())
        g_sig_serial()[] += 1
        return
    var which = result.get("activeSignature")[].as_int()
    if which < 0 or which >= sigs.count():
        which = 0
    let sig = sigs.at(which)[]
    let label = sig.get("label")[].as_string()

    var active = -1
    if sig.has("activeParameter"):
        active = sig.get("activeParameter")[].as_int()
    elif result.has("activeParameter"):
        active = result.get("activeParameter")[].as_int()
    var param = String()
    let params = sig.get("parameters")[]
    if active >= 0 and active < params.count():
        let p = params.at(active)[]
        # A parameter's label is a string, or a [start, end] pair of offsets
        # into the signature's label -- both legal, and the second is what a
        # server sends when it wants the editor to highlight in place.
        let plabel = p.get("label")[]
        if plabel.count() == 2:
            let a = plabel.at(0)[].as_int()
            let b = plabel.at(1)[].as_int()
            if a >= 0 and b > a and b <= label.byte_length():
                param = String(label[byte=a:b])
        else:
            param = plabel.as_string()
    g_sig_active()[] = active
    _put_sig(label, param^)
    g_sig_serial()[] += 1


def _put_sig(var label: String, var param: String):
    let l = g_sig_label()
    if len(l[]) == 0:
        l[].append(label^)
    else:
        l[][0] = label^
    let pp = g_sig_param()
    if len(pp[]) == 0:
        pp[].append(param^)
    else:
        pp[][0] = param^


def definition_serial() -> Int:
    return g_def_serial()[]


def definition_uri() -> String:
    let slot = g_def_uri()
    return slot[][0] if len(slot[]) > 0 else String()


def definition_line() -> Int:
    return g_def_line()[]


def definition_character() -> Int:
    return g_def_char()[]


def hover_serial() -> Int:
    return g_hover_serial()[]


def hover_text() -> String:
    let slot = g_hover_text()
    return slot[][0] if len(slot[]) > 0 else String()


def _location_fields(loc: JSON) -> Tuple[String, Int, Int]:
    """uri, line and character out of one location, whichever shape it is.

    A Location names `uri` and `range`; a LocationLink names `targetUri` and
    `targetSelectionRange` (falling back to `targetRange`). Both are legal
    replies to the same request, so both are read here rather than in the
    caller.
    """
    var uri = loc.get("uri")[].as_string()
    if uri != "":
        let start = loc.get("range")[].get("start")[]
        return (
            uri^,
            start.get("line")[].as_int(),
            start.get("character")[].as_int(),
        )
    uri = loc.get("targetUri")[].as_string()
    if uri == "":
        return (String(), -1, 0)
    var range_key = String("targetSelectionRange")
    if loc.get("targetSelectionRange")[].count() == 0:
        range_key = String("targetRange")
    let start = loc.get(range_key)[].get("start")[]
    return (
        uri^,
        start.get("line")[].as_int(),
        start.get("character")[].as_int(),
    )


def _take_definition(result: JSON):
    """A definition reply comes in three shapes and the protocol permits all
    of them: a single Location, an array of Locations, or an array of
    LocationLinks. A client that handles only the shape its server happens to
    send is a client that breaks on the next server.

    Read through references rather than bound to a local: JSON owns two Lists
    and a String and is deliberately not ImplicitlyCopyable, so `var loc =
    result` is a copy the compiler is right to refuse.
    """
    var found = (String(), -1, 0)
    if result.has("uri") or result.has("targetUri"):
        found = _location_fields(result)
    elif result.count() > 0:
        # An array: the first entry is the definition; the rest, if any, are
        # alternatives nothing asks about at this size.
        found = _location_fields(result.at(0)[])
    let slot = g_def_uri()
    if len(slot[]) == 0:
        slot[].append(found[0])
    else:
        slot[][0] = found[0]
    g_def_line()[] = found[1]
    g_def_char()[] = found[2]
    g_def_serial()[] += 1


def _take_hover(result: JSON):
    """Hover contents are `MarkupContent {kind, value}` in modern servers and
    were a string, or an array of strings and {language, value} pairs, in
    older ones. Only the first line is kept: this goes in a status bar, and
    the first line of a hover is the signature that answers the question."""
    var text = String()
    let contents = result.get("contents")[]
    if contents.has("value"):
        text = contents.get("value")[].as_string()
    elif contents.count() > 0:
        let first = contents.at(0)[]
        text = first.get("value")[].as_string() if first.has(
            "value"
        ) else first.as_string()
    else:
        text = contents.as_string()
    # Markdown fences and blank lines are noise in one line of status bar.
    var out = String()
    let lines = text.split("\n")
    var i = 0
    while i < len(lines):
        # String() around strip(): strip returns a span into the split's
        # temporary, and a span outlives nothing here.
        var one = String(String(lines[i]).strip())
        if one != "" and not one.startswith("```"):
            out = one^
            break
        i += 1
    let slot = g_hover_text()
    if len(slot[]) == 0:
        slot[].append(out^)
    else:
        slot[][0] = out^
    g_hover_serial()[] += 1


def set_shown_uri(var uri: String):
    """Name the document on screen, so diagnostics for the others stay off it."""
    let slot = g_shown_uri()
    if len(slot[]) == 0:
        slot[].append(uri^)
    else:
        slot[][0] = uri^


def shown_uri() -> String:
    let slot = g_shown_uri()
    return slot[][0] if len(slot[]) > 0 else String()


def diag_visible(i: Int) -> Bool:
    """Is this diagnostic about the document on screen?"""
    if i < 0 or i >= len(g_diag_uri()[]):
        return False
    return g_diag_uri()[][i] == shown_uri()


def visible_diagnostic_count() -> Int:
    var n = 0
    var i = 0
    while i < len(g_diag_uri()[]):
        if diag_visible(i):
            n += 1
        i += 1
    return n


def first_visible_diagnostic() -> Int:
    """Index of the first diagnostic about the shown document, or -1."""
    var i = 0
    while i < len(g_diag_uri()[]):
        if diag_visible(i):
            return i
        i += 1
    return -1


def _drop_diagnostics_for(uri: String):
    """Remove the set belonging to one document, leaving the others alone."""
    let l = g_diag_line()
    let c = g_diag_col()
    let e = g_diag_end()
    let sv = g_diag_sev()
    let m = g_diag_msg()
    let u = g_diag_uri()
    var i = len(u[]) - 1
    while i >= 0:
        if u[][i] == uri:
            # Order does not matter to the reader, so swap-with-last and pop
            # rather than shifting five lists down for every removal.
            let last = len(u[]) - 1
            l[].swap_elements(i, last)
            c[].swap_elements(i, last)
            e[].swap_elements(i, last)
            sv[].swap_elements(i, last)
            m[].swap_elements(i, last)
            u[].swap_elements(i, last)
            _ = l[].pop()
            _ = c[].pop()
            _ = e[].pop()
            _ = sv[].pop()
            _ = m[].pop()
            _ = u[].pop()
        i -= 1


def clear_diagnostics():
    let l = g_diag_line()
    let c = g_diag_col()
    let e = g_diag_end()
    let s = g_diag_sev()
    let m = g_diag_msg()
    let u = g_diag_uri()
    while len(u[]) > 0:
        _ = u[].pop()
    while len(l[]) > 0:
        _ = l[].pop()
    while len(c[]) > 0:
        _ = c[].pop()
    while len(e[]) > 0:
        _ = e[].pop()
    while len(s[]) > 0:
        _ = s[].pop()
    while len(m[]) > 0:
        _ = m[].pop()


# ── Framing ─────────────────────────────────────────────────────────────────
def frame(body: String) -> String:
    """A message on the wire: Content-Length, a blank line, then the bytes.

    The length counts bytes, not characters -- a header saying 40 for a
    39-byte body leaves the server waiting forever for one more.
    """
    var out = String("Content-Length: ")
    out += String(body.byte_length())
    out += "\r\n\r\n"
    out += body
    return out^


def send(var message: JSON) -> Bool:
    """Write one message. Returns False if the server is not running."""
    if g_in()[] == 0:
        return False
    try:
        return write_all(g_in()[], frame(message.serialize()))
    except:
        return False


def request(var method: String, var params: JSON) -> Int:
    """Send a request and return its id, so a reply can be matched to it."""
    g_next_id()[] += 1
    let id = g_next_id()[]
    var msg = JSON.object()
    msg.set(String("jsonrpc"), JSON(String("2.0")))
    msg.set(String("id"), JSON(id))
    msg.set(String("method"), JSON(method^))
    msg.set(String("params"), params^)
    _ = send(msg^)
    return id


def notify(var method: String, var params: JSON):
    """A notification has no id and expects no reply."""
    var msg = JSON.object()
    msg.set(String("jsonrpc"), JSON(String("2.0")))
    msg.set(String("method"), JSON(method^))
    msg.set(String("params"), params^)
    _ = send(msg^)


# ── Lifecycle ───────────────────────────────────────────────────────────────
def start(server: String, root_uri: String, import_path: String = String()) -> Bool:
    return start_with_environment(
        server, root_uri, import_path, JSON.object()
    )


def start_with_environment(
    server: String,
    root_uri: String,
    import_path: String,
    var environment: JSON,
) -> Bool:
    """Spawn the server and send initialize.

    The server is the one beside us in the distribution, which matters: an
    editor built by this toolchain should ask this toolchain's server, not
    whichever one happens to be on PATH.
    """
    if is_running():
        return True

    # The server needs the stdlib, and it will not guess where it is.
    # IDE-EMBEDDING.md is blunt about this: there is no lex-only mode, so
    # every parse imports std, and without a path every line of every file
    # comes back as "unable to locate module 'std'" -- a configuration error
    # wearing a source error's clothes.
    #
    # MODULAR_MOJO_MAX_IMPORT_PATH is the config key mojo-max.import_path as
    # an environment variable. Set here and inherited, rather than assembled
    # into an environment block: the block would have to be a copy of this
    # process's whole environment with one line changed.
    try:
        if import_path != "":
            set_env(String("MODULAR_MOJO_MAX_IMPORT_PATH"), import_path)
        var i = 0
        while i < environment.count():
            set_env(environment.keys[i], environment.items[i][].as_string())
            i += 1

        var child = spawn(server)
        if not child.running():
            print("  lsp: could not start", server)
            return False
        g_task()[] = child.process
        g_thread()[] = child.thread
        g_in()[] = child.writes_to
        g_read_fd()[] = child.reads_from
    except err:
        print("  lsp: could not start:", String(err))
        return False

    var params = JSON.object()
    params.set(String("processId"), JSON())
    params.set(String("rootUri"), JSON(root_uri))
    var caps = JSON.object()
    params.set(String("capabilities"), caps^)
    _ = request(String("initialize"), params^)
    return True


def stop():
    """Terminate the server and forget everything it told us.

    The state has to go with the process. A restart re-roots the server, so
    diagnostics and completions from the old workspace are about files it is
    no longer looking at, and half a message left in the inbox would be
    parsed as the front of the new server's first reply.
    """
    if not is_running():
        return
    var child = Child(
        g_task()[], g_thread()[], g_in()[], g_read_fd()[]
    )
    try:
        kill(child)
    except:
        pass
    g_task()[] = 0
    g_thread()[] = 0
    g_in()[] = 0
    g_ready()[] = 0
    g_read_fd()[] = 0
    set_inbox(String())
    g_def_request()[] = 0
    g_hover_request()[] = 0
    g_ref_request()[] = 0
    g_sig_request()[] = 0
    g_ren_request()[] = 0
    clear_rename()
    clear_references()
    clear_diagnostics()
    clear_completions()


def did_open(uri: String, text: String):
    var doc = JSON.object()
    doc.set(String("uri"), JSON(uri))
    doc.set(String("languageId"), JSON(String("mojo")))
    doc.set(String("version"), JSON(1))
    doc.set(String("text"), JSON(text))
    var params = JSON.object()
    params.set(String("textDocument"), doc^)
    notify(String("textDocument/didOpen"), params^)


def did_change(uri: String, version: Int, text: String):
    """Full-text sync. Incremental sync is the next step and needs the rope's
    edit spans, which it already knows; whole-document keeps the first version
    honest about what it does."""
    var doc = JSON.object()
    doc.set(String("uri"), JSON(uri))
    doc.set(String("version"), JSON(version))
    var change = JSON.object()
    change.set(String("text"), JSON(text))
    var changes = JSON.array()
    changes.push(change^)
    var params = JSON.object()
    params.set(String("textDocument"), doc^)
    params.set(String("contentChanges"), changes^)
    notify(String("textDocument/didChange"), params^)


# ── Reading ─────────────────────────────────────────────────────────────────
def poll() -> Int:
    """Drain whatever has arrived and handle every complete message.

    Returns how many messages were handled, so a caller can tell whether
    anything happened without inspecting the state.
    """
    if g_read_fd()[] == 0:
        return 0
    var handled = 0
    # 64 KB at a time; the loop repeats while the pipe keeps giving.
    comptime CAP = 65536
    while True:
        # Zeroed, and one byte spare: whatever is read is already
        # NUL-terminated and needs no length carried beside it. The server
        # sends JSON, which has no embedded NULs.
        var buf = alloc[UInt8](CAP + 1, alignment=8)
        for k in range(CAP + 1):
            buf.unsafe_offset(k)[] = 0
        var n = 0
        try:
            n = read_some(g_read_fd()[], Int(buf), CAP)
        except:
            n = -1
        if n <= 0:
            buf.unsafe_free()
            break
        var acc = inbox()
        # Whole characters only -- see pipeutf8. The server's JSON is about
        # to be parsed, so a replacement character would be corruption; the
        # partial sequence waits for the next read.
        acc += take_chunk(g_pending()[], OpaquePointer[MutUntrackedOrigin](
            unsafe_from_address=Int(buf)
        ), n)
        set_inbox(acc^)
        buf.unsafe_free()
        if n < CAP:
            break

    if True:

        # Every whole message currently in the inbox.
        while True:
            var acc = inbox()
            let header_end = acc.find("\r\n\r\n")
            if header_end < 0:
                break
            let header = String(acc[byte=0:header_end])
            let marker = header.find("Content-Length:")
            if marker < 0:
                # Not a frame we understand; drop it rather than spin.
                set_inbox(String(acc[byte = header_end + 4 : acc.byte_length()]))
                continue
            var length = 0
            var i = marker + 15
            let hb = header.as_bytes()
            while i < header.byte_length():
                let c = Int(hb[i])
                if c >= 0x30 and c <= 0x39:
                    length = length * 10 + (c - 0x30)
                elif length > 0:
                    break
                i += 1
            let body_at = header_end + 4
            # Same bound as the debug adapter, for the same reason: a length
            # that is not a length leaves an inbox that can never drain, and
            # every later read is appended to it until a String asks the
            # allocator for gigabytes. The server's largest real messages --
            # semantic tokens for a big file -- are megabytes at worst.
            if length < 0 or length > MAX_MESSAGE:
                set_inbox(String())
                print("  lsp: implausible Content-Length", length, "— resynchronising")
                break
            if acc.byte_length() < body_at + length:
                if acc.byte_length() > MAX_INBOX:
                    set_inbox(String())
                    print("  lsp: inbox past", MAX_INBOX, "bytes with no whole message — resynchronising")
                break  # the rest has not arrived
            let body = String(acc[byte = body_at : body_at + length])
            set_inbox(String(acc[byte = body_at + length : acc.byte_length()]))
            _handle(parse(body))
            handled += 1
    return handled


def _handle(var msg: JSON):
    """One message from the server."""
    let method = msg.get("method")[].as_string()
    if method == "textDocument/publishDiagnostics":
        _take_diagnostics(msg.get("params")[])
        return
    # A reply to the outstanding completion request.
    if msg.has("id") and msg.has("error"):
        # An error reply has no `result`, so it fell through every branch
        # below and left the request id live -- meaning the feature waited
        # forever for an answer that had already arrived, and the NEXT reply
        # with that id would have been taken for it. Clear whichever request
        # it answers, and let the app see a serial move so it can say so.
        let bad = msg.get("id")[].as_int()
        let why = msg.get("error")[].get("message")[].as_string()
        if bad != 0:
            if bad == g_def_request()[]:
                g_def_request()[] = 0
                g_def_line()[] = -1
                g_def_serial()[] += 1
            elif bad == g_ref_request()[]:
                g_ref_request()[] = 0
                clear_references()
                g_ref_serial()[] += 1
            elif bad == g_sig_request()[]:
                g_sig_request()[] = 0
                _put_sig(String(), String())
                g_sig_serial()[] += 1
            elif bad == symbols_request_id():
                clear_symbols()
            elif bad == g_ren_request()[]:
                g_ren_request()[] = 0
                clear_rename()
                g_ren_serial()[] += 1
            elif bad == g_comp_request()[]:
                g_comp_request()[] = 0
                clear_completions()
                g_comp_serial()[] += 1
            elif bad == g_hover_request()[]:
                g_hover_request()[] = 0
                g_hover_serial()[] += 1
            print("lsp: request", bad, "failed:", why)
        return

    if msg.has("id") and msg.has("result"):
        let id = msg.get("id")[].as_int()
        if id == g_def_request()[] and id != 0:
            g_def_request()[] = 0
            _take_definition(msg.get("result")[])
            return
        if id == g_hover_request()[] and id != 0:
            g_hover_request()[] = 0
            _take_hover(msg.get("result")[])
            return
        if id == g_ref_request()[] and id != 0:
            g_ref_request()[] = 0
            _take_references(msg.get("result")[])
            return
        if id == g_sig_request()[] and id != 0:
            g_sig_request()[] = 0
            _take_signature(msg.get("result")[])
            return
        if id == g_ren_request()[] and id != 0:
            g_ren_request()[] = 0
            _take_rename(msg.get("result")[])
            return
        # Document symbols live in their own module because they are a view
        # rather than a piece of the protocol's plumbing, but a reply can only
        # be recognised here -- an id this dispatch does not claim is dropped
        # on the floor, silently, which is the correct behaviour for a stray
        # message and a mystery for a feature. `take_symbols` clears its own
        # outstanding id, which is what makes a late or duplicate reply
        # harmless.
        if id == symbols_request_id() and id != 0:
            take_symbols(msg.get("result")[])
            return
        if id == g_comp_request()[] and id != 0:
            # Answered, whatever we do with it: leaving the id live would let
            # the next reply-shaped message be mistaken for this one.
            g_comp_request()[] = 0
            if _completion_still_wanted():
                _take_completions(msg.get("result")[])
            else:
                clear_completions()
                g_comp_serial()[] += 1
            return

    # A reply to initialize: tell the server we are ready, then we are.
    if msg.has("result") and not msg.has("method"):
        if g_ready()[] == 0:
            var empty = JSON.object()
            notify(String("initialized"), empty^)
            g_ready()[] = 1
            g_ready_serial()[] += 1


def _completion_still_wanted() -> Bool:
    """Is the outstanding request still about the document on screen?

    Both unknowns mean yes. A caller that never names a shown document -- the
    test harness, and anything embedding this client without a tab bar -- gets
    the old unconditional behaviour rather than silence.
    """
    let want = shown_uri()
    if want == "":
        return True
    let slot = g_comp_uri()
    if len(slot[]) == 0:
        return True
    return slot[][0] == want


def _take_completions(result: JSON):
    """A completion reply is either a bare array of items or a list object with
    them under `items`. Servers send both shapes; this reads either.

    Two branches rather than a conditional expression, because a conditional
    would have to produce a JSON value and JSON owns two Lists and a String --
    copying one is a decision, not something to slip into an expression.
    """
    clear_completions()
    if result.has("items"):
        _collect_completions(result.get("items")[])
    else:
        _collect_completions(result)
    g_comp_serial()[] += 1


def _collect_completions(items: JSON):
    var i = 0
    while i < items.count():
        let it = items.at(i)[]
        let label = it.get("label")[].as_string()
        if label != "":
            g_comp_label()[].append(label)
            g_comp_detail()[].append(it.get("detail")[].as_string())
            # insertText when the server gives one, otherwise the label. They
            # differ wherever the visible name is not what gets typed.
            let insert = it.get("insertText")[].as_string()
            g_comp_insert()[].append(insert if insert != "" else label)
        i += 1


# The one thing the server says that means "I have finished reading this
# file". It publishes diagnostics for a document when its parse completes,
# empty list and all, so a question that is only answerable from a finished
# parse can wait for this rather than for a guessed number of milliseconds.
comptime g_parse_serial = named_global["lsp.parse.serial", Int]
comptime g_parsed_uri = named_global["lsp.parse.uri", List[String]]


def parse_serial() -> Int:
    """How many documents have finished parsing since the server started.

    Returns:
        A number that only goes up.
    """
    return g_parse_serial()[]


def parsed_uri() -> String:
    """Which document the last parse was of.

    Returns:
        The uri, or empty before the first one.
    """
    var slot = g_parsed_uri()
    return slot[][0] if len(slot[]) > 0 else String()


def _take_diagnostics(params: JSON):
    # A publish replaces that document's set and touches no other. The server
    # sends one of these per document it is watching, so clearing everything
    # here -- which is what this used to do -- meant the last file to be
    # analysed owned the display.
    let uri = params.get("uri")[].as_string()
    g_parse_serial()[] += 1
    var seen = g_parsed_uri()
    if len(seen[]) == 0:
        seen[].append(uri)
    else:
        seen[][0] = uri
    _drop_diagnostics_for(uri)
    let list = params.get("diagnostics")[]
    var i = 0
    while i < list.count():
        let d = list.at(i)[]
        let rng = d.get("range")[]
        let start = rng.get("start")[]
        let end = rng.get("end")[]
        g_diag_line()[].append(start.get("line")[].as_int())
        g_diag_col()[].append(start.get("character")[].as_int())
        # An end on a later line is clamped to the start line: the gutter and
        # the underline are per-line, and a squiggle that wraps is worse than
        # one that stops.
        var end_col = end.get("character")[].as_int()
        if end.get("line")[].as_int() != start.get("line")[].as_int():
            end_col = start.get("character")[].as_int() + 1
        g_diag_end()[].append(end_col)
        # 1 error, 2 warning, 3 information, 4 hint.
        g_diag_sev()[].append(d.get("severity")[].as_int())
        g_diag_msg()[].append(d.get("message")[].as_string())
        g_diag_uri()[].append(uri)
        i += 1
