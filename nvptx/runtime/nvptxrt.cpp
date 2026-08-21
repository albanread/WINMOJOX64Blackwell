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
using CUmodule = void *;
using CUfunction = void *;

constexpr CUresult CUDA_SUCCESS = 0;
constexpr int CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR = 75;
constexpr int CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR = 76;

#define CUDA_API __stdcall
#define CUDA_FUNCTION(result, name, ...)                                      \
  using name##Fn = result(CUDA_API *)(__VA_ARGS__);                           \
  static name##Fn name = nullptr

CUDA_FUNCTION(CUresult, cuInit, unsigned int);
CUDA_FUNCTION(CUresult, cuDriverGetVersion, int *);
CUDA_FUNCTION(CUresult, cuDeviceGetCount, int *);
CUDA_FUNCTION(CUresult, cuDeviceGet, CUdevice *, int);
CUDA_FUNCTION(CUresult, cuDeviceGetName, char *, int, CUdevice);
CUDA_FUNCTION(CUresult, cuDeviceGetAttribute, int *, int, CUdevice);
CUDA_FUNCTION(CUresult, cuDeviceTotalMem, size_t *, CUdevice);
CUDA_FUNCTION(CUresult, cuCtxCreate, CUcontext *, unsigned int, CUdevice);
CUDA_FUNCTION(CUresult, cuCtxDestroy, CUcontext);
CUDA_FUNCTION(CUresult, cuCtxSetCurrent, CUcontext);
CUDA_FUNCTION(CUresult, cuCtxSynchronize);
CUDA_FUNCTION(CUresult, cuMemGetInfo, size_t *, size_t *);
CUDA_FUNCTION(CUresult, cuMemAlloc, CUdeviceptr *, size_t);
CUDA_FUNCTION(CUresult, cuMemFree, CUdeviceptr);
CUDA_FUNCTION(CUresult, cuMemcpyHtoD, CUdeviceptr, const void *, size_t);
CUDA_FUNCTION(CUresult, cuMemcpyDtoH, void *, CUdeviceptr, size_t);
CUDA_FUNCTION(CUresult, cuMemcpyDtoD, CUdeviceptr, CUdeviceptr, size_t);
CUDA_FUNCTION(CUresult, cuMemsetD8, CUdeviceptr, unsigned char, size_t);
CUDA_FUNCTION(CUresult, cuMemsetD16, CUdeviceptr, unsigned short, size_t);
CUDA_FUNCTION(CUresult, cuMemsetD32, CUdeviceptr, unsigned int, size_t);
CUDA_FUNCTION(CUresult, cuStreamCreate, CUstream *, unsigned int);
CUDA_FUNCTION(CUresult, cuStreamDestroy, CUstream);
CUDA_FUNCTION(CUresult, cuStreamSynchronize, CUstream);
CUDA_FUNCTION(CUresult, cuModuleLoadDataEx, CUmodule *, const void *,
              unsigned int, int *, void **);
CUDA_FUNCTION(CUresult, cuModuleGetFunction, CUfunction *, CUmodule,
              const char *);
CUDA_FUNCTION(CUresult, cuModuleUnload, CUmodule);
CUDA_FUNCTION(CUresult, cuLaunchKernel, CUfunction, unsigned int, unsigned int,
              unsigned int, unsigned int, unsigned int, unsigned int,
              unsigned int, CUstream, void **, void **);
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

#define LOAD(name)                                                            \
  if (!loadProc(module, name, #name))                                         \
    return
#define LOAD_V2(name)                                                         \
  if (!loadProc(module, name, #name "_v2", #name))                           \
    return

  LOAD(cuInit);
  LOAD(cuDriverGetVersion);
  LOAD(cuDeviceGetCount);
  LOAD(cuDeviceGet);
  LOAD(cuDeviceGetName);
  LOAD(cuDeviceGetAttribute);
  LOAD_V2(cuDeviceTotalMem);
  LOAD_V2(cuCtxCreate);
  LOAD_V2(cuCtxDestroy);
  LOAD(cuCtxSetCurrent);
  LOAD(cuCtxSynchronize);
  LOAD_V2(cuMemGetInfo);
  LOAD_V2(cuMemAlloc);
  LOAD_V2(cuMemFree);
  LOAD_V2(cuMemcpyHtoD);
  LOAD_V2(cuMemcpyDtoH);
  LOAD_V2(cuMemcpyDtoD);
  LOAD_V2(cuMemsetD8);
  LOAD_V2(cuMemsetD16);
  LOAD_V2(cuMemsetD32);
  LOAD(cuStreamCreate);
  LOAD_V2(cuStreamDestroy);
  LOAD(cuStreamSynchronize);
  LOAD(cuModuleLoadDataEx);
  LOAD(cuModuleGetFunction);
  LOAD(cuModuleUnload);
  LOAD(cuLaunchKernel);
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
  bool owning = true;
};

struct NVPTXFunction {
  std::atomic<int> references{1};
  CUmodule module = nullptr;
  CUfunction function = nullptr;
  NVPTXContext *context = nullptr;
};

struct NVPTXContext {
  std::atomic<int> references{1};
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

struct StringRefABI {
  const char *data;
  size_t length;
};

static const char *setCurrent(const NVPTXContext *context) {
  if (!context)
    return errf("CUDA context is null");
  CUresult status = cuCtxSetCurrent(context->context);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuCtxSetCurrent", status);
}

static void releaseStream(NVPTXStream *stream) {
  if (!stream)
    return;
  if (stream->owning && stream->stream)
    cuStreamDestroy(stream->stream);
  delete stream;
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

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_create(
    const NVPTXContext **result, const char *api, int id) {
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
  status = cuCtxCreate(&cudaContext, 0, device);
  if (status != CUDA_SUCCESS)
    return cudaError("cuCtxCreate", status);

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

  auto *stream = new NVPTXStream();
  stream->context = context;
  context->defaultStream = stream;
  context->streams.push_back(stream);

  *result = context;
  return nullptr;
}

NVPTXRT_EXPORT void AsyncRT_DeviceContext_retain(const NVPTXContext *context) {
  if (context)
    const_cast<NVPTXContext *>(context)->references.fetch_add(1);
}

NVPTXRT_EXPORT void AsyncRT_DeviceContext_release(const NVPTXContext *context) {
  if (!context)
    return;
  auto *mutableContext = const_cast<NVPTXContext *>(context);
  if (mutableContext->references.fetch_sub(1) != 1)
    return;
  cuCtxSetCurrent(mutableContext->context);
  for (NVPTXStream *stream : mutableContext->streams)
    releaseStream(stream);
  if (mutableContext->context)
    cuCtxDestroy(mutableContext->context);
  delete mutableContext;
}

NVPTXRT_EXPORT int64_t
AsyncRT_DeviceContext_id(const NVPTXContext *context) {
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
AsyncRT_DeviceContext_getApiVersion(int *result,
                                    const NVPTXContext *context) {
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
  CUresult status = cuCtxSynchronize();
  return status == CUDA_SUCCESS ? nullptr
                                : cudaError("cuCtxSynchronize", status);
}

NVPTXRT_EXPORT void AsyncRT_DeviceContext_strfree(const char *pointer) {
  free(const_cast<char *>(pointer));
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_getMemoryInfo(
    const NVPTXContext *context, size_t *freeMemory, size_t *totalMemory) {
  if (const char *error = setCurrent(context))
    return error;
  CUresult status = cuMemGetInfo(freeMemory, totalMemory);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuMemGetInfo", status);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_maxSingleAllocationSize(
    size_t *result, const NVPTXContext *context) {
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

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_computeCapability(
    int32_t *result, const NVPTXContext *context) {
  if (!context)
    return errf("computeCapability: null context");
  if (result)
    *result = context->computeCapability;
  return nullptr;
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_getAttribute(
    int *result, const NVPTXContext *context, int attribute) {
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
    *devicePointer = reinterpret_cast<void *>(
        static_cast<uintptr_t>(allocation));
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
  void *allocation = malloc(std::max<size_t>(bytes, 1));
  if (!allocation)
    return errf("createHostBuffer: out of memory (%zu bytes)", bytes);

  auto *buffer = new NVPTXBuffer();
  buffer->host = allocation;
  buffer->bytes = bytes;
  buffer->context = const_cast<NVPTXContext *>(context);
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
  buffer->device = static_cast<CUdeviceptr>(
      reinterpret_cast<uintptr_t>(devicePointer));
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
  if (mutableBuffer->host && mutableBuffer->owning)
    free(mutableBuffer->host);
  else if (mutableBuffer->device && mutableBuffer->owning) {
    cuCtxSetCurrent(context->context);
    cuMemFree(mutableBuffer->device);
  }
  delete mutableBuffer;
  AsyncRT_DeviceContext_release(context);
}

NVPTXRT_EXPORT void
AsyncRT_DeviceBuffer_release_ptr(const NVPTXBuffer *buffer) {
  if (buffer)
    const_cast<NVPTXBuffer *>(buffer)->owning = false;
  AsyncRT_DeviceBuffer_release(buffer);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_HtoD_async(
    const NVPTXContext *context, const NVPTXBuffer *destination,
    const void *source) {
  if (!destination || !source)
    return errf("HtoD_async: null argument");
  if (const char *error = setCurrent(context))
    return error;
  if (destination->host) {
    memcpy(destination->host, source, destination->bytes);
    return nullptr;
  }
  CUresult status =
      cuMemcpyHtoD(destination->device, source, destination->bytes);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuMemcpyHtoD", status);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_DtoH_async(
    const NVPTXContext *context, void *destination,
    const NVPTXBuffer *source) {
  if (!destination || !source)
    return errf("DtoH_async: null argument");
  if (const char *error = setCurrent(context))
    return error;
  if (source->host) {
    memcpy(destination, source->host, source->bytes);
    return nullptr;
  }
  CUresult status = cuMemcpyDtoH(destination, source->device, source->bytes);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuMemcpyDtoH", status);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_DtoD_async(
    const NVPTXContext *context, const NVPTXBuffer *destination,
    const NVPTXBuffer *source) {
  if (!destination || !source)
    return errf("DtoD_async: null argument");
  if (const char *error = setCurrent(context))
    return error;
  size_t bytes = std::min(destination->bytes, source->bytes);
  if (destination->host && source->host) {
    memcpy(destination->host, source->host, bytes);
    return nullptr;
  }

  CUresult status = CUDA_SUCCESS;
  const char *operation = nullptr;
  if (source->host) {
    operation = "cuMemcpyHtoD";
    status = cuMemcpyHtoD(destination->device, source->host, bytes);
  } else if (destination->host) {
    operation = "cuMemcpyDtoH";
    status = cuMemcpyDtoH(destination->host, source->device, bytes);
  } else {
    operation = "cuMemcpyDtoD";
    status = cuMemcpyDtoD(destination->device, source->device, bytes);
  }
  return status == CUDA_SUCCESS ? nullptr : cudaError(operation, status);
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_DtoD_async_no_cross_stream_sync(
    const NVPTXContext *context, const NVPTXBuffer *destination,
    const NVPTXBuffer *source) {
  return AsyncRT_DeviceContext_DtoD_async(context, destination, source);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_setMemory_async(
    const NVPTXContext *context, const NVPTXBuffer *destination, uint64_t value,
    size_t valueSize) {
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
    status = cuMemsetD8(destination->device, static_cast<unsigned char>(value),
                        destination->bytes);
  } else if (valueSize == 2 && destination->bytes % 2 == 0) {
    status = cuMemsetD16(destination->device,
                         static_cast<unsigned short>(value),
                         destination->bytes / 2);
  } else if (valueSize == 4 && destination->bytes % 4 == 0) {
    status = cuMemsetD32(destination->device, static_cast<unsigned int>(value),
                         destination->bytes / 4);
  } else {
    std::vector<unsigned char> staging(destination->bytes);
    for (size_t offset = 0; offset < staging.size(); offset += valueSize)
      memcpy(staging.data() + offset, &value,
             std::min(valueSize, staging.size() - offset));
    status = cuMemcpyHtoD(destination->device, staging.data(), staging.size());
  }
  return status == CUDA_SUCCESS ? nullptr : cudaError("CUDA memset", status);
}

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_createStream(
    const NVPTXStream **result, int priority, const NVPTXContext *context) {
  (void)priority;
  if (const char *error = setCurrent(context))
    return error;
  CUstream cudaStream = nullptr;
  CUresult status = cuStreamCreate(&cudaStream, 0);
  if (status != CUDA_SUCCESS)
    return cudaError("cuStreamCreate", status);
  auto *stream = new NVPTXStream();
  stream->stream = cudaStream;
  stream->context = const_cast<NVPTXContext *>(context);
  stream->owning = true;
  {
    std::lock_guard<std::mutex> lock(stream->context->mutex);
    stream->context->streams.push_back(stream);
  }
  if (result)
    *result = stream;
  return nullptr;
}

NVPTXRT_EXPORT const char *
AsyncRT_DeviceContext_stream(const NVPTXStream **result,
                             const NVPTXContext *context) {
  if (!context)
    return errf("stream: null context");
  if (result)
    *result = context->defaultStream;
  return nullptr;
}

NVPTXRT_EXPORT void AsyncRT_DeviceStream_retain(const NVPTXStream *stream) {
  if (stream)
    const_cast<NVPTXStream *>(stream)->references.fetch_add(1);
}

NVPTXRT_EXPORT void AsyncRT_DeviceStream_release(const NVPTXStream *stream) {
  if (stream)
    const_cast<NVPTXStream *>(stream)->references.fetch_sub(1);
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

NVPTXRT_EXPORT const char *AsyncRT_DeviceContext_enqueueFunctionDirect(
    const NVPTXContext *context, const NVPTXFunction *function,
    uint32_t gridX, uint32_t gridY, uint32_t gridZ, uint32_t blockX,
    uint32_t blockY, uint32_t blockZ, uint32_t sharedMemoryBytes,
    void *attributes, uint32_t attributeCount, void **arguments,
    uint32_t argumentCount, uint64_t *argumentSizes) {
  (void)attributes;
  (void)argumentCount;
  (void)argumentSizes;
  if (!context || !function)
    return errf("enqueueFunctionDirect: null argument");
  if (attributeCount)
    return errf("nvptxrt does not yet implement CUDA launch attributes");
  if (const char *error = setCurrent(context))
    return error;

  CUresult status = cuLaunchKernel(
      function->function, gridX, gridY, gridZ, blockX, blockY, blockZ,
      sharedMemoryBytes, context->defaultStream->stream, arguments, nullptr);
  return status == CUDA_SUCCESS ? nullptr : cudaError("cuLaunchKernel", status);
}

#undef NVPTXRT_EXPORT

} // extern "C"
