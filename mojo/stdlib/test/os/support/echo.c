/*===----------------------------------------------------------------------===*\
|*
|* `echo` for the Windows test environment.
|*
|* test_process.mojo spawns echo, sleep and printenv. On Unix those are real
|* executables on PATH; on Windows `echo` is a cmd builtin and the other two do
|* not exist at all, so there is nothing for posix_spawnp to find and the test
|* cannot run whatever the shim does.
|*
|* These stand-ins are built into the test's own package so they land beside
|* the test binary. That directory is the first one SearchPathW consults, which
|* is what the shim uses to resolve a bare program name -- so these are found
|* ahead of anything installed on the system, and the test does not depend on
|* what else happens to be on PATH.
|*
|* Only the behaviour test_process relies on is implemented.
|*
\*===----------------------------------------------------------------------===*/

#include <stdio.h>

int main(int argc, char **argv) {
  /* Arguments separated by single spaces, one trailing newline -- the subset
   * of echo(1) the test uses. No -n, no escape interpretation: those vary
   * between implementations and nothing here depends on them. */
  for (int i = 1; i < argc; i++) {
    if (i > 1)
      fputc(' ', stdout);
    fputs(argv[i], stdout);
  }
  fputc('\n', stdout);

  /* The parent interleaves its own prints with this output and FileCheck
   * matches the combined stream in order, so this must not sit in a buffer
   * until exit. */
  fflush(stdout);
  return 0;
}
