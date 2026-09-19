/* clip_opencv.h — C surface over the CLIP ViT-B/32 image encoder (ONNX) run by
 * OpenCV's DNN module. Same reasoning as face_opencv.h: no C API in OpenCV, and
 * the preprocessing (resize, centre crop, CLIP's mean/std) is a dozen lines here
 * against a second image pipeline in D. One call, plain floats cross the boundary.
 */
#ifndef CLIP_OPENCV_H
#define CLIP_OPENCV_H

#ifdef __cplusplus
extern "C" {
#endif

/* Loads the image encoder. 0 on success. Safe to call more than once. */
int pw_clip_init(const char *vision_onnx_path);

/* Frees the model (about a gigabyte of weights and buffers); pw_clip_init loads it again. */
void pw_clip_release(void);

/* Encodes an image file into a unit-length 512-float embedding.
   Returns 0, or -1 when the image cannot be read or the model is not loaded. */
int pw_clip_encode(const char *image_path, float *out512);

/* The CLIP text tower — the other half, for natural-language search. Loads the text
   ONNX (Xenova/clip-vit-base-patch32, onnx/text_model.onnx). 0 on success. */
int pw_clip_text_init(const char *text_onnx_path);

/* Frees the text model. */
void pw_clip_text_release(void);

/* Encodes 77 CLIP token ids (from cliptext.d) into a unit-length 512-float embedding
   in the same space as pw_clip_encode. Returns 0, or -1 on failure / model not loaded. */
int pw_clip_encode_text(const int *ids77, float *out512);

#ifdef __cplusplus
}
#endif
#endif
