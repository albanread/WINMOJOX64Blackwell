// Smallest target that still proves the native Windows toolchain end to end:
// the clang driver, the MSVC STL headers found via -imsvc, and a CRT link.

#include <cstdio>
#include <string>
#include <vector>

int main() {
#if defined(_M_X64)
  constexpr const char *architecture = "x86_64";
#elif defined(_M_ARM64)
  constexpr const char *architecture = "arm64";
#else
#error "unsupported Windows architecture"
#endif
  std::vector<std::string> parts{"windows", architecture, "clang"};
  std::string joined;
  for (const auto &part : parts) {
    if (!joined.empty()) {
      joined += "-";
    }
    joined += part;
  }

  std::printf("winmojo smoke ok: %s\n", joined.c_str());
  std::printf("pointer width: %zu bits\n", sizeof(void *) * 8);
  return 0;
}
