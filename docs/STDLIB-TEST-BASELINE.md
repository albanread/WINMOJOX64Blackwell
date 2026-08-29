# stdlib test baseline — Windows x64 port

Recorded 2026-08-29 at commit f77aeb7 (COM suite 32/32).

The stdlib battery cannot be a pass/fail gate on this port: it has a large
pre-existing failure set that has nothing to do with our work. It becomes a
gate by DIFFERENCE — run it, compare against this list, and investigate only
what is new. Regenerate with:

    ./bazelw.cmd test //mojo/stdlib/test/... --keep_going

Run of 2026-08-29: 369 tests, 301 executed, 183 pass, 4 fail to build,
132 fail locally, 50 skipped.

The causes, all environmental or platform gaps:

  - missing LLVM test tooling: FileCheck.exe and not.exe are absent from
    the runfiles, so every FileCheck-based test fails before running
  - POSIX assumptions: tests that look for a standard C library, symlinks,
    isatty, realpath and POSIX path semantics
  - LLP64: test_c_types asserts C type widths that differ on Windows
  - lit configuration that does not parse on this platform

None of the failing test sources use the `class` keyword or import
std.sys.com, std.sys._com or std.sys._winkb, so the COM work cannot reach
them. That was checked mechanically, not assumed.

## Failing targets

//mojo/stdlib/test/memory/uninit_check:test_uninit_check_bfloat16_poison.mojo.test
//mojo/stdlib/test/memory/uninit_check:test_uninit_check_float16_poison.mojo.test
//mojo/stdlib/test/memory/uninit_check:test_uninit_check_float32_poison.mojo.test
//mojo/stdlib/test/memory/uninit_check:test_uninit_check_float64_poison.mojo.test
//mojo/stdlib/test/memory/uninit_check:test_uninit_check_gather_poison.mojo.test
//mojo/stdlib/test/memory/uninit_check:test_uninit_check_masked_load_poison.mojo.test
//mojo/stdlib/test/memory/uninit_check:test_uninit_check_simd_vector_poison.mojo.test
//mojo/stdlib/test/os:echo_support/echo.c.tidy
//mojo/stdlib/test/os:path/test_basename.mojo.test
//mojo/stdlib/test/os:path/test_exists.mojo.test
//mojo/stdlib/test/os:path/test_expanduser.mojo.test
//mojo/stdlib/test/os:path/test_isfile.mojo.test
//mojo/stdlib/test/os:path/test_islink.mojo.test
//mojo/stdlib/test/os:path/test_realpath.mojo.test
//mojo/stdlib/test/os:path/test_split.mojo.test
//mojo/stdlib/test/os:printenv_support/printenv.c.tidy
//mojo/stdlib/test/os:sleep_support/sleep.c.tidy
//mojo/stdlib/test/os:test_chdir.mojo.test
//mojo/stdlib/test/os:test_isatty.mojo.test
//mojo/stdlib/test/os:test_listdir.mojo.test
//mojo/stdlib/test/os:test_mkdir_and_rmdir.mojo.test
//mojo/stdlib/test/os:test_no_trap.mojo.test
//mojo/stdlib/test/os:test_process.mojo.test
//mojo/stdlib/test/os:test_stat.mojo.test
//mojo/stdlib/test/os:test_symlink.mojo.test
//mojo/stdlib/test/os:test_trap.mojo.test
//mojo/stdlib/test/os:test_trap_gpu.mojo.test
//mojo/stdlib/test/pathlib:test_pathlib.mojo.test
//mojo/stdlib/test/python/compile_fail:test_numpy_unsupported_dtype.mojo.test
//mojo/stdlib/test/runtime:test_asyncrt.mojo.test
//mojo/stdlib/test/runtime:test_locks.mojo.test
//mojo/stdlib/test/subprocess:test_run.mojo.test
//mojo/stdlib/test/sys:test_c_types.mojo.test
//mojo/stdlib/test/sys:test_c_types_32bit.mojo.test
//mojo/stdlib/test/sys:test_compile_sanitize_address.mojo.test
//mojo/stdlib/test/sys:test_dlhandle.mojo.test
//mojo/stdlib/test/sys:test_exit_1.mojo.test
//mojo/stdlib/test/sys:test_has_feature_unknown_warning.mojo.test
//mojo/stdlib/test/testing:test_assertion.mojo.test
