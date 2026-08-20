//===----------------------------------------------------------------------===//
//
// A POSIX shim for the entry points the Mojo standard library calls by name.
//
// The standard library reaches libc through `external_call["name", ...]`, so
// these have to exist as C symbols at link time or every program that touches
// os/subprocess/file_descriptor fails to link. The MSVC CRT supplies most of
// what it wants: `oldnames.lib` aliases the legacy set (open, read, write, dup,
// stat, chdir, ...) to their underscore-prefixed spellings, and `_popen` and
// `_pclose` exist under those names. What is left has no CRT equivalent at all
// and is implemented here on Win32.
//
// The aim is behavioural equivalence at the call sites the standard library
// actually has -- not a general POSIX layer. Where Windows cannot express a
// POSIX guarantee, the difference is commented rather than papered over.
//
// GNU's Windows ports (Cygwin, MSYS2, glibc) are GPL and cannot be used here;
// this file is written against the Win32 API directly and stays under the
// repository's Apache-2.0-with-LLVM-exceptions licence.
//
//===----------------------------------------------------------------------===//

#ifdef _WIN32

#include "Support/SymbolExport.h"

#include "llvm/ADT/StringMap.h"

#include <windows.h>

#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

#include <mutex>
#include <string>
#include <vector>

// Linux's PATH_MAX. The standard library sizes its realpath destination buffer
// against this value, so we must not write more than this into a caller buffer
// even though Windows itself permits considerably longer paths.
#define KGEN_POSIX_PATH_MAX 4096

#define KGEN_FD_CLOEXEC 1
#define KGEN_F_GETFD 1
#define KGEN_F_SETFD 2

namespace {

/// Translate a Win32 error into the closest errno value. Only the codes these
/// entry points can actually produce are mapped; anything else becomes EINVAL,
/// which is at least an error rather than a spurious success.
int errnoFromWin32(DWORD err) {
  switch (err) {
  case ERROR_FILE_NOT_FOUND:
  case ERROR_PATH_NOT_FOUND:
  case ERROR_INVALID_DRIVE:
    return ENOENT;
  case ERROR_ACCESS_DENIED:
  case ERROR_SHARING_VIOLATION:
    return EACCES;
  case ERROR_FILE_EXISTS:
  case ERROR_ALREADY_EXISTS:
    return EEXIST;
  case ERROR_NOT_SAME_DEVICE:
    return EXDEV;
  case ERROR_TOO_MANY_LINKS:
    return EMLINK;
  case ERROR_DIRECTORY:
  case ERROR_INVALID_NAME:
    return EINVAL;
  case ERROR_FILENAME_EXCED_RANGE:
    return ENAMETOOLONG;
  case ERROR_NOT_ENOUGH_MEMORY:
  case ERROR_OUTOFMEMORY:
    return ENOMEM;
  case ERROR_PRIVILEGE_NOT_HELD:
    // CreateSymbolicLinkW without Developer Mode or SeCreateSymbolicLink.
    return EPERM;
  default:
    return EINVAL;
  }
}

void setErrnoFromWin32() { errno = errnoFromWin32(::GetLastError()); }

/// UTF-8 to UTF-16. Mojo strings are UTF-8, so every path crossing into a
/// Win32 W-suffixed call goes through here. Returns false on malformed input.
bool widen(const char *utf8, std::wstring &out) {
  if (!utf8) {
    errno = EINVAL;
    return false;
  }
  int n = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1,
                                nullptr, 0);
  if (n <= 0) {
    errno = EINVAL;
    return false;
  }
  out.resize(static_cast<size_t>(n - 1));
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, &out[0],
                            n) <= 0) {
    errno = EINVAL;
    return false;
  }
  return true;
}

/// UTF-16 back to UTF-8.
bool narrow(const wchar_t *wide, std::string &out) {
  int n = ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr,
                                nullptr);
  if (n <= 0) {
    errno = EINVAL;
    return false;
  }
  out.resize(static_cast<size_t>(n - 1));
  if (::WideCharToMultiByte(CP_UTF8, 0, wide, -1, &out[0], n, nullptr,
                            nullptr) <= 0) {
    errno = EINVAL;
    return false;
  }
  return true;
}

/// Open a path purely to identify it. FILE_FLAG_BACKUP_SEMANTICS is what makes
/// a directory openable as a handle; without it this works on files only.
HANDLE openForQuery(const wchar_t *path) {
  return ::CreateFileW(path, /*dwDesiredAccess=*/0,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       /*lpSecurityAttributes=*/nullptr, OPEN_EXISTING,
                       FILE_FLAG_BACKUP_SEMANTICS, /*hTemplateFile=*/nullptr);
}

/// Resolve a handle to its canonical DOS path, with the \\?\ prefix removed.
/// GetFinalPathNameByHandleW always returns the extended-length form; POSIX
/// callers expect a plain path, and the prefix leaks into error messages and
/// string comparisons if left in place.
bool finalPathOf(HANDLE h, std::wstring &out) {
  DWORD n = ::GetFinalPathNameByHandleW(h, nullptr, 0,
                                        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (n == 0)
    return false;
  out.resize(n);
  DWORD written = ::GetFinalPathNameByHandleW(
      h, &out[0], n, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (written == 0 || written >= n)
    return false;
  out.resize(written);

  // "\\?\UNC\server\share" is a UNC path; restore its "\\server\share" form.
  if (out.compare(0, 8, L"\\\\?\\UNC\\") == 0)
    out = L"\\\\" + out.substr(8);
  else if (out.compare(0, 4, L"\\\\?\\") == 0)
    out = out.substr(4);
  return true;
}

} // namespace

//===----------------------------------------------------------------------===//
// Link creation
//===----------------------------------------------------------------------===//

/// POSIX symlink(2). Note the argument order inverts: POSIX names the target
/// first, CreateSymbolicLinkW names the link first.
///
/// Windows distinguishes file and directory symlinks at creation time, so the
/// target has to be probed. A dangling symlink -- legal under POSIX -- is
/// therefore created as a file symlink, which is the closest available
/// behaviour but is not identical if the target later appears as a directory.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int
symlink(const char *target, const char *linkpath) {
  std::wstring wTarget, wLink;
  if (!widen(target, wTarget) || !widen(linkpath, wLink))
    return -1;

  DWORD flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
  DWORD attrs = ::GetFileAttributesW(wTarget.c_str());
  if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY))
    flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;

  if (!::CreateSymbolicLinkW(wLink.c_str(), wTarget.c_str(), flags)) {
    setErrnoFromWin32();
    return -1;
  }
  return 0;
}

/// POSIX link(2). The argument order inverts here too.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int link(const char *oldpath,
                                                        const char *newpath) {
  std::wstring wOld, wNew;
  if (!widen(oldpath, wOld) || !widen(newpath, wNew))
    return -1;

  if (!::CreateHardLinkW(wNew.c_str(), wOld.c_str(),
                         /*lpSecurityAttributes=*/nullptr)) {
    setErrnoFromWin32();
    return -1;
  }
  return 0;
}

//===----------------------------------------------------------------------===//
// Path resolution
//===----------------------------------------------------------------------===//

/// POSIX realpath(3). Resolves symlinks and returns an absolute canonical path.
///
/// The resolution is done by opening the file and asking Windows what it
/// actually opened, which follows symlinks and normalises case and short
/// (8.3) names the way POSIX expects. It also inherits POSIX's requirement
/// that the path exist: a missing component yields ENOENT rather than a
/// syntactically-cleaned string.
///
/// When `resolved` is null a buffer is allocated with malloc, which the caller
/// frees. That is only safe because every module in this build shares one CRT
/// heap (`-fms-runtime-lib=dll`); under a static CRT this allocation would be
/// freed against a different heap.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT char *
realpath(const char *path, char *resolved) {
  std::wstring wPath;
  if (!widen(path, wPath))
    return nullptr;

  HANDLE h = openForQuery(wPath.c_str());
  if (h == INVALID_HANDLE_VALUE) {
    setErrnoFromWin32();
    return nullptr;
  }

  std::wstring wFinal;
  bool ok = finalPathOf(h, wFinal);
  DWORD err = ::GetLastError();
  ::CloseHandle(h);
  if (!ok) {
    errno = errnoFromWin32(err);
    return nullptr;
  }

  std::string utf8;
  if (!narrow(wFinal.c_str(), utf8))
    return nullptr;

  if (resolved) {
    // The caller's buffer is PATH_MAX by contract and carries no length, so a
    // longer Windows path has to be refused rather than truncated.
    if (utf8.size() + 1 > KGEN_POSIX_PATH_MAX) {
      errno = ENAMETOOLONG;
      return nullptr;
    }
    ::memcpy(resolved, utf8.c_str(), utf8.size() + 1);
    return resolved;
  }

  char *out = static_cast<char *>(::malloc(utf8.size() + 1));
  if (!out) {
    errno = ENOMEM;
    return nullptr;
  }
  ::memcpy(out, utf8.c_str(), utf8.size() + 1);
  return out;
}

//===----------------------------------------------------------------------===//
// Descriptor operations
//===----------------------------------------------------------------------===//

/// POSIX fchdir(2). Windows has no directory-handle form of
/// SetCurrentDirectory, so the handle is resolved back to a path first. The
/// POSIX guarantee this loses is atomicity: if the directory is renamed
/// between the two calls, we follow the name rather than the handle.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int fchdir(int fd) {
  HANDLE h = reinterpret_cast<HANDLE>(::_get_osfhandle(fd));
  if (h == INVALID_HANDLE_VALUE) {
    errno = EBADF;
    return -1;
  }

  std::wstring wPath;
  if (!finalPathOf(h, wPath)) {
    setErrnoFromWin32();
    return -1;
  }

  if (!::SetCurrentDirectoryW(wPath.c_str())) {
    setErrnoFromWin32();
    return -1;
  }
  return 0;
}

/// POSIX fcntl(2), restricted to the commands the standard library issues:
/// F_GETFD and F_SETFD carrying FD_CLOEXEC.
///
/// Windows expresses the same idea inverted -- a handle is either inheritable
/// or not, and close-on-exec is the absence of inheritance -- so the flag is
/// negated in both directions. Any other command is rejected with EINVAL
/// rather than silently succeeding, since a quiet no-op here would surface as
/// a descriptor leak somewhere far away.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int fcntl(int fd, int cmd, ...) {
  HANDLE h = reinterpret_cast<HANDLE>(::_get_osfhandle(fd));
  if (h == INVALID_HANDLE_VALUE) {
    errno = EBADF;
    return -1;
  }

  switch (cmd) {
  case KGEN_F_GETFD: {
    DWORD flags = 0;
    if (!::GetHandleInformation(h, &flags)) {
      setErrnoFromWin32();
      return -1;
    }
    return (flags & HANDLE_FLAG_INHERIT) ? 0 : KGEN_FD_CLOEXEC;
  }
  case KGEN_F_SETFD: {
    va_list ap;
    va_start(ap, cmd);
    int want = va_arg(ap, int);
    va_end(ap);
    DWORD inherit = (want & KGEN_FD_CLOEXEC) ? 0 : HANDLE_FLAG_INHERIT;
    if (!::SetHandleInformation(h, HANDLE_FLAG_INHERIT, inherit)) {
      setErrnoFromWin32();
      return -1;
    }
    return 0;
  }
  default:
    errno = EINVAL;
    return -1;
  }
}

//===----------------------------------------------------------------------===//
// stdio
//===----------------------------------------------------------------------===//

/// POSIX getline(3). Reads through the next newline, growing *lineptr as
/// needed; the newline is kept, and the result is always NUL-terminated.
/// Returns the byte count, or -1 at end of file or on error.
///
/// The buffer is malloc/realloc'd for the caller to free -- see the note on
/// realpath about why that is sound in this build.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT ptrdiff_t
getline(char **lineptr, size_t *n, FILE *stream) {
  if (!lineptr || !n || !stream) {
    errno = EINVAL;
    return -1;
  }

  if (!*lineptr || *n == 0) {
    size_t cap = 128;
    char *buf = static_cast<char *>(::malloc(cap));
    if (!buf) {
      errno = ENOMEM;
      return -1;
    }
    *lineptr = buf;
    *n = cap;
  }

  size_t len = 0;
  for (;;) {
    int ch = ::getc(stream);
    if (ch == EOF) {
      // A partial final line without a trailing newline is still a line.
      if (len == 0)
        return -1;
      break;
    }

    // Keep one byte spare so the terminator always fits.
    if (len + 1 >= *n) {
      size_t cap = *n * 2;
      char *buf = static_cast<char *>(::realloc(*lineptr, cap));
      if (!buf) {
        errno = ENOMEM;
        return -1;
      }
      *lineptr = buf;
      *n = cap;
    }

    (*lineptr)[len++] = static_cast<char>(ch);
    if (ch == '\n')
      break;
  }

  (*lineptr)[len] = '\0';
  return static_cast<ptrdiff_t>(len);
}

//===----------------------------------------------------------------------===//
// Process pipes
//===----------------------------------------------------------------------===//
//
// The CRT has these under underscore-prefixed names and `oldnames.lib` does
// not alias them, so they are forwarded rather than reimplemented.

COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT FILE *popen(const char *command,
                                                           const char *mode) {
  return ::_popen(command, mode);
}

COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int pclose(FILE *stream) {
  return ::_pclose(stream);
}

/// POSIX pipe(2). The CRT's `_pipe` is not a rename of this one -- it takes
/// two extra arguments, so oldnames.lib cannot alias it and it has to be
/// wrapped. _O_BINARY is required: the default text mode would translate CRLF
/// in the pipe and corrupt any binary payload passing through it.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int pipe(int fds[2]) {
  return ::_pipe(fds, 4096, _O_BINARY);
}

//===----------------------------------------------------------------------===//
// Process creation
//===----------------------------------------------------------------------===//
//
// Windows identifies a running process by HANDLE, but POSIX identifies it by
// pid, and a pid is reused once the process is gone. Handing callers a raw pid
// and re-opening it later would therefore race against reuse -- so the handle
// CreateProcessW returns is kept here, keyed by the pid we report. waitpid and
// kill look the handle up rather than reopening, and the entry is dropped once
// the process has been reaped.

namespace {

struct SpawnedChild {
  DWORD pid;
  HANDLE handle;
};

std::mutex &childTableMutex() {
  static std::mutex m;
  return m;
}

std::vector<SpawnedChild> &childTable() {
  static std::vector<SpawnedChild> t;
  return t;
}

void rememberChild(DWORD pid, HANDLE handle) {
  std::lock_guard<std::mutex> lock(childTableMutex());
  childTable().push_back({pid, handle});
}

/// Look up a child's handle. Returns nullptr if we did not spawn it.
HANDLE handleForChild(DWORD pid) {
  std::lock_guard<std::mutex> lock(childTableMutex());
  for (const auto &c : childTable())
    if (c.pid == pid)
      return c.handle;
  return nullptr;
}

void forgetChild(DWORD pid) {
  std::lock_guard<std::mutex> lock(childTableMutex());
  auto &t = childTable();
  for (size_t i = 0; i < t.size(); ++i) {
    if (t[i].pid == pid) {
      ::CloseHandle(t[i].handle);
      t.erase(t.begin() + static_cast<ptrdiff_t>(i));
      return;
    }
  }
}

/// Append one argument to a Windows command line, quoted so that the CRT
/// parser in the child reconstructs exactly this string as one argv entry.
///
/// This is the inverse of the documented MSVCRT parsing rule, and the reason
/// it cannot be a simple "wrap in quotes": a backslash is only an escape
/// character when it precedes a quote, so a run of backslashes must be
/// doubled in that position and left alone everywhere else. Getting this wrong
/// silently corrupts paths ending in a separator.
void appendQuotedArg(std::wstring &out, const std::wstring &arg) {
  if (!arg.empty() && arg.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    out += arg;
    return;
  }

  out += L'"';
  for (auto it = arg.begin();; ++it) {
    size_t backslashes = 0;
    while (it != arg.end() && *it == L'\\') {
      ++it;
      ++backslashes;
    }

    if (it == arg.end()) {
      // Trailing backslashes precede the closing quote, so they escape.
      out.append(backslashes * 2, L'\\');
      break;
    }
    if (*it == L'"') {
      out.append(backslashes * 2 + 1, L'\\');
      out += *it;
    } else {
      out.append(backslashes, L'\\');
      out += *it;
    }
  }
  out += L'"';
}

/// Resolve an executable the way execvp/posix_spawnp do: consult PATH unless
/// the name already contains a separator. Windows also needs the extension
/// supplied, which SearchPathW appends when the name carries none.
bool resolveExecutable(const std::wstring &file, std::wstring &out) {
  wchar_t *filePart = nullptr;
  DWORD n = ::SearchPathW(/*lpPath=*/nullptr, file.c_str(),
                          /*lpExtension=*/L".exe", 0, nullptr, &filePart);
  if (n == 0)
    return false;
  out.resize(n);
  DWORD written = ::SearchPathW(nullptr, file.c_str(), L".exe", n, &out[0],
                                &filePart);
  if (written == 0 || written >= n)
    return false;
  out.resize(written);
  return true;
}

} // namespace

/// POSIX posix_spawnp(3).
///
/// The standard library always passes null for `file_actions` and `attrp` --
/// there is no descriptor redirection or attribute handling to emulate -- so
/// those are rejected rather than silently ignored if they ever become
/// non-null, which would otherwise drop redirections on the floor.
///
/// Returns an errno value directly (0 on success), as POSIX specifies; it does
/// not use -1/errno.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int
posix_spawnp(int *pid, const char *file, const void *file_actions,
             const void *attrp, char *const argv[], char *const envp[]) {
  if (!pid || !file || !argv)
    return EINVAL;
  if (file_actions || attrp)
    return ENOSYS;

  std::wstring wFile;
  if (!widen(file, wFile))
    return EINVAL;

  std::wstring appName;
  if (!resolveExecutable(wFile, appName)) {
    // No PATH match. Fall back to the name as given so an explicit or
    // extensioned path still works, and let CreateProcessW report the error.
    appName = wFile;
  }

  // POSIX passes argv separately from the executable, and argv[0] is free to
  // differ from it. Windows has only a command line, so argv is rendered
  // whole and the resolved path is passed as the application name -- which is
  // what keeps argv[0] intact instead of forcing it to be the program path.
  std::wstring cmdline;
  for (size_t i = 0; argv[i] != nullptr; ++i) {
    std::wstring wArg;
    if (!widen(argv[i], wArg))
      return EINVAL;
    if (i)
      cmdline += L' ';
    appendQuotedArg(cmdline, wArg);
  }
  if (cmdline.empty())
    appendQuotedArg(cmdline, appName);

  // A null envp means inherit, matching posix_spawn with no attribute set.
  std::wstring envBlock;
  bool haveEnv = envp != nullptr;
  if (haveEnv) {
    for (size_t i = 0; envp[i] != nullptr; ++i) {
      std::wstring entry;
      if (!widen(envp[i], entry))
        return EINVAL;
      envBlock += entry;
      envBlock.push_back(L'\0');
    }
    // The block itself is terminated by a second NUL.
    envBlock.push_back(L'\0');
  }

  STARTUPINFOW si;
  ::ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);

  PROCESS_INFORMATION pi;
  ::ZeroMemory(&pi, sizeof(pi));

  // The command line buffer must be writable: CreateProcessW may modify it.
  std::vector<wchar_t> mutableCmdline(cmdline.begin(), cmdline.end());
  mutableCmdline.push_back(L'\0');

  BOOL ok = ::CreateProcessW(
      appName.c_str(), mutableCmdline.data(),
      /*lpProcessAttributes=*/nullptr, /*lpThreadAttributes=*/nullptr,
      /*bInheritHandles=*/TRUE, CREATE_UNICODE_ENVIRONMENT,
      haveEnv ? static_cast<LPVOID>(&envBlock[0]) : nullptr,
      /*lpCurrentDirectory=*/nullptr, &si, &pi);

  if (!ok)
    return errnoFromWin32(::GetLastError());

  // The thread handle is of no interest; the process handle is retained.
  ::CloseHandle(pi.hThread);
  rememberChild(pi.dwProcessId, pi.hProcess);
  *pid = static_cast<int>(pi.dwProcessId);
  return 0;
}

/// POSIX waitpid(2), for children spawned through posix_spawnp above.
///
/// `status` is encoded the way the standard library decodes it -- musl's
/// layout, exit code in bits 8..15. One difference is deliberate: a process
/// killed through kill() below is still reported as *exited* with that code
/// rather than as signalled, because Windows keeps no record of a "signal"
/// and Process.wait() raises outright on a status that has not exited.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int waitpid(int pid, int *status,
                                                           int options) {
  HANDLE h = handleForChild(static_cast<DWORD>(pid));
  if (!h) {
    errno = ECHILD;
    return -1;
  }

  // WNOHANG is 1 on Linux; poll for it rather than blocking.
  DWORD timeout = (options & 1) ? 0 : INFINITE;
  DWORD waited = ::WaitForSingleObject(h, timeout);
  if (waited == WAIT_TIMEOUT)
    return 0; // Still running, as WNOHANG specifies.
  if (waited != WAIT_OBJECT_0) {
    setErrnoFromWin32();
    return -1;
  }

  DWORD code = 0;
  if (!::GetExitCodeProcess(h, &code)) {
    setErrnoFromWin32();
    return -1;
  }

  if (status)
    *status = static_cast<int>((code & 0xff) << 8);
  forgetChild(static_cast<DWORD>(pid));
  return pid;
}

/// POSIX kill(2), restricted to what Windows can express.
///
/// Signal 0 is the existence probe and is answered without touching the
/// process. Any other signal terminates it: Windows has no signal delivery, so
/// there is no distinction between TERM and KILL here, and no opportunity for
/// the child to handle it. The exit code is set to the signal number so the
/// value survives into waitpid.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int kill(int pid, int sig) {
  HANDLE h = handleForChild(static_cast<DWORD>(pid));
  if (!h) {
    errno = ESRCH;
    return -1;
  }

  if (sig == 0)
    return 0;

  if (!::TerminateProcess(h, static_cast<UINT>(sig))) {
    setErrnoFromWin32();
    return -1;
  }
  return 0;
}

//===----------------------------------------------------------------------===//
// Module cache
//===----------------------------------------------------------------------===//
//
// Win32 bindings resolve entry points at run time, and loading a DLL per call
// site -- worse, per call -- is both slow and semantically wrong, since an
// OwnedDLHandle frees the library on drop while Windows may still hold
// callbacks into it. The cache loads each module once and never frees it,
// which for user32/kernel32/d3d11 is also what any Windows process does
// anyway. Mojo has no mutable-global idiom in this snapshot, so the statics
// live here, where they are one lock and one map.

namespace {

std::mutex &moduleCacheMutex() {
  static std::mutex m;
  return m;
}

llvm::StringMap<HMODULE> &moduleCache() {
  static llvm::StringMap<HMODULE> cache;
  return cache;
}

} // namespace

/// Return the named module, loading it on first use and caching it for the
/// life of the process. Returns null if the module cannot be loaded; the
/// failure is also cached, so a misspelled name does not retry the loader on
/// every call.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT void *
KGEN_CompilerRT_Win32Module(const char *name) {
  if (!name)
    return nullptr;

  std::lock_guard<std::mutex> lock(moduleCacheMutex());
  auto it = moduleCache().find(name);
  if (it != moduleCache().end())
    return it->second;

  std::wstring wide;
  HMODULE module = nullptr;
  if (widen(name, wide)) {
    // Already-loaded modules resolve without touching the loader path.
    module = ::GetModuleHandleW(wide.c_str());
    if (!module)
      module = ::LoadLibraryW(wide.c_str());
  }
  moduleCache()[name] = module;
  return module;
}

/// GetProcAddress against a cached module handle.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT void *
KGEN_CompilerRT_Win32Symbol(void *module, const char *name) {
  if (!module || !name)
    return nullptr;
  return reinterpret_cast<void *>(
      ::GetProcAddress(static_cast<HMODULE>(module), name));
}

#endif // _WIN32
