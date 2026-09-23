/* face_opencv.h — C surface over OpenCV's YuNet detector + a face embedder.
 *
 * Why C++ exists in this repository: OpenCV 5 has no C API for FaceDetectorYN
 * and FaceRecognizerSF (the legacy C API was removed in 4.x). This file is the
 * whole boundary: plain structs, no OpenCV type crosses it.
 *
 * Detection + the 112x112 alignment are YuNet + SFace's alignCrop (a 5-point
 * similarity warp — model-independent). The EMBEDDING is ArcFace ResNet-100
 * (arcfaceresnet100-8, 512-d) run through cv::dnn: measured on the real library
 * it separates DIFFERENT people far better than SFace (co-occurring cosine mean
 * 0.075 vs 0.178), which is what stops different babies/siblings — whose adult-
 * trained SFace features sit ~0.72 apart — from being merged into one person.
 * The model's ONNX carries its own normalisation (Sub/Mul on the "data" input),
 * so it is fed RAW pixels; embeddings are L2-normalised, so "same" is a cosine.
 */
#ifndef FACE_OPENCV_H
#define FACE_OPENCV_H

#ifdef __cplusplus
extern "C" {
#endif

#define PW_FACE_EMB_DIM 512

/* Loads: YuNet (detect) + SFace (alignment only) + the ArcFace embedder.
   0 on success. Safe to call more than once. */
int pw_face_init(const char *yunet_onnx_path, const char *sface_onnx_path, const char *embed_onnx_path);

typedef struct {
    /* box as fractions of the decoded (EXIF-rotated) image, so any later
       resize of the image keeps them valid */
    float x, y, w, h;
    float score;                        /* detection confidence 0..1 */
    float embedding[PW_FACE_EMB_DIM];   /* ArcFace r100 feature, L2-normalised */
} PwFace;

/* Detects faces in an image file and extracts their embeddings.
   Images larger than max_edge on their longest side are downscaled first
   (0 = never); with edge_hint (the picture's longest edge, when known) the JPEG
   is decoded at 1/2, 1/4 or 1/8 right away instead of in full.
   Returns the number of faces written, or -1 on error. */
int pw_face_detect(const char *image_path, int max_edge, int edge_hint, PwFace *out, int max_faces);

#ifdef __cplusplus
}
#endif
#endif
