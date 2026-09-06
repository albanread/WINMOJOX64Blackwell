"""ABC notation: parse it, schedule it, play it on the chip or write it out.

Lifted from `examples/abcplayer` unchanged in spirit. It lives here for the
same reason the chip does: the example had VENDORED a copy of the
synthesiser, with a comment asking whoever changed the original to remember
to update it, and by the time G7 landed that copy was four fixes behind. One
copy, imported.

`model` is the note and event types, `parse` the header and body reader,
`music` the note arithmetic -- keys, accidentals, ties, chords, octaves --
`repeats` the expansion, `schedule` the flattening into timed steps, and
`midi` the SMF writer.
"""

from .model import (
    Tune, Event, Voice, TICKS_PER_QUARTER, TICKS_PER_WHOLE,
    EV_NOTE, EV_REST, EV_BAR, EV_TEMPO, EV_KEY, EV_METER, EV_VOICE, EV_CHIP,
)
from .schedule import (
    Step, SE_NOTE_ON, SE_NOTE_OFF, SE_CHIP,
    ticks_per_beat, tick_to_sample, resolve_ties, build_schedule, sort_steps,
    MsEvent, to_ms_events,
)
from .midi import build_midi, write_midi, put_varlen, channel_for
from .parse import parse_abc
from .chipplay import (
    flatten_schedule, render_scheduled, silent_tick,
    SC_ADDR, SC_COUNT, SC_CURSOR, SC_SAMPLE, SC_END, SC_LOOP, SC_PAUSE,
    SC_DONE, STEP_SLOTS,
)
