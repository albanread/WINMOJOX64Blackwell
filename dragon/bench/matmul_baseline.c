/* D2 baseline: fp32 matmul on Oryon CPU vs Adreno GPU, same process.
 *
 * The question this exists to answer is narrow and decides D3: is the Adreno
 * X1-45 worth building a device runtime for, or does the CPU already win?
 * Both paths get the same matrices, the same timer, and the same verification,
 * so the comparison is not an artefact of measuring them differently.
 *
 * No OpenCL SDK is installed, so the handful of entry points used here are
 * declared directly and resolved from OpenCL.dll at runtime. The C API is
 * stable and these signatures are from the Khronos spec.
 *
 * Build (from an ARM64 developer prompt, or via build.ps1):
 *     cl /O2 /favor:ARM64 /openmp /Fe:matmul_baseline.exe matmul_baseline.c
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#ifdef _OPENMP
#include <omp.h>
#endif

/* ---- OpenCL, declared rather than included ---------------------------- */

typedef void *cl_platform_id, *cl_device_id, *cl_context, *cl_command_queue;
typedef void *cl_mem, *cl_program, *cl_kernel;
typedef int cl_int;
typedef unsigned int cl_uint;
typedef unsigned long long cl_ulong, cl_bitfield;

#define CL_PLATFORM_NAME 0x0902
#define CL_DEVICE_NAME 0x102B
#define CL_DEVICE_TYPE_ALL 0xFFFFFFFF
#define CL_MEM_READ_ONLY (1 << 2)
#define CL_MEM_WRITE_ONLY (1 << 1)
#define CL_TRUE 1
#define CL_PROGRAM_BUILD_LOG 0x1183
#define CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE 0x11B3

typedef cl_int(__stdcall *pfn_GetPlatformIDs)(cl_uint, cl_platform_id *, cl_uint *);
typedef cl_int(__stdcall *pfn_GetPlatformInfo)(cl_platform_id, cl_uint, size_t, void *,
                                               size_t *);
typedef cl_int(__stdcall *pfn_GetDeviceIDs)(cl_platform_id, cl_bitfield, cl_uint,
                                            cl_device_id *, cl_uint *);
typedef cl_int(__stdcall *pfn_GetDeviceInfo)(cl_device_id, cl_uint, size_t, void *,
                                             size_t *);
typedef cl_context(__stdcall *pfn_CreateContext)(void *, cl_uint, const cl_device_id *,
                                                 void *, void *, cl_int *);
typedef cl_command_queue(__stdcall *pfn_CreateCommandQueue)(cl_context, cl_device_id,
                                                            cl_bitfield, cl_int *);
typedef cl_mem(__stdcall *pfn_CreateBuffer)(cl_context, cl_bitfield, size_t, void *,
                                            cl_int *);
typedef cl_program(__stdcall *pfn_CreateProgramWithSource)(cl_context, cl_uint,
                                                           const char **, const size_t *,
                                                           cl_int *);
typedef cl_int(__stdcall *pfn_BuildProgram)(cl_program, cl_uint, const cl_device_id *,
                                            const char *, void *, void *);
typedef cl_int(__stdcall *pfn_GetProgramBuildInfo)(cl_program, cl_device_id, cl_uint,
                                                   size_t, void *, size_t *);
typedef cl_kernel(__stdcall *pfn_CreateKernel)(cl_program, const char *, cl_int *);
typedef cl_int(__stdcall *pfn_SetKernelArg)(cl_kernel, cl_uint, size_t, const void *);
typedef cl_int(__stdcall *pfn_EnqueueWriteBuffer)(cl_command_queue, cl_mem, cl_uint,
                                                  size_t, size_t, const void *, cl_uint,
                                                  const void *, void *);
typedef cl_int(__stdcall *pfn_EnqueueReadBuffer)(cl_command_queue, cl_mem, cl_uint,
                                                 size_t, size_t, void *, cl_uint,
                                                 const void *, void *);
typedef cl_int(__stdcall *pfn_EnqueueNDRangeKernel)(cl_command_queue, cl_kernel, cl_uint,
                                                    const size_t *, const size_t *,
                                                    const size_t *, cl_uint,
                                                    const void *, void *);
typedef cl_int(__stdcall *pfn_Finish)(cl_command_queue);
typedef cl_int(__stdcall *pfn_GetKernelWorkGroupInfo)(cl_kernel, cl_device_id, cl_uint,
                                                      size_t, void *, size_t *);

static struct {
    pfn_GetPlatformIDs GetPlatformIDs;
    pfn_GetPlatformInfo GetPlatformInfo;
    pfn_GetDeviceIDs GetDeviceIDs;
    pfn_GetDeviceInfo GetDeviceInfo;
    pfn_CreateContext CreateContext;
    pfn_CreateCommandQueue CreateCommandQueue;
    pfn_CreateBuffer CreateBuffer;
    pfn_CreateProgramWithSource CreateProgramWithSource;
    pfn_BuildProgram BuildProgram;
    pfn_GetProgramBuildInfo GetProgramBuildInfo;
    pfn_CreateKernel CreateKernel;
    pfn_SetKernelArg SetKernelArg;
    pfn_EnqueueWriteBuffer EnqueueWriteBuffer;
    pfn_EnqueueReadBuffer EnqueueReadBuffer;
    pfn_EnqueueNDRangeKernel EnqueueNDRangeKernel;
    pfn_Finish Finish;
    pfn_GetKernelWorkGroupInfo GetKernelWorkGroupInfo;
} cl;

#define LOAD(h, name)                                                        \
    do {                                                                     \
        cl.name = (pfn_##name)GetProcAddress(h, "cl" #name);                 \
        if (!cl.name) {                                                      \
            printf("missing entry point cl%s\n", #name);                     \
            return 0;                                                        \
        }                                                                    \
    } while (0)

static int load_opencl(void) {
    HMODULE h = LoadLibraryA("OpenCL.dll");
    if (!h) {
        printf("cannot load OpenCL.dll\n");
        return 0;
    }
    LOAD(h, GetPlatformIDs);
    LOAD(h, GetPlatformInfo);
    LOAD(h, GetDeviceIDs);
    LOAD(h, GetDeviceInfo);
    LOAD(h, CreateContext);
    LOAD(h, CreateCommandQueue);
    LOAD(h, CreateBuffer);
    LOAD(h, CreateProgramWithSource);
    LOAD(h, BuildProgram);
    LOAD(h, GetProgramBuildInfo);
    LOAD(h, CreateKernel);
    LOAD(h, SetKernelArg);
    LOAD(h, EnqueueWriteBuffer);
    LOAD(h, EnqueueReadBuffer);
    LOAD(h, EnqueueNDRangeKernel);
    LOAD(h, Finish);
    LOAD(h, GetKernelWorkGroupInfo);
    return 1;
}

/* ---- timing ------------------------------------------------------------ */

static double now_s(void) {
    static LARGE_INTEGER freq;
    LARGE_INTEGER t;
    if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart / (double)freq.QuadPart;
}

/* ---- the workload ------------------------------------------------------ */

#ifndef MATN
#define MATN 1024
#endif
#define TILE 16

static const char *KSRC =
    "#define TILE 16\n"
    "__kernel void matmul_tiled(__global const float *A,\n"
    "                           __global const float *B,\n"
    "                           __global float *C, const int N)\n"
    "{\n"
    "    __local float As[TILE][TILE];\n"
    "    __local float Bs[TILE][TILE];\n"
    "    int lr = get_local_id(1), lc = get_local_id(0);\n"
    "    int r  = get_global_id(1), c = get_global_id(0);\n"
    "    float acc = 0.0f;\n"
    "    for (int t = 0; t < N / TILE; ++t) {\n"
    "        As[lr][lc] = A[r * N + (t * TILE + lc)];\n"
    "        Bs[lr][lc] = B[(t * TILE + lr) * N + c];\n"
    "        barrier(CLK_LOCAL_MEM_FENCE);\n"
    "        for (int k = 0; k < TILE; ++k) acc += As[lr][k] * Bs[k][lc];\n"
    "        barrier(CLK_LOCAL_MEM_FENCE);\n"
    "    }\n"
    "    C[r * N + c] = acc;\n"
    "}\n";

static void cpu_matmul(const float *A, const float *B, float *C, int N) {
    /* i-k-j so the inner loop walks B and C contiguously; this is what a
     * competent-but-not-hand-tuned CPU path looks like, which is the honest
     * thing to compare a first-cut GPU kernel against. */
    memset(C, 0, (size_t)N * N * sizeof(float));
    int i;
#ifdef _OPENMP
#pragma omp parallel for schedule(static)
#endif
    for (i = 0; i < N; ++i) {
        for (int k = 0; k < N; ++k) {
            float a = A[(size_t)i * N + k];
            const float *b = &B[(size_t)k * N];
            float *c = &C[(size_t)i * N];
            for (int j = 0; j < N; ++j) c[j] += a * b[j];
        }
    }
}

static int pick_qualcomm(cl_platform_id *out_p, cl_device_id *out_d) {
    cl_uint np = 0;
    if (cl.GetPlatformIDs(0, NULL, &np) != 0 || np == 0) return 0;
    cl_platform_id *ps = malloc(np * sizeof(*ps));
    cl.GetPlatformIDs(np, ps, NULL);
    for (cl_uint i = 0; i < np; ++i) {
        char name[256] = {0};
        cl.GetPlatformInfo(ps[i], CL_PLATFORM_NAME, sizeof(name), name, NULL);
        /* By platform, never by device name: OpenCLOn12 reports the same
         * device string as the native driver. */
        if (!strstr(name, "QUALCOMM")) continue;
        cl_uint nd = 0;
        if (cl.GetDeviceIDs(ps[i], CL_DEVICE_TYPE_ALL, 0, NULL, &nd) != 0 || !nd)
            continue;
        cl_device_id *ds = malloc(nd * sizeof(*ds));
        cl.GetDeviceIDs(ps[i], CL_DEVICE_TYPE_ALL, nd, ds, NULL);
        *out_p = ps[i];
        *out_d = ds[0];
        free(ds);
        free(ps);
        return 1;
    }
    free(ps);
    return 0;
}

int main(void) {
    const int N = MATN;
    const double flop = 2.0 * (double)N * N * N;
    printf("DragonMax D2 baseline - fp32 matmul %dx%d (%.2f GFLOP)\n\n", N, N,
           flop / 1e9);

    size_t bytes = (size_t)N * N * sizeof(float);
    float *A = malloc(bytes), *B = malloc(bytes);
    float *C_cpu = malloc(bytes), *C_gpu = malloc(bytes);
    if (!A || !B || !C_cpu || !C_gpu) {
        printf("out of memory\n");
        return 1;
    }
    for (int i = 0; i < N * N; ++i) {
        A[i] = (float)((i * 37 % 101) - 50) / 50.0f;
        B[i] = (float)((i * 17 % 97) - 48) / 48.0f;
    }

    /* ---- CPU ---------------------------------------------------------- */
    int threads = 1;
#ifdef _OPENMP
    threads = omp_get_max_threads();
#endif
    cpu_matmul(A, B, C_cpu, N); /* warm the caches and the thread pool */
    double t0 = now_s();
    cpu_matmul(A, B, C_cpu, N);
    double cpu_s = now_s() - t0;
    printf("CPU  (Oryon, %d threads) : %7.1f ms   %6.2f GFLOP/s\n", threads,
           cpu_s * 1e3, flop / cpu_s / 1e9);

    /* ---- GPU ---------------------------------------------------------- */
    if (!load_opencl()) return 1;
    cl_platform_id plat;
    cl_device_id dev;
    if (!pick_qualcomm(&plat, &dev)) {
        printf("GPU  : no QUALCOMM OpenCL platform\n");
        return 1;
    }
    char dname[256] = {0};
    cl.GetDeviceInfo(dev, CL_DEVICE_NAME, sizeof(dname), dname, NULL);

    cl_int err = 0;
    cl_context ctx = cl.CreateContext(NULL, 1, &dev, NULL, NULL, &err);
    cl_command_queue q = cl.CreateCommandQueue(ctx, dev, 0, &err);
    size_t srclen = strlen(KSRC);
    cl_program prog = cl.CreateProgramWithSource(ctx, 1, &KSRC, &srclen, &err);
    if (cl.BuildProgram(prog, 1, &dev, NULL, NULL, NULL) != 0) {
        size_t n = 0;
        cl.GetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, 0, NULL, &n);
        char *log = malloc(n + 1);
        cl.GetProgramBuildInfo(prog, dev, CL_PROGRAM_BUILD_LOG, n, log, NULL);
        log[n] = 0;
        printf("GPU  : build failed\n%s\n", log);
        return 1;
    }
    cl_kernel k = cl.CreateKernel(prog, "matmul_tiled", &err);

    size_t mult = 0;
    cl.GetKernelWorkGroupInfo(k, dev, CL_KERNEL_PREFERRED_WORK_GROUP_SIZE_MULTIPLE,
                              sizeof(mult), &mult, NULL);

    cl_mem dA = cl.CreateBuffer(ctx, CL_MEM_READ_ONLY, bytes, NULL, &err);
    cl_mem dB = cl.CreateBuffer(ctx, CL_MEM_READ_ONLY, bytes, NULL, &err);
    cl_mem dC = cl.CreateBuffer(ctx, CL_MEM_WRITE_ONLY, bytes, NULL, &err);

    double h0 = now_s();
    cl.EnqueueWriteBuffer(q, dA, CL_TRUE, 0, bytes, A, 0, NULL, NULL);
    cl.EnqueueWriteBuffer(q, dB, CL_TRUE, 0, bytes, B, 0, NULL, NULL);
    cl.Finish(q);
    double h2d_s = now_s() - h0;

    cl.SetKernelArg(k, 0, sizeof(cl_mem), &dA);
    cl.SetKernelArg(k, 1, sizeof(cl_mem), &dB);
    cl.SetKernelArg(k, 2, sizeof(cl_mem), &dC);
    cl.SetKernelArg(k, 3, sizeof(int), &N);

    size_t gws[2] = {(size_t)N, (size_t)N};
    size_t lws[2] = {TILE, TILE};

    cl.EnqueueNDRangeKernel(q, k, 2, NULL, gws, lws, 0, NULL, NULL); /* warm */
    cl.Finish(q);

    double g0 = now_s();
    cl.EnqueueNDRangeKernel(q, k, 2, NULL, gws, lws, 0, NULL, NULL);
    cl.Finish(q);
    double gpu_s = now_s() - g0;

    double d0 = now_s();
    cl.EnqueueReadBuffer(q, dC, CL_TRUE, 0, bytes, C_gpu, 0, NULL, NULL);
    cl.Finish(q);
    double d2h_s = now_s() - d0;

    printf("GPU  (%s)\n", dname);
    printf("       kernel only        : %7.1f ms   %6.2f GFLOP/s\n", gpu_s * 1e3,
           flop / gpu_s / 1e9);
    printf("       H2D %.1f ms + D2H %.1f ms -> with transfers: %6.2f GFLOP/s\n",
           h2d_s * 1e3, d2h_s * 1e3, flop / (gpu_s + h2d_s + d2h_s) / 1e9);
    printf("       tile %dx%d, local %zu B, preferred multiple %zu\n", TILE, TILE,
           (size_t)(2 * TILE * TILE * sizeof(float)), mult);

    /* ---- verify: a fast wrong answer is worth nothing ------------------ */
    double worst = 0.0;
    long bad = 0;
    for (int i = 0; i < N * N; ++i) {
        double d = fabs((double)C_gpu[i] - (double)C_cpu[i]);
        double scale = fabs((double)C_cpu[i]) + 1e-3;
        if (d / scale > 1e-4) ++bad;
        if (d > worst) worst = d;
    }
    printf("\nverify: %s  (worst abs diff %.3g, %ld of %d elements outside 1e-4)\n",
           bad ? "MISMATCH" : "ok", worst, bad, N * N);

    printf("\nspeedup (kernel only)   : %.2fx CPU\n", cpu_s / gpu_s);
    printf("speedup (with transfers): %.2fx CPU\n", cpu_s / (gpu_s + h2d_s + d2h_s));
    return bad ? 1 : 0;
}
