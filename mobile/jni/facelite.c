// facelite.c — on-device face detection + ArcFace-r100 embeddings for the phone, so it
// enriches its OWN photos offline instead of round-tripping to the desktop. Pure C over the
// classic TFLite C API (exported by libLiteRt.so); no OpenCV, no JNI. It replicates the
// desktop pipeline (csrc/face_opencv.cpp) EXACTLY — the algorithm was validated in Python
// (tools/mlphone/proto_full.py) to cosine 1.00000 against OpenCV FaceDetectorYN +
// FaceRecognizerSF.alignCrop + r100, so the phone's 512-d embeddings live in the same space
// as the desktop's and cluster together.
//
// Pipeline (see the "ALGORITHM VALIDATED" memory for the spec):
//   1. squish-resize the RGB image to 640x640, feed YuNet as BGR float 0-255 (YuNet is BGR!)
//   2. decode the 12 heads (group by shape; score = sqrt(cls*obj)) + NMS
//   3. 5-point Umeyama similarity align to 112x112 (ArcFace template)
//   4. r100 (fp16) embed on the RGB crop -> L2-normalised 512-d
//
// The caller (D / phoneindex) decodes+EXIF-rotates the image on the Qt thread and hands us a
// packed RGB888 buffer. Detection runs on XNNPACK (CPU); r100 can later move to the GPU
// delegate. TODO(quality): letterbox instead of squish, and align from the full-res buffer.

#include "tflite_c_api.h"
#if defined(__ANDROID__)
#include "litert/c/litert_common.h"
#include "litert/c/litert_environment.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_model_types.h"
#include "litert/c/litert_layout.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_compiled_model.h"
#include "litert/c/litert_tensor_buffer.h"
#include "litert/c/litert_tensor_buffer_requirements.h"
#define PW_R100_LITERT 1
#endif
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#if defined(__ANDROID__)
#include <android/log.h>
#define LOGE(...) __android_log_print(6, "pwface", __VA_ARGS__)
#else
#include <stdio.h>
#define LOGE(...) fprintf(stderr, __VA_ARGS__)
#endif

#define PW_FACE_EMB_DIM 512
#define YN 640            /* YuNet fixed input side */
#define AL 112            /* aligned crop side */

typedef struct {
    float x, y, w, h;                   /* box as fractions of the image */
    float score;
    float embedding[PW_FACE_EMB_DIM];   /* r100 feature, L2-normalised */
} PwFace;

/* One loaded model: the flatbuffer must outlive the interpreter, so we keep all three. */
typedef struct {
    TfLiteModel *model;
    TfLiteInterpreter *interp;
    TfLiteDelegate *xnn;
} Net;

static Net g_yunet;

/* ArcFace canonical 5-point template on a 112x112 crop (== SFace's alignCrop template). */
static const float TEMPLATE[5][2] = {
    {38.2946f, 51.6963f}, {73.5318f, 51.5014f}, {56.0252f, 71.7366f},
    {41.5493f, 92.3655f}, {70.7299f, 92.2041f}
};

static void net_free(Net *n)
{
    if (n->interp) TfLiteInterpreterDelete(n->interp);
    if (n->xnn)    TfLiteXNNPackDelegateDelete(n->xnn);
    if (n->model)  TfLiteModelDelete(n->model);
    memset(n, 0, sizeof *n);
}

static int net_load(Net *n, const char *path)
{
    memset(n, 0, sizeof *n);
    n->model = TfLiteModelCreateFromFile(path);
    if (!n->model) { LOGE("facelite: cannot load %s", path); return -1; }
    TfLiteInterpreterOptions *opt = TfLiteInterpreterOptionsCreate();
    TfLiteInterpreterOptionsSetNumThreads(opt, 4);
    n->xnn = TfLiteXNNPackDelegateCreate(NULL);              /* CPU, portable */
    if (n->xnn) TfLiteInterpreterOptionsAddDelegate(opt, n->xnn);
    n->interp = TfLiteInterpreterCreate(n->model, opt);
    TfLiteInterpreterOptionsDelete(opt);
    if (!n->interp || TfLiteInterpreterAllocateTensors(n->interp) != kTfLiteOk) {
        LOGE("facelite: interpreter/allocate failed for %s", path);
        net_free(n);
        return -1;
    }
    return 0;
}

/* --- r100 (the ArcFace embedder) -------------------------------------------------------
   On the phone it runs through the LiteRt Compiled Model API so it can use the GPU
   (LITERT_CL delegate) — ~5x faster than XNNPACK CPU, same embeddings (cosine 0.9999),
   with a CPU fallback if the GPU compile is rejected. On a non-Android host build (the
   offscreen decode/align test) it uses the classic TfLite interpreter. Both expose the
   same r100_init()/r100_embed(in112x112x3 RGB float, out PW_FACE_EMB_DIM raw floats). */
#if defined(PW_R100_LITERT)
/* r100 has two live paths on the phone: the LiteRt GPU (LITERT_CL) when the OpenCL/GL stack is
   reachable (proven on-device standalone), and the classic TfLite XNNPACK CPU otherwise — the
   app's restricted linker namespace can't always load OpenCL (libvndksupport.so), so we try GPU
   and fall back to the always-works CPU path. */
static LiteRtEnvironment g_env;
static LiteRtModel g_r100_model;
static LiteRtCompiledModel g_r100;
static LiteRtTensorBuffer g_r100_in, g_r100_out;
static Net g_r100_cpu;          /* classic XNNPACK fallback */
static int g_r100_gpu = 0;      /* 1 = the LiteRt GPU path is live */
#define PW_R100_READY (g_r100_gpu ? (g_r100 != NULL) : (g_r100_cpu.interp != NULL))

/* Everything the LiteRt GPU path may have created — tensor buffers first, the environment
   last — whether its init completed or stopped half-way. */
static void r100_free_gpu(void)
{
    if (g_r100_in)    LiteRtDestroyTensorBuffer(g_r100_in);
    if (g_r100_out)   LiteRtDestroyTensorBuffer(g_r100_out);
    if (g_r100)       LiteRtDestroyCompiledModel(g_r100);
    if (g_r100_model) LiteRtDestroyModel(g_r100_model);
    if (g_env)        LiteRtDestroyEnvironment(g_env);
    g_r100_in = g_r100_out = NULL; g_r100 = NULL; g_r100_model = NULL; g_env = NULL;
}

static void r100_free(void)
{
    r100_free_gpu();
    net_free(&g_r100_cpu);
    g_r100_gpu = 0;
}

/* Try the LiteRt GPU path only; 0 on success, -1 to let the caller fall back to CPU. */
static int r100_init_gpu(const char *path)
{
    if (LiteRtCreateEnvironment(0, NULL, &g_env) != kLiteRtStatusOk) return -1;
    if (LiteRtCreateModelFromFile(g_env, path, &g_r100_model) != kLiteRtStatusOk) return -1;
    LiteRtOptions opt;
    if (LiteRtCreateOptions(&opt) != kLiteRtStatusOk) return -1;
    LiteRtSetOptionsHardwareAccelerators(opt, kLiteRtHwAcceleratorGpu);
    LiteRtStatus cs = LiteRtCreateCompiledModel(g_env, g_r100_model, opt, &g_r100);
    LiteRtDestroyOptions(opt);
    if (cs != kLiteRtStatusOk) { LOGE("facelite: r100 GPU compile rejected (%d)", cs); return -1; }
    LiteRtRankedTensorType it; memset(&it, 0, sizeof it);
    it.element_type = kLiteRtElementTypeFloat32;
    it.layout.rank = 4;
    it.layout.dimensions[0] = 1; it.layout.dimensions[1] = AL; it.layout.dimensions[2] = AL; it.layout.dimensions[3] = 3;
    LiteRtRankedTensorType ot; memset(&ot, 0, sizeof ot);
    ot.element_type = kLiteRtElementTypeFloat32;
    ot.layout.rank = 2; ot.layout.dimensions[0] = 1; ot.layout.dimensions[1] = PW_FACE_EMB_DIM;
    LiteRtTensorBufferRequirements ir, orq;
    if (LiteRtGetCompiledModelInputBufferRequirements(g_r100, 0, 0, &ir) != kLiteRtStatusOk) return -1;
    if (LiteRtGetCompiledModelOutputBufferRequirements(g_r100, 0, 0, &orq) != kLiteRtStatusOk) return -1;
    if (LiteRtCreateManagedTensorBufferFromRequirements(g_env, &it, ir, &g_r100_in) != kLiteRtStatusOk) return -1;
    if (LiteRtCreateManagedTensorBufferFromRequirements(g_env, &ot, orq, &g_r100_out) != kLiteRtStatusOk) return -1;
    return 0;
}

static int r100_init(const char *path)
{
    r100_free();
    if (r100_init_gpu(path) == 0) {
        g_r100_gpu = 1;
        return 0;
    }
    /* GPU path failed (e.g. no OpenCL in the app namespace) — free ALL its partial state (a
       tensor buffer may exist without its sibling) and use the classic XNNPACK CPU r100
       (always works, ~1s/face; the pass is battery-gated and off the UI thread). */
    r100_free_gpu();
    LOGE("facelite: r100 on classic XNNPACK CPU (GPU unavailable here)");
    return net_load(&g_r100_cpu, path);
}

static int r100_embed(const float *in112, float *emb)
{
    if (!g_r100_gpu) {                       /* classic XNNPACK CPU */
        TfLiteTensor *rin = TfLiteInterpreterGetInputTensor(g_r100_cpu.interp, 0);
        memcpy(TfLiteTensorData(rin), in112, (size_t) AL * AL * 3 * sizeof(float));
        if (TfLiteInterpreterInvoke(g_r100_cpu.interp) != kTfLiteOk) return -1;
        const TfLiteTensor *rout = TfLiteInterpreterGetOutputTensor(g_r100_cpu.interp, 0);
        memcpy(emb, TfLiteTensorData(rout), (size_t) PW_FACE_EMB_DIM * sizeof(float));
        return 0;
    }
    void *p;
    if (LiteRtLockTensorBuffer(g_r100_in, &p, kLiteRtTensorBufferLockModeWrite) != kLiteRtStatusOk) return -1;
    memcpy(p, in112, (size_t) AL * AL * 3 * sizeof(float));
    LiteRtUnlockTensorBuffer(g_r100_in);
    LiteRtTensorBuffer ins[1] = { g_r100_in }, outs[1] = { g_r100_out };
    if (LiteRtRunCompiledModel(g_r100, 0, 1, ins, 1, outs) != kLiteRtStatusOk) return -1;
    void *o;
    if (LiteRtLockTensorBuffer(g_r100_out, &o, kLiteRtTensorBufferLockModeRead) != kLiteRtStatusOk) return -1;
    memcpy(emb, o, (size_t) PW_FACE_EMB_DIM * sizeof(float));
    LiteRtUnlockTensorBuffer(g_r100_out);
    return 0;
}
#else  /* host build: classic TfLite r100 (XNNPACK) */
static Net g_r100;
#define PW_R100_READY (g_r100.interp != NULL)
static void r100_free(void) { net_free(&g_r100); }
static int r100_init(const char *path) { return net_load(&g_r100, path); }
static int r100_embed(const float *in112, float *emb)
{
    TfLiteTensor *rin = TfLiteInterpreterGetInputTensor(g_r100.interp, 0);
    memcpy(TfLiteTensorData(rin), in112, (size_t) AL * AL * 3 * sizeof(float));
    if (TfLiteInterpreterInvoke(g_r100.interp) != kTfLiteOk) return -1;
    const TfLiteTensor *rout = TfLiteInterpreterGetOutputTensor(g_r100.interp, 0);
    memcpy(emb, TfLiteTensorData(rout), (size_t) PW_FACE_EMB_DIM * sizeof(float));
    return 0;
}
#endif

/* Loads YuNet (detect) + r100 (embed). 0 on success. Safe to call again (reloads). */
int pw_facelite_init(const char *yunet_tflite, const char *r100_tflite)
{
    net_free(&g_yunet);
    r100_free();
    if (net_load(&g_yunet, yunet_tflite) != 0) return -1;
    if (r100_init(r100_tflite) != 0) { net_free(&g_yunet); return -1; }
    return 0;
}

/* Bilinear sample one channel from a packed RGB888 buffer at (fx,fy). */
static inline float sample(const uint8_t *rgb, int W, int H, int stride, float fx, float fy, int ch)
{
    if (fx < 0) fx = 0;
    else if (fx > W - 1) fx = W - 1;
    if (fy < 0) fy = 0;
    else if (fy > H - 1) fy = H - 1;
    int x0 = (int) fx, y0 = (int) fy;
    int x1 = x0 + 1 < W ? x0 + 1 : x0, y1 = y0 + 1 < H ? y0 + 1 : y0;
    float ax = fx - x0, ay = fy - y0;
    const uint8_t *r = rgb + ch;
    float v00 = r[y0 * stride + x0 * 3], v01 = r[y0 * stride + x1 * 3];
    float v10 = r[y1 * stride + x0 * 3], v11 = r[y1 * stride + x1 * 3];
    return (v00 * (1 - ax) + v01 * ax) * (1 - ay) + (v10 * (1 - ax) + v11 * ax) * ay;
}

/* Detection candidate during decode. */
typedef struct { float x, y, w, h, score, lmk[10]; } Cand;

/* Heads of one stride, collected from the (shape-identified) YuNet outputs. */
typedef struct { int stride, N, ns; const float *s[2], *bbox, *kps; } Head;

static float iou(const Cand *a, const Cand *b)
{
    float ax2 = a->x + a->w, ay2 = a->y + a->h, bx2 = b->x + b->w, by2 = b->y + b->h;
    float ix1 = a->x > b->x ? a->x : b->x, iy1 = a->y > b->y ? a->y : b->y;
    float ix2 = ax2 < bx2 ? ax2 : bx2, iy2 = ay2 < by2 ? ay2 : by2;
    float iw = ix2 - ix1, ih = iy2 - iy1;
    if (iw <= 0 || ih <= 0) return 0;
    float inter = iw * ih;
    return inter / (a->w * a->h + b->w * b->h - inter + 1e-9f);
}

static int cand_cmp(const void *pa, const void *pb)
{
    float d = ((const Cand *) pb)->score - ((const Cand *) pa)->score;
    return d > 0 ? 1 : d < 0 ? -1 : 0;
}

/* Detects faces in a packed RGB888 image and fills `out` with boxes (as fractions) + 512-d
   embeddings. Returns the count written, or -1 on error. */
int pw_facelite_detect(const uint8_t *rgb, int W, int H, int stride, PwFace *out, int max_faces)
{
    if (!g_yunet.interp || !PW_R100_READY || !rgb || W <= 0 || H <= 0) return -1;

    /* 1. squish-resize to 640x640: keep an RGB copy (for alignment) and fill YuNet input BGR. */
    uint8_t *sq = (uint8_t *) malloc((size_t) YN * YN * 3);
    if (!sq) return -1;
    TfLiteTensor *yin = TfLiteInterpreterGetInputTensor(g_yunet.interp, 0);
    float *ydata = (float *) TfLiteTensorData(yin);
    float sx = (float) W / YN, sy = (float) H / YN;
    for (int oy = 0; oy < YN; ++oy) {
        for (int ox = 0; ox < YN; ++ox) {
            float fx = (ox + 0.5f) * sx - 0.5f, fy = (oy + 0.5f) * sy - 0.5f;
            float R = sample(rgb, W, H, stride, fx, fy, 0);
            float G = sample(rgb, W, H, stride, fx, fy, 1);
            float B = sample(rgb, W, H, stride, fx, fy, 2);
            int p = oy * YN + ox;
            sq[p * 3 + 0] = (uint8_t) (R + 0.5f);
            sq[p * 3 + 1] = (uint8_t) (G + 0.5f);
            sq[p * 3 + 2] = (uint8_t) (B + 0.5f);
            ydata[p * 3 + 0] = B;                /* YuNet wants BGR */
            ydata[p * 3 + 1] = G;
            ydata[p * 3 + 2] = R;
        }
    }

    /* 2. run YuNet + decode. */
    if (TfLiteInterpreterInvoke(g_yunet.interp) != kTfLiteOk) { free(sq); return -1; }
    Head heads[3] = { {8, 6400, 0, {0, 0}, 0, 0}, {16, 1600, 0, {0, 0}, 0, 0}, {32, 400, 0, {0, 0}, 0, 0} };
    int nout = TfLiteInterpreterGetOutputTensorCount(g_yunet.interp);
    for (int i = 0; i < nout; ++i) {
        const TfLiteTensor *t = TfLiteInterpreterGetOutputTensor(g_yunet.interp, i);
        if (TfLiteTensorNumDims(t) != 3) continue;
        int N = TfLiteTensorDim(t, 1), k = TfLiteTensorDim(t, 2);
        Head *h = NULL;
        for (int j = 0; j < 3; ++j) if (heads[j].N == N) { h = &heads[j]; break; }
        if (!h) continue;
        const float *d = (const float *) TfLiteTensorData(t);
        if (k == 1 && h->ns < 2) h->s[h->ns++] = d;
        else if (k == 4) h->bbox = d;
        else if (k == 10) h->kps = d;
    }

    const float CONF = 0.6f;
    int cap = 256, nc = 0;
    Cand *cand = (Cand *) malloc(sizeof(Cand) * cap);
    if (!cand) { free(sq); return -1; }
    for (int hi = 0; hi < 3; ++hi) {
        Head *h = &heads[hi];
        if (h->ns < 2 || !h->bbox || !h->kps) continue;
        int s = h->stride, cols = YN / s;
        for (int idx = 0; idx < h->N; ++idx) {
            float prod = h->s[0][idx] * h->s[1][idx];        /* cls*obj (order-agnostic) */
            float score = prod > 0 ? sqrtf(prod) : 0;
            if (score <= CONF) continue;
            int row = idx / cols, col = idx % cols;
            const float *b = h->bbox + idx * 4, *kp = h->kps + idx * 10;
            float cx = (col + b[0]) * s, cy = (row + b[1]) * s;
            float w = expf(b[2]) * s, hh = expf(b[3]) * s;
            if (nc == cap) {
                Cand *grown = (Cand *) realloc(cand, sizeof(Cand) * cap * 2);   /* keep cand on failure */
                if (!grown) { free(cand); free(sq); return -1; }
                cand = grown; cap *= 2;
            }
            Cand *c = &cand[nc++];
            c->x = cx - w / 2; c->y = cy - hh / 2; c->w = w; c->h = hh; c->score = score;
            for (int j = 0; j < 5; ++j) { c->lmk[2 * j] = (col + kp[2 * j]) * s; c->lmk[2 * j + 1] = (row + kp[2 * j + 1]) * s; }
        }
    }

    /* NMS (IOU 0.3). */
    qsort(cand, nc, sizeof(Cand), cand_cmp);
    int nkeep = 0, wrote = 0;
    Cand *keep = (Cand *) malloc(sizeof(Cand) * (nc ? nc : 1));
    if (!keep) { free(cand); free(sq); return -1; }
    for (int i = 0; i < nc && wrote < max_faces; ++i) {
        int ok = 1;
        for (int j = 0; j < nkeep; ++j) if (iou(&cand[i], &keep[j]) >= 0.3f) { ok = 0; break; }
        if (!ok) continue;
        keep[nkeep++] = cand[i];

        /* 3. Umeyama similarity (closed-form 2D) from the 5 landmarks to the template. */
        const float *L = cand[i].lmk;
        float smx = 0, smy = 0, dmx = 0, dmy = 0;
        for (int j = 0; j < 5; ++j) { smx += L[2 * j]; smy += L[2 * j + 1]; dmx += TEMPLATE[j][0]; dmy += TEMPLATE[j][1]; }
        smx /= 5; smy /= 5; dmx /= 5; dmy /= 5;
        float a = 0, bb = 0, norm = 0;
        for (int j = 0; j < 5; ++j) {
            float sxc = L[2 * j] - smx, syc = L[2 * j + 1] - smy;
            float dxc = TEMPLATE[j][0] - dmx, dyc = TEMPLATE[j][1] - dmy;
            a += sxc * dxc + syc * dyc;
            bb += sxc * dyc - syc * dxc;
            norm += sxc * sxc + syc * syc;
        }
        float m0 = a / norm, m1 = -bb / norm, m3 = bb / norm, m4 = a / norm;   /* linear src->dst */
        float m2 = dmx - (m0 * smx + m1 * smy), m5 = dmy - (m3 * smx + m4 * smy);
        /* invert the 2x3 affine to map dst(112) -> src(640) for sampling. */
        float det = m0 * m4 - m1 * m3;
        if (fabsf(det) < 1e-12f) { continue; }
        float i00 = m4 / det, i01 = -m1 / det, i10 = -m3 / det, i11 = m0 / det;

        /* 4. warp into a 112x112 RGB buffer, then embed (r100 on the GPU via LiteRt, or CPU). */
        float in112[AL * AL * 3];
        for (int dy = 0; dy < AL; ++dy) {
            for (int dx = 0; dx < AL; ++dx) {
                float ux = dx - m2, uy = dy - m5;
                float srcx = i00 * ux + i01 * uy, srcy = i10 * ux + i11 * uy;
                int p = (dy * AL + dx) * 3;
                in112[p + 0] = sample(sq, YN, YN, YN * 3, srcx, srcy, 0);   /* R */
                in112[p + 1] = sample(sq, YN, YN, YN * 3, srcx, srcy, 1);   /* G */
                in112[p + 2] = sample(sq, YN, YN, YN * 3, srcx, srcy, 2);   /* B */
            }
        }
        float emb[PW_FACE_EMB_DIM];
        if (r100_embed(in112, emb) != 0) {
            /* a face we found but could not embed: the result would be incomplete, and the
               caller would record the photo as scanned — fail the whole photo so it retries */
            free(keep); free(cand); free(sq);
            return -1;
        }
        float nrm = 0;
        for (int j = 0; j < PW_FACE_EMB_DIM; ++j) nrm += emb[j] * emb[j];
        nrm = sqrtf(nrm) + 1e-12f;

        PwFace *o = &out[wrote++];
        o->x = cand[i].x / YN; o->y = cand[i].y / YN; o->w = cand[i].w / YN; o->h = cand[i].h / YN;
        o->score = cand[i].score;
        for (int j = 0; j < PW_FACE_EMB_DIM; ++j) o->embedding[j] = emb[j] / nrm;
    }

    free(keep);
    free(cand);
    free(sq);
    return wrote;
}
