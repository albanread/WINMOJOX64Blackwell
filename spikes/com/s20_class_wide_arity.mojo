# A class method may take up to nine arguments.
#
# The ceiling used to be four, because there were five trampolines. Nothing
# chose four -- it was however many had been written when the first object
# needed one, and it held until sprint 1.5 went to implement `ITextStoreACP`,
# where eight of the twenty-six methods are wider and `GetText` takes nine.
#
# The sprint plan said those would go through the raw `slot[]` escape hatch.
# They do not, because the honest reading of "the sugar stops working at five
# arguments" is that the sugar was short five trampolines -- not that the
# caller should drop a layer. `com_tramp5` through `com_tramp9` were one
# generated patch. The escape hatch stays for what it is actually for: a
# signature the metadata cannot describe.
#
# Three classes here, at five, eight and nine arguments -- the first past the
# old ceiling, and the two ends of what `ITextStoreACP` needs. All three are
# driven through their own vtables, because "it compiled" and "Windows can
# call it" are different claims and only the second one matters.
#
# One thing the exercise turned up, worth knowing before choosing an
# interface to implement: the argument-width check reads `type_width` from the
# metadata, and a struct passed BY VALUE -- a `Guid`, say -- has no entry. So
# `IAccPropServer`, whose one method takes a GUID by value, cannot be
# implemented through this surface at all yet. That is a real gap and a
# different one from arity.

from std.memory import OpaquePointer, Pointer
from std.sys._com import com_addr, com_method_of


class FiveArgs(IFtpRoleProvider):
    var seen: Int

    def IsUserInRole(
        mut self,
        session: Int,
        user: Int,
        role: Int,
        domain: Int,
        answer: Int,
    ) raises:
        self.seen += 1
        Pointer[Int32, MutAnyOrigin](unsafe_from_address=answer)[] = 1


class EightArgs(IWiaDataCallback):
    var seen: Int
    var last_length: Int

    def BandedDataCallback(
        mut self,
        message: Int32,
        status: Int32,
        percent: Int32,
        offset: Int32,
        length: Int32,
        reserved: Int32,
        res_length: Int32,
        buffer: Int,
    ) raises:
        self.seen += 1
        self.last_length = Int(length)


class NineArgs(IActiveScriptParseProcedureOld32):
    var seen: Int
    var last_line: Int

    def ParseProcedureText(
        mut self,
        code: Int,
        formal_params: Int,
        item_name: Int,
        context: Int,
        delimiter: Int,
        source_context: UInt32,
        starting_line: UInt32,
        flags: UInt32,
        out_dispatch: Int,
    ) raises:
        self.seen += 1
        self.last_line = Int(starting_line)


def main() raises:
    var five = FiveArgs(0).into_com()
    var a = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=five.address())
    var answer = Int32(0)
    var hr5 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Int,
            Int,
            Pointer[Int32, MutAnyOrigin],
        ) thin abi("C") -> Int32,
        "IFtpRoleProvider",
        "IsUserInRole",
    ](a)(a, 0, 0, 0, 0, com_addr(answer))
    print("S20 five arguments:  hr", hr5, " out-parameter written:", answer == 1)
    if hr5 != 0 or answer != 1:
        raise Error("a five-argument class method did not dispatch")

    var eight = EightArgs(0, 0).into_com()
    var b = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=eight.address()
    )
    var hr8 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Int,
        ) thin abi("C") -> Int32,
        "IWiaDataCallback",
        "BandedDataCallback",
    ](b)(b, 1, 2, 3, 4, Int32(4096), 0, 0, 0)
    print("S20 eight arguments: hr", hr8)
    if hr8 != 0:
        raise Error("an eight-argument class method did not dispatch")

    var nine = NineArgs(0, 0).into_com()
    var c = OpaquePointer[MutUntrackedOrigin](unsafe_from_address=nine.address())
    var hr9 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Int,
            Int,
            Int,
            UInt32,
            UInt32,
            UInt32,
            Int,
        ) thin abi("C") -> Int32,
        "IActiveScriptParseProcedureOld32",
        "ParseProcedureText",
    ](c)(c, 0, 0, 0, 0, 0, UInt32(1), UInt32(42), UInt32(0), 0)
    print("S20 nine arguments:  hr", hr9)
    if hr9 != 0:
        raise Error("a nine-argument class method did not dispatch")

    print("S20 PASS")
