/* face_opencv.h — C surface over OpenCV's YuNet detector and SFace recognizer.
 *
 * Why C++ exists in this repository: OpenCV 5 has no C API for FaceDetectorYN
 * and FaceRecognizerSF (the legacy C API was removed in 4.x), and reimplementing
 * YuNet's anchor decoding, NMS and SFace's alignment in D would be a second
 * implementation of something OpenCV already does well. This file is the whole
 * boundary: two calls, plain structs, no OpenCV type crosses it.
 */
#ifndef FACE_OPENCV_H
#define FACE_OPENCV_H

#ifdef __cplusplus
extern "C" {
#endif

/* Loads the two ONNX models. 0 on success. Safe to call more than once. */
int pw_face_init(const char *yunet_onnx_path, const char *sface_onnx_path);

typedef struct {
    /* box as fractions of the decoded (EXIF-rotated) image, so any later
       resize of the image keeps them valid */
    float x, y, w, h;
    float score;              /* detection confidence 0..1 */
    float embedding[128];     /* SFace feature; cosine >= 0.363 => same person */
} PwFace;

/* Detects faces in an image file and extracts their embeddings.
   Images larger than max_edge on their longest side are downscaled first
   (0 = never). Returns the number of faces written, or -1 on error. */
int pw_face_detect(const char *image_path, int max_edge, PwFace *out, int max_faces);

#ifdef __cplusplus
}
#endif
#endif
