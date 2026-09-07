/**
 * face_opencv.h — thin C wrapper around OpenCV's YuNet face detector
 *                 and SFace face recognizer (DNN-based ONNX models).
 *
 * Called from the D daemon via extern(C) linkage.
 */
#ifndef FACE_OPENCV_H
#define FACE_OPENCV_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize the face detector (YuNet) + recognizer (SFace).
 * @param yunet_onnx_path   absolute path to face_detection_yunet_2023mar.onnx
 * @param sface_onnx_path   absolute path to face_recognition_sface_2021dec.onnx
 * @return 0 on success, -1 on failure
 */
int face_init(const char *yunet_onnx_path, const char *sface_onnx_path);

/** A single detected face and its 128-d embedding. */
typedef struct {
    int x, y, w, h;             /* bounding box in image coords         */
    int image_width, image_height;
    float score;                /* detection confidence [0..1]           */
    float embedding[128];       /* SFace 128-d feature vector            */
} FaceResult;

/**
 * Detect faces in an image file and extract embeddings.
 * @param image_path   absolute path to the image (JPEG, PNG, etc.)
 * @param out_faces    output array (caller pre-allocates)
 * @param max_faces    size of out_faces array
 * @return number of faces written (<=max_faces), or -1 on error
 */
int face_detect(const char *image_path, FaceResult *out_faces, int max_faces);

/**
 * Compute cosine similarity between two 128-d embeddings.
 * @return cosine similarity in [-1, 1]; >= 0.363 => same person (SFace threshold)
 */
float face_cosine_similarity(const float *a, const float *b);

#ifdef __cplusplus
}
#endif

#endif /* FACE_OPENCV_H */
