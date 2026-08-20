/*===----------------------------------------------------------------------===*\
|*
|* `sleep` for the Windows test environment. See echo.c for why these exist.
|*
|* Behaves as sleep(1) does: suspend for the sum of the operands, then exit 0.
|* Each operand is a non-negative decimal with an optional unit suffix -- s
|* seconds (the default), m minutes, h hours, d days -- and an invalid one is
|* an error rather than a zero-length sleep, so a mistyped test does not
|* silently pass by returning immediately.
|*
\*===----------------------------------------------------------------------===*/

#include <stdio.h>
#include <stdlib.h>

#include <windows.h>

/* Parse one operand. Returns 0 and reports the problem if it is not a
 * well-formed non-negative interval. */
static int parse_interval(const char *arg, double *out) {
  char *end = NULL;
  double value = strtod(arg, &end);

  if (end == arg || value < 0.0) {
    fprintf(stderr, "sleep: invalid time interval '%s'\n", arg);
    return 0;
  }

  double scale;
  switch (*end) {
  case '\0':
  case 's':
    scale = 1.0;
    break;
  case 'm':
    scale = 60.0;
    break;
  case 'h':
    scale = 3600.0;
    break;
  case 'd':
    scale = 86400.0;
    break;
  default:
    fprintf(stderr, "sleep: invalid time interval '%s'\n", arg);
    return 0;
  }

  /* A suffix must be the last character; "5sx" is not an interval. */
  if (*end != '\0' && *(end + 1) != '\0') {
    fprintf(stderr, "sleep: invalid time interval '%s'\n", arg);
    return 0;
  }

  *out = value * scale;
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "sleep: missing operand\n");
    return 1;
  }

  /* sleep(1) sums its operands rather than taking only the first. */
  double seconds = 0.0;
  for (int i = 1; i < argc; i++) {
    double interval;
    if (!parse_interval(argv[i], &interval))
      return 1;
    seconds += interval;
  }

  /* Sleep takes DWORD milliseconds, which tops out around 49 days. Rather
   * than clamp -- which would turn a long sleep into a short one and let a
   * test pass without ever having waited -- issue it in chunks. */
  const double chunk_ms = 1000.0 * 1000.0; /* well inside DWORD range */
  double remaining_ms = seconds * 1000.0;

  while (remaining_ms > 0.0) {
    double slice = (remaining_ms > chunk_ms) ? chunk_ms : remaining_ms;
    Sleep((DWORD)slice);
    remaining_ms -= slice;
  }

  return 0;
}
