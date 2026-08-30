# MUST FAIL: the width check still applies past the old four-argument ceiling.
#
# `starting_line` is a 4-byte u32; this declares a 1-byte UInt8. Five new
# trampolines were generated to raise the arity ceiling to nine (see
# s20_class_wide_arity), and generated code is exactly where a check quietly
# stops being applied -- so the eighth argument of a nine-argument method is
# the place to prove it did not.
class WideNarrow(IActiveScriptParseProcedureOld32):
    var seen: Int

    def ParseProcedureText(
        mut self,
        code: Int,
        formal_params: Int,
        item_name: Int,
        context: Int,
        delimiter: Int,
        source_context: UInt32,
        starting_line: UInt8,
        flags: UInt32,
        out_dispatch: Int,
    ) raises:
        self.seen += 1


def main() raises:
    var obj = WideNarrow(0).into_com()
    _ = obj
    print("must not compile")
