//===----------------------------------------------------------------------===//
// crashcatch — a minimal Win32 debugger that turns a silent crash into a
// stack trace and a minidump.
//
// Why this exists: heap corruption (0xC0000374) and fastfail (0xC0000409)
// are raised through RtlReportCriticalFailure/__fastfail, which bypass SEH
// and vectored handlers by design. In-process crash reporting never sees
// them; only a debugger does. The Windows SDK's cdb is not installed on
// every machine, but the Debug API is always there, so this program is the
// dependency-free way to answer "where did it die".
//
//   crashcatch.exe [-o dump.dmp] -- program.exe args...
//
// The child runs under DEBUG_ONLY_THIS_PROCESS. C++ exceptions (0xE06D7363)
// and first-chance access violations pass through untouched so the child's
// own SEH keeps working; the fatal codes are captured at first chance
// because the process is torn down before they would ever get a second one.
// On capture: one ARM64 stack walk per line, module!symbol+0xoff when
// dbghelp can see a PDB, module+0xrva otherwise (feed those to
// llvm-symbolizer), then a MiniDumpWithFullMemory dump for post-mortem use.
//===----------------------------------------------------------------------===//

#include <windows.h>

#include <dbghelp.h>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <map>
#include <string>
#include <vector>

namespace {

struct ModuleInfo {
  std::wstring path;
  uint64_t base = 0;
};

// Keyed by base address; LOAD_DLL events populate it so frames can be
// attributed even when symbol loading fails.
std::map<uint64_t, ModuleInfo> gModules;

std::wstring pathFromHandle(HANDLE file) {
  wchar_t buf[MAX_PATH * 2] = {};
  if (file &&
      GetFinalPathNameByHandleW(file, buf, MAX_PATH * 2, FILE_NAME_NORMALIZED)) {
    // dbghelp rejects the \?\ long-path prefix when resolving PDBs.
    if (wcsncmp(buf, L"\\\\?\\", 4) == 0)
      return buf + 4;
    return buf;
  }
  return L"<unknown>";
}

const ModuleInfo *moduleForAddress(uint64_t addr) {
  const ModuleInfo *best = nullptr;
  for (const auto &[base, mod] : gModules)
    if (base <= addr && (!best || base > best->base))
      best = &mod;
  // The map is sorted; the last module whose base precedes addr wins. A
  // 512 MB cap avoids attributing wild pointers to the nearest module.
  if (best && addr - best->base > (512ull << 20))
    return nullptr;
  return best;
}

const wchar_t *baseName(const std::wstring &path) {
  size_t pos = path.find_last_of(L"\\/");
  return pos == std::wstring::npos ? path.c_str() : path.c_str() + pos + 1;
}

void printFrame(HANDLE process, int depth, uint64_t pc) {
  // Symbol if dbghelp found a PDB for this module.
  char symBuf[sizeof(SYMBOL_INFOW) + 512 * sizeof(wchar_t)] = {};
  auto *sym = reinterpret_cast<SYMBOL_INFOW *>(symBuf);
  sym->SizeOfStruct = sizeof(SYMBOL_INFOW);
  sym->MaxNameLen = 511;
  DWORD64 disp = 0;
  if (SymFromAddrW(process, pc, &disp, sym)) {
    IMAGEHLP_LINEW64 line = {sizeof(IMAGEHLP_LINEW64)};
    DWORD lineDisp = 0;
    if (SymGetLineFromAddrW64(process, pc, &lineDisp, &line))
      fwprintf(stderr, L"  #%02d 0x%016llx %ls+0x%llx [%ls:%lu]\n", depth,
               (unsigned long long)pc, sym->Name, (unsigned long long)disp,
               line.FileName, line.LineNumber);
    else
      fwprintf(stderr, L"  #%02d 0x%016llx %ls+0x%llx\n", depth,
               (unsigned long long)pc, sym->Name, (unsigned long long)disp);
    return;
  }

  if (const ModuleInfo *mod = moduleForAddress(pc)) {
    fwprintf(stderr, L"  #%02d 0x%016llx %ls+0x%llx\n", depth,
             (unsigned long long)pc, baseName(mod->path),
             (unsigned long long)(pc - mod->base));
  } else {
    fwprintf(stderr, L"  #%02d 0x%016llx <no module>\n", depth,
             (unsigned long long)pc);
  }
}

void printStack(HANDLE process, HANDLE thread) {
  CONTEXT ctx = {};
  ctx.ContextFlags = CONTEXT_FULL;
  if (!GetThreadContext(thread, &ctx)) {
    fwprintf(stderr, L"crashcatch: GetThreadContext failed (%lu)\n",
             GetLastError());
    return;
  }

  // Manual AAPCS64 frame-record walk. Everything in this tree is compiled
  // with -fno-omit-frame-pointer, so x29 chains through [fp] = caller's fp,
  // [fp+8] = return address. This is more robust here than StackWalk64,
  // which needs symbols to unwind through ntdll's leaf frames and produced
  // garbage after one frame without them.
  //
  // Return addresses in the records carry ARM64 pointer-authentication bits
  // in the top byte(s); user-space code addresses are canonical 48-bit, so
  // mask before use or every PAC-signed frame reads as garbage.
  // Windows user-space VAs top out below 2^47, so the PAC field reaches
  // down through bit 47.
  const uint64_t kVAMask = 0x00007FFFFFFFFFFFull;
  printFrame(process, 0, ctx.Pc & kVAMask);
  int depth = 1;
  if (ctx.Lr && (ctx.Lr & kVAMask) != (ctx.Pc & kVAMask))
    printFrame(process, depth++, ctx.Lr & kVAMask);

  uint64_t fp = ctx.Fp & kVAMask;
  for (; depth < 64 && fp; ++depth) {
    // Reject unaligned or wildly implausible frame pointers.
    if (fp & 0x7)
      break;
    uint64_t record[2] = {};
    SIZE_T bytes = 0;
    if (!ReadProcessMemory(process, (LPCVOID)fp, record, sizeof(record),
                           &bytes) ||
        bytes != sizeof(record))
      break;
    uint64_t ret = record[1] & kVAMask;
    if (!ret)
      break;
    printFrame(process, depth, ret);
    uint64_t nextFp = record[0] & kVAMask;
    if (nextFp <= fp) // frame pointers must strictly ascend
      break;
    fp = nextFp;
  }
}

void writeDump(HANDLE process, DWORD pid, DWORD tid,
               EXCEPTION_RECORD *record, const wchar_t *dumpPath) {
  HANDLE file = CreateFileW(dumpPath, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    fwprintf(stderr, L"crashcatch: cannot create %ls (%lu)\n", dumpPath,
             GetLastError());
    return;
  }

  // MiniDumpWriteDump wants the exception via a pointers struct whose
  // ExceptionPointers live in the *target* process for the ClientPointers
  // case; passing ClientPointers=FALSE with our copies works for a debugger.
  CONTEXT ctx = {};
  ctx.ContextFlags = CONTEXT_FULL;
  HANDLE thread = OpenThread(THREAD_ALL_ACCESS, FALSE, tid);
  EXCEPTION_POINTERS pointers = {};
  pointers.ExceptionRecord = record;
  if (thread && GetThreadContext(thread, &ctx))
    pointers.ContextRecord = &ctx;

  MINIDUMP_EXCEPTION_INFORMATION info = {};
  info.ThreadId = tid;
  info.ExceptionPointers = &pointers;
  info.ClientPointers = FALSE;

  BOOL ok = MiniDumpWriteDump(
      process, pid, file,
      static_cast<MINIDUMP_TYPE>(MiniDumpWithFullMemory |
                                 MiniDumpWithHandleData |
                                 MiniDumpWithThreadInfo),
      pointers.ContextRecord ? &info : nullptr, nullptr, nullptr);
  if (ok)
    fwprintf(stderr, L"crashcatch: minidump written to %ls\n", dumpPath);
  else
    fwprintf(stderr, L"crashcatch: MiniDumpWriteDump failed (0x%08lx)\n",
             GetLastError());
  if (thread)
    CloseHandle(thread);
  CloseHandle(file);
}

bool isFatalFirstChance(DWORD code) {
  return code == 0xC0000374 /* STATUS_HEAP_CORRUPTION */ ||
         code == 0xC0000409 /* STATUS_STACK_BUFFER_OVERRUN / fastfail */;
}

} // namespace

int wmain(int argc, wchar_t **argv) {
  const wchar_t *dumpPath = L"crashcatch.dmp";
  int cmdStart = -1;
  for (int i = 1; i < argc; ++i) {
    if (wcscmp(argv[i], L"-o") == 0 && i + 1 < argc) {
      dumpPath = argv[++i];
    } else if (wcscmp(argv[i], L"--") == 0) {
      cmdStart = i + 1;
      break;
    }
  }
  if (cmdStart < 0 || cmdStart >= argc) {
    fwprintf(stderr, L"usage: crashcatch [-o dump.dmp] -- prog.exe args...\n");
    return 2;
  }

  // Rebuild a quoted command line for CreateProcess.
  std::wstring cmdline;
  for (int i = cmdStart; i < argc; ++i) {
    if (i > cmdStart)
      cmdline += L' ';
    bool needQuotes = wcschr(argv[i], L' ') != nullptr;
    if (needQuotes)
      cmdline += L'"';
    cmdline += argv[i];
    if (needQuotes)
      cmdline += L'"';
  }

  STARTUPINFOW si = {sizeof(si)};
  PROCESS_INFORMATION pi = {};
  std::vector<wchar_t> mutableCmd(cmdline.begin(), cmdline.end());
  mutableCmd.push_back(L'\0');
  if (!CreateProcessW(argv[cmdStart], mutableCmd.data(), nullptr, nullptr,
                      FALSE, DEBUG_ONLY_THIS_PROCESS, nullptr, nullptr, &si,
                      &pi)) {
    fwprintf(stderr, L"crashcatch: CreateProcess failed (%lu) for %ls\n",
             GetLastError(), argv[cmdStart]);
    return 2;
  }
  DebugSetProcessKillOnExit(TRUE);

  SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES);
  bool symInitialized = false;
  bool sawInitialBreakpoint = false;
  DWORD exitCode = 0;
  bool crashed = false;

  for (;;) {
    DEBUG_EVENT ev = {};
    if (!WaitForDebugEvent(&ev, INFINITE))
      break;
    DWORD continueStatus = DBG_CONTINUE;

    switch (ev.dwDebugEventCode) {
    case CREATE_PROCESS_DEBUG_EVENT: {
      // The RSDS record in lld-link output names the PDB relative to the
      // link's working directory, which is not ours; searching the image's
      // own directory finds the PDB laid down beside it.
      std::wstring exeDir = pathFromHandle(ev.u.CreateProcessInfo.hFile);
      size_t slash = exeDir.find_last_of(L"\\/");
      if (slash != std::wstring::npos)
        exeDir.resize(slash);
      symInitialized =
          SymInitializeW(pi.hProcess, exeDir.c_str(), FALSE);
      uint64_t base = (uint64_t)ev.u.CreateProcessInfo.lpBaseOfImage;
      std::wstring path = pathFromHandle(ev.u.CreateProcessInfo.hFile);
      gModules[base] = {path, base};
      if (symInitialized)
        SymLoadModuleExW(pi.hProcess, nullptr, path.c_str(), nullptr, base, 0,
                         nullptr, 0);
      if (ev.u.CreateProcessInfo.hFile)
        CloseHandle(ev.u.CreateProcessInfo.hFile);
      break;
    }
    case LOAD_DLL_DEBUG_EVENT: {
      uint64_t base = (uint64_t)ev.u.LoadDll.lpBaseOfDll;
      std::wstring path = pathFromHandle(ev.u.LoadDll.hFile);
      gModules[base] = {path, base};
      if (symInitialized)
        SymLoadModuleExW(pi.hProcess, nullptr, path.c_str(), nullptr, base, 0,
                         nullptr, 0);
      if (ev.u.LoadDll.hFile)
        CloseHandle(ev.u.LoadDll.hFile);
      break;
    }
    case UNLOAD_DLL_DEBUG_EVENT:
      gModules.erase((uint64_t)ev.u.UnloadDll.lpBaseOfDll);
      break;
    case EXCEPTION_DEBUG_EVENT: {
      const EXCEPTION_RECORD &rec = ev.u.Exception.ExceptionRecord;
      DWORD code = rec.ExceptionCode;

      if (code == EXCEPTION_BREAKPOINT && !sawInitialBreakpoint) {
        // The loader breakpoint that every debuggee raises once.
        sawInitialBreakpoint = true;
        break;
      }

      bool secondChance = ev.u.Exception.dwFirstChance == 0;
      if (secondChance || isFatalFirstChance(code)) {
        crashed = true;
        fwprintf(stderr,
                 L"\ncrashcatch: exception 0x%08lx (%ls chance) at 0x%016llx "
                 L"in thread %lu\n",
                 code, secondChance ? L"second" : L"first",
                 (unsigned long long)(uintptr_t)rec.ExceptionAddress,
                 ev.dwThreadId);
        for (const auto &[base, mod] : gModules) {
          uint64_t addr = (uint64_t)(uintptr_t)rec.ExceptionAddress;
          if (base <= addr && addr - base < (512ull << 20))
            ; // moduleForAddress reports it below; the loop keeps map warm.
        }
        HANDLE thread =
            OpenThread(THREAD_ALL_ACCESS, FALSE, ev.dwThreadId);
        if (thread) {
          printStack(pi.hProcess, thread);
          CloseHandle(thread);
        }
        writeDump(pi.hProcess, pi.dwProcessId, ev.dwThreadId,
                  const_cast<EXCEPTION_RECORD *>(&rec), dumpPath);
        // Let the process die of its exception rather than masking it.
        continueStatus = DBG_EXCEPTION_NOT_HANDLED;
      } else {
        // First-chance, non-fatal: the child's own handlers (C++ EH, SEH
        // probes) must see it.
        continueStatus = DBG_EXCEPTION_NOT_HANDLED;
      }
      break;
    }
    case EXIT_PROCESS_DEBUG_EVENT:
      exitCode = ev.u.ExitProcess.dwExitCode;
      ContinueDebugEvent(ev.dwProcessId, ev.dwThreadId, DBG_CONTINUE);
      goto done;
    default:
      break;
    }
    ContinueDebugEvent(ev.dwProcessId, ev.dwThreadId, continueStatus);
  }
done:

  fwprintf(stderr, L"crashcatch: process exited with 0x%08lx%ls\n", exitCode,
           crashed ? L" (crash captured)" : L"");
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return exitCode ? 1 : 0;
}
