# MUST FAIL: a read-only property. IAudioClock declares GetFrequency and no
# SetFrequency, so `view.frequency = ...` has no setter to mean -- the
# metadata refuses the write at compile time, naming the interface and the
# property. Read-only in the SDK is read-only here.

from std.sys.com import ComPtr, Com
from std.memory import Pointer


class Clock(IAudioClock):
    var freq: UInt64

    def GetFrequency(mut self, freq: Pointer[UInt64, MutAnyOrigin]) raises:
        freq[] = self.freq

    def GetPosition(mut self, pos: Pointer[UInt64, MutAnyOrigin], qpc: Pointer[UInt64, MutAnyOrigin]) raises:
        pos[] = 0
        qpc[] = 0

    def GetCharacteristics(mut self, chars: Pointer[UInt32, MutAnyOrigin]) raises:
        chars[] = 0


def main() raises:
    var obj = Clock(0).into_com()
    var view = Com[StaticString("IAudioClock")](of=obj)
    view.frequency = 44100
