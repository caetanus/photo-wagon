// Host validation of facelite.c's hand-ported decode+NMS+Umeyama+warp, WITHOUT libLiteRt
// (the Android .so won't load on glibc). We stub the TFLite C API: the YuNet "interpreter"
// returns the 12 output heads dumped from Python (tools/mlphone/dump/out_*.f32), so the C
// runs its REAL decode/align, and we capture the r100 input buffer it fills and compare it to
// Python's aligned crop (dump/py_r100in.f32). Match => the C port is numerically correct.
#include "tflite_c_api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct TfLiteModel { int which; };                 /* 0 = yunet, 1 = r100 */
struct TfLiteInterpreterOptions { int _; };
struct TfLiteDelegate { int _; };
struct TfLiteTensor { int ndims; int dims[4]; float *data; };
struct TfLiteInterpreter { int which; struct TfLiteTensor in; struct TfLiteTensor out[12]; int nout; };

static float *g_r100_input = NULL;                 /* captured: what the C shim fed r100 */

TfLiteModel *TfLiteModelCreateFromFile(const char *path) {
    TfLiteModel *m = calloc(1, sizeof *m);
    m->which = strstr(path, "yunet") ? 0 : 1;
    return m;
}
void TfLiteModelDelete(TfLiteModel *m) { free(m); }
TfLiteInterpreterOptions *TfLiteInterpreterOptionsCreate(void) { return calloc(1, sizeof(TfLiteInterpreterOptions)); }
void TfLiteInterpreterOptionsDelete(TfLiteInterpreterOptions *o) { free(o); }
void TfLiteInterpreterOptionsSetNumThreads(TfLiteInterpreterOptions *o, int32_t n) { (void)o; (void)n; }
void TfLiteInterpreterOptionsAddDelegate(TfLiteInterpreterOptions *o, TfLiteDelegate *d) { (void)o; (void)d; }
TfLiteDelegate *TfLiteXNNPackDelegateCreate(const void *o) { (void)o; return calloc(1, sizeof(TfLiteDelegate)); }
void TfLiteXNNPackDelegateDelete(TfLiteDelegate *d) { free(d); }

TfLiteInterpreter *TfLiteInterpreterCreate(const TfLiteModel *m, const TfLiteInterpreterOptions *o) {
    (void)o;
    TfLiteInterpreter *it = calloc(1, sizeof *it);
    it->which = m->which;
    if (m->which == 0) {                            /* yunet: 640x640x3 in, 12 heads out from dump */
        it->in.ndims = 4; it->in.dims[0]=1; it->in.dims[1]=640; it->in.dims[2]=640; it->in.dims[3]=3;
        it->in.data = malloc(sizeof(float)*640*640*3);
        FILE *mf = fopen("tools/mlphone/dump/manifest.txt","r");
        int idx, N, k; it->nout = 0;
        while (mf && fscanf(mf, "%d %d %d", &idx, &N, &k) == 3) {
            struct TfLiteTensor *t = &it->out[idx];
            t->ndims = 3; t->dims[0]=1; t->dims[1]=N; t->dims[2]=k;
            t->data = malloc(sizeof(float)*N*k);
            char p[128]; snprintf(p, sizeof p, "tools/mlphone/dump/out_%d.f32", idx);
            FILE *df = fopen(p,"rb"); fread(t->data, sizeof(float), (size_t)N*k, df); fclose(df);
            if (idx+1 > it->nout) it->nout = idx+1;
        }
        if (mf) fclose(mf);
    } else {                                        /* r100: 112x112x3 in, 512 out */
        it->in.ndims = 4; it->in.dims[0]=1; it->in.dims[1]=112; it->in.dims[2]=112; it->in.dims[3]=3;
        it->in.data = calloc(112*112*3, sizeof(float));
        g_r100_input = it->in.data;                 /* capture */
        it->nout = 1; it->out[0].ndims=2; it->out[0].dims[0]=1; it->out[0].dims[1]=512;
        it->out[0].data = calloc(512, sizeof(float));
    }
    return it;
}
void TfLiteInterpreterDelete(TfLiteInterpreter *it) { (void)it; }
TfLiteStatus TfLiteInterpreterAllocateTensors(TfLiteInterpreter *it) { (void)it; return kTfLiteOk; }
TfLiteStatus TfLiteInterpreterInvoke(TfLiteInterpreter *it) { (void)it; return kTfLiteOk; }   /* heads already loaded */
int32_t TfLiteInterpreterGetInputTensorCount(const TfLiteInterpreter *it) { (void)it; return 1; }
TfLiteTensor *TfLiteInterpreterGetInputTensor(const TfLiteInterpreter *it, int32_t i) { (void)i; return &((TfLiteInterpreter*)it)->in; }
int32_t TfLiteInterpreterGetOutputTensorCount(const TfLiteInterpreter *it) { return it->nout; }
const TfLiteTensor *TfLiteInterpreterGetOutputTensor(const TfLiteInterpreter *it, int32_t i) { return &it->out[i]; }
void *TfLiteTensorData(const TfLiteTensor *t) { return t->data; }
int32_t TfLiteTensorNumDims(const TfLiteTensor *t) { return t->ndims; }
int32_t TfLiteTensorDim(const TfLiteTensor *t, int32_t i) { return t->dims[i]; }
size_t TfLiteTensorByteSize(const TfLiteTensor *t) { size_t n=sizeof(float); for(int i=0;i<t->ndims;i++) n*=t->dims[i]; return n; }
TfLiteType TfLiteTensorType(const TfLiteTensor *t) { (void)t; return kTfLiteFloat32; }

/* facelite.c's public API (redeclared; struct layout must match) */
#define PW_FACE_EMB_DIM 512
typedef struct { float x,y,w,h,score; float embedding[PW_FACE_EMB_DIM]; } PwFace;
int pw_facelite_init(const char*, const char*);
int pw_facelite_detect(const unsigned char*, int, int, int, PwFace*, int);

int main(void) {
    unsigned char *rgb = malloc(640*640*3);
    FILE *f = fopen("tools/mlphone/dump/img640.rgb","rb");
    if (!f) { printf("no img640.rgb\n"); return 1; }
    fread(rgb, 1, 640*640*3, f); fclose(f);

    if (pw_facelite_init("yunet.tflite","r100.tflite") != 0) { printf("init failed\n"); return 1; }
    PwFace out[8];
    int n = pw_facelite_detect(rgb, 640, 640, 640*3, out, 8);
    printf("C detected %d faces\n", n);
    if (n < 1) return 1;
    printf("C face0 bbox(frac*640) = %.1f %.1f %.1f %.1f  score=%.3f\n",
           out[0].x*640, out[0].y*640, out[0].w*640, out[0].h*640, out[0].score);

    /* compare the r100 input buffer the C shim produced to Python's aligned crop */
    float *py = malloc(sizeof(float)*112*112*3);
    FILE *pf = fopen("tools/mlphone/dump/py_r100in.f32","rb");
    fread(py, sizeof(float), 112*112*3, pf); fclose(pf);
    double sad=0, mx=0; for (int i=0;i<112*112*3;i++){ double d=fabs(g_r100_input[i]-py[i]); sad+=d; if(d>mx)mx=d; }
    printf("r100-input C-vs-Python: mean|Δ|=%.4f  max|Δ|=%.2f (0-255 scale)  %s\n",
           sad/(112*112*3), mx, (sad/(112*112*3) < 1.0) ? "PASS" : "CHECK");
    return 0;
}
