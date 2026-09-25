// Standalone GPU r100 test via the LiteRt Compiled Model API. Loads r100 fp16, compiles it
// for the GPU, feeds the aligned 112x112x3 RGB crop (py_r100in.f32), and reports whether the
// GPU actually accelerated it, the timing, and the cosine vs the desktop reference.
#include "litert/c/litert_common.h"
#include "litert/c/litert_environment.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_model_types.h"
#include "litert/c/litert_layout.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_compiled_model.h"
#include "litert/c/litert_tensor_buffer.h"
#include "litert/c/litert_tensor_buffer_requirements.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
#define CK(call) do{ LiteRtStatus _s=(call); if(_s!=kLiteRtStatusOk){ printf("FAIL %s -> %d\n", #call, _s); return 1; } }while(0)

int main(int argc, char** argv){
    // argv: r100.tflite in_112x112x3.f32 ref512.f32
    LiteRtEnvironment env; CK(LiteRtCreateEnvironment(0, NULL, &env));
    LiteRtModel model;     CK(LiteRtCreateModelFromFile(env, argv[1], &model));
    LiteRtOptions opts;    CK(LiteRtCreateOptions(&opts));
    CK(LiteRtSetOptionsHardwareAccelerators(opts, kLiteRtHwAcceleratorGpu));
    double tc=now();
    LiteRtCompiledModel compiled;
    LiteRtStatus cs = LiteRtCreateCompiledModel(env, model, opts, &compiled);
    printf("compile(GPU): %d  (%.0f ms)\n", cs, now()-tc);
    if (cs != kLiteRtStatusOk){ printf("GPU compile rejected\n"); return 1; }
    bool nonCpu=false; LiteRtCompiledModelIsFullyAccelerated(compiled, &nonCpu);
    printf("fully accelerated (any delegate): %s\n", nonCpu?"YES":"no");

    LiteRtRankedTensorType inType; memset(&inType,0,sizeof inType);
    inType.element_type = kLiteRtElementTypeFloat32;
    inType.layout.rank = 4; inType.layout.dimensions[0]=1; inType.layout.dimensions[1]=112; inType.layout.dimensions[2]=112; inType.layout.dimensions[3]=3;
    LiteRtRankedTensorType outType; memset(&outType,0,sizeof outType);
    outType.element_type = kLiteRtElementTypeFloat32;
    outType.layout.rank = 2; outType.layout.dimensions[0]=1; outType.layout.dimensions[1]=512;

    LiteRtTensorBufferRequirements inReq, outReq;
    CK(LiteRtGetCompiledModelInputBufferRequirements(compiled, 0, 0, &inReq));
    CK(LiteRtGetCompiledModelOutputBufferRequirements(compiled, 0, 0, &outReq));
    LiteRtTensorBuffer inBuf, outBuf;
    CK(LiteRtCreateManagedTensorBufferFromRequirements(env, &inType, inReq, &inBuf));
    CK(LiteRtCreateManagedTensorBufferFromRequirements(env, &outType, outReq, &outBuf));

    // fill input from the aligned crop file
    float* pin; CK(LiteRtLockTensorBuffer(inBuf, (void**)&pin, kLiteRtTensorBufferLockModeWrite));
    FILE* f=fopen(argv[2],"rb"); if(!f){printf("no input\n");return 1;} fread(pin, 4, 112*112*3, f); fclose(f);
    CK(LiteRtUnlockTensorBuffer(inBuf));

    LiteRtTensorBuffer ins[1]={inBuf}, outs[1]={outBuf};
    double nrm=0; float* po=NULL;
    for(int r=0;r<6;r++){ double t=now();
        CK(LiteRtRunCompiledModel(compiled, 0, 1, ins, 1, outs));
        CK(LiteRtLockTensorBuffer(outBuf, (void**)&po, kLiteRtTensorBufferLockModeRead));  // forces GPU sync
        nrm=0; for(int i=0;i<512;i++) nrm+=po[i]*po[i]; nrm=sqrt(nrm)+1e-12;
        printf("run+sync #%d: %.0f ms\n", r, now()-t);
        CK(LiteRtUnlockTensorBuffer(outBuf));
    }
    CK(LiteRtLockTensorBuffer(outBuf, (void**)&po, kLiteRtTensorBufferLockModeRead));
    float ref[512]; FILE* rf=fopen(argv[3],"rb"); if(rf){ fread(ref,4,512,rf); fclose(rf);
        double c=0; for(int i=0;i<512;i++) c+=(po[i]/nrm)*ref[i];
        printf("COSINE(GPU r100) vs desktop = %.5f  %s\n", c, c>0.97?"PASS":"CHECK");
    }
    CK(LiteRtUnlockTensorBuffer(outBuf));
    return 0;
}
