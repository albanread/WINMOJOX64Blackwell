/* Drive dragonrt.dll through its exported ABI only - exactly the way Mojo's
 * DeviceContext does, via the same symbols and the same calling convention.
 *
 * Nothing here includes a DragonMax header. If this passes, the ABI surface is
 * behaving as Mojo will find it: opaque handles, NULL-means-success error
 * strings owned by the caller, uint32 launch dimensions.
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

typedef struct { const char *data; size_t length; } StringRefABI;

static const char *(*DC_create)(const void **, const char *, int);
static void (*DC_release)(const void *);
static int64_t (*DC_id)(const void *);
static const char *(*DC_deviceName)(const void *);
static void (*DC_deviceApi)(StringRefABI *, const void *);
static const char *(*DC_getApiVersion)(int *, const void *);
static const char *(*DC_synchronize)(const void *);
static void (*DC_strfree)(const char *);
static const char *(*DC_getMemoryInfo)(const void *, size_t *, size_t *);
static const char *(*DC_maxAlloc)(size_t *, const void *);
static const char *(*DC_createBuffer)(const void **, void **, const void *, size_t, size_t);
static const char *(*DC_HtoD)(const void *, const void *, const void *);
static const char *(*DC_DtoH)(const void *, void *, const void *);
static const char *(*DC_loadFunction)(const void **, const void *, const char *,
                                      const char *, const char *, size_t, int32_t,
                                      const char *, int32_t);
static const char *(*DC_launch)(const void *, const void *, uint32_t, uint32_t,
                                uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                void *, uint32_t, void **, uint32_t, uint64_t *);
static int64_t (*DB_bytesize)(const void *);
static void (*DB_release)(const void *);
static void (*DF_release)(const void *);

static int fails = 0;

static void check(const char *what, const char *err) {
    if (err) {
        printf("  [FAIL] %s: %s\n", what, err);
        DC_strfree(err);
        ++fails;
    } else {
        printf("  [ok]   %s\n", what);
    }
}

/* saxpy, so the result is trivially checkable by hand. */
static const char *KSRC =
    "__kernel void saxpy(__global const float *x, __global const float *y,\n"
    "                    __global float *out, const float a)\n"
    "{ int i = get_global_id(0); out[i] = a * x[i] + y[i]; }\n";

#define N 4096

int main(int argc, char **argv) {
    HMODULE h = LoadLibraryA("dragonrt.dll");
    if (!h) { printf("cannot load dragonrt.dll (%lu)\n", GetLastError()); return 1; }

#define BIND(var, name)                                                        \
    var = (void *)GetProcAddress(h, name);                                     \
    if (!var) { printf("missing export %s\n", name); return 1; }

    BIND(DC_create, "AsyncRT_DeviceContext_create")
    BIND(DC_release, "AsyncRT_DeviceContext_release")
    BIND(DC_id, "AsyncRT_DeviceContext_id")
    BIND(DC_deviceName, "AsyncRT_DeviceContext_deviceName")
    BIND(DC_deviceApi, "AsyncRT_DeviceContext_deviceApi")
    BIND(DC_getApiVersion, "AsyncRT_DeviceContext_getApiVersion")
    BIND(DC_synchronize, "AsyncRT_DeviceContext_synchronize")
    BIND(DC_strfree, "AsyncRT_DeviceContext_strfree")
    BIND(DC_getMemoryInfo, "AsyncRT_DeviceContext_getMemoryInfo")
    BIND(DC_maxAlloc, "AsyncRT_DeviceContext_maxSingleAllocationSize")
    BIND(DC_createBuffer, "AsyncRT_DeviceContext_createBuffer_async")
    BIND(DC_HtoD, "AsyncRT_DeviceContext_HtoD_async")
    BIND(DC_DtoH, "AsyncRT_DeviceContext_DtoH_async")
    BIND(DC_loadFunction, "AsyncRT_DeviceContext_loadFunction")
    BIND(DC_launch, "AsyncRT_DeviceContext_enqueueFunctionDirect")
    BIND(DB_bytesize, "AsyncRT_DeviceBuffer_bytesize")
    BIND(DB_release, "AsyncRT_DeviceBuffer_release")
    BIND(DF_release, "AsyncRT_DeviceFunction_release")
#undef BIND
    printf("all bring-up exports resolved\n\n");

    const void *ctx = NULL;
    check("DeviceContext_create(\"adreno\", 0)", DC_create(&ctx, "adreno", 0));
    if (!ctx) { printf("no context, stopping\n"); return 1; }

    const char *nm = DC_deviceName(ctx);
    printf("  device : %s\n", nm ? nm : "?");
    if (nm) DC_strfree(nm);

    StringRefABI api = {0, 0};
    DC_deviceApi(&api, ctx);
    printf("  api    : %.*s   id=%lld\n", (int)api.length, api.data,
           (long long)DC_id(ctx));

    int ver = 0;
    check("getApiVersion", DC_getApiVersion(&ver, ctx));
    size_t freeMem = 0, totalMem = 0, maxAlloc = 0;
    check("getMemoryInfo", DC_getMemoryInfo(ctx, &freeMem, &totalMem));
    check("maxSingleAllocationSize", DC_maxAlloc(&maxAlloc, ctx));
    printf("  ver=%d  total=%zu MiB  maxAlloc=%zu MiB\n\n", ver,
           totalMem / (1024 * 1024), maxAlloc / (1024 * 1024));

    /* --- buffers + transfer + launch, the way Mojo drives it -------------- */
    const void *dx = NULL, *dy = NULL, *dout = NULL;
    void *px = NULL, *py = NULL, *pout = NULL;
    check("createBuffer x", DC_createBuffer(&dx, &px, ctx, N, sizeof(float)));
    check("createBuffer y", DC_createBuffer(&dy, &py, ctx, N, sizeof(float)));
    check("createBuffer out", DC_createBuffer(&dout, &pout, ctx, N, sizeof(float)));
    printf("  buffer bytesize reported: %lld (expected %d)\n",
           (long long)DB_bytesize(dx), (int)(N * sizeof(float)));

    float *hx = malloc(N * sizeof(float)), *hy = malloc(N * sizeof(float));
    float *hout = malloc(N * sizeof(float));
    for (int i = 0; i < N; ++i) { hx[i] = (float)i; hy[i] = (float)(N - i); }
    check("HtoD x", DC_HtoD(ctx, dx, hx));
    check("HtoD y", DC_HtoD(ctx, dy, hy));

    const void *fn = NULL;
    check("loadFunction(saxpy)",
          DC_loadFunction(&fn, ctx, "test_module", "saxpy", KSRC, strlen(KSRC), 0,
                          "none", 3));
    if (!fn) { printf("no kernel, stopping\n"); return 1; }

    float a = 2.5f;
    void *args[4] = {&dx, &dy, &dout, &a};
    /* Buffer args are cl_mem handles; the runtime dereferences args[i] for
     * `size` bytes, so pass the handle size for buffers and 4 for the float. */
    uint64_t sizes[4] = {sizeof(void *), sizeof(void *), sizeof(void *), sizeof(float)};

    /* The device-side handle lives inside our opaque buffer struct, so hand the
     * launch the same pointers Mojo would: pointers to the cl_mem values. */
    void *mx = px, *my = py, *mo = pout;
    void *args2[4] = {&mx, &my, &mo, &a};

    check("enqueueFunctionDirect",
          DC_launch(ctx, fn, N / 64, 1, 1, 64, 1, 1, 0, NULL, 0, args2, 4, sizes));
    check("synchronize", DC_synchronize(ctx));
    check("DtoH out", DC_DtoH(ctx, hout, dout));
    check("synchronize (after read)", DC_synchronize(ctx));

    int bad = 0;
    for (int i = 0; i < N; ++i) {
        float want = a * hx[i] + hy[i];
        if (fabsf(hout[i] - want) > 1e-3f) ++bad;
    }
    if (bad) { printf("\n  [FAIL] %d of %d elements wrong\n", bad, N); ++fails; }
    else printf("\n  [ok]   all %d elements correct (out[0]=%.1f out[%d]=%.1f)\n",
                N, hout[0], N - 1, hout[N - 1]);

    DF_release(fn);
    DB_release(dx); DB_release(dy); DB_release(dout);
    DC_release(ctx);
    free(hx); free(hy); free(hout);

    /* Optional: argv[1] = a .spv module. Drives it through loadFunction the
     * way a Mojo binary does - including the runtime's kernel-arg storage
     * bridge - then launches the saxpy shape and verifies numerically. */
    if (argc > 1) {
        FILE *f = fopen(argv[1], "rb");
        if (!f) { printf("cannot open %s\n", argv[1]); return 1; }
        fseek(f, 0, SEEK_END);
        long len = ftell(f);
        fseek(f, 0, SEEK_SET);
        char *spv = malloc(len);
        fread(spv, 1, (size_t)len, f);
        fclose(f);

        /* Entry-point name straight from the module's OpEntryPoint. */
        char entry[512] = {0};
        const unsigned *w = (const unsigned *)spv;
        long nw = len / 4;
        for (long i = 5; i < nw;) {
            unsigned wc = w[i] >> 16, op = w[i] & 0xFFFFu;
            if (!wc) break;
            if (op == 15) {
                const char *nm = (const char *)&w[i + 3];
                strncpy(entry, nm, sizeof(entry) - 1);
                break;
            }
            i += wc;
        }
        printf("\n[spv] %s (%ld bytes), entry '%.60s...'\n", argv[1], len, entry);

        const void *ctx2 = NULL;
        check("spv: DeviceContext_create", DC_create(&ctx2, "adreno", 0));
        const void *fn2 = NULL;
        check("spv: loadFunction(module)",
              DC_loadFunction(&fn2, ctx2, "mojo_module", entry, spv, (size_t)len,
                              0, "none", 3));
        if (fn2) {
            const void *bx = NULL, *by = NULL, *bo = NULL;
            void *px2 = NULL, *py2 = NULL, *po2 = NULL;
            check("spv: buffers", DC_createBuffer(&bx, &px2, ctx2, N, 4));
            DC_createBuffer(&by, &py2, ctx2, N, 4);
            DC_createBuffer(&bo, &po2, ctx2, N, 4);
            float *hx2 = malloc(N * 4), *hy2 = malloc(N * 4), *ho2 = malloc(N * 4);
            for (int i = 0; i < N; ++i) { hx2[i] = (float)i; hy2[i] = (float)(N - i); }
            check("spv: HtoD", DC_HtoD(ctx2, bx, hx2));
            DC_HtoD(ctx2, by, hy2);
            float a2 = 2.5f;
            void *m1 = px2, *m2 = py2, *m3 = po2;
            void *args3[4] = {&m1, &m2, &m3, &a2};
            uint64_t sz3[4] = {sizeof(void *), sizeof(void *), sizeof(void *), 4};
            check("spv: launch",
                  DC_launch(ctx2, fn2, N / 64, 1, 1, 64, 1, 1, 0, NULL, 0, args3,
                            4, sz3));
            check("spv: synchronize", DC_synchronize(ctx2));
            check("spv: DtoH", DC_DtoH(ctx2, ho2, bo));
            DC_synchronize(ctx2);
            int bad2 = 0;
            for (int i = 0; i < N; ++i)
                if (fabsf(ho2[i] - (2.5f * hx2[i] + hy2[i])) > 1e-3f) ++bad2;
            if (bad2) { printf("  [FAIL] spv verify: %d wrong\n", bad2); ++fails; }
            else printf("  [ok]   spv verify: all %d elements correct\n", N);
        }
        DC_release(ctx2);
    }

    printf("\n%s\n", fails ? "FAILURES" : "ALL PASS - the MAX device ABI works on Adreno");
    return fails ? 1 : 0;
}
