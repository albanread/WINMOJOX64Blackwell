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
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
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

struct alignas(64) CUtensorMap {
  uint64_t opaque[16];
};

static_assert(sizeof(CUlaunchAttribute) == 72,
              "CUDA launch attribute ABI mismatch");
static_assert(sizeof(CUlaunchConfig) == 56, "CUDA launch config ABI mismatch");

constexpr CUresult CUDA_SUCCESS = 0;
constexpr unsigned int CU_STREAM_NON_BLOCKING = 1;
constexpr unsigned int CU_EVENT_DISABLE_TIMING = 2;
constexpr int CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR = 75;
constexpr int CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR = 76;

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
CUDA_FUNCTION(CUresult, cuDeviceTotalMem, size_t *, CUdevice);
CUDA_FUNCTION(CUresult, cuDevicePrimaryCtxRetain, CUcontext *, CUdevice);
CUDA_FUNCTION(CUresult, cuDevicePrimaryCtxRelease, CUdevice);
CUDA_FUNCTION(CUresult, cuCtxSetCurrent, CUcontext);
CUDA_FUNCTION(CUresult, cuCtxGetCurrent, CUcontext *);
CUDA_FUNCTION(CUresult, cuCtxPushCurrent, CUcontext);
CUDA_FUNCTION(CUresult, cuCtxPopCurrent, CUcontext *);
CUDA_FUNCTION(CUresult, cuCtxSynchronize);
CUDA_FUNCTION(CUresult, cuCtxGetStreamPriorityRange, int *, int *);
CUDA_FUNCTION(CUresult, cuMemGetInfo, size_t *, size_t *);
CUDA_FUNCTION(CUresult, cuMemAlloc, CUdeviceptr *, size_t);
CUDA_FUNCTION(CUresult, cuMemFree, CUdeviceptr);
CUDA_FUNCTION(CUresult, cuMemHostAlloc, void **, size_t, unsigned int);
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
CUDA_FUNCTION(CUresult, cuMemsetD8, CUdeviceptr, unsigned char, size_t);
CUDA_FUNCTION(CUresult, cuMemsetD16, CUdeviceptr, unsigned short, size_t);
CUDA_FUNCTION(CUresult, cuMemsetD32, CUdeviceptr, unsigned int, size_t);
CUDA_FUNCTION(CUresult, cuMemsetD8Async, CUdeviceptr, unsigned char, size_t,
              CUstream);
CUDA_FUNCTION(CUresult, cuMemsetD16Async, CUdeviceptr, unsigned short, size_t,
              CUstream);
CUDA_FUNCTION(CUresult, cuMemsetD32Async, CUdeviceptr, unsigned int, size_t,
              CUstream);
CUDA_FUNCTION(CUresult, cuStreamCreate, CUstream *, unsigned int);
CUDA_FUNCTION(CUresult, cuStreamCreateWithPriority, CUstream *, unsigned int,
              int);
CUDA_FUNCTION(CUresult, cuStreamDestroy, CUstream);
CUDA_FUNCTION(CUresult, cuStreamSynchronize, CUstream);
CUDA_FUNCTION(CUresult, cuStreamWaitEvent, CUstream, CUevent, unsigned int);
CUDA_FUNCTION(CUresult, cuEventCreate, CUevent *, unsigned int);
CUDA_FUNCTION(CUresult, cuEventDestroy, CUevent);
CUDA_FUNCTION(CUresult, cuEventRecord, CUevent, CUstream);
CUDA_FUNCTION(CUresult, cuEventSynchronize, CUevent);
CUDA_FUNCTION(CUresult, cuEventElapsedTime, float *, CUevent, CUevent);
using CUhostFn = void(CUDA_API *)(void *);
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
CUDA_FUNCTION(CUresult, cuGetErrorString, CUresult, const char **);

#undef CUDA_FUNCTION

static std::once_flag cudaLoadOnce;
static bool cudaLoaded = false;
static char cudaLoadError[512] = {};

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
  LOAD_V2(cuDeviceTotalMem);
  LOAD(cuDevicePrimaryCtxRetain);
  LOAD_V2(cuDevicePrimaryCtxRelease);
  LOAD(cuCtxSetCurrent);
  LOAD(cuCtxGetCurrent);
  LOAD_V2(cuCtxPushCurrent);
  LOAD_V2(cuCtxPopCurrent);
  LOAD(cuCtxSynchronize);
  LOAD(cuCtxGetStreamPriorityRange);
  LOAD_V2(cuMemGetInfo);
  LOAD_V2(cuMemAlloc);
  LOAD_V2(cuMemFree);
  LOAD(cuMemHostAlloc);
  LOAD(cuMemFreeHost);
  LOAD_V2(cuMemcpyHtoD);
  LOAD_V2(cuMemcpyDtoH);
  LOAD_V2(cuMemcpyDtoD);
  LOAD_V2(cuMemcpyHtoDAsync);
  LOAD_V2(cuMemcpyDtoHAsync);
  LOAD_V2(cuMemcpyDtoDAsync);
  LOAD_V2(cuMemsetD8);
  LOAD_V2(cuMemsetD16);
  LOAD_V2(cuMemsetD32);
  LOAD(cuMemsetD8Async);
  LOAD(cuMemsetD16Async);
  LOAD(cuMemsetD32Async);
  LOAD(cuStreamCreate);
  LOAD(cuStreamCreateWithPriority);
  LOAD_V2(cuStreamDestroy);
  LOAD(cuStreamSynchronize);
  LOAD(cuStreamWaitEvent);
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

struct NVPTXStream {
  std::atomic<int> references{1};
  CUstream stream = nullptr;
  NVPTXContext *context = nullptr;
  bool owning = false;
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
  std::vector<NVPTXStream *> streams;
  std::mutex mutex;
};

struct NVPTXEvent {
  std::atomic<int> references{1};
  CUevent event = nullptr;
  NVPTXContext *context = nullptr;
};

struct NVPTXTimer {
  CUevent start = nullptr;
  CUevent stop = nullptr;
  NVPTXContext *context = nullptr;
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

static CUstream activeStream(const NVPTXContext *context) {
  return context && context->defaultStream ? context->defaultStream->stream
                                           : nullptr;
}

static void retainContext(const NVPTXContext *context) {
  if (context)
    const_cast<NVPTXContext *>(context)->references.fetch_add(1);
}

static void releaseContext(const NVPTXContext *context);

static const char *setCurrent(const NVPTXContext *context) {
  if (!context)
    return errf("CUDA context is null");
  CUresult status = cuCtxSetCurrent(context->context);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuCtxSetCurrent", status);
}

static void releaseStream(NVPTXStream *stream) {
  if (!stream)
    return;
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
  if (activeStream(context) == activeStream(other) &&
      rootContext(context)->context == rootContext(other)->context)
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

static bool isCudaKind(const char *api) {
  if (!api || !*api)
    return true;
  return strcmp(api, "cuda") == 0 || strcmp(api, "nvidia") == 0 ||
         strcmp(api, "gpu") == 0;
}

} // namespace

extern "C" {

#define NVPTXRT_EXPORT __declspec(dllexport)

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_create(const NVPTXContext **result, const char *api,
                             int id) {
  if (!result)
    return errf("AsyncRT_DeviceContext_create: result is null");
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
  if (major == 12 && minor == 0)
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

NVPTXRT_EXPORT int32_t *
AsyncRT_DeviceContext_numberOfDevices(const char *kind) {
  static thread_local int32_t count = 0;
  count = 0;
  if (!isCudaKind(kind) || !loadCUDA())
    return &count;
  int cudaCount = 0;
  if (cuDeviceGetCount(&cudaCount) == CUDA_SUCCESS)
    count = cudaCount;
  return &count;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_setAsCurrent(const NVPTXContext *context) {
  return setCurrent(context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_synchronize(const NVPTXContext *context) {
  if (const char *error = setCurrent(context))
    return error;
  CUresult status = cuStreamSynchronize(activeStream(context));
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuStreamSynchronize", status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_isCompatible(const NVPTXContext *context) {
  if (!context)
    return errf("isCompatible: null context");
  if (!loadCUDA())
    return errf("%s", cudaLoadError);
  return setCurrent(context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_runHealthcheck(NVPTXContext *context) {
  if (!context)
    return errf("runHealthcheck: null context");
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
  CUresult status = cuCtxPushCurrent(context->context);
  if (status != CUDA_SUCCESS)
    return cudaError("cuCtxPushCurrent", status);
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
  CUcontext popped = nullptr;
  cuCtxPopCurrent(&popped);
  NVPTXContext *context = mutableScope->context;
  delete mutableScope;
  releaseContext(context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_cuda_context(CUcontext *result,
                                   const NVPTXContext *context) {
  if (!result || !context)
    return errf("cuda_context: null argument");
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
    *result = context->computeCapability;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_getAttribute(int *result, const NVPTXContext *context,
                                   int attribute) {
  if (!context)
    return errf("getAttribute: null context");
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
  if (const char *error = setCurrent(context))
    return error;

  size_t bytes = length * elementSize;
  CUdeviceptr allocation = 0;
  CUresult status = cuMemAlloc(&allocation, std::max<size_t>(bytes, 1));
  if (status != CUDA_SUCCESS)
    return cudaError("cuMemAlloc", status);

  auto *buffer = new NVPTXBuffer();
  buffer->device = allocation;
  buffer->bytes = bytes;
  buffer->context = const_cast<NVPTXContext *>(context);
  AsyncRT_DeviceContext_retain(context);
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
  if (const char *error = setCurrent(context))
    return error;
  size_t bytes = length * elementSize;
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
  buffer->device =
      static_cast<CUdeviceptr>(reinterpret_cast<uintptr_t>(devicePointer));
  buffer->bytes = length * elementSize;
  buffer->context = const_cast<NVPTXContext *>(context);
  buffer->owning = owning;
  AsyncRT_DeviceContext_retain(context);
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
  if (mutableBuffer->references.fetch_sub(1) != 1)
    return;
  NVPTXContext *context = mutableBuffer->context;
  NVPTXBuffer *parent = mutableBuffer->parent;
  if (mutableBuffer->host && mutableBuffer->owning) {
    if (mutableBuffer->hostPinned) {
      cuCtxSetCurrent(context->context);
      cuMemFreeHost(mutableBuffer->host);
    } else {
      free(mutableBuffer->host);
    }
  } else if (mutableBuffer->device && mutableBuffer->owning) {
    cuCtxSetCurrent(context->context);
    cuMemFree(mutableBuffer->device);
  }
  delete mutableBuffer;
  if (parent)
    AsyncRT_DeviceBuffer_release(parent);
  AsyncRT_DeviceContext_release(context);
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
    if (const char *error = setCurrent(source->context))
      return error;
    CUresult syncStatus = cuStreamSynchronize(activeStream(source->context));
    if (syncStatus != CUDA_SUCCESS)
      return cudaError("cuStreamSynchronize", syncStatus);
    memcpy(destination->host, source->host, bytes);
    return nullptr;
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
    operation = "cuMemcpyDtoDAsync";
    status = cuMemcpyDtoDAsync(destination->device, source->device, bytes,
                               activeStream(context));
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
  releaseContext(stream->context);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceStream_synchronize(const NVPTXStream *stream) {
  if (!stream)
    return errf("stream synchronize: null stream");
  if (const char *error = setCurrent(stream->context))
    return error;
  CUresult status = cuStreamSynchronize(stream->stream);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuStreamSynchronize", status);
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
  if (const char *error = setCurrent(stream->context))
    return error;
  CUresult status = cuLaunchHostFunc(
      stream->stream, reinterpret_cast<CUhostFn>(function), userData);
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuLaunchHostFunc", status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_startTimer(NVPTXTimer **result,
                                 const NVPTXContext *context) {
  if (!result || !context)
    return errf("startTimer: null argument");
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
  cuCtxSetCurrent(context->context);
  if (mutableTimer->stop)
    cuEventDestroy(mutableTimer->stop);
  if (mutableTimer->start)
    cuEventDestroy(mutableTimer->start);
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
  return launchFunctionDirect(stream->context, stream->stream, function, gridX,
                              gridY, gridZ, blockX, blockY, blockZ,
                              sharedMemoryBytes, attributes, attributeCount,
                              arguments, argumentCount, argumentSizes);
}

#undef NVPTXRT_EXPORT

} // extern "C"
