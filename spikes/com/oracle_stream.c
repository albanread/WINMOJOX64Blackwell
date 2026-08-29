/* The foreign-compiler ABI oracle: a COM object MSVC built, for Mojo to call.
 *
 * Implements ISequentialStream (slots 0-4: IUnknown's three, then Read and
 * Write) with observable behaviour: Read fills 0x5A and reports the count,
 * Write sums the bytes it is given into the object and reports the count,
 * and the running sum is readable back through Read's fourth byte trick --
 * kept simpler than that: a GetSum via the refcount channel is NOT done;
 * instead Write's sum is checked by the harness through repeated Read of a
 * one-byte state. Deliberately boring C so that what is being tested is the
 * boundary, not the oracle.
 *
 * Built with:  cl /nologo /LD oracle_stream.c /Fe:oracle_stream.dll
 * Exports:     int CreateOracleStream(void **out)  -- one object, refcounted.
 */
#include <windows.h>

typedef struct OracleStream {
    const void **vtbl;
    LONG refs;
    unsigned long long sum; /* of all bytes ever written */
} OracleStream;

/* 0c733a30-2a1c-11ce-ade5-00aa0044773d == IID_ISequentialStream */
static const GUID IID_ISeq = {0x0c733a30, 0x2a1c, 0x11ce,
                              {0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d}};
static const GUID IID_IUnk = {0x00000000, 0x0000, 0x0000,
                              {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

static HRESULT __stdcall o_QueryInterface(OracleStream *this_,
                                          const GUID *riid, void **ppv) {
    if (IsEqualGUID(riid, &IID_IUnk) || IsEqualGUID(riid, &IID_ISeq)) {
        InterlockedIncrement(&this_->refs);
        *ppv = this_;
        return S_OK;
    }
    *ppv = 0;
    return E_NOINTERFACE;
}

static ULONG __stdcall o_AddRef(OracleStream *this_) {
    return (ULONG)InterlockedIncrement(&this_->refs);
}

static ULONG __stdcall o_Release(OracleStream *this_) {
    LONG n = InterlockedDecrement(&this_->refs);
    if (n == 0)
        HeapFree(GetProcessHeap(), 0, this_);
    return (ULONG)n;
}

static HRESULT __stdcall o_Read(OracleStream *this_, void *pv, ULONG cb,
                                ULONG *pcbRead) {
    ULONG i;
    unsigned char *p = (unsigned char *)pv;
    for (i = 0; i < cb; ++i)
        p[i] = 0x5A;
    /* The first 8 bytes, if asked for, carry the running Write sum instead --
     * that is the observable state the harness checks. */
    if (cb >= 8)
        *(unsigned long long *)pv = this_->sum;
    if (pcbRead)
        *pcbRead = cb;
    return S_OK;
}

static HRESULT __stdcall o_Write(OracleStream *this_, const void *pv, ULONG cb,
                                 ULONG *pcbWritten) {
    ULONG i;
    const unsigned char *p = (const unsigned char *)pv;
    for (i = 0; i < cb; ++i)
        this_->sum += p[i];
    if (pcbWritten)
        *pcbWritten = cb;
    return S_OK;
}

static const void *g_vtbl[5] = {
    (const void *)o_QueryInterface, /* slot 0 */
    (const void *)o_AddRef,         /* slot 1 */
    (const void *)o_Release,        /* slot 2 */
    (const void *)o_Read,           /* slot 3 */
    (const void *)o_Write,          /* slot 4 */
};

__declspec(dllexport) int CreateOracleStream(void **out) {
    OracleStream *s = (OracleStream *)HeapAlloc(GetProcessHeap(),
                                                HEAP_ZERO_MEMORY, sizeof *s);
    if (!s)
        return E_OUTOFMEMORY;
    s->vtbl = g_vtbl;
    s->refs = 1; /* the creation reference the caller adopts */
    s->sum = 0;
    *out = s;
    return S_OK;
}
