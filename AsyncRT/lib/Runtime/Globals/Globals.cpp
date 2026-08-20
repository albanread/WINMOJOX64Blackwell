//===----------------------------------------------------------------------===//
// Copyright (c) 2026, Modular Inc. All rights reserved.
//
// Licensed under the Apache License v2.0 with LLVM Exceptions:
// https://llvm.org/LICENSE.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

// NOTE: We use the legacy tcmalloc on macOS only because the modern tcmalloc
// doesn't support it
#if defined(__APPLE__)
#include <gperftools/tcmalloc.h>
#elif defined(_WIN32)
// Neither tcmalloc nor gperftools supports Windows, so the Bazel alias resolves
// to an empty library there and this header does not exist. The allocations
// below fall back to the CRT's aligned allocator. Note that memory from
// _aligned_malloc must be released with _aligned_free and never with free, so
// tc_delete has to match tc_new.
#include <malloc.h>
#else
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wprivate-header"
#include <tcmalloc/tcmalloc.h>
#pragma GCC diagnostic pop
#endif

#include "AsyncRT/Runtime/CompactCPUDevicePtr.h"
#include "AsyncRT/Runtime/Globals/Globals.h"
#include "Support/BinaryID.h"

#include <atomic>
#include <cstdio>

using namespace M::AsyncRT;

[[maybe_unused]] MODULAR_CXX_EXPORT std::atomic<std::ptrdiff_t>
    M::AsyncRT::Globals::totalAllocatedAsyncValues{0};

MODULAR_CXX_EXPORT CompactCPUDevicePtr &
M::AsyncRT::Globals::getCurrentCPUDeviceInTLS() {
  static thread_local CompactCPUDevicePtr currentCPUDeviceInTLS;
  return currentCPUDeviceInTLS;
}

MODULAR_CXX_EXPORT Detail::CPUDeviceTable &
M::AsyncRT::Globals::getCPUDeviceTableSingleton(
    const std::function<Detail::CPUDeviceTable *()> &ctor) {
  static Detail::CPUDeviceTable *table = ctor();
  return *table;
}

MODULAR_CXX_EXPORT void *TCMallocGlobals::tc_new(size_t alignment,
                                                 size_t size) {
#if defined(__APPLE__)
  return ::tc_memalign(alignment, size);
#elif defined(_WIN32)
  return _aligned_malloc(size, alignment);
#else
  return TCMallocInternalMemalign(alignment, size);
#endif
}
MODULAR_CXX_EXPORT void *TCMallocGlobals::tc_new(size_t alignment, size_t size,
                                                 size_t numaPartition) {
#if defined(__APPLE__)
  // gperftools has no NUMA partition support; fall back to unpartitioned alloc.
  return ::tc_memalign(alignment, size);
#elif defined(_WIN32)
  // No NUMA-partitioned allocator here either.
  (void)numaPartition;
  return _aligned_malloc(size, alignment);
#else
  return TCMallocInternalMemalignNumaPartition(alignment, size, numaPartition);
#endif
}
MODULAR_CXX_EXPORT void TCMallocGlobals::tc_delete(void *ptr) {
#if defined(__APPLE__)
  return ::tc_free(ptr);
#elif defined(_WIN32)
  return _aligned_free(ptr);
#else
  return TCMallocInternalFree(ptr);
#endif
}

MODULAR_CXX_EXPORT std::string M::AsyncRT::getRuntimeGlobalsBinaryID() {
  // M::getBinaryID() returns the binary ID of the shared library that contains
  // it. For the purposes of MEF cache invalidation, we need to know when
  // there's been a change in these shared libraries.
  return M::getBinaryID();
}

/// Global counter for assigning unique task IDs across all AsyncRT users.
/// Must live in a shared library to ensure a single instance.
static std::atomic<uint64_t> globalUniqueTaskIdCounter{0};

MODULAR_CXX_EXPORT uint64_t M::AsyncRT::getUniqueTaskIdForWorkItem() {
  uint64_t id =
      globalUniqueTaskIdCounter.fetch_add(1, std::memory_order_relaxed);
  return id;
}
