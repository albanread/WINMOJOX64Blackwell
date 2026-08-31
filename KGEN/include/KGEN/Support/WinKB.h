//===----------------------------------------------------------------------===//
// The Win32 metadata database, for tools that are not the elaborator.
//
// `windows_api.db` is read during elaboration to answer `winkb_query`: a slot
// index, a struct size, an interface's IID. That reader is a lazily-opened
// singleton inside IREvaluatorContext.cpp, and until sprint 2.4 nothing
// outside elaboration needed it.
//
// The language server does. Completion inside a `class Name(IFace):` body
// should offer the methods of IFace that the body has not implemented yet,
// with the parameter types the database records rather than ones a person
// remembered -- which is the whole argument of this repository applied to the
// editor rather than to the compiler. That needs the same database, from a
// different tool, so the query lives behind this header instead of inside a
// translation unit.
//===----------------------------------------------------------------------===//

#ifndef KGEN_SUPPORT_WINKB_H
#define KGEN_SUPPORT_WINKB_H

#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Error.h"

#include <string>
#include <vector>

namespace M {
namespace KGEN {

/// One method of a COM interface, as the metadata records it.
struct WinKBMethod {
  /// The method's name, e.g. "DragOver".
  std::string name;
  /// Its absolute vtable slot. Absolute, not relative: an inherited method
  /// keeps the slot its declaring interface gave it, which is the arithmetic
  /// a hand-written binding gets wrong.
  int slot = 0;
  /// The parameter types, in order, as the metadata spells them --
  /// "u32", "Windows.Win32.Foundation.HWND", and so on. The `this` pointer is
  /// not among them; COM passes it as an ordinary first argument and every
  /// caller supplies it.
  std::vector<std::string> paramTypes;
  /// And their names, as Windows spells them. Cosmetic: a completion reads
  /// better with them than with arg0, arg1, arg2, and a person renames them
  /// freely. The types are the half that has to be right.
  std::vector<std::string> paramNames;
};

/// Every method an interface declares, in slot order, including those it
/// inherits.
///
/// Returns an error if the database is not configured or the interface is not
/// in it -- the caller is a language server, so "no such interface" is
/// something to say quietly rather than to fail a build over.
llvm::Expected<std::vector<WinKBMethod>>
winkbInterfaceMethods(llvm::StringRef interfaceName);

/// A Mojo parameter list for a method, as a person would write it in a class
/// body: `(mut self, key: UInt32, pt: Int, effect: Int) raises`.
///
/// The names are invented -- the metadata has them, but they are Windows'
/// names and often a Hungarian mouthful -- while the *types* are the
/// database's, which is the half that has to be right. A wrong name is a
/// rename; a wrong width silently reads the wrong register.
std::string winkbMojoSignature(const WinKBMethod &method);

} // namespace KGEN
} // namespace M

#endif // KGEN_SUPPORT_WINKB_H
