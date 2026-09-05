//===----------------------------------------------------------------------===//
// Copyright (c) 2026, WINMOJO contributors.
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
//
// nvptxrt is the Windows NVIDIA implementation of the MAX AsyncRT device ABI.
// It consumes the PTX emitted by KGEN's NVPTX backend and delegates final
// machine-code generation to the installed NVIDIA driver.  The CUDA SDK is not
// a build or runtime dependency: every entry point is loaded from nvcuda.dll.
//
//===----------------------------------------------------------------------===//

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <exception>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using CUresult = int;
using CUdevice = int;
using CUdeviceptr = unsigned long long;
using CUcontext = void *;
using CUstream = void *;
using CUevent = void *;
using CUmodule = void *;
using CUfunction = void *;
using CUgraph = void *;
using CUgraphExec = void *;
using CUgraphNode = void *;
using CUarray = void *;
using CUhostFn = void (*)(void *);

struct CUlaunchAttribute {
  int id;
  char padding[4];
  unsigned char value[64];
};

struct CUlaunchConfig {
  unsigned int gridDimX;
  unsigned int gridDimY;
  unsigned int gridDimZ;
  unsigned int blockDimX;
  unsigned int blockDimY;
  unsigned int blockDimZ;
  unsigned int sharedMemBytes;
  CUstream stream;
  CUlaunchAttribute *attributes;
  unsigned int attributeCount;
};

struct CUDAKernelNodeParams {
  CUfunction function;
  unsigned int gridX;
  unsigned int gridY;
  unsigned int gridZ;
  unsigned int blockX;
  unsigned int blockY;
  unsigned int blockZ;
  unsigned int sharedMemoryBytes;
  void **kernelParams;
  void **extra;
  void *kernel;
  CUcontext context;
};

struct CUDAMemcpy3D {
  size_t sourceXBytes;
  size_t sourceY;
  size_t sourceZ;
  size_t sourceLevel;
  int sourceMemoryType;
  const void *sourceHost;
  CUdeviceptr sourceDevice;
  CUarray sourceArray;
  void *sourceReserved;
  size_t sourcePitch;
  size_t sourceHeight;
  size_t destinationXBytes;
  size_t destinationY;
  size_t destinationZ;
  size_t destinationLevel;
  int destinationMemoryType;
  void *destinationHost;
  CUdeviceptr destinationDevice;
  CUarray destinationArray;
  void *destinationReserved;
  size_t destinationPitch;
  size_t destinationHeight;
  size_t widthBytes;
  size_t height;
  size_t depth;
};

struct CUDAMemsetNodeParams {
  CUdeviceptr destination;
  size_t pitch;
  unsigned int value;
  unsigned int elementSize;
  size_t width;
  size_t height;
};

struct CUDAHostNodeParams {
  CUhostFn function;
  void *userData;
};

struct CUDAStreamWaitValue64Params {
  int operation;
  unsigned int reserved0;
  CUdeviceptr address;
  uint64_t value;
  unsigned int flags;
  unsigned int reserved1;
  CUdeviceptr alias;
  uint64_t reserved2;
};

struct CUDABatchMemOpNodeParams {
  CUcontext context;
  unsigned int count;
  unsigned int reserved0;
  CUDAStreamWaitValue64Params *parameters;
  unsigned int flags;
  unsigned int reserved1;
};

struct alignas(64) CUtensorMap {
  uint64_t opaque[16];
};

static_assert(sizeof(CUlaunchAttribute) == 72,
              "CUDA launch attribute ABI mismatch");
static_assert(sizeof(CUlaunchConfig) == 56, "CUDA launch config ABI mismatch");
static_assert(sizeof(CUDAKernelNodeParams) == 72,
              "CUDA kernel node ABI mismatch");
static_assert(sizeof(CUDAMemcpy3D) == 200, "CUDA memcpy node ABI mismatch");
static_assert(sizeof(CUDAMemsetNodeParams) == 40,
              "CUDA memset node ABI mismatch");
static_assert(sizeof(CUDAHostNodeParams) == 16,
              "CUDA host node ABI mismatch");
static_assert(sizeof(CUDAStreamWaitValue64Params) == 48,
              "CUDA stream wait ABI mismatch");
static_assert(sizeof(CUDABatchMemOpNodeParams) == 32,
              "CUDA batch memory operation node ABI mismatch");

constexpr CUresult CUDA_SUCCESS = 0;
constexpr unsigned int CU_STREAM_NON_BLOCKING = 1;
constexpr unsigned int CU_EVENT_DISABLE_TIMING = 2;
constexpr int CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR = 75;
constexpr int CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR = 76;
constexpr int CU_LIMIT_STACK_SIZE = 0;
constexpr size_t NVPTX_MIN_THREAD_STACK_SIZE = 4096;
constexpr int CU_MEMORYTYPE_HOST = 1;
constexpr int CU_MEMORYTYPE_DEVICE = 2;

#define CUDA_API __stdcall
#define CUDA_FUNCTION(result, name, ...)                                       \
  using name##Fn = result(CUDA_API *)(__VA_ARGS__);                            \
  static name##Fn name = nullptr

CUDA_FUNCTION(CUresult, cuInit, unsigned int);
CUDA_FUNCTION(CUresult, cuDriverGetVersion, int *);
CUDA_FUNCTION(CUresult, cuDeviceGetCount, int *);
CUDA_FUNCTION(CUresult, cuDeviceGet, CUdevice *, int);
CUDA_FUNCTION(CUresult, cuDeviceGetName, char *, int, CUdevice);
CUDA_FUNCTION(CUresult, cuDeviceGetAttribute, int *, int, CUdevice);
CUDA_FUNCTION(CUresult, cuDeviceCanAccessPeer, int *, CUdevice, CUdevice);
CUDA_FUNCTION(CUresult, cuDeviceTotalMem, size_t *, CUdevice);
CUDA_FUNCTION(CUresult, cuDevicePrimaryCtxRetain, CUcontext *, CUdevice);
CUDA_FUNCTION(CUresult, cuDevicePrimaryCtxRelease, CUdevice);
CUDA_FUNCTION(CUresult, cuCtxSetCurrent, CUcontext);
CUDA_FUNCTION(CUresult, cuCtxGetCurrent, CUcontext *);
CUDA_FUNCTION(CUresult, cuCtxPushCurrent, CUcontext);
CUDA_FUNCTION(CUresult, cuCtxPopCurrent, CUcontext *);
CUDA_FUNCTION(CUresult, cuCtxSynchronize);
CUDA_FUNCTION(CUresult, cuCtxGetLimit, size_t *, int);
CUDA_FUNCTION(CUresult, cuCtxSetLimit, int, size_t);
CUDA_FUNCTION(CUresult, cuCtxGetStreamPriorityRange, int *, int *);
CUDA_FUNCTION(CUresult, cuCtxEnablePeerAccess, CUcontext, unsigned int);
CUDA_FUNCTION(CUresult, cuMemGetInfo, size_t *, size_t *);
CUDA_FUNCTION(CUresult, cuMemAlloc, CUdeviceptr *, size_t);
CUDA_FUNCTION(CUresult, cuMemFree, CUdeviceptr);
CUDA_FUNCTION(CUresult, cuMemHostAlloc, void **, size_t, unsigned int);
CUDA_FUNCTION(CUresult, cuMemHostGetDevicePointer, CUdeviceptr *, void *,
              unsigned int);
CUDA_FUNCTION(CUresult, cuMemFreeHost, void *);
CUDA_FUNCTION(CUresult, cuMemcpyHtoD, CUdeviceptr, const void *, size_t);
CUDA_FUNCTION(CUresult, cuMemcpyDtoH, void *, CUdeviceptr, size_t);
CUDA_FUNCTION(CUresult, cuMemcpyDtoD, CUdeviceptr, CUdeviceptr, size_t);
CUDA_FUNCTION(CUresult, cuMemcpyHtoDAsync, CUdeviceptr, const void *, size_t,
              CUstream);
CUDA_FUNCTION(CUresult, cuMemcpyDtoHAsync, void *, CUdeviceptr, size_t,
              CUstream);
CUDA_FUNCTION(CUresult, cuMemcpyDtoDAsync, CUdeviceptr, CUdeviceptr, size_t,
              CUstream);
CUDA_FUNCTION(CUresult, cuMemcpyPeerAsync, CUdeviceptr, CUcontext, CUdeviceptr,
              CUcontext, size_t, CUstream);
CUDA_FUNCTION(CUresult, cuMemsetD8, CUdeviceptr, unsigned char, size_t);
CUDA_FUNCTION(CUresult, cuMemsetD16, CUdeviceptr, unsigned short, size_t);
CUDA_FUNCTION(CUresult, cuMemsetD32, CUdeviceptr, unsigned int, size_t);
CUDA_FUNCTION(CUresult, cuMemsetD8Async, CUdeviceptr, unsigned char, size_t,
              CUstream);
CUDA_FUNCTION(CUresult, cuMemsetD16Async, CUdeviceptr, unsigned short, size_t,
              CUstream);
CUDA_FUNCTION(CUresult, cuMemsetD32Async, CUdeviceptr, unsigned int, size_t,
              CUstream);
CUDA_FUNCTION(CUresult, cuMemsetD2D32Async, CUdeviceptr, size_t, unsigned int,
              size_t, size_t, CUstream);
CUDA_FUNCTION(CUresult, cuStreamCreate, CUstream *, unsigned int);
CUDA_FUNCTION(CUresult, cuStreamCreateWithPriority, CUstream *, unsigned int,
              int);
CUDA_FUNCTION(CUresult, cuStreamDestroy, CUstream);
CUDA_FUNCTION(CUresult, cuStreamSynchronize, CUstream);
CUDA_FUNCTION(CUresult, cuStreamWaitEvent, CUstream, CUevent, unsigned int);
CUDA_FUNCTION(CUresult, cuStreamWaitValue64, CUstream, CUdeviceptr, uint64_t,
              unsigned int);
CUDA_FUNCTION(CUresult, cuEventCreate, CUevent *, unsigned int);
CUDA_FUNCTION(CUresult, cuEventDestroy, CUevent);
CUDA_FUNCTION(CUresult, cuEventRecord, CUevent, CUstream);
CUDA_FUNCTION(CUresult, cuEventSynchronize, CUevent);
CUDA_FUNCTION(CUresult, cuEventElapsedTime, float *, CUevent, CUevent);
CUDA_FUNCTION(CUresult, cuLaunchHostFunc, CUstream, CUhostFn, void *);
CUDA_FUNCTION(CUresult, cuModuleLoadDataEx, CUmodule *, const void *,
              unsigned int, int *, void **);
CUDA_FUNCTION(CUresult, cuModuleGetFunction, CUfunction *, CUmodule,
              const char *);
CUDA_FUNCTION(CUresult, cuModuleGetGlobal, CUdeviceptr *, size_t *, CUmodule,
              const char *);
CUDA_FUNCTION(CUresult, cuModuleUnload, CUmodule);
CUDA_FUNCTION(CUresult, cuFuncGetAttribute, int *, int, CUfunction);
CUDA_FUNCTION(CUresult, cuOccupancyMaxActiveBlocksPerMultiprocessor, int *,
              CUfunction, int, size_t);
CUDA_FUNCTION(CUresult, cuTensorMapEncodeTiled, CUtensorMap *, int, uint32_t,
              void *, const uint64_t *, const uint64_t *, const uint32_t *,
              const uint32_t *, int, int, int, int);
CUDA_FUNCTION(CUresult, cuTensorMapEncodeIm2col, CUtensorMap *, int, uint32_t,
              void *, const uint64_t *, const uint64_t *, const int *,
              const int *, uint32_t, uint32_t, const uint32_t *, int, int, int,
              int);
CUDA_FUNCTION(CUresult, cuLaunchKernel, CUfunction, unsigned int, unsigned int,
              unsigned int, unsigned int, unsigned int, unsigned int,
              unsigned int, CUstream, void **, void **);
CUDA_FUNCTION(CUresult, cuLaunchKernelEx, const CUlaunchConfig *, CUfunction,
              void **, void **);
CUDA_FUNCTION(CUresult, cuGraphCreate, CUgraph *, unsigned int);
CUDA_FUNCTION(CUresult, cuGraphAddKernelNode, CUgraphNode *, CUgraph,
              const CUgraphNode *, size_t, const CUDAKernelNodeParams *);
CUDA_FUNCTION(CUresult, cuGraphKernelNodeSetAttribute, CUgraphNode, int,
              const unsigned char *);
CUDA_FUNCTION(CUresult, cuGraphAddMemcpyNode, CUgraphNode *, CUgraph,
              const CUgraphNode *, size_t, const CUDAMemcpy3D *, CUcontext);
CUDA_FUNCTION(CUresult, cuGraphAddMemsetNode, CUgraphNode *, CUgraph,
              const CUgraphNode *, size_t, const CUDAMemsetNodeParams *,
              CUcontext);
CUDA_FUNCTION(CUresult, cuGraphAddEmptyNode, CUgraphNode *, CUgraph,
              const CUgraphNode *, size_t);
CUDA_FUNCTION(CUresult, cuGraphAddHostNode, CUgraphNode *, CUgraph,
              const CUgraphNode *, size_t, const CUDAHostNodeParams *);
CUDA_FUNCTION(CUresult, cuGraphAddBatchMemOpNode, CUgraphNode *, CUgraph,
              const CUgraphNode *, size_t, const CUDABatchMemOpNodeParams *);
CUDA_FUNCTION(CUresult, cuGraphInstantiate, CUgraphExec *, CUgraph,
              unsigned long long);
CUDA_FUNCTION(CUresult, cuGraphLaunch, CUgraphExec, CUstream);
CUDA_FUNCTION(CUresult, cuGraphExecDestroy, CUgraphExec);
CUDA_FUNCTION(CUresult, cuGraphDestroy, CUgraph);
CUDA_FUNCTION(CUresult, cuGetErrorString, CUresult, const char **);

#undef CUDA_FUNCTION

static std::once_flag cudaLoadOnce;
static bool cudaLoaded = false;
static char cudaLoadError[512] = {};
static std::mutex peerAccessMutex;

static std::vector<std::pair<int, int>> &enabledPeerPairs() {
  static auto *pairs = new std::vector<std::pair<int, int>>();
  return *pairs;
}

static std::vector<std::pair<int, CUcontext>> &retainedPeerContexts() {
  static auto *contexts = new std::vector<std::pair<int, CUcontext>>();
  return *contexts;
}

template <typename T>
bool loadProc(HMODULE module, T &result, const char *name,
              const char *fallback = nullptr) {
  result = reinterpret_cast<T>(GetProcAddress(module, name));
  if (!result && fallback)
    result = reinterpret_cast<T>(GetProcAddress(module, fallback));
  if (result)
    return true;
  snprintf(cudaLoadError, sizeof(cudaLoadError),
           "nvcuda.dll is missing entry point '%s'", name);
  return false;
}

static void loadCUDAOnce() {
  HMODULE module = LoadLibraryW(L"nvcuda.dll");
  if (!module) {
    snprintf(cudaLoadError, sizeof(cudaLoadError),
             "unable to load nvcuda.dll (Windows error %lu)", GetLastError());
    return;
  }

#define LOAD(name)                                                             \
  if (!loadProc(module, name, #name))                                          \
  return
#define LOAD_V2(name)                                                          \
  if (!loadProc(module, name, #name "_v2", #name))                             \
  return

  LOAD(cuInit);
  LOAD(cuDriverGetVersion);
  LOAD(cuDeviceGetCount);
  LOAD(cuDeviceGet);
  LOAD(cuDeviceGetName);
  LOAD(cuDeviceGetAttribute);
  LOAD(cuDeviceCanAccessPeer);
  LOAD_V2(cuDeviceTotalMem);
  LOAD(cuDevicePrimaryCtxRetain);
  LOAD_V2(cuDevicePrimaryCtxRelease);
  LOAD(cuCtxSetCurrent);
  LOAD(cuCtxGetCurrent);
  LOAD_V2(cuCtxPushCurrent);
  LOAD_V2(cuCtxPopCurrent);
  LOAD(cuCtxSynchronize);
  LOAD(cuCtxGetLimit);
  LOAD(cuCtxSetLimit);
  LOAD(cuCtxGetStreamPriorityRange);
  LOAD(cuCtxEnablePeerAccess);
  LOAD_V2(cuMemGetInfo);
  LOAD_V2(cuMemAlloc);
  LOAD_V2(cuMemFree);
  LOAD(cuMemHostAlloc);
  LOAD_V2(cuMemHostGetDevicePointer);
  LOAD(cuMemFreeHost);
  LOAD_V2(cuMemcpyHtoD);
  LOAD_V2(cuMemcpyDtoH);
  LOAD_V2(cuMemcpyDtoD);
  LOAD_V2(cuMemcpyHtoDAsync);
  LOAD_V2(cuMemcpyDtoHAsync);
  LOAD_V2(cuMemcpyDtoDAsync);
  LOAD(cuMemcpyPeerAsync);
  LOAD_V2(cuMemsetD8);
  LOAD_V2(cuMemsetD16);
  LOAD_V2(cuMemsetD32);
  LOAD(cuMemsetD8Async);
  LOAD(cuMemsetD16Async);
  LOAD(cuMemsetD32Async);
  LOAD_V2(cuMemsetD2D32Async);
  LOAD(cuStreamCreate);
  LOAD(cuStreamCreateWithPriority);
  LOAD_V2(cuStreamDestroy);
  LOAD(cuStreamSynchronize);
  LOAD(cuStreamWaitEvent);
  LOAD_V2(cuStreamWaitValue64);
  LOAD(cuEventCreate);
  LOAD_V2(cuEventDestroy);
  LOAD(cuEventRecord);
  LOAD(cuEventSynchronize);
  LOAD(cuEventElapsedTime);
  LOAD(cuLaunchHostFunc);
  LOAD(cuModuleLoadDataEx);
  LOAD(cuModuleGetFunction);
  LOAD_V2(cuModuleGetGlobal);
  LOAD(cuModuleUnload);
  LOAD(cuFuncGetAttribute);
  LOAD(cuOccupancyMaxActiveBlocksPerMultiprocessor);
  LOAD(cuTensorMapEncodeTiled);
  LOAD(cuTensorMapEncodeIm2col);
  LOAD(cuLaunchKernel);
  LOAD(cuLaunchKernelEx);
  LOAD(cuGraphCreate);
  if (!loadProc(module, cuGraphAddKernelNode, "cuGraphAddKernelNode_v2"))
    return;
  LOAD(cuGraphKernelNodeSetAttribute);
  LOAD(cuGraphAddMemcpyNode);
  LOAD(cuGraphAddMemsetNode);
  LOAD(cuGraphAddEmptyNode);
  LOAD(cuGraphAddHostNode);
  LOAD(cuGraphAddBatchMemOpNode);
  if (!loadProc(module, cuGraphInstantiate, "cuGraphInstantiateWithFlags"))
    return;
  LOAD(cuGraphLaunch);
  LOAD(cuGraphExecDestroy);
  LOAD(cuGraphDestroy);
  LOAD(cuGetErrorString);

#undef LOAD_V2
#undef LOAD

  CUresult status = cuInit(0);
  if (status != CUDA_SUCCESS) {
    snprintf(cudaLoadError, sizeof(cudaLoadError),
             "cuInit failed with CUDA error %d", status);
    return;
  }
  cudaLoaded = true;
}

static bool loadCUDA() {
  std::call_once(cudaLoadOnce, loadCUDAOnce);
  return cudaLoaded;
}

static const char *errf(const char *format, ...) {
  char buffer[2048];
  va_list args;
  va_start(args, format);
  vsnprintf(buffer, sizeof(buffer), format, args);
  va_end(args);
  size_t length = strlen(buffer) + 1;
  char *result = static_cast<char *>(malloc(length));
  if (result)
    memcpy(result, buffer, length);
  return result;
}

static const char *cudaError(const char *operation, CUresult status) {
  const char *description = nullptr;
  if (cuGetErrorString)
    cuGetErrorString(status, &description);
  if (description)
    return errf("%s failed: CUDA error %d (%s)", operation, status,
                description);
  return errf("%s failed: CUDA error %d", operation, status);
}

struct NVPTXContext;
struct NVPTXGraphBuilder;
struct NVPTXCompletionFlag;

struct NVPTXStream {
  std::atomic<int> references{1};
  CUstream stream = nullptr;
  NVPTXContext *context = nullptr;
  std::vector<NVPTXCompletionFlag *> pendingCompletionFlags;
  bool owning = false;
  bool transient = false;
};

struct NVPTXBuffer {
  std::atomic<int> references{1};
  CUdeviceptr device = 0;
  void *host = nullptr;
  size_t bytes = 0;
  NVPTXContext *context = nullptr;
  NVPTXBuffer *parent = nullptr;
  bool owning = true;
  bool hostPinned = false;
};

struct NVPTXFunction {
  std::atomic<int> references{1};
  CUmodule module = nullptr;
  CUfunction function = nullptr;
  NVPTXContext *context = nullptr;
};

struct NVPTXContext {
  std::atomic<int> references{1};
  NVPTXContext *root = nullptr;
  CUdevice device = 0;
  CUcontext context = nullptr;
  int id = 0;
  int computeCapability = 0;
  int driverVersion = 0;
  std::string name;
  std::string arch;
  std::string api = "cuda";
  NVPTXStream *defaultStream = nullptr;
  NVPTXGraphBuilder *recordingBuilder = nullptr;
  int32_t recordingLastNode = -1;
  std::vector<NVPTXStream *> streams;
  std::vector<NVPTXBuffer *> liveHostBuffers;
  // Owning device allocations, so a graph node handed a bare device address
  // can find the buffer that owns it and keep it alive. See
  // retainGraphDevicePointer.
  std::vector<NVPTXBuffer *> liveDeviceBuffers;
  std::string pendingError;
  std::mutex mutex;
  std::mutex cpuMutex;
  std::condition_variable cpuTasksComplete;
  size_t pendingCpuTasks = 0;
};

struct NVPTXGraphBuilder {
  CUgraph graph = nullptr;
  NVPTXContext *context = nullptr;
  std::vector<CUgraphNode> nodes;
  std::vector<NVPTXBuffer *> buffers;
  std::vector<NVPTXFunction *> functions;
  std::vector<NVPTXCompletionFlag *> completionFlags;
  std::vector<void *> outputs;
  int64_t inputCount = 0;
};

struct NVPTXGraph {
  std::atomic<int> references{1};
  CUgraphExec executable = nullptr;
  NVPTXContext *context = nullptr;
  std::vector<NVPTXBuffer *> buffers;
  std::vector<NVPTXFunction *> functions;
  std::vector<NVPTXCompletionFlag *> completionFlags;
  std::vector<void *> outputs;
};

constexpr uint64_t NVPTX_ASYNC_VALUE_MAGIC = 0x4e56505458415631ull;

struct NVPTXAsyncValue {
  uint64_t magic = NVPTX_ASYNC_VALUE_MAGIC;
  std::atomic<int> references{1};
  NVPTXBuffer *buffer = nullptr;
};

constexpr uint64_t NVPTX_COMPLETION_FLAG_MAGIC = 0x4e56505458434631ull;

struct NVPTXCompletionFlag {
  uint64_t magic = NVPTX_COMPLETION_FLAG_MAGIC;
  std::atomic<int> references{1};
  std::atomic<uint64_t> *host = nullptr;
  CUdeviceptr device = 0;
  NVPTXContext *context = nullptr;
};

extern "C" __declspec(dllexport) void
AsyncRT_DeviceBuffer_release(const NVPTXBuffer *buffer);

struct NVPTXEvent {
  std::atomic<int> references{1};
  CUevent event = nullptr;
  NVPTXContext *context = nullptr;
};

struct NVPTXTimer {
  CUevent start = nullptr;
  CUevent stop = nullptr;
  NVPTXContext *context = nullptr;
  std::chrono::steady_clock::time_point cpuStart;
};

struct NVPTXContextScope {
  NVPTXContext *context = nullptr;
};

struct StringRefABI {
  const char *data;
  size_t length;
};

static NVPTXContext *rootContext(const NVPTXContext *context) {
  if (!context)
    return nullptr;
  return context->root ? context->root : const_cast<NVPTXContext *>(context);
}

static bool isCPUContext(const NVPTXContext *context) {
  const NVPTXContext *root = rootContext(context);
  return root && root->api == "cpu";
}

static void recordPendingError(const NVPTXContext *context,
                               std::string message) {
  NVPTXContext *root = rootContext(context);
  if (!root || message.empty())
    return;
  std::lock_guard<std::mutex> lock(root->mutex);
  if (root->pendingError.empty())
    root->pendingError = std::move(message);
}

static void recordPendingCudaError(const NVPTXContext *context,
                                   const char *operation, CUresult status) {
  NVPTXContext *root = rootContext(context);
  if (!root || status == CUDA_SUCCESS)
    return;
  const char *allocatedError = cudaError(operation, status);
  std::string message =
      allocatedError ? allocatedError : "CUDA operation failed";
  free(const_cast<char *>(allocatedError));
  recordPendingError(root, std::move(message));
}

static const char *takePendingError(const NVPTXContext *context) {
  NVPTXContext *root = rootContext(context);
  if (!root)
    return nullptr;
  std::string message;
  {
    std::lock_guard<std::mutex> lock(root->mutex);
    message = std::move(root->pendingError);
    root->pendingError.clear();
  }
  return message.empty() ? nullptr : errf("%s", message.c_str());
}

static void registerHostBuffer(NVPTXBuffer *buffer) {
  if (!buffer || !buffer->host || !buffer->context)
    return;
  NVPTXContext *root = rootContext(buffer->context);
  std::lock_guard<std::mutex> lock(root->mutex);
  root->liveHostBuffers.push_back(buffer);
}

static void unregisterHostBuffer(NVPTXBuffer *buffer) {
  if (!buffer || !buffer->host || !buffer->context)
    return;
  NVPTXContext *root = rootContext(buffer->context);
  std::lock_guard<std::mutex> lock(root->mutex);
  auto position = std::find(root->liveHostBuffers.begin(),
                            root->liveHostBuffers.end(), buffer);
  if (position != root->liveHostBuffers.end())
    root->liveHostBuffers.erase(position);
}

static void registerDeviceBuffer(NVPTXBuffer *buffer) {
  if (!buffer || !buffer->device || !buffer->owning || !buffer->context)
    return;
  NVPTXContext *root = rootContext(buffer->context);
  std::lock_guard<std::mutex> lock(root->mutex);
  root->liveDeviceBuffers.push_back(buffer);
}

static void unregisterDeviceBuffer(NVPTXBuffer *buffer) {
  if (!buffer || !buffer->device || !buffer->context)
    return;
  NVPTXContext *root = rootContext(buffer->context);
  std::lock_guard<std::mutex> lock(root->mutex);
  auto position = std::find(root->liveDeviceBuffers.begin(),
                            root->liveDeviceBuffers.end(), buffer);
  if (position != root->liveDeviceBuffers.end())
    root->liveDeviceBuffers.erase(position);
}

static CUstream activeStream(const NVPTXContext *context) {
  return context && context->defaultStream ? context->defaultStream->stream
                                           : nullptr;
}

static void retainContext(const NVPTXContext *context) {
  if (context)
    const_cast<NVPTXContext *>(context)->references.fetch_add(1);
}

static void releaseContext(const NVPTXContext *context);

struct CPUWorkItem {
  NVPTXContext *context = nullptr;
  std::function<void()> task;
};

class CPUWorkerPool {
public:
  CPUWorkerPool() {
    unsigned workerCount = std::thread::hardware_concurrency();
    workerCount = std::max(1u, std::min(workerCount, 16u));
    workers.reserve(workerCount);
    for (unsigned index = 0; index < workerCount; ++index)
      workers.emplace_back([this]() { workerLoop(); });
  }

  ~CPUWorkerPool() {
    {
      std::lock_guard<std::mutex> lock(mutex);
      stopping = true;
    }
    taskAvailable.notify_all();
    for (std::thread &worker : workers)
      if (worker.joinable())
        worker.join();
  }

  size_t size() const { return workers.size(); }

  void enqueue(NVPTXContext *context, std::function<void()> task) {
    retainContext(context);
    {
      std::lock_guard<std::mutex> lock(context->cpuMutex);
      ++context->pendingCpuTasks;
    }
    {
      std::lock_guard<std::mutex> lock(mutex);
      tasks.push_back({context, std::move(task)});
    }
    taskAvailable.notify_one();
  }

private:
  void workerLoop() {
    for (;;) {
      CPUWorkItem work;
      {
        std::unique_lock<std::mutex> lock(mutex);
        taskAvailable.wait(lock, [this]() { return stopping || !tasks.empty(); });
        if (stopping && tasks.empty())
          return;
        work = std::move(tasks.front());
        tasks.pop_front();
      }

      try {
        work.task();
      } catch (const std::exception &error) {
        recordPendingError(work.context,
                           std::string("CPU worker failed: ") + error.what());
      } catch (...) {
        recordPendingError(work.context, "CPU worker failed");
      }

      {
        std::lock_guard<std::mutex> lock(work.context->cpuMutex);
        if (--work.context->pendingCpuTasks == 0)
          work.context->cpuTasksComplete.notify_all();
      }
      releaseContext(work.context);
    }
  }

  std::mutex mutex;
  std::condition_variable taskAvailable;
  std::deque<CPUWorkItem> tasks;
  std::vector<std::thread> workers;
  bool stopping = false;
};

static CPUWorkerPool &cpuWorkerPool() {
  static CPUWorkerPool pool;
  return pool;
}

static const char *enqueueCPUTask(const NVPTXContext *context,
                                  std::function<void()> task) {
  NVPTXContext *root = rootContext(context);
  if (!root || !isCPUContext(root))
    return errf("CPU task requires a CPU DeviceContext");
  cpuWorkerPool().enqueue(root, std::move(task));
  return nullptr;
}

static const char *synchronizeCPU(const NVPTXContext *context) {
  NVPTXContext *root = rootContext(context);
  if (!root || !isCPUContext(root))
    return errf("CPU synchronize requires a CPU DeviceContext");
  {
    std::unique_lock<std::mutex> lock(root->cpuMutex);
    root->cpuTasksComplete.wait(
        lock, [root]() { return root->pendingCpuTasks == 0; });
  }
  return takePendingError(root);
}

static const char *setCurrent(const NVPTXContext *context) {
  if (!context)
    return errf("CUDA context is null");
  if (isCPUContext(context))
    return nullptr;
  CUresult status = cuCtxSetCurrent(context->context);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuCtxSetCurrent", status);
}

static void releaseCompletionFlag(NVPTXCompletionFlag *flag) {
  if (!flag || flag->magic != NVPTX_COMPLETION_FLAG_MAGIC ||
      flag->references.fetch_sub(1) != 1)
    return;
  NVPTXContext *context = flag->context;
  if (context)
    cuCtxSetCurrent(context->context);
  if (flag->host)
    cuMemFreeHost(flag->host);
  flag->magic = 0;
  delete flag;
  releaseContext(context);
}

static void drainStreamCompletionFlags(NVPTXStream *stream) {
  if (!stream || !stream->context)
    return;
  std::vector<NVPTXCompletionFlag *> completed;
  NVPTXContext *root = rootContext(stream->context);
  {
    std::lock_guard<std::mutex> lock(root->mutex);
    completed.swap(stream->pendingCompletionFlags);
  }
  for (NVPTXCompletionFlag *flag : completed)
    releaseCompletionFlag(flag);
}

static void releaseStream(NVPTXStream *stream) {
  if (!stream)
    return;
  if (stream->stream) {
    cuStreamSynchronize(stream->stream);
    drainStreamCompletionFlags(stream);
  }
  if (stream->owning && stream->stream)
    cuStreamDestroy(stream->stream);
  delete stream;
}

static void releaseContext(const NVPTXContext *context) {
  if (!context)
    return;
  auto *mutableContext = const_cast<NVPTXContext *>(context);
  if (mutableContext->references.fetch_sub(1) != 1)
    return;

  if (mutableContext->root) {
    NVPTXContext *root = mutableContext->root;
    delete mutableContext;
    releaseContext(root);
    return;
  }

  if (isCPUContext(mutableContext)) {
    delete mutableContext;
    return;
  }

  cuCtxSetCurrent(mutableContext->context);
  for (NVPTXStream *stream : mutableContext->streams)
    releaseStream(stream);
  cuDevicePrimaryCtxRelease(mutableContext->device);
  delete mutableContext;
}

static const char *waitForContext(const NVPTXContext *context,
                                  const NVPTXContext *other) {
  if (!context || !other)
    return errf("enqueue_wait_for_context: null context");
  NVPTXContext *contextRoot = rootContext(context);
  NVPTXContext *otherRoot = rootContext(other);
  if (contextRoot == otherRoot)
    return nullptr;
  if (isCPUContext(otherRoot))
    return synchronizeCPU(otherRoot);
  if (isCPUContext(contextRoot)) {
    if (const char *error = setCurrent(otherRoot))
      return error;
    CUresult status = cuStreamSynchronize(activeStream(other));
    return status == CUDA_SUCCESS ? nullptr
                                  : cudaError("cuStreamSynchronize", status);
  }
  if (activeStream(context) == activeStream(other) &&
      contextRoot->context == otherRoot->context)
    return nullptr;

  if (const char *error = setCurrent(other))
    return error;
  CUevent event = nullptr;
  CUresult status = cuEventCreate(&event, CU_EVENT_DISABLE_TIMING);
  if (status != CUDA_SUCCESS)
    return cudaError("cuEventCreate", status);
  status = cuEventRecord(event, activeStream(other));
  if (status != CUDA_SUCCESS) {
    cuEventDestroy(event);
    return cudaError("cuEventRecord", status);
  }

  if (const char *error = setCurrent(context)) {
    cuEventDestroy(event);
    return error;
  }
  status = cuStreamWaitEvent(activeStream(context), event, 0);
  CUresult destroyStatus = cuEventDestroy(event);
  if (status != CUDA_SUCCESS)
    return cudaError("cuStreamWaitEvent", status);
  return destroyStatus == CUDA_SUCCESS
             ? nullptr
             : cudaError("cuEventDestroy", destroyStatus);
}

static const char *graphDependencies(const NVPTXGraphBuilder *builder,
                                     const int32_t *ids, int64_t count,
                                     std::vector<CUgraphNode> &result) {
  if (!builder)
    return errf("device graph builder is null");
  if (count < 0)
    return errf("device graph dependency count is negative");
  if (count && !ids)
    return errf("device graph dependencies are null");
  result.clear();
  result.reserve(static_cast<size_t>(count));
  for (int64_t index = 0; index < count; ++index) {
    const int32_t id = ids[index];
    if (id < 0 || static_cast<size_t>(id) >= builder->nodes.size())
      return errf("device graph dependency id %d is invalid", id);
    result.push_back(builder->nodes[static_cast<size_t>(id)]);
  }
  return nullptr;
}

static void retainGraphBuffer(NVPTXGraphBuilder *builder,
                              NVPTXBuffer *buffer) {
  if (!builder || !buffer ||
      std::find(builder->buffers.begin(), builder->buffers.end(), buffer) !=
          builder->buffers.end())
    return;
  buffer->references.fetch_add(1);
  builder->buffers.push_back(buffer);
}

static void retainGraphHostPointer(NVPTXGraphBuilder *builder,
                                   const void *pointer) {
  if (!builder || !builder->context || !pointer)
    return;
  NVPTXContext *root = rootContext(builder->context);
  std::lock_guard<std::mutex> lock(root->mutex);
  for (NVPTXBuffer *buffer : root->liveHostBuffers) {
    if (buffer->host == pointer) {
      retainGraphBuffer(builder, buffer);
      return;
    }
  }
}

// A kernel argument that is a device address inside a live owning buffer
// makes the graph a co-owner of that buffer. Anything else -- a scalar that
// happens to look like an address, a pointer into memory this runtime did
// not allocate -- matches nothing and is left alone.
static void retainGraphDevicePointer(NVPTXGraphBuilder *builder,
                                     uintptr_t address) {
  if (!builder || !builder->context || !address)
    return;
  NVPTXContext *root = rootContext(builder->context);
  std::lock_guard<std::mutex> lock(root->mutex);
  for (NVPTXBuffer *buffer : root->liveDeviceBuffers) {
    const uintptr_t start = static_cast<uintptr_t>(buffer->device);
    if (address >= start && address < start + std::max<size_t>(buffer->bytes, 1)) {
      retainGraphBuffer(builder, buffer);
      return;
    }
  }
}

static void retainGraphFunction(NVPTXGraphBuilder *builder,
                                NVPTXFunction *function) {
  if (!builder || !function ||
      std::find(builder->functions.begin(), builder->functions.end(),
                function) != builder->functions.end())
    return;
  function->references.fetch_add(1);
  builder->functions.push_back(function);
}

static void retainGraphCompletionFlag(NVPTXGraphBuilder *builder,
                                      NVPTXCompletionFlag *flag) {
  if (!builder || !flag ||
      std::find(builder->completionFlags.begin(), builder->completionFlags.end(),
                flag) != builder->completionFlags.end())
    return;
  flag->references.fetch_add(1);
  builder->completionFlags.push_back(flag);
}

static const char *addRecordedHostFunction(NVPTXContext *context,
                                           CUhostFn function,
                                           void *userData) {
  if (!context || !context->recordingBuilder)
    return errf("recorded host function: invalid recording context");
  NVPTXGraphBuilder *builder = context->recordingBuilder;
  const int32_t dependency = context->recordingLastNode;
  std::vector<CUgraphNode> dependencies;
  if (const char *error = graphDependencies(
          builder, dependency >= 0 ? &dependency : nullptr,
          dependency >= 0 ? 1 : 0, dependencies))
    return error;
  CUDAHostNodeParams parameters = {function, userData};
  CUgraphNode node = nullptr;
  CUresult status = cuGraphAddHostNode(&node, builder->graph,
                                       dependencies.data(), dependencies.size(),
                                       &parameters);
  if (status != CUDA_SUCCESS)
    return cudaError("cuGraphAddHostNode", status);
  builder->nodes.push_back(node);
  context->recordingLastNode =
      static_cast<int32_t>(builder->nodes.size() - 1);
  return nullptr;
}

static const char *addRecordedWaitOnHostValue(NVPTXContext *context,
                                              NVPTXCompletionFlag *flag,
                                              uint64_t value) {
  if (!context || !context->recordingBuilder || !flag)
    return errf("recorded host-value wait: invalid argument");
  NVPTXGraphBuilder *builder = context->recordingBuilder;
  const int32_t dependency = context->recordingLastNode;
  std::vector<CUgraphNode> dependencies;
  if (const char *error = graphDependencies(
          builder, dependency >= 0 ? &dependency : nullptr,
          dependency >= 0 ? 1 : 0, dependencies))
    return error;
  constexpr int CU_STREAM_MEM_OP_WAIT_VALUE_64 = 4;
  CUDAStreamWaitValue64Params wait = {
      CU_STREAM_MEM_OP_WAIT_VALUE_64, 0, flag->device, value, 0, 0, 0, 0};
  CUDABatchMemOpNodeParams parameters = {
      builder->context->context, 1, 0, &wait, 0, 0};
  CUgraphNode node = nullptr;
  CUresult status = cuGraphAddBatchMemOpNode(
      &node, builder->graph, dependencies.data(), dependencies.size(),
      &parameters);
  if (status != CUDA_SUCCESS)
    return cudaError("cuGraphAddBatchMemOpNode", status);
  builder->nodes.push_back(node);
  context->recordingLastNode =
      static_cast<int32_t>(builder->nodes.size() - 1);
  retainGraphCompletionFlag(builder, flag);
  return nullptr;
}

// The graph node builders, defined below among the exports; declared here so
// the recording helpers can reach them. dllexport spelled out because the
// definitions carry it and a declaration may not add it later.
extern "C" __declspec(dllexport) const char *
AsyncRT_DeviceGraphBuilder_addCopyHostToDevice(
    NVPTXGraphBuilder *, NVPTXBuffer *, const void *, const int32_t *, int64_t);
extern "C" __declspec(dllexport) const char *
AsyncRT_DeviceGraphBuilder_addCopyDeviceToHost(
    NVPTXGraphBuilder *, void *, NVPTXBuffer *, const int32_t *, int64_t);
extern "C" __declspec(dllexport) const char *
AsyncRT_DeviceGraphBuilder_addCopyDeviceToDevice(
    NVPTXGraphBuilder *, NVPTXBuffer *, NVPTXBuffer *, const int32_t *,
    int64_t);
extern "C" __declspec(dllexport) const char *
AsyncRT_DeviceGraphBuilder_addSetMemory(
    NVPTXGraphBuilder *, NVPTXBuffer *, uint64_t, size_t, const int32_t *,
    int64_t);
extern "C" __declspec(dllexport) int32_t
AsyncRT_DeviceGraphBuilder_lastNodeIdOrNone(NVPTXGraphBuilder *);

// A memset or a copy enqueued through a recording context is part of the
// graph being recorded, not something to run on the live stream halfway
// through capture. Until this existed they did exactly that -- executed
// eagerly and never became nodes -- so a replayed graph silently computed
// without them, whatever the recording surface's documentation promised.
// The node chains after whatever the recording has produced so far, the
// same linear order recorded kernels get, and becomes the last node so
// whatever is recorded next orders after it.
template <typename AddRecordedNode>
static const char *recordMemOp(NVPTXContext *context, AddRecordedNode add) {
  NVPTXGraphBuilder *builder = context->recordingBuilder;
  const int32_t dependency = context->recordingLastNode;
  const char *error = add(builder, dependency >= 0 ? &dependency : nullptr,
                          dependency >= 0 ? 1 : 0);
  if (!error)
    context->recordingLastNode =
        AsyncRT_DeviceGraphBuilder_lastNodeIdOrNone(builder);
  return error;
}

static void releaseAsyncValue(void *value) {
  if (!value)
    return;
  auto *nvptxValue = static_cast<NVPTXAsyncValue *>(value);
  if (nvptxValue->magic == NVPTX_ASYNC_VALUE_MAGIC) {
    if (nvptxValue->references.fetch_sub(1) != 1)
      return;
    NVPTXBuffer *buffer = nvptxValue->buffer;
    delete nvptxValue;
    if (buffer)
      AsyncRT_DeviceBuffer_release(buffer);
    return;
  }
  HMODULE module = GetModuleHandleW(L"AsyncRTRuntimeGlobals.dll");
  if (!module)
    return;
  using ReleaseFn = void (*)(void *);
  auto release = reinterpret_cast<ReleaseFn>(
      GetProcAddress(module, "AsyncRT_AsyncValue_release"));
  if (release)
    release(value);
}

static bool isCudaKind(const char *api) {
  if (!api || !*api)
    return true;
  return strcmp(api, "cuda") == 0 || strcmp(api, "nvidia") == 0 ||
         strcmp(api, "gpu") == 0;
}

static bool isCPUKind(const char *api) {
  return api && strcmp(api, "cpu") == 0;
}

static bool peerAccessEnabledLocked(int device, int peerDevice) {
  auto &pairs = enabledPeerPairs();
  return std::find(pairs.begin(), pairs.end(),
                   std::make_pair(device, peerDevice)) !=
         pairs.end();
}

static void markPeerAccessEnabledLocked(int device, int peerDevice) {
  if (!peerAccessEnabledLocked(device, peerDevice))
    enabledPeerPairs().emplace_back(device, peerDevice);
}

static const char *retainedPeerContextLocked(int ordinal, CUdevice &device,
                                             CUcontext &context) {
  CUresult status = cuDeviceGet(&device, ordinal);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDeviceGet", status);
  for (const auto &entry : retainedPeerContexts()) {
    if (entry.first == device) {
      context = entry.second;
      return nullptr;
    }
  }
  status = cuDevicePrimaryCtxRetain(&context, device);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDevicePrimaryCtxRetain", status);
  // Keep one process-lifetime reference after enableAllPeerAccess so the
  // primary contexts (and their peer mappings) cannot be reset underneath
  // later DeviceContext instances.
  retainedPeerContexts().emplace_back(device, context);
  return nullptr;
}

} // namespace

extern "C" {

#define NVPTXRT_EXPORT __declspec(dllexport)

// Device-to-worker affinity is an optional MLRT hint.  The public Windows
// build does not contain MLRT's NUMA affinity mapper, so report the ABI's
// documented "no preferred worker" value instead of leaving the symbol
// unresolved.
NVPTXRT_EXPORT int32_t MLRT_TaskIdForDevice(int32_t deviceId) {
  (void)deviceId;
  return -1;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_create(const NVPTXContext **result, const char *api,
                             int id) {
  if (!result)
    return errf("AsyncRT_DeviceContext_create: result is null");
  if (isCPUKind(api)) {
    if (id != 0)
      return errf("CPU device %d is unavailable (device count: 1)", id);
    auto *context = new NVPTXContext();
    context->id = id;
    context->name = "Windows x64 CPU";
    context->arch = "x86_64";
    context->api = "cpu";
    *result = context;
    return nullptr;
  }
  if (!isCudaKind(api))
    return errf("nvptxrt does not implement device API '%s'", api ? api : "");
  if (!loadCUDA())
    return errf("%s", cudaLoadError);

  int count = 0;
  CUresult status = cuDeviceGetCount(&count);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDeviceGetCount", status);
  if (id < 0 || id >= count)
    return errf("CUDA device %d is unavailable (device count: %d)", id, count);

  CUdevice device = 0;
  status = cuDeviceGet(&device, id);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDeviceGet", status);

  CUcontext cudaContext = nullptr;
  status = cuDevicePrimaryCtxRetain(&cudaContext, device);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDevicePrimaryCtxRetain", status);
  status = cuCtxSetCurrent(cudaContext);
  if (status != CUDA_SUCCESS) {
    cuDevicePrimaryCtxRelease(device);
    return cudaError("cuCtxSetCurrent", status);
  }

  // Unoptimized NVPTX deliberately retains device helper calls so debug
  // stepping remains useful.  Their combined frames can exceed CUDA's small
  // default per-thread stack and otherwise surface later as an illegal-memory
  // error.  Keep the floor conservative because this limit affects the
  // primary context's device-memory reservation.
  size_t threadStackSize = 0;
  status = cuCtxGetLimit(&threadStackSize, CU_LIMIT_STACK_SIZE);
  if (status != CUDA_SUCCESS) {
    cuDevicePrimaryCtxRelease(device);
    return cudaError("cuCtxGetLimit(CU_LIMIT_STACK_SIZE)", status);
  }
  if (threadStackSize < NVPTX_MIN_THREAD_STACK_SIZE) {
    status = cuCtxSetLimit(CU_LIMIT_STACK_SIZE, NVPTX_MIN_THREAD_STACK_SIZE);
    if (status != CUDA_SUCCESS) {
      cuDevicePrimaryCtxRelease(device);
      return cudaError("cuCtxSetLimit(CU_LIMIT_STACK_SIZE)", status);
    }
  }

  auto *context = new NVPTXContext();
  context->device = device;
  context->context = cudaContext;
  context->id = id;
  cuDriverGetVersion(&context->driverVersion);

  char name[256] = {};
  if (cuDeviceGetName(name, sizeof(name), device) == CUDA_SUCCESS)
    context->name = name;
  else
    context->name = "NVIDIA CUDA device";

  int major = 0;
  int minor = 0;
  cuDeviceGetAttribute(&major, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR,
                       device);
  cuDeviceGetAttribute(&minor, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR,
                       device);
  context->computeCapability = major * 10 + minor;
  context->arch = "sm_" + std::to_string(major) + std::to_string(minor);
  const bool hasArchitectureSpecificTarget =
      (major == 9 && minor == 0) ||
      (major == 10 && (minor == 0 || minor == 3)) ||
      (major == 11 && minor == 0) ||
      (major == 12 && (minor == 0 || minor == 1));
  if (hasArchitectureSpecificTarget)
    context->arch += "a";

  CUstream cudaStream = nullptr;
  status = cuStreamCreate(&cudaStream, CU_STREAM_NON_BLOCKING);
  if (status != CUDA_SUCCESS) {
    cuDevicePrimaryCtxRelease(device);
    delete context;
    return cudaError("cuStreamCreate", status);
  }

  auto *stream = new NVPTXStream();
  stream->references.store(0);
  stream->stream = cudaStream;
  stream->context = context;
  stream->owning = true;
  context->defaultStream = stream;
  context->streams.push_back(stream);

  *result = context;
  return nullptr;
}

NVPTXRT_EXPORT void AsyncRT_DeviceContext_retain(const NVPTXContext *context) {
  retainContext(context);
}

NVPTXRT_EXPORT void AsyncRT_DeviceContext_release(const NVPTXContext *context) {
  releaseContext(context);
}

NVPTXRT_EXPORT int64_t AsyncRT_DeviceContext_id(const NVPTXContext *context) {
  return context ? context->id : -1;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_deviceName(const NVPTXContext *context) {
  return context ? errf("%s", context->name.c_str()) : errf("<null>");
}

NVPTXRT_EXPORT void
AsyncRT_DeviceContext_archName(StringRefABI *result,
                               const NVPTXContext *context) {
  static const char unknown[] = "<null>";
  if (!result)
    return;
  result->data = context ? context->arch.data() : unknown;
  result->length = context ? context->arch.size() : sizeof(unknown) - 1;
}

NVPTXRT_EXPORT void
AsyncRT_DeviceContext_deviceApi(StringRefABI *result,
                                const NVPTXContext *context) {
  static const char cuda[] = "cuda";
  if (!result)
    return;
  result->data = context ? context->api.data() : cuda;
  result->length = context ? context->api.size() : sizeof(cuda) - 1;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_getApiVersion(int *result, const NVPTXContext *context) {
  if (result)
    *result = context ? context->driverVersion : 0;
  return nullptr;
}

NVPTXRT_EXPORT int32_t AsyncRT_DeviceContext_numberOfDevices(const char *kind) {
  if (isCPUKind(kind))
    return 1;
  if (!isCudaKind(kind) || !loadCUDA())
    return 0;
  int cudaCount = 0;
  if (cuDeviceGetCount(&cudaCount) == CUDA_SUCCESS)
    return cudaCount;
  return 0;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_canAccess(bool *result, const NVPTXContext *context,
                                const NVPTXContext *peer) {
  if (!result || !context || !peer)
    return errf("canAccess: null argument");
  NVPTXContext *root = rootContext(context);
  NVPTXContext *peerRoot = rootContext(peer);
  *result = false;
  if (isCPUContext(root) || isCPUContext(peerRoot))
    return nullptr;
  if (root->device == peerRoot->device)
    return nullptr;
  int canAccess = 0;
  CUresult status =
      cuDeviceCanAccessPeer(&canAccess, root->device, peerRoot->device);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDeviceCanAccessPeer", status);
  *result = canAccess != 0;
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_enablePeerAccess(
    const NVPTXContext *context, const NVPTXContext *peer) {
  if (!context || !peer)
    return errf("enablePeerAccess: null context");
  NVPTXContext *root = rootContext(context);
  NVPTXContext *peerRoot = rootContext(peer);
  if (isCPUContext(root) || isCPUContext(peerRoot))
    return errf("enablePeerAccess is only supported between CUDA contexts");
  if (root->device == peerRoot->device)
    return errf("enablePeerAccess: a device cannot be its own peer");

  int canAccess = 0;
  CUresult status =
      cuDeviceCanAccessPeer(&canAccess, root->device, peerRoot->device);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDeviceCanAccessPeer", status);
  if (!canAccess)
    return errf("CUDA device %d cannot access peer device %d", root->id,
                peerRoot->id);
  if (const char *error = setCurrent(root))
    return error;
  status = cuCtxEnablePeerAccess(peerRoot->context, 0);
  constexpr CUresult CUDA_ERROR_PEER_ACCESS_ALREADY_ENABLED = 704;
  if (status != CUDA_SUCCESS &&
      status != CUDA_ERROR_PEER_ACCESS_ALREADY_ENABLED)
    return cudaError("cuCtxEnablePeerAccess", status);
  {
    std::lock_guard<std::mutex> lock(peerAccessMutex);
    markPeerAccessEnabledLocked(root->device, peerRoot->device);
  }
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_enableAllPeerAccess() {
  if (!loadCUDA())
    return errf("%s", cudaLoadError);
  int count = 0;
  CUresult status = cuDeviceGetCount(&count);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDeviceGetCount", status);
  if (count < 2)
    return nullptr;

  CUcontext previous = nullptr;
  status = cuCtxGetCurrent(&previous);
  if (status != CUDA_SUCCESS)
    return cudaError("cuCtxGetCurrent", status);

  std::lock_guard<std::mutex> lock(peerAccessMutex);
  std::vector<CUdevice> devices(static_cast<size_t>(count));
  std::vector<CUcontext> contexts(static_cast<size_t>(count));
  for (int ordinal = 0; ordinal < count; ++ordinal) {
    if (const char *error = retainedPeerContextLocked(
            ordinal, devices[static_cast<size_t>(ordinal)],
            contexts[static_cast<size_t>(ordinal)])) {
      cuCtxSetCurrent(previous);
      return error;
    }
  }

  constexpr CUresult CUDA_ERROR_PEER_ACCESS_ALREADY_ENABLED = 704;
  for (int ordinal = 0; ordinal < count; ++ordinal) {
    for (int peerOrdinal = 0; peerOrdinal < count; ++peerOrdinal) {
      if (ordinal == peerOrdinal)
        continue;
      int canAccess = 0;
      status = cuDeviceCanAccessPeer(
          &canAccess, devices[static_cast<size_t>(ordinal)],
          devices[static_cast<size_t>(peerOrdinal)]);
      if (status != CUDA_SUCCESS || !canAccess) {
        cuCtxSetCurrent(previous);
        if (status != CUDA_SUCCESS)
          return cudaError("cuDeviceCanAccessPeer", status);
        return errf("CUDA device %d cannot access peer device %d", ordinal,
                    peerOrdinal);
      }
      status = cuCtxSetCurrent(contexts[static_cast<size_t>(ordinal)]);
      if (status == CUDA_SUCCESS)
        status = cuCtxEnablePeerAccess(
            contexts[static_cast<size_t>(peerOrdinal)], 0);
      if (status != CUDA_SUCCESS &&
          status != CUDA_ERROR_PEER_ACCESS_ALREADY_ENABLED) {
        cuCtxSetCurrent(previous);
        return cudaError("cuCtxEnablePeerAccess", status);
      }
      markPeerAccessEnabledLocked(devices[static_cast<size_t>(ordinal)],
                                  devices[static_cast<size_t>(peerOrdinal)]);
    }
  }
  status = cuCtxSetCurrent(previous);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuCtxSetCurrent", status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_allPeerAccessEnabled(bool *result) {
  if (!result)
    return errf("allPeerAccessEnabled: result is null");
  *result = false;
  if (!loadCUDA())
    return errf("%s", cudaLoadError);
  int count = 0;
  CUresult status = cuDeviceGetCount(&count);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDeviceGetCount", status);
  if (count < 2)
    return nullptr;

  std::vector<CUdevice> devices(static_cast<size_t>(count));
  for (int ordinal = 0; ordinal < count; ++ordinal) {
    status = cuDeviceGet(&devices[static_cast<size_t>(ordinal)], ordinal);
    if (status != CUDA_SUCCESS)
      return cudaError("cuDeviceGet", status);
  }
  std::lock_guard<std::mutex> lock(peerAccessMutex);
  for (int ordinal = 0; ordinal < count; ++ordinal)
    for (int peerOrdinal = 0; peerOrdinal < count; ++peerOrdinal)
      if (ordinal != peerOrdinal &&
          !peerAccessEnabledLocked(devices[static_cast<size_t>(ordinal)],
                                   devices[static_cast<size_t>(peerOrdinal)]))
        return nullptr;
  *result = true;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_supportsMulticast(bool *result,
                                        const NVPTXContext *context) {
  if (!result || !context)
    return errf("supportsMulticast: null argument");
  // CUDA multicast objects require the fabric/NVSwitch virtual-memory APIs.
  // This Windows driver-only backend does not expose them yet.
  *result = false;
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceMulticastBuffer_allocate(
    void **result, size_t, const NVPTXContext **, size_t, size_t) {
  if (result)
    *result = nullptr;
  return errf("CUDA multicast memory is not supported by nvptxrt on Windows");
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceMulticastBuffer_unicastBufferFor(
    const NVPTXBuffer **result, void **devicePointer, const void *,
    const NVPTXContext *) {
  if (result)
    *result = nullptr;
  if (devicePointer)
    *devicePointer = nullptr;
  return errf("CUDA multicast memory is not supported by nvptxrt on Windows");
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceMulticastBuffer_multicastBufferFor(
    const NVPTXBuffer **result, void **devicePointer, const void *,
    const NVPTXContext *) {
  if (result)
    *result = nullptr;
  if (devicePointer)
    *devicePointer = nullptr;
  return errf("CUDA multicast memory is not supported by nvptxrt on Windows");
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_setAsCurrent(const NVPTXContext *context) {
  return setCurrent(context);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_startMetalTraceCapture(
    const NVPTXContext *context, const char *path) {
  (void)context;
  (void)path;
  return errf("Metal trace capture is unavailable on an NVIDIA context");
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_stopMetalTraceCapture(const NVPTXContext *context) {
  (void)context;
  return errf("no Metal capture is in progress on an NVIDIA context");
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_setMetalPrintEnabled(
    const NVPTXContext *context, bool enabled) {
  (void)context;
  (void)enabled;
  return errf("Metal GPU printing is unavailable on an NVIDIA context");
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_enqueueHostFunction(
    const NVPTXContext *context, CUhostFn resume, CUhostFn destroy,
    void *handle) {
  if (!isCPUContext(context) || !resume || !destroy || !handle)
    return errf("enqueueHostFunction: invalid CPU coroutine");
  return enqueueCPUTask(context, [resume, destroy, handle]() {
    resume(handle);
    destroy(handle);
  });
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_enqueueHostFunctionRange(
    const NVPTXContext *context, CUhostFn resume, CUhostFn destroy,
    void *const *handles, int64_t count) {
  if (!isCPUContext(context) || !resume || !destroy || count < 0 ||
      (count && !handles))
    return errf("enqueueHostFunctionRange: invalid CPU coroutine range");
  if (count == 0)
    return nullptr;

  auto ownedHandles = std::make_shared<std::vector<void *>>(
      handles, handles + static_cast<size_t>(count));
  const size_t taskCount =
      std::min(static_cast<size_t>(count), cpuWorkerPool().size());
  for (size_t task = 0; task < taskCount; ++task) {
    const size_t begin = static_cast<size_t>(count) * task / taskCount;
    const size_t end = static_cast<size_t>(count) * (task + 1) / taskCount;
    if (const char *error = enqueueCPUTask(
            context, [resume, destroy, ownedHandles, begin, end]() {
              for (size_t index = begin; index < end; ++index) {
                void *handle = (*ownedHandles)[index];
                resume(handle);
                destroy(handle);
              }
            }))
      return error;
  }
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_synchronize(const NVPTXContext *context) {
  if (context && context->recordingBuilder)
    return errf("synchronize is unavailable while recording a device graph");
  if (isCPUContext(context))
    return synchronizeCPU(context);
  if (const char *error = setCurrent(context))
    return error;
  CUresult status = cuStreamSynchronize(activeStream(context));
  if (status == CUDA_SUCCESS && context && context->defaultStream)
    drainStreamCompletionFlags(context->defaultStream);
  if (status != CUDA_SUCCESS)
    return cudaError("cuStreamSynchronize", status);
  return takePendingError(context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_isCompatible(const NVPTXContext *context) {
  if (!context)
    return errf("isCompatible: null context");
  if (isCPUContext(context))
    return nullptr;
  if (!loadCUDA())
    return errf("%s", cudaLoadError);
  return setCurrent(context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_runHealthcheck(NVPTXContext *context) {
  if (!context)
    return errf("runHealthcheck: null context");
  if (isCPUContext(context)) {
    constexpr uint32_t expected = 0x4d4f4a4f;
    uint32_t actual = 0;
    memcpy(&actual, &expected, sizeof(expected));
    return actual == expected ? nullptr
                              : errf("CPU healthcheck returned corrupt data");
  }
  if (const char *error = setCurrent(context))
    return error;

  constexpr uint32_t expected = 0x4d4f4a4f;
  uint32_t actual = 0;
  CUdeviceptr allocation = 0;
  CUresult status = cuMemAlloc(&allocation, sizeof(expected));
  if (status == CUDA_SUCCESS)
    status = cuMemcpyHtoD(allocation, &expected, sizeof(expected));
  if (status == CUDA_SUCCESS)
    status = cuMemcpyDtoH(&actual, allocation, sizeof(actual));
  CUresult freeStatus =
      allocation ? cuMemFree(allocation) : static_cast<CUresult>(CUDA_SUCCESS);
  if (status != CUDA_SUCCESS)
    return cudaError("CUDA healthcheck transfer", status);
  if (freeStatus != CUDA_SUCCESS)
    return cudaError("CUDA healthcheck free", freeStatus);
  return actual == expected ? nullptr
                            : errf("CUDA healthcheck returned corrupt data");
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContextScope_create(const NVPTXContextScope **result,
                                  const NVPTXContext *context) {
  if (!result || !context)
    return errf("DeviceContextScope_create: null argument");
  if (!isCPUContext(context)) {
    CUresult status = cuCtxPushCurrent(context->context);
    if (status != CUDA_SUCCESS)
      return cudaError("cuCtxPushCurrent", status);
  }
  auto *scope = new NVPTXContextScope();
  scope->context = const_cast<NVPTXContext *>(context);
  retainContext(context);
  *result = scope;
  return nullptr;
}

NVPTXRT_EXPORT void
AsyncRT_DeviceContextScope_release(const NVPTXContextScope *scope) {
  if (!scope)
    return;
  auto *mutableScope = const_cast<NVPTXContextScope *>(scope);
  NVPTXContext *context = mutableScope->context;
  if (!isCPUContext(context)) {
    CUcontext popped = nullptr;
    cuCtxPopCurrent(&popped);
  }
  delete mutableScope;
  releaseContext(context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_cuda_context(CUcontext *result,
                                   const NVPTXContext *context) {
  if (!result || !context)
    return errf("cuda_context: null argument");
  if (isCPUContext(context))
    return errf("cuda_context is unavailable on a CPU DeviceContext");
  *result = context->context;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_cuda_current_context(CUcontext *result) {
  if (!result)
    return errf("cuda_current_context: null result");
  if (!loadCUDA())
    return errf("%s", cudaLoadError);
  CUresult status = cuCtxGetCurrent(result);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuCtxGetCurrent", status);
}

NVPTXRT_EXPORT void AsyncRT_DeviceContext_strfree(const char *pointer) {
  free(const_cast<char *>(pointer));
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_getMemoryInfo(const NVPTXContext *context,
                                    size_t *freeMemory, size_t *totalMemory) {
  if (isCPUContext(context)) {
    MEMORYSTATUSEX status = {};
    status.dwLength = sizeof(status);
    if (!GlobalMemoryStatusEx(&status))
      return errf("GlobalMemoryStatusEx failed: Windows error %lu",
                  GetLastError());
    if (freeMemory)
      *freeMemory = static_cast<size_t>(status.ullAvailPhys);
    if (totalMemory)
      *totalMemory = static_cast<size_t>(status.ullTotalPhys);
    return nullptr;
  }
  if (const char *error = setCurrent(context))
    return error;
  CUresult status = cuMemGetInfo(freeMemory, totalMemory);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuMemGetInfo", status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_maxSingleAllocationSize(size_t *result,
                                              const NVPTXContext *context) {
  if (!context)
    return errf("maxSingleAllocationSize: null context");
  if (isCPUContext(context)) {
    size_t freeMemory = 0;
    if (const char *error =
            AsyncRT_DeviceContext_getMemoryInfo(context, &freeMemory, nullptr))
      return error;
    if (result)
      *result = freeMemory;
    return nullptr;
  }
  size_t total = 0;
  CUresult status = cuDeviceTotalMem(&total, context->device);
  if (status != CUDA_SUCCESS)
    return cudaError("cuDeviceTotalMem", status);
  if (result)
    *result = total;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_computeCapability(int32_t *result,
                                        const NVPTXContext *context) {
  if (!context)
    return errf("computeCapability: null context");
  if (result)
    *result = isCPUContext(context) ? 0 : context->computeCapability;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_getAttribute(int *result, const NVPTXContext *context,
                                   int attribute) {
  if (!context)
    return errf("getAttribute: null context");
  if (isCPUContext(context))
    return errf("CUDA device attributes are unavailable on a CPU context");
  CUresult status = cuDeviceGetAttribute(result, attribute, context->device);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuDeviceGetAttribute", status);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_createBuffer_async(
    const NVPTXBuffer **result, void **devicePointer,
    const NVPTXContext *context, size_t length, size_t elementSize) {
  if (!context)
    return errf("createBuffer_async: null context");
  if (elementSize && length > std::numeric_limits<size_t>::max() / elementSize)
    return errf("createBuffer_async: allocation size overflow");
  size_t bytes = length * elementSize;
  if (isCPUContext(context)) {
    void *allocation = malloc(std::max<size_t>(bytes, 1));
    if (!allocation)
      return errf("CPU buffer allocation failed for %zu bytes", bytes);
    auto *buffer = new NVPTXBuffer();
    buffer->host = allocation;
    buffer->bytes = bytes;
    buffer->context = const_cast<NVPTXContext *>(context);
    retainContext(context);
    registerHostBuffer(buffer);
    if (result)
      *result = buffer;
    if (devicePointer)
      *devicePointer = allocation;
    return nullptr;
  }
  if (const char *error = setCurrent(context))
    return error;

  CUdeviceptr allocation = 0;
  CUresult status = cuMemAlloc(&allocation, std::max<size_t>(bytes, 1));
  if (status != CUDA_SUCCESS)
    return cudaError("cuMemAlloc", status);

  auto *buffer = new NVPTXBuffer();
  buffer->device = allocation;
  buffer->bytes = bytes;
  buffer->context = const_cast<NVPTXContext *>(context);
  AsyncRT_DeviceContext_retain(context);
  registerDeviceBuffer(buffer);
  if (result)
    *result = buffer;
  if (devicePointer)
    *devicePointer =
        reinterpret_cast<void *>(static_cast<uintptr_t>(allocation));
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_createHostBuffer(
    const NVPTXBuffer **result, void **devicePointer,
    const NVPTXContext *context, size_t length, size_t elementSize) {
  if (!context)
    return errf("createHostBuffer: null context");
  if (elementSize && length > std::numeric_limits<size_t>::max() / elementSize)
    return errf("createHostBuffer: allocation size overflow");
  size_t bytes = length * elementSize;
  if (isCPUContext(context)) {
    void *allocation = malloc(std::max<size_t>(bytes, 1));
    if (!allocation)
      return errf("CPU host-buffer allocation failed for %zu bytes", bytes);
    auto *buffer = new NVPTXBuffer();
    buffer->host = allocation;
    buffer->bytes = bytes;
    buffer->context = const_cast<NVPTXContext *>(context);
    retainContext(context);
    registerHostBuffer(buffer);
    if (result)
      *result = buffer;
    if (devicePointer)
      *devicePointer = allocation;
    return nullptr;
  }
  if (const char *error = setCurrent(context))
    return error;
  void *allocation = nullptr;
  CUresult status = cuMemHostAlloc(&allocation, std::max<size_t>(bytes, 1), 0);
  if (status != CUDA_SUCCESS)
    return cudaError("cuMemHostAlloc", status);

  auto *buffer = new NVPTXBuffer();
  buffer->host = allocation;
  buffer->bytes = bytes;
  buffer->context = const_cast<NVPTXContext *>(context);
  buffer->hostPinned = true;
  AsyncRT_DeviceContext_retain(context);
  registerHostBuffer(buffer);
  if (result)
    *result = buffer;
  if (devicePointer)
    *devicePointer = allocation;
  return nullptr;
}

NVPTXRT_EXPORT void AsyncRT_DeviceContext_createBuffer_owning(
    const NVPTXBuffer **result, const NVPTXContext *context,
    void *devicePointer, size_t length, size_t elementSize, bool owning) {
  auto *buffer = new NVPTXBuffer();
  if (isCPUContext(context))
    buffer->host = devicePointer;
  else
    buffer->device =
        static_cast<CUdeviceptr>(reinterpret_cast<uintptr_t>(devicePointer));
  buffer->bytes = length * elementSize;
  buffer->context = const_cast<NVPTXContext *>(context);
  buffer->owning = owning;
  AsyncRT_DeviceContext_retain(context);
  if (buffer->host)
    registerHostBuffer(buffer);
  else
    registerDeviceBuffer(buffer);
  if (result)
    *result = buffer;
}

NVPTXRT_EXPORT int64_t
AsyncRT_DeviceBuffer_bytesize(const NVPTXBuffer *buffer) {
  return buffer ? static_cast<int64_t>(buffer->bytes) : 0;
}

NVPTXRT_EXPORT void AsyncRT_DeviceBuffer_retain(const NVPTXBuffer *buffer) {
  if (buffer)
    const_cast<NVPTXBuffer *>(buffer)->references.fetch_add(1);
}

NVPTXRT_EXPORT void AsyncRT_DeviceBuffer_release(const NVPTXBuffer *buffer);

NVPTXRT_EXPORT const char *AsyncRT_DeviceBuffer_createSubBuffer(
    const NVPTXBuffer **result, void **devicePointer, const NVPTXBuffer *buffer,
    size_t offset, size_t length, size_t elementSize) {
  if (!result || !buffer)
    return errf("createSubBuffer: null argument");
  if (elementSize &&
      (offset > std::numeric_limits<size_t>::max() / elementSize ||
       length > std::numeric_limits<size_t>::max() / elementSize))
    return errf("createSubBuffer: byte range overflow");
  const size_t byteOffset = offset * elementSize;
  const size_t bytes = length * elementSize;
  if (byteOffset > buffer->bytes || bytes > buffer->bytes - byteOffset)
    return errf("createSubBuffer: range [%zu, %zu) exceeds %zu-byte buffer",
                byteOffset, byteOffset + bytes, buffer->bytes);

  auto *subBuffer = new NVPTXBuffer();
  subBuffer->bytes = bytes;
  subBuffer->context = buffer->context;
  subBuffer->parent = const_cast<NVPTXBuffer *>(buffer);
  subBuffer->owning = false;
  if (buffer->host) {
    subBuffer->host = static_cast<unsigned char *>(buffer->host) + byteOffset;
    subBuffer->hostPinned = buffer->hostPinned;
    if (devicePointer)
      *devicePointer = subBuffer->host;
  } else {
    subBuffer->device = buffer->device + byteOffset;
    if (devicePointer)
      *devicePointer =
          reinterpret_cast<void *>(static_cast<uintptr_t>(subBuffer->device));
  }
  AsyncRT_DeviceBuffer_retain(buffer);
  retainContext(subBuffer->context);
  if (subBuffer->host)
    registerHostBuffer(subBuffer);
  *result = subBuffer;
  return nullptr;
}

NVPTXRT_EXPORT NVPTXContext *
AsyncRT_DeviceBuffer_context(const NVPTXBuffer *buffer) {
  return buffer ? buffer->context : nullptr;
}

NVPTXRT_EXPORT void AsyncRT_DeviceBuffer_release(const NVPTXBuffer *buffer) {
  if (!buffer)
    return;
  auto *mutableBuffer = const_cast<NVPTXBuffer *>(buffer);
  const int previousReferences = mutableBuffer->references.fetch_sub(1);
  if (previousReferences != 1)
    return;
  NVPTXContext *context = mutableBuffer->context;
  NVPTXBuffer *parent = mutableBuffer->parent;
  unregisterHostBuffer(mutableBuffer);
  unregisterDeviceBuffer(mutableBuffer);
  if (mutableBuffer->host && mutableBuffer->owning) {
    if (mutableBuffer->hostPinned) {
      CUresult status = cuCtxSetCurrent(context->context);
      if (status == CUDA_SUCCESS)
        status = cuMemFreeHost(mutableBuffer->host);
      recordPendingCudaError(context, "cuMemFreeHost", status);
    } else {
      free(mutableBuffer->host);
    }
  } else if (mutableBuffer->device && mutableBuffer->owning) {
    CUresult status = cuCtxSetCurrent(context->context);
    if (status == CUDA_SUCCESS)
      status = cuMemFree(mutableBuffer->device);
    recordPendingCudaError(context, "cuMemFree", status);
  }
  delete mutableBuffer;
  if (parent)
    AsyncRT_DeviceBuffer_release(parent);
  AsyncRT_DeviceContext_release(context);
}

NVPTXRT_EXPORT NVPTXAsyncValue *
AsyncRT_AsyncValue_createFromDeviceBuffer(NVPTXBuffer *buffer) {
  if (!buffer)
    return nullptr;
  auto *value = new NVPTXAsyncValue();
  value->buffer = buffer;
  return value;
}

NVPTXRT_EXPORT void AsyncRT_AsyncValue_retain(NVPTXAsyncValue *value) {
  if (value && value->magic == NVPTX_ASYNC_VALUE_MAGIC)
    value->references.fetch_add(1);
}

NVPTXRT_EXPORT void AsyncRT_AsyncValue_release(NVPTXAsyncValue *value) {
  releaseAsyncValue(value);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceBuffer_reassignOwnershipTo(const NVPTXBuffer *buffer,
                                         const NVPTXContext *context) {
  if (!buffer || !context)
    return errf("reassignOwnershipTo: null argument");
  auto *mutableBuffer = const_cast<NVPTXBuffer *>(buffer);
  NVPTXContext *oldContext = mutableBuffer->context;
  if (oldContext == context)
    return nullptr;
  if (const char *error = waitForContext(context, oldContext))
    return error;
  retainContext(context);
  mutableBuffer->context = const_cast<NVPTXContext *>(context);
  releaseContext(oldContext);
  return nullptr;
}

NVPTXRT_EXPORT void
AsyncRT_DeviceBuffer_release_ptr(const NVPTXBuffer *buffer) {
  if (buffer)
    const_cast<NVPTXBuffer *>(buffer)->owning = false;
  AsyncRT_DeviceBuffer_release(buffer);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_HtoD_async(const NVPTXContext *context,
                                 const NVPTXBuffer *destination,
                                 const void *source) {
  if (!destination || !source)
    return errf("HtoD_async: null argument");
  if (context && context->recordingBuilder)
    return recordMemOp(
        const_cast<NVPTXContext *>(context),
        [destination, source](NVPTXGraphBuilder *builder, const int32_t *deps,
                              int64_t count) {
          return AsyncRT_DeviceGraphBuilder_addCopyHostToDevice(
              builder, const_cast<NVPTXBuffer *>(destination), source, deps,
              count);
        });
  if (const char *error = setCurrent(context))
    return error;
  if (destination->host) {
    memcpy(destination->host, source, destination->bytes);
    return nullptr;
  }
  CUresult status = cuMemcpyHtoDAsync(
      destination->device, source, destination->bytes, activeStream(context));
  if (status == CUDA_SUCCESS)
    return nullptr;
  // The CUDA driver requires page-locked memory for genuinely asynchronous
  // raw-pointer transfers.  Span storage is commonly pageable, so retain the
  // ABI's correctness with a synchronous fallback in that case. HostBuffer
  // transfers take the pinned path in DtoD_async below.
  status = cuMemcpyHtoD(destination->device, source, destination->bytes);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuMemcpyHtoD", status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_DtoH_async(const NVPTXContext *context, void *destination,
                                 const NVPTXBuffer *source) {
  if (!destination || !source)
    return errf("DtoH_async: null argument");
  if (context && context->recordingBuilder)
    return recordMemOp(
        const_cast<NVPTXContext *>(context),
        [destination, source](NVPTXGraphBuilder *builder, const int32_t *deps,
                              int64_t count) {
          return AsyncRT_DeviceGraphBuilder_addCopyDeviceToHost(
              builder, destination, const_cast<NVPTXBuffer *>(source), deps,
              count);
        });
  if (const char *error = setCurrent(context))
    return error;
  if (source->host) {
    memcpy(destination, source->host, source->bytes);
    return nullptr;
  }
  CUresult status = cuMemcpyDtoHAsync(destination, source->device,
                                      source->bytes, activeStream(context));
  if (status == CUDA_SUCCESS)
    return nullptr;
  status = cuMemcpyDtoH(destination, source->device, source->bytes);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuMemcpyDtoH", status);
}

static const char *copyBuffersAsync(const NVPTXContext *context,
                                    const NVPTXBuffer *destination,
                                    const NVPTXBuffer *source,
                                    bool crossStreamSync) {
  if (!destination || !source)
    return errf("DtoD_async: null argument");
  // Recording a buffer-to-buffer copy makes the cross-stream question moot:
  // there is no live stream to synchronise, and the replayed node's
  // dependencies say everything about ordering. Both DtoD entry points share
  // this branch, so the no-cross-stream-sync spelling records identically.
  if (context && context->recordingBuilder)
    return recordMemOp(
        const_cast<NVPTXContext *>(context),
        [destination, source](NVPTXGraphBuilder *builder, const int32_t *deps,
                              int64_t count) {
          return AsyncRT_DeviceGraphBuilder_addCopyDeviceToDevice(
              builder, const_cast<NVPTXBuffer *>(destination),
              const_cast<NVPTXBuffer *>(source), deps, count);
        });
  if (crossStreamSync) {
    if (const char *error = waitForContext(context, source->context))
      return error;
    if (destination->context != source->context)
      if (const char *error = waitForContext(context, destination->context))
        return error;
  }
  if (const char *error = setCurrent(context))
    return error;
  size_t bytes = std::min(destination->bytes, source->bytes);
  if (destination->host && source->host) {
    if (isCPUContext(source->context)) {
      if (rootContext(source->context) != rootContext(context))
        if (const char *error = synchronizeCPU(source->context))
          return error;
    } else {
      if (const char *error = setCurrent(source->context))
        return error;
      CUresult syncStatus =
          cuStreamSynchronize(activeStream(source->context));
      if (syncStatus != CUDA_SUCCESS)
        return cudaError("cuStreamSynchronize", syncStatus);
    }
    memcpy(destination->host, source->host, bytes);
    return nullptr;
  }

  if (isCPUContext(context) && source->host) {
    if (const char *error = synchronizeCPU(source->context))
      return error;
    if (const char *error = setCurrent(destination->context))
      return error;
    CUresult status =
        cuMemcpyHtoD(destination->device, source->host, bytes);
    return status == CUDA_SUCCESS ? nullptr
                                  : cudaError("cuMemcpyHtoD", status);
  }
  if (isCPUContext(context) && destination->host) {
    if (const char *error = setCurrent(source->context))
      return error;
    CUresult status =
        cuMemcpyDtoH(destination->host, source->device, bytes);
    return status == CUDA_SUCCESS ? nullptr
                                  : cudaError("cuMemcpyDtoH", status);
  }

  CUresult status = CUDA_SUCCESS;
  const char *operation = nullptr;
  if (source->host) {
    operation = "cuMemcpyHtoDAsync";
    status = cuMemcpyHtoDAsync(destination->device, source->host, bytes,
                               activeStream(context));
  } else if (destination->host) {
    operation = "cuMemcpyDtoHAsync";
    status = cuMemcpyDtoHAsync(destination->host, source->device, bytes,
                               activeStream(context));
  } else {
    NVPTXContext *destinationContext = rootContext(destination->context);
    NVPTXContext *sourceContext = rootContext(source->context);
    if (destinationContext->context != sourceContext->context) {
      int canAccessPeer = 0;
      CUresult peerStatus = cuDeviceCanAccessPeer(
          &canAccessPeer, destinationContext->device, sourceContext->device);
      if (peerStatus == CUDA_SUCCESS && canAccessPeer) {
        if (const char *error = setCurrent(destinationContext))
          return error;
        peerStatus = cuCtxEnablePeerAccess(sourceContext->context, 0);
        (void)peerStatus;
      }
      if (const char *error = setCurrent(context))
        return error;
      operation = "cuMemcpyPeerAsync";
      status = cuMemcpyPeerAsync(
          destination->device, destinationContext->context, source->device,
          sourceContext->context, bytes, activeStream(context));
      if (status != CUDA_SUCCESS) {
        // Some Windows/WDDM combinations expose multiple devices without a
        // peer path. Preserve correctness with a synchronous pinned-host
        // staging copy when the driver rejects the direct transfer.
        std::vector<unsigned char> staging(bytes);
        if (const char *error = setCurrent(sourceContext))
          return error;
        CUresult sourceStatus =
            cuStreamSynchronize(activeStream(source->context));
        if (sourceStatus == CUDA_SUCCESS)
          sourceStatus = cuMemcpyDtoH(staging.data(), source->device, bytes);
        if (sourceStatus != CUDA_SUCCESS)
          return cudaError("cross-device cuMemcpyDtoH", sourceStatus);
        if (const char *error = setCurrent(destinationContext))
          return error;
        CUresult destinationStatus =
            cuMemcpyHtoD(destination->device, staging.data(), bytes);
        return destinationStatus == CUDA_SUCCESS
                   ? nullptr
                   : cudaError("cross-device cuMemcpyHtoD", destinationStatus);
      }
    } else {
      operation = "cuMemcpyDtoDAsync";
      status = cuMemcpyDtoDAsync(destination->device, source->device, bytes,
                                 activeStream(context));
    }
  }
  return status == CUDA_SUCCESS ? nullptr : cudaError(operation, status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_DtoD_async(const NVPTXContext *context,
                                 const NVPTXBuffer *destination,
                                 const NVPTXBuffer *source) {
  return copyBuffersAsync(context, destination, source, true);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_DtoD_async_no_cross_stream_sync(
    const NVPTXContext *context, const NVPTXBuffer *destination,
    const NVPTXBuffer *source) {
  return copyBuffersAsync(context, destination, source, false);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_setMemory_async(const NVPTXContext *context,
                                      const NVPTXBuffer *destination,
                                      uint64_t value, size_t valueSize) {
  if (!destination || valueSize == 0)
    return errf("setMemory_async: invalid argument");
  if (context && context->recordingBuilder)
    return recordMemOp(
        const_cast<NVPTXContext *>(context),
        [destination, value, valueSize](NVPTXGraphBuilder *builder,
                                        const int32_t *deps, int64_t count) {
          return AsyncRT_DeviceGraphBuilder_addSetMemory(
              builder, const_cast<NVPTXBuffer *>(destination), value,
              valueSize, deps, count);
        });
  if (const char *error = setCurrent(context))
    return error;

  if (destination->host) {
    auto *bytes = static_cast<unsigned char *>(destination->host);
    for (size_t offset = 0; offset < destination->bytes; offset += valueSize)
      memcpy(bytes + offset, &value,
             std::min(valueSize, destination->bytes - offset));
    return nullptr;
  }

  CUresult status = CUDA_SUCCESS;
  if (valueSize == 1) {
    status =
        cuMemsetD8Async(destination->device, static_cast<unsigned char>(value),
                        destination->bytes, activeStream(context));
  } else if (valueSize == 2 && destination->bytes % 2 == 0) {
    status = cuMemsetD16Async(destination->device,
                              static_cast<unsigned short>(value),
                              destination->bytes / 2, activeStream(context));
  } else if (valueSize == 4 && destination->bytes % 4 == 0) {
    status =
        cuMemsetD32Async(destination->device, static_cast<unsigned int>(value),
                         destination->bytes / 4, activeStream(context));
  } else if (valueSize == 8 && destination->bytes % 8 == 0) {
    // CUDA has no 64-bit linear memset.  Fill the low and high halves as two
    // strided 32-bit planes so arbitrary Int64/Float64 bit patterns remain
    // asynchronous and ordered on the context's active stream.
    const size_t elements = destination->bytes / 8;
    status = cuMemsetD2D32Async(
        destination->device, /*destinationPitch=*/8,
        static_cast<unsigned int>(value), /*width=*/1, elements,
        activeStream(context));
    if (status == CUDA_SUCCESS)
      status = cuMemsetD2D32Async(
          destination->device + 4, /*destinationPitch=*/8,
          static_cast<unsigned int>(value >> 32), /*width=*/1, elements,
          activeStream(context));
  } else {
    std::vector<unsigned char> staging(destination->bytes);
    for (size_t offset = 0; offset < staging.size(); offset += valueSize)
      memcpy(staging.data() + offset, &value,
             std::min(valueSize, staging.size() - offset));
    status = cuMemcpyHtoD(destination->device, staging.data(), staging.size());
  }
  return status == CUDA_SUCCESS ? nullptr : cudaError("CUDA memset", status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_createStream(const NVPTXStream **result, int priority,
                                   const NVPTXContext *context) {
  if (!result || !context)
    return errf("createStream: null argument");
  if (const char *error = setCurrent(context))
    return error;
  CUstream cudaStream = nullptr;
  CUresult status =
      cuStreamCreateWithPriority(&cudaStream, CU_STREAM_NON_BLOCKING, priority);
  if (status != CUDA_SUCCESS)
    return cudaError("cuStreamCreateWithPriority", status);
  NVPTXContext *root = rootContext(context);
  auto *stream = new NVPTXStream();
  stream->stream = cudaStream;
  stream->context = root;
  stream->owning = true;
  {
    std::lock_guard<std::mutex> lock(root->mutex);
    root->streams.push_back(stream);
  }
  retainContext(root);
  *result = stream;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_createExternalStream(const NVPTXStream **result,
                                           void *externalStream,
                                           const NVPTXContext *context) {
  if (!result || !context)
    return errf("createExternalStream: null argument");
  NVPTXContext *root = rootContext(context);
  auto *stream = new NVPTXStream();
  stream->stream = static_cast<CUstream>(externalStream);
  stream->context = root;
  stream->owning = false;
  {
    std::lock_guard<std::mutex> lock(root->mutex);
    root->streams.push_back(stream);
  }
  retainContext(root);
  *result = stream;
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_streamPriorityRange(
    int *leastPriority, int *greatestPriority, const NVPTXContext *context) {
  if (!leastPriority || !greatestPriority)
    return errf("streamPriorityRange: null result");
  if (const char *error = setCurrent(context))
    return error;
  CUresult status =
      cuCtxGetStreamPriorityRange(leastPriority, greatestPriority);
  return status == CUDA_SUCCESS
             ? nullptr
             : cudaError("cuCtxGetStreamPriorityRange", status);
}

NVPTXRT_EXPORT int
AsyncRT_DeviceContext_numStreams(const NVPTXContext *context) {
  NVPTXContext *root = rootContext(context);
  if (!root)
    return 0;
  std::lock_guard<std::mutex> lock(root->mutex);
  return static_cast<int>(root->streams.size());
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_selectStream(const NVPTXContext **result,
                                   const NVPTXContext *context,
                                   unsigned int streamId) {
  if (!result || !context)
    return errf("selectStream: null argument");
  NVPTXContext *root = rootContext(context);
  NVPTXStream *selected = nullptr;
  {
    std::lock_guard<std::mutex> lock(root->mutex);
    if (streamId >= root->streams.size())
      return errf("selectStream: stream %u is unavailable (stream count: %zu)",
                  streamId, root->streams.size());
    selected = root->streams[streamId];
  }

  auto *view = new NVPTXContext();
  view->root = root;
  view->device = root->device;
  view->context = root->context;
  view->id = root->id;
  view->computeCapability = root->computeCapability;
  view->driverVersion = root->driverVersion;
  view->name = root->name;
  view->arch = root->arch;
  view->api = root->api;
  view->defaultStream = selected;
  retainContext(root);
  *result = view;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_stream(const NVPTXStream **result,
                             const NVPTXContext *context) {
  if (!context)
    return errf("stream: null context");
  if (!result)
    return errf("stream: null result");
  if (context->recordingBuilder) {
    auto *view = new NVPTXStream();
    view->stream = activeStream(context);
    view->context = const_cast<NVPTXContext *>(context);
    view->transient = true;
    retainContext(context);
    *result = view;
    return nullptr;
  }
  auto *stream = context->defaultStream;
  stream->references.fetch_add(1);
  retainContext(stream->context);
  *result = stream;
  return nullptr;
}

NVPTXRT_EXPORT void AsyncRT_DeviceStream_retain(const NVPTXStream *stream) {
  if (stream) {
    const_cast<NVPTXStream *>(stream)->references.fetch_add(1);
    retainContext(stream->context);
  }
}

NVPTXRT_EXPORT void AsyncRT_DeviceStream_release(const NVPTXStream *stream) {
  if (!stream)
    return;
  auto *mutableStream = const_cast<NVPTXStream *>(stream);
  int oldReferences = mutableStream->references.fetch_sub(1);
  if (oldReferences <= 0) {
    mutableStream->references.fetch_add(1);
    return;
  }
  NVPTXContext *context = mutableStream->context;
  if (mutableStream->transient && oldReferences == 1)
    delete mutableStream;
  releaseContext(context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceStream_synchronize(const NVPTXStream *stream) {
  if (!stream)
    return errf("stream synchronize: null stream");
  if (stream->context && stream->context->recordingBuilder)
    return errf("stream synchronize is unavailable while recording a device graph");
  if (const char *error = setCurrent(stream->context))
    return error;
  CUresult status = cuStreamSynchronize(stream->stream);
  if (status == CUDA_SUCCESS)
    drainStreamCompletionFlags(const_cast<NVPTXStream *>(stream));
  if (status != CUDA_SUCCESS)
    return cudaError("cuStreamSynchronize", status);
  return takePendingError(stream->context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceStream_cuda_stream(CUstream *result, const NVPTXStream *stream) {
  if (!result || !stream)
    return errf("cuda_stream: null argument");
  *result = stream->stream;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_eventCreate(const NVPTXEvent **result,
                                  const NVPTXContext *context,
                                  unsigned int flags) {
  if (!result || !context)
    return errf("eventCreate: null argument");
  if (const char *error = setCurrent(context))
    return error;
  CUevent cudaEvent = nullptr;
  CUresult status = cuEventCreate(&cudaEvent, flags);
  if (status != CUDA_SUCCESS)
    return cudaError("cuEventCreate", status);
  auto *event = new NVPTXEvent();
  event->references.store(0);
  event->event = cudaEvent;
  event->context = rootContext(context);
  retainContext(event->context);
  *result = event;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_enqueue_event(const NVPTXEvent **result,
                                    const NVPTXContext *context) {
  const char *error = AsyncRT_DeviceContext_eventCreate(
      result, context, CU_EVENT_DISABLE_TIMING);
  if (error)
    return error;
  const_cast<NVPTXEvent *>(*result)->references.fetch_add(1);
  CUresult status = cuEventRecord((*result)->event, activeStream(context));
  if (status == CUDA_SUCCESS)
    return nullptr;
  auto *event = const_cast<NVPTXEvent *>(*result);
  cuEventDestroy(event->event);
  releaseContext(event->context);
  delete event;
  *result = nullptr;
  return cudaError("cuEventRecord", status);
}

NVPTXRT_EXPORT void AsyncRT_DeviceEvent_retain(const NVPTXEvent *event) {
  if (event)
    const_cast<NVPTXEvent *>(event)->references.fetch_add(1);
}

NVPTXRT_EXPORT void AsyncRT_DeviceEvent_release(const NVPTXEvent *event) {
  if (!event)
    return;
  auto *mutableEvent = const_cast<NVPTXEvent *>(event);
  if (mutableEvent->references.fetch_sub(1) != 1)
    return;
  NVPTXContext *context = mutableEvent->context;
  cuCtxSetCurrent(context->context);
  if (mutableEvent->event)
    cuEventDestroy(mutableEvent->event);
  delete mutableEvent;
  releaseContext(context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceEvent_synchronize(const NVPTXEvent *event) {
  if (!event)
    return errf("event synchronize: null event");
  if (const char *error = setCurrent(event->context))
    return error;
  CUresult status = cuEventSynchronize(event->event);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuEventSynchronize", status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceStream_eventRecord(const NVPTXStream *stream,
                                 const NVPTXEvent *event) {
  if (!stream || !event)
    return errf("eventRecord: null argument");
  if (const char *error = setCurrent(stream->context))
    return error;
  CUresult status = cuEventRecord(event->event, stream->stream);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuEventRecord", status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceStream_waitForEvent(const NVPTXStream *stream,
                                  const NVPTXEvent *event) {
  if (!stream || !event)
    return errf("waitForEvent: null argument");
  if (const char *error = setCurrent(stream->context))
    return error;
  CUresult status = cuStreamWaitEvent(stream->stream, event->event, 0);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuStreamWaitEvent", status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_enqueue_wait_for_context(const NVPTXContext *context,
                                               const NVPTXContext *other) {
  return waitForContext(context, other);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceStream_enqueueHostFunc(const NVPTXStream *stream,
                                     void (*function)(void *), void *userData) {
  if (!stream || !function)
    return errf("enqueueHostFunc: null argument");
  if (stream->context && stream->context->recordingBuilder)
    return addRecordedHostFunction(stream->context,
                                   reinterpret_cast<CUhostFn>(function),
                                   userData);
  if (const char *error = setCurrent(stream->context))
    return error;
  CUresult status = cuLaunchHostFunc(
      stream->stream, reinterpret_cast<CUhostFn>(function), userData);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuLaunchHostFunc", status);
}

NVPTXRT_EXPORT const char *AsyncRT_CompletionFlag_create(
    NVPTXCompletionFlag **result, const NVPTXContext *context) {
  if (!result || !context)
    return errf("CompletionFlag_create: null argument");
  if (const char *error = setCurrent(context))
    return error;
  void *allocation = nullptr;
  constexpr unsigned int CU_MEMHOSTALLOC_DEVICEMAP = 0x02;
  CUresult status = cuMemHostAlloc(&allocation, sizeof(uint64_t),
                                   CU_MEMHOSTALLOC_DEVICEMAP);
  if (status != CUDA_SUCCESS)
    return cudaError("cuMemHostAlloc", status);
  CUdeviceptr device = 0;
  status = cuMemHostGetDevicePointer(&device, allocation, 0);
  if (status != CUDA_SUCCESS) {
    cuMemFreeHost(allocation);
    return cudaError("cuMemHostGetDevicePointer", status);
  }
  auto *flag = new NVPTXCompletionFlag();
  flag->host = new (allocation) std::atomic<uint64_t>(0);
  flag->device = device;
  flag->context = rootContext(context);
  retainContext(flag->context);
  *result = flag;
  return nullptr;
}

NVPTXRT_EXPORT void
AsyncRT_CompletionFlag_retain(NVPTXCompletionFlag *flag) {
  if (flag && flag->magic == NVPTX_COMPLETION_FLAG_MAGIC)
    flag->references.fetch_add(1);
}

NVPTXRT_EXPORT void
AsyncRT_CompletionFlag_release(NVPTXCompletionFlag *flag) {
  releaseCompletionFlag(flag);
}

NVPTXRT_EXPORT void AsyncRT_CompletionFlag_signal(NVPTXCompletionFlag *flag,
                                                  uint64_t value) {
  if (flag && flag->magic == NVPTX_COMPLETION_FLAG_MAGIC && flag->host)
    flag->host->store(value, std::memory_order_release);
}

NVPTXRT_EXPORT void AsyncRT_CompletionFlag_reset(NVPTXCompletionFlag *flag) {
  AsyncRT_CompletionFlag_signal(flag, 0);
}

NVPTXRT_EXPORT uint64_t
AsyncRT_CompletionFlag_load(const NVPTXCompletionFlag *flag) {
  return flag && flag->magic == NVPTX_COMPLETION_FLAG_MAGIC && flag->host
             ? flag->host->load(std::memory_order_acquire)
             : 0;
}

NVPTXRT_EXPORT uint64_t
AsyncRT_CompletionFlag_devicePtr(const NVPTXCompletionFlag *flag) {
  return flag && flag->magic == NVPTX_COMPLETION_FLAG_MAGIC ? flag->device : 0;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceStream_enqueueWaitOnHostValue(
    const NVPTXStream *stream, NVPTXCompletionFlag *flag, uint64_t value) {
  if (!stream || !flag || flag->magic != NVPTX_COMPLETION_FLAG_MAGIC)
    return errf("enqueueWaitOnHostValue: invalid argument");
  if (rootContext(stream->context) != rootContext(flag->context))
    return errf("enqueueWaitOnHostValue: flag belongs to another context");
  if (stream->context && stream->context->recordingBuilder)
    return addRecordedWaitOnHostValue(stream->context, flag, value);
  if (const char *error = setCurrent(stream->context))
    return error;
  CUresult status = cuStreamWaitValue64(stream->stream, flag->device, value, 0);
  if (status != CUDA_SUCCESS)
    return cudaError("cuStreamWaitValue64", status);
  flag->references.fetch_add(1);
  NVPTXContext *root = rootContext(stream->context);
  {
    std::lock_guard<std::mutex> lock(root->mutex);
    const_cast<NVPTXStream *>(stream)->pendingCompletionFlags.push_back(flag);
  }
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_startTimer(NVPTXTimer **result,
                                 const NVPTXContext *context) {
  if (!result || !context)
    return errf("startTimer: null argument");
  if (isCPUContext(context)) {
    auto *timer = new NVPTXTimer();
    timer->context = rootContext(context);
    timer->cpuStart = std::chrono::steady_clock::now();
    retainContext(timer->context);
    *result = timer;
    return nullptr;
  }
  if (const char *error = setCurrent(context))
    return error;
  auto *timer = new NVPTXTimer();
  timer->context = rootContext(context);
  CUresult status = cuEventCreate(&timer->start, 0);
  if (status == CUDA_SUCCESS)
    status = cuEventCreate(&timer->stop, 0);
  if (status == CUDA_SUCCESS)
    status = cuEventRecord(timer->start, activeStream(context));
  if (status != CUDA_SUCCESS) {
    if (timer->stop)
      cuEventDestroy(timer->stop);
    if (timer->start)
      cuEventDestroy(timer->start);
    delete timer;
    return cudaError("CUDA timer start", status);
  }
  retainContext(timer->context);
  *result = timer;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_stopTimer(int64_t *elapsedNanos,
                                const NVPTXContext *context,
                                const NVPTXTimer *timer) {
  if (!elapsedNanos || !context || !timer)
    return errf("stopTimer: null argument");
  if (isCPUContext(context)) {
    if (const char *error = synchronizeCPU(context))
      return error;
    *elapsedNanos = std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now() - timer->cpuStart)
                        .count();
    return nullptr;
  }
  if (const char *error = setCurrent(context))
    return error;
  CUresult status = cuEventRecord(timer->stop, activeStream(context));
  if (status == CUDA_SUCCESS)
    status = cuEventSynchronize(timer->stop);
  float elapsedMilliseconds = 0.0f;
  if (status == CUDA_SUCCESS)
    status =
        cuEventElapsedTime(&elapsedMilliseconds, timer->start, timer->stop);
  if (status != CUDA_SUCCESS)
    return cudaError("CUDA timer stop", status);
  *elapsedNanos = static_cast<int64_t>(elapsedMilliseconds * 1000000.0f + 0.5f);
  return nullptr;
}

NVPTXRT_EXPORT void AsyncRT_DeviceTimer_release(const NVPTXTimer *timer) {
  if (!timer)
    return;
  auto *mutableTimer = const_cast<NVPTXTimer *>(timer);
  NVPTXContext *context = mutableTimer->context;
  if (!isCPUContext(context)) {
    cuCtxSetCurrent(context->context);
    if (mutableTimer->stop)
      cuEventDestroy(mutableTimer->stop);
    if (mutableTimer->start)
      cuEventDestroy(mutableTimer->start);
  }
  delete mutableTimer;
  releaseContext(context);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_loadFunction(
    const NVPTXFunction **result, const NVPTXContext *context,
    const char *moduleName, const char *functionName, const char *data,
    size_t dataLength, int32_t maxDynamicSharedBytes, const char *debugLevel,
    int32_t optimizationLevel) {
  (void)maxDynamicSharedBytes;
  (void)debugLevel;
  (void)optimizationLevel;
  if (!context || !functionName || !data)
    return errf("loadFunction: null argument");
  if (const char *error = setCurrent(context))
    return error;

  std::vector<char> image(data, data + dataLength);
  image.push_back('\0');

  CUmodule module = nullptr;
  CUresult status =
      cuModuleLoadDataEx(&module, image.data(), 0, nullptr, nullptr);
  if (status != CUDA_SUCCESS)
    return cudaError(moduleName ? moduleName : "cuModuleLoadDataEx", status);

  CUfunction function = nullptr;
  status = cuModuleGetFunction(&function, module, functionName);
  if (status != CUDA_SUCCESS) {
    cuModuleUnload(module);
    return cudaError("cuModuleGetFunction", status);
  }

  auto *deviceFunction = new NVPTXFunction();
  deviceFunction->module = module;
  deviceFunction->function = function;
  deviceFunction->context = const_cast<NVPTXContext *>(context);
  AsyncRT_DeviceContext_retain(context);
  if (result)
    *result = deviceFunction;
  return nullptr;
}

NVPTXRT_EXPORT void
AsyncRT_DeviceFunction_retain(const NVPTXFunction *function) {
  if (function)
    const_cast<NVPTXFunction *>(function)->references.fetch_add(1);
}

NVPTXRT_EXPORT void
AsyncRT_DeviceFunction_release(const NVPTXFunction *function) {
  if (!function)
    return;
  auto *mutableFunction = const_cast<NVPTXFunction *>(function);
  if (mutableFunction->references.fetch_sub(1) != 1)
    return;
  NVPTXContext *context = mutableFunction->context;
  cuCtxSetCurrent(context->context);
  if (mutableFunction->module)
    cuModuleUnload(mutableFunction->module);
  delete mutableFunction;
  AsyncRT_DeviceContext_release(context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceFunction_cuda_module(CUmodule *result,
                                   const NVPTXFunction *function) {
  if (!result || !function)
    return errf("cuda_module: null argument");
  *result = function->module;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceFunction_copyToConstantMemory(const NVPTXFunction *function,
                                            const void *name, size_t nameSize,
                                            const void *data, size_t dataSize) {
  if (!function || !name || (!data && dataSize))
    return errf("copyToConstantMemory: null argument");
  if (const char *error = setCurrent(function->context))
    return error;
  std::string symbol(static_cast<const char *>(name), nameSize);
  CUdeviceptr destination = 0;
  size_t destinationSize = 0;
  CUresult status = cuModuleGetGlobal(&destination, &destinationSize,
                                      function->module, symbol.c_str());
  if (status != CUDA_SUCCESS)
    return cudaError("cuModuleGetGlobal", status);
  if (dataSize > destinationSize)
    return errf("constant '%s' is %zu bytes, cannot copy %zu bytes",
                symbol.c_str(), destinationSize, dataSize);
  status = cuMemcpyHtoDAsync(destination, data, dataSize,
                             activeStream(function->context));
  if (status != CUDA_SUCCESS)
    status = cuMemcpyHtoD(destination, data, dataSize);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("constant memory copy", status);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceFunction_getAttribute(
    int32_t *result, const NVPTXFunction *function, int32_t attribute) {
  if (!result || !function)
    return errf("DeviceFunction_getAttribute: null argument");
  if (const char *error = setCurrent(function->context))
    return error;
  int value = 0;
  CUresult status = cuFuncGetAttribute(&value, attribute, function->function);
  if (status == CUDA_SUCCESS)
    *result = value;
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuFuncGetAttribute", status);
}

NVPTXRT_EXPORT const char *AsyncRT_occupancyMaxActiveBlocksPerMultiprocessor(
    int32_t *result, const NVPTXFunction *function, int32_t blockSize,
    size_t dynamicSharedMemorySize) {
  if (!result || !function)
    return errf("occupancyMaxActiveBlocksPerMultiprocessor: null argument");
  if (const char *error = setCurrent(function->context))
    return error;
  int blocks = 0;
  CUresult status = cuOccupancyMaxActiveBlocksPerMultiprocessor(
      &blocks, function->function, blockSize, dynamicSharedMemorySize);
  if (status == CUDA_SUCCESS)
    *result = blocks;
  return status == CUDA_SUCCESS
             ? nullptr
             : cudaError("cuOccupancyMaxActiveBlocksPerMultiprocessor", status);
}

NVPTXRT_EXPORT const char *AsyncRT_cuda_tensorMapEncodeTiled(
    CUtensorMap *tensorMap, int32_t dataType, int32_t rank,
    const NVPTXBuffer *buffer, const int64_t *globalDimensions,
    const int64_t *globalStrides, const int32_t *boxDimensions,
    const int32_t *elementStrides, int32_t interleave, int32_t swizzle,
    int32_t l2Promotion, int32_t outOfBoundsFill) {
  if (!tensorMap || !buffer || !globalDimensions || !boxDimensions ||
      !elementStrides)
    return errf("tensorMapEncodeTiled: null argument");
  if (rank <= 0)
    return errf("tensorMapEncodeTiled: invalid rank %d", rank);
  if (const char *error = setCurrent(buffer->context))
    return error;
  void *address =
      buffer->host
          ? buffer->host
          : reinterpret_cast<void *>(static_cast<uintptr_t>(buffer->device));
  CUresult status = cuTensorMapEncodeTiled(
      tensorMap, dataType, static_cast<uint32_t>(rank), address,
      reinterpret_cast<const uint64_t *>(globalDimensions),
      reinterpret_cast<const uint64_t *>(globalStrides),
      reinterpret_cast<const uint32_t *>(boxDimensions),
      reinterpret_cast<const uint32_t *>(elementStrides), interleave, swizzle,
      l2Promotion, outOfBoundsFill);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuTensorMapEncodeTiled", status);
}

NVPTXRT_EXPORT const char *AsyncRT_cuda_tensorMapEncodeIm2col(
    CUtensorMap *tensorMap, int32_t dataType, int32_t rank,
    const NVPTXBuffer *buffer, const int64_t *globalDimensions,
    const int64_t *globalStrides, const int32_t *pixelBoxLowerCorner,
    const int32_t *pixelBoxUpperCorner, int32_t channelsPerPixel,
    int32_t pixelsPerColumn, const int32_t *elementStrides, int32_t interleave,
    int32_t swizzle, int32_t l2Promotion, int32_t outOfBoundsFill) {
  if (!tensorMap || !buffer || !globalDimensions || !pixelBoxLowerCorner ||
      !pixelBoxUpperCorner || !elementStrides)
    return errf("tensorMapEncodeIm2col: null argument");
  if (rank <= 0 || channelsPerPixel < 0 || pixelsPerColumn < 0)
    return errf("tensorMapEncodeIm2col: invalid dimensions");
  if (const char *error = setCurrent(buffer->context))
    return error;
  void *address =
      buffer->host
          ? buffer->host
          : reinterpret_cast<void *>(static_cast<uintptr_t>(buffer->device));
  CUresult status = cuTensorMapEncodeIm2col(
      tensorMap, dataType, static_cast<uint32_t>(rank), address,
      reinterpret_cast<const uint64_t *>(globalDimensions),
      reinterpret_cast<const uint64_t *>(globalStrides), pixelBoxLowerCorner,
      pixelBoxUpperCorner, static_cast<uint32_t>(channelsPerPixel),
      static_cast<uint32_t>(pixelsPerColumn),
      reinterpret_cast<const uint32_t *>(elementStrides), interleave, swizzle,
      l2Promotion, outOfBoundsFill);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuTensorMapEncodeIm2col", status);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraphBuilder_addFunctionDirect(
    NVPTXGraphBuilder *builder, NVPTXFunction *function, int64_t gridX,
    int64_t gridY, int64_t gridZ, int64_t blockX, int64_t blockY,
    int64_t blockZ, int64_t sharedMemoryBytes, void *attributes,
    int64_t attributeCount, void **arguments, uint32_t argumentCount,
    uint64_t *argumentSizes, const int32_t *dependencyIds,
    int64_t dependencyCount);
NVPTXRT_EXPORT int32_t AsyncRT_DeviceGraphBuilder_lastNodeIdOrNone(
    NVPTXGraphBuilder *builder);

static const char *launchFunctionDirect(
    const NVPTXContext *context, CUstream stream, const NVPTXFunction *function,
    uint32_t gridX, uint32_t gridY, uint32_t gridZ, uint32_t blockX,
    uint32_t blockY, uint32_t blockZ, uint32_t sharedMemoryBytes,
    void *attributes, uint32_t attributeCount, void **arguments,
    uint32_t argumentCount, uint64_t *argumentSizes) {
  (void)argumentCount;
  (void)argumentSizes;
  if (!context || !function)
    return errf("enqueueFunctionDirect: null argument");
  if (const char *error = setCurrent(context))
    return error;

  if (attributeCount) {
    if (!attributes)
      return errf("enqueueFunctionDirect: launch attributes are null");
    CUlaunchConfig config = {gridX,
                             gridY,
                             gridZ,
                             blockX,
                             blockY,
                             blockZ,
                             sharedMemoryBytes,
                             stream,
                             static_cast<CUlaunchAttribute *>(attributes),
                             attributeCount};
    CUresult status =
        cuLaunchKernelEx(&config, function->function, arguments, nullptr);
    return status == CUDA_SUCCESS ? nullptr
                                  : cudaError("cuLaunchKernelEx", status);
  }

  CUresult status =
      cuLaunchKernel(function->function, gridX, gridY, gridZ, blockX, blockY,
                     blockZ, sharedMemoryBytes, stream, arguments, nullptr);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuLaunchKernel", status);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_enqueueFunctionDirect(
    const NVPTXContext *context, const NVPTXFunction *function, uint32_t gridX,
    uint32_t gridY, uint32_t gridZ, uint32_t blockX, uint32_t blockY,
    uint32_t blockZ, uint32_t sharedMemoryBytes, void *attributes,
    uint32_t attributeCount, void **arguments, uint32_t argumentCount,
    uint64_t *argumentSizes) {
  if (context && context->recordingBuilder) {
    const int32_t dependency = context->recordingLastNode;
    const char *error = AsyncRT_DeviceGraphBuilder_addFunctionDirect(
        context->recordingBuilder, const_cast<NVPTXFunction *>(function),
        gridX, gridY, gridZ, blockX, blockY, blockZ, sharedMemoryBytes,
        attributes, attributeCount, arguments, argumentCount, argumentSizes,
        dependency >= 0 ? &dependency : nullptr, dependency >= 0 ? 1 : 0);
    if (!error)
      const_cast<NVPTXContext *>(context)->recordingLastNode =
          AsyncRT_DeviceGraphBuilder_lastNodeIdOrNone(
              context->recordingBuilder);
    return error;
  }
  return launchFunctionDirect(context, activeStream(context), function, gridX,
                              gridY, gridZ, blockX, blockY, blockZ,
                              sharedMemoryBytes, attributes, attributeCount,
                              arguments, argumentCount, argumentSizes);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceStream_enqueueFunctionDirect(
    const NVPTXStream *stream, const NVPTXFunction *function, uint32_t gridX,
    uint32_t gridY, uint32_t gridZ, uint32_t blockX, uint32_t blockY,
    uint32_t blockZ, uint32_t sharedMemoryBytes, void *attributes,
    uint32_t attributeCount, void **arguments, uint32_t argumentCount,
    uint64_t *argumentSizes) {
  if (!stream)
    return errf("enqueueFunctionDirect: null stream");
  if (stream->context && stream->context->recordingBuilder) {
    NVPTXContext *context = stream->context;
    const int32_t dependency = context->recordingLastNode;
    const char *error = AsyncRT_DeviceGraphBuilder_addFunctionDirect(
        context->recordingBuilder, const_cast<NVPTXFunction *>(function),
        gridX, gridY, gridZ, blockX, blockY, blockZ, sharedMemoryBytes,
        attributes, attributeCount, arguments, argumentCount, argumentSizes,
        dependency >= 0 ? &dependency : nullptr, dependency >= 0 ? 1 : 0);
    if (!error)
      context->recordingLastNode =
          AsyncRT_DeviceGraphBuilder_lastNodeIdOrNone(
              context->recordingBuilder);
    return error;
  }
  return launchFunctionDirect(stream->context, stream->stream, function, gridX,
                              gridY, gridZ, blockX, blockY, blockZ,
                              sharedMemoryBytes, attributes, attributeCount,
                              arguments, argumentCount, argumentSizes);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_createGraphBuilder(
    NVPTXGraphBuilder **result, NVPTXContext *context) {
  if (!result || !context)
    return errf("createGraphBuilder: null argument");
  if (const char *error = setCurrent(context))
    return error;
  CUgraph graph = nullptr;
  CUresult status = cuGraphCreate(&graph, 0);
  if (status != CUDA_SUCCESS)
    return cudaError("cuGraphCreate", status);
  auto *builder = new NVPTXGraphBuilder();
  builder->graph = graph;
  builder->context = rootContext(context);
  retainContext(builder->context);
  *result = builder;
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraphBuilder_recordingContext(
    NVPTXContext **result, NVPTXGraphBuilder *builder, int32_t seedNodeId) {
  if (!result || !builder || !builder->context)
    return errf("recordingContext: null argument");
  if (seedNodeId < -1 ||
      (seedNodeId >= 0 &&
       static_cast<size_t>(seedNodeId) >= builder->nodes.size()))
    return errf("recordingContext: invalid seed node id %d", seedNodeId);
  NVPTXContext *root = rootContext(builder->context);
  auto *view = new NVPTXContext();
  view->root = root;
  view->device = root->device;
  view->context = root->context;
  view->id = root->id;
  view->computeCapability = root->computeCapability;
  view->driverVersion = root->driverVersion;
  view->name = root->name;
  view->arch = root->arch;
  view->api = root->api;
  view->defaultStream = root->defaultStream;
  view->recordingBuilder = builder;
  view->recordingLastNode = seedNodeId;
  retainContext(root);
  *result = view;
  return nullptr;
}

NVPTXRT_EXPORT void
AsyncRT_DeviceGraphBuilder_release(NVPTXGraphBuilder *builder) {
  if (!builder)
    return;
  if (builder->context)
    cuCtxSetCurrent(builder->context->context);
  if (builder->graph)
    cuGraphDestroy(builder->graph);
  for (NVPTXFunction *function : builder->functions)
    AsyncRT_DeviceFunction_release(function);
  for (NVPTXBuffer *buffer : builder->buffers)
    AsyncRT_DeviceBuffer_release(buffer);
  for (NVPTXCompletionFlag *flag : builder->completionFlags)
    releaseCompletionFlag(flag);
  for (void *output : builder->outputs)
    releaseAsyncValue(output);
  NVPTXContext *context = builder->context;
  delete builder;
  releaseContext(context);
}

NVPTXRT_EXPORT int32_t AsyncRT_DeviceGraphBuilder_lastNodeIdOrNone(
    NVPTXGraphBuilder *builder) {
  if (!builder || builder->nodes.empty())
    return -1;
  return static_cast<int32_t>(builder->nodes.size() - 1);
}

NVPTXRT_EXPORT int64_t
AsyncRT_DeviceGraphBuilder_numInputs(NVPTXGraphBuilder *builder) {
  return builder ? builder->inputCount : 0;
}

NVPTXRT_EXPORT int64_t
AsyncRT_DeviceGraphBuilder_numOutputs(NVPTXGraphBuilder *builder) {
  return builder ? static_cast<int64_t>(builder->outputs.size()) : 0;
}

NVPTXRT_EXPORT void AsyncRT_DeviceGraphBuilder_addInput(
    NVPTXGraphBuilder *builder, NVPTXBuffer *input) {
  if (!builder || !input)
    return;
  retainGraphBuffer(builder, input);
  ++builder->inputCount;
}

NVPTXRT_EXPORT void
AsyncRT_DeviceGraphBuilder_addInPlaceInput(NVPTXGraphBuilder *builder) {
  if (builder)
    ++builder->inputCount;
}

NVPTXRT_EXPORT void AsyncRT_DeviceGraphBuilder_addOutput(
    NVPTXGraphBuilder *builder, void *output) {
  if (builder && output)
    builder->outputs.push_back(output);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraphBuilder_addEmpty(
    NVPTXGraphBuilder *builder, const int32_t *dependencyIds,
    int64_t dependencyCount) {
  std::vector<CUgraphNode> dependencies;
  if (const char *error = graphDependencies(builder, dependencyIds,
                                             dependencyCount, dependencies))
    return error;
  CUgraphNode node = nullptr;
  CUresult status = cuGraphAddEmptyNode(
      &node, builder->graph, dependencies.data(), dependencies.size());
  if (status != CUDA_SUCCESS)
    return cudaError("cuGraphAddEmptyNode", status);
  builder->nodes.push_back(node);
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraphBuilder_addFunctionDirect(
    NVPTXGraphBuilder *builder, NVPTXFunction *function, int64_t gridX,
    int64_t gridY, int64_t gridZ, int64_t blockX, int64_t blockY,
    int64_t blockZ, int64_t sharedMemoryBytes, void *attributes,
    int64_t attributeCount, void **arguments, uint32_t argumentCount,
    uint64_t *argumentSizes, const int32_t *dependencyIds,
    int64_t dependencyCount) {
  if (!builder || !function)
    return errf("addFunctionDirect: null argument");
  if (rootContext(function->context) != rootContext(builder->context))
    return errf("addFunctionDirect: function belongs to another context");
  constexpr int64_t uintMax = std::numeric_limits<uint32_t>::max();
  if (gridX <= 0 || gridY <= 0 || gridZ <= 0 || blockX <= 0 || blockY <= 0 ||
      blockZ <= 0 || gridX > uintMax || gridY > uintMax || gridZ > uintMax ||
      blockX > uintMax || blockY > uintMax || blockZ > uintMax ||
      sharedMemoryBytes < 0 || sharedMemoryBytes > uintMax)
    return errf("addFunctionDirect: invalid launch dimensions");
  if (attributeCount < 0 || (attributeCount && !attributes))
    return errf("addFunctionDirect: invalid launch attributes");
  if (argumentCount && !arguments)
    return errf("addFunctionDirect: kernel arguments are null");
  if (argumentSizes) {
    for (uint32_t index = 0; index < argumentCount; ++index)
      if (!argumentSizes[index])
        return errf("addFunctionDirect: argument %u has zero size", index);
  }

  // Own the buffers this node will read and write, as a recorded copy or
  // memset already does. The graph outlives the caller's variables --
  // Mojo destroys a value at its last use -- and a replay against a buffer
  // freed in the meantime is a use-after-free that faults as soon as the
  // driver reclaims the pages. Only pointer-sized arguments are looked at;
  // a null size table is the runtime's existing pointer-sized fallback.
  for (uint32_t index = 0; index < argumentCount; ++index) {
    if (!arguments || !arguments[index])
      continue;
    if (argumentSizes && argumentSizes[index] < sizeof(void *))
      continue;
    const uintptr_t value = *static_cast<const uintptr_t *>(arguments[index]);
    retainGraphDevicePointer(builder, value);
    retainGraphHostPointer(builder, reinterpret_cast<const void *>(value));
  }

  std::vector<CUgraphNode> dependencies;
  if (const char *error = graphDependencies(builder, dependencyIds,
                                             dependencyCount, dependencies))
    return error;
  CUDAKernelNodeParams params = {
      function->function,
      static_cast<unsigned int>(gridX),
      static_cast<unsigned int>(gridY),
      static_cast<unsigned int>(gridZ),
      static_cast<unsigned int>(blockX),
      static_cast<unsigned int>(blockY),
      static_cast<unsigned int>(blockZ),
      static_cast<unsigned int>(sharedMemoryBytes),
      arguments,
      nullptr,
      nullptr,
      nullptr,
  };
  CUgraphNode node = nullptr;
  CUresult status = cuGraphAddKernelNode(
      &node, builder->graph, dependencies.data(), dependencies.size(), &params);
  if (status != CUDA_SUCCESS)
    return cudaError("cuGraphAddKernelNode", status);

  auto *launchAttributes = static_cast<const CUlaunchAttribute *>(attributes);
  for (int64_t index = 0; index < attributeCount; ++index) {
    if (!launchAttributes[index].id)
      continue;
    status = cuGraphKernelNodeSetAttribute(
        node, launchAttributes[index].id, launchAttributes[index].value);
    if (status != CUDA_SUCCESS)
      return cudaError("cuGraphKernelNodeSetAttribute", status);
  }
  builder->nodes.push_back(node);
  retainGraphFunction(builder, function);
  return nullptr;
}

static const char *addGraphMemcpyNode(
    NVPTXGraphBuilder *builder, CUDAMemcpy3D &params,
    const int32_t *dependencyIds, int64_t dependencyCount) {
  std::vector<CUgraphNode> dependencies;
  if (const char *error = graphDependencies(builder, dependencyIds,
                                             dependencyCount, dependencies))
    return error;
  CUgraphNode node = nullptr;
  CUresult status = cuGraphAddMemcpyNode(
      &node, builder->graph, dependencies.data(), dependencies.size(), &params,
      builder->context->context);
  if (status != CUDA_SUCCESS)
    return cudaError("cuGraphAddMemcpyNode", status);
  builder->nodes.push_back(node);
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraphBuilder_addCopyHostToDevice(
    NVPTXGraphBuilder *builder, NVPTXBuffer *destination, const void *source,
    const int32_t *dependencyIds, int64_t dependencyCount) {
  if (!builder || !destination || !source)
    return errf("addCopyHostToDevice: null argument");
  if (destination->host)
    return errf("addCopyHostToDevice: destination is not device memory");
  if (destination->bytes > std::numeric_limits<unsigned int>::max())
    return errf("addCopyHostToDevice: copy exceeds CUDA graph node limit");
  CUDAMemcpy3D params = {};
  params.sourceMemoryType = CU_MEMORYTYPE_HOST;
  params.sourceHost = source;
  params.destinationMemoryType = CU_MEMORYTYPE_DEVICE;
  params.destinationDevice = destination->device;
  params.widthBytes = destination->bytes;
  params.sourcePitch = params.widthBytes;
  params.sourceHeight = 1;
  params.destinationPitch = params.widthBytes;
  params.destinationHeight = 1;
  params.height = 1;
  params.depth = 1;
  if (const char *error = addGraphMemcpyNode(
          builder, params, dependencyIds, dependencyCount))
    return error;
  retainGraphBuffer(builder, destination);
  retainGraphHostPointer(builder, source);
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraphBuilder_addCopyDeviceToHost(
    NVPTXGraphBuilder *builder, void *destination, NVPTXBuffer *source,
    const int32_t *dependencyIds, int64_t dependencyCount) {
  if (!builder || !destination || !source)
    return errf("addCopyDeviceToHost: null argument");
  if (source->host)
    return errf("addCopyDeviceToHost: source is not device memory");
  if (source->bytes > std::numeric_limits<unsigned int>::max())
    return errf("addCopyDeviceToHost: copy exceeds CUDA graph node limit");
  CUDAMemcpy3D params = {};
  params.sourceMemoryType = CU_MEMORYTYPE_DEVICE;
  params.sourceDevice = source->device;
  params.destinationMemoryType = CU_MEMORYTYPE_HOST;
  params.destinationHost = destination;
  params.widthBytes = source->bytes;
  params.sourcePitch = params.widthBytes;
  params.sourceHeight = 1;
  params.destinationPitch = params.widthBytes;
  params.destinationHeight = 1;
  params.height = 1;
  params.depth = 1;
  if (const char *error = addGraphMemcpyNode(
          builder, params, dependencyIds, dependencyCount))
    return error;
  retainGraphBuffer(builder, source);
  retainGraphHostPointer(builder, destination);
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraphBuilder_addCopyDeviceToDevice(
    NVPTXGraphBuilder *builder, NVPTXBuffer *destination, NVPTXBuffer *source,
    const int32_t *dependencyIds, int64_t dependencyCount) {
  if (!builder || !destination || !source)
    return errf("addCopyDeviceToDevice: null argument");
  if (destination->host || source->host)
    return errf("addCopyDeviceToDevice: buffer is not device memory");
  if (destination->bytes < source->bytes)
    return errf("addCopyDeviceToDevice: destination is too small");
  if (source->bytes > std::numeric_limits<unsigned int>::max())
    return errf("addCopyDeviceToDevice: copy exceeds CUDA graph node limit");
  CUDAMemcpy3D params = {};
  params.sourceMemoryType = CU_MEMORYTYPE_DEVICE;
  params.sourceDevice = source->device;
  params.destinationMemoryType = CU_MEMORYTYPE_DEVICE;
  params.destinationDevice = destination->device;
  params.widthBytes = source->bytes;
  params.sourcePitch = params.widthBytes;
  params.sourceHeight = 1;
  params.destinationPitch = params.widthBytes;
  params.destinationHeight = 1;
  params.height = 1;
  params.depth = 1;
  if (const char *error = addGraphMemcpyNode(
          builder, params, dependencyIds, dependencyCount))
    return error;
  retainGraphBuffer(builder, source);
  retainGraphBuffer(builder, destination);
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraphBuilder_addSetMemory(
    NVPTXGraphBuilder *builder, NVPTXBuffer *destination, uint64_t value,
    size_t valueSize, const int32_t *dependencyIds, int64_t dependencyCount) {
  if (!builder || !destination)
    return errf("addSetMemory: null argument");
  if (destination->host)
    return errf("addSetMemory: destination is not device memory");
  if (valueSize == 8) {
    if (static_cast<uint32_t>(value) != static_cast<uint32_t>(value >> 32))
      return errf("addSetMemory: non-repeating 64-bit values are unsupported");
    valueSize = 4;
  }
  if (valueSize != 1 && valueSize != 2 && valueSize != 4)
    return errf("addSetMemory: element size must be 1, 2, 4, or 8");
  if (destination->bytes % valueSize)
    return errf("addSetMemory: buffer size is not element aligned");

  std::vector<CUgraphNode> dependencies;
  if (const char *error = graphDependencies(builder, dependencyIds,
                                             dependencyCount, dependencies))
    return error;
  CUDAMemsetNodeParams params = {
      destination->device,
      0,
      static_cast<unsigned int>(value),
      static_cast<unsigned int>(valueSize),
      destination->bytes / valueSize,
      1,
  };
  CUgraphNode node = nullptr;
  CUresult status = cuGraphAddMemsetNode(
      &node, builder->graph, dependencies.data(), dependencies.size(), &params,
      builder->context->context);
  if (status != CUDA_SUCCESS)
    return cudaError("cuGraphAddMemsetNode", status);
  builder->nodes.push_back(node);
  retainGraphBuffer(builder, destination);
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraph_createBuffer(
    const NVPTXBuffer **result, void **devicePointer,
    NVPTXGraphBuilder *builder, size_t length, size_t elementSize, bool isHost) {
  if (!builder)
    return errf("DeviceGraph_createBuffer: builder is null");
  const char *error = isHost
                          ? AsyncRT_DeviceContext_createHostBuffer(
                                result, devicePointer, builder->context, length,
                                elementSize)
                          : AsyncRT_DeviceContext_createBuffer_async(
                                result, devicePointer, builder->context, length,
                                elementSize);
  if (error)
    return error;
  retainGraphBuffer(builder, const_cast<NVPTXBuffer *>(*result));
  return nullptr;
}

NVPTXRT_EXPORT void AsyncRT_DeviceGraph_release(NVPTXGraph *graph);

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraphBuilder_instantiate(
    NVPTXGraph **result, NVPTXGraphBuilder *builder) {
  if (!result || !builder || !builder->graph || !builder->context)
    return errf("instantiate: null or consumed graph builder");
  if (const char *error = setCurrent(builder->context))
    return error;
  CUgraphExec executable = nullptr;
  CUresult status = cuGraphInstantiate(&executable, builder->graph, 0);
  if (status != CUDA_SUCCESS)
    return cudaError("cuGraphInstantiateWithFlags", status);

  auto *graph = new NVPTXGraph();
  graph->executable = executable;
  graph->context = builder->context;
  graph->buffers = std::move(builder->buffers);
  graph->functions = std::move(builder->functions);
  graph->completionFlags = std::move(builder->completionFlags);
  graph->outputs = std::move(builder->outputs);
  builder->context = nullptr;
  status = cuGraphDestroy(builder->graph);
  builder->graph = nullptr;
  if (status != CUDA_SUCCESS) {
    AsyncRT_DeviceGraph_release(graph);
    return cudaError("cuGraphDestroy", status);
  }
  *result = graph;
  return nullptr;
}

NVPTXRT_EXPORT void AsyncRT_DeviceGraph_retain(NVPTXGraph *graph) {
  if (graph)
    graph->references.fetch_add(1);
}

NVPTXRT_EXPORT void AsyncRT_DeviceGraph_release(NVPTXGraph *graph) {
  if (!graph || graph->references.fetch_sub(1) != 1)
    return;
  if (graph->context)
    cuCtxSetCurrent(graph->context->context);
  if (graph->executable)
    cuGraphExecDestroy(graph->executable);
  for (NVPTXFunction *function : graph->functions)
    AsyncRT_DeviceFunction_release(function);
  for (NVPTXBuffer *buffer : graph->buffers)
    AsyncRT_DeviceBuffer_release(buffer);
  for (NVPTXCompletionFlag *flag : graph->completionFlags)
    releaseCompletionFlag(flag);
  for (void *output : graph->outputs)
    releaseAsyncValue(output);
  NVPTXContext *context = graph->context;
  delete graph;
  releaseContext(context);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceGraph_replay(NVPTXGraph *graph) {
  if (!graph || !graph->context || !graph->executable)
    return errf("DeviceGraph_replay: null graph");
  if (const char *error = setCurrent(graph->context))
    return error;
  CUresult status =
      cuGraphLaunch(graph->executable, activeStream(graph->context));
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuGraphLaunch", status);
}

#undef NVPTXRT_EXPORT

} // extern "C"
