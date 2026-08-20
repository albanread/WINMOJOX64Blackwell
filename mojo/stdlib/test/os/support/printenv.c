/*===----------------------------------------------------------------------===*\
|*
|* `printenv` for the Windows test environment. See echo.c for why these exist.
|*
|* test_process uses the one-argument form as an inheritance probe: exit 0 if
|* the variable reached the child, 1 if it did not. That makes this program the
|* actual test of whether posix_spawnp's environment handling works, since the
|* shim passes a null environment block to CreateProcessW and relies on Windows
|* to inherit the parent's.
|*
\*===----------------------------------------------------------------------===*/

#include <stdio.h>
#include <stdlib.h>

/* The CRT populates this from the environment block the parent passed at
 * process start, so reading it here reports what was actually inherited. */
extern char **_environ;

int main(int argc, char **argv) {
  if (argc < 2) {
    /* No operand: list the whole environment, as printenv(1) does. */
    for (char **e = _environ; e && *e; ++e)
      puts(*e);
    fflush(stdout);
    return 0;
  }

  const char *value = getenv(argv[1]);
  if (!value) {
    /* printenv(1) exits non-zero when no variable was found. This is the
     * signal test_process_inherits_env asserts on. */
    return 1;
  }

  puts(value);
  fflush(stdout);
  return 0;
}
