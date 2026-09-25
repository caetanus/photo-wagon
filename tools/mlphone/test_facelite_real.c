// On-device (Android) validation of facelite.c with the REAL libLiteRt + tflite models.
// Args: yunet.tflite r100.tflite testface.rgb W H ref640_emb.f32
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
#define EMB 512
typedef struct { float x,y,w,h,score; float embedding[EMB]; } PwFace;
int pw_facelite_init(const char*, const char*);
int pw_facelite_detect(const unsigned char*, int, int, int, PwFace*, int);
int main(int argc, char** argv){
    if (argc < 7){ printf("usage: %s yunet r100 rgb W H ref\n", argv[0]); return 2; }
    double t0=now(); if (pw_facelite_init(argv[1], argv[2])){ printf("INIT FAILED\n"); return 1; } printf("init: %.0f ms\n", now()-t0);
    int W=atoi(argv[4]), H=atoi(argv[5]);
    unsigned char* rgb = (unsigned char*)malloc((size_t)W*H*3);
    FILE* f=fopen(argv[3],"rb"); if(!f){printf("no rgb\n");return 1;} fread(rgb,1,(size_t)W*H*3,f); fclose(f);
    PwFace out[16]; int n=0;
    for(int r=0;r<3;r++){ double td=now(); n=pw_facelite_detect(rgb, W, H, W*3, out, 16); printf("detect #%d: %.0f ms (%d faces)\n", r, now()-td, n); }
    printf("ON-DEVICE detected %d faces\n", n);
    if (n < 1) return 1;
    printf("face0 bbox(frac) %.4f %.4f %.4f %.4f  score %.3f\n", out[0].x,out[0].y,out[0].w,out[0].h,out[0].score);
    printf("emb[:4] = %.4f %.4f %.4f %.4f\n", out[0].embedding[0],out[0].embedding[1],out[0].embedding[2],out[0].embedding[3]);
    float ref[EMB]; FILE* rf=fopen(argv[6],"rb"); if(rf){ fread(ref,4,EMB,rf); fclose(rf);
        double c=0; for(int i=0;i<EMB;i++) c+=out[0].embedding[i]*ref[i];
        printf("COSINE vs desktop reference = %.5f  %s\n", c, c>0.97?"PASS":"CHECK");
    }
    return 0;
}
