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

#ifndef KGEN_COMPILERRT_MEMORY_H
#define KGEN_COMPILERRT_MEMORY_H

#include "Support/SymbolExport.h"

// The guard here used to be #ifndef _MSC_VER around <unistd.h> alone, on the
// assumption that an MSVC-compatible compiler supplies ssize_t. It does not,
// and clang defines _MSC_VER when targeting the MSVC ABI, so both the include
// and the type went missing. SSIZE_T is the Windows spelling of the same type.
#ifdef _WIN32
#include <BaseTsd.h>
using ssize_t = SSIZE_T;
#else
#include <unistd.h>
#endif

// Set allocators to system memalign/free to support asan
// this function is NOT thread safe and needs to be called
// before any allocations
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT void
KGEN_CompilerRT_SetAsanAllocators();

/// Returns an alignment allocated memory. If the alignment value is not
/// positive, then the default alignment is used.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT void *
KGEN_CompilerRT_AlignedAlloc(ssize_t alignment, ssize_t size);

/// Frees memory allocated via KGEN_CompilerRT_AlignedAlloc.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT void
KGEN_CompilerRT_AlignedFree(void *ptr);

#endif // KGEN_COMPILERRT_MEMORY_H
