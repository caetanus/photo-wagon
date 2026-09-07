/**
 * face_opencv.cpp — OpenCV YuNet + SFace C wrapper implementation.
 *
 * Uses cv::FaceDetectorYN for detection and cv::FaceRecognizerSF for
 * 128-d face embedding extraction.  Both use ONNX models from
 * https://github.com/opencv/opencv_zoo
 */
#include "face_opencv.h"

#include <cmath>
#include <cstring>
#include <mutex>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>

/* ------------------------------------------------------------------ */
/* Global singletons (guarded by mutex)                               */
/* ------------------------------------------------------------------ */

static std::mutex g_mutex;
static cv::Ptr<cv::FaceDetectorYN> g_detector;
static cv::Ptr<cv::FaceRecognizerSF> g_recognizer;
static bool g_initialized = false;

/* ------------------------------------------------------------------ */
/* Public API                                                         */
/* ------------------------------------------------------------------ */

int face_init(const char *yunet_onnx_path, const char *sface_onnx_path)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_initialized)
        return 0;

    try {
        /*  YuNet: score_threshold=0.7, nms_threshold=0.3, top_k=5000
         *  Input size will be updated per-image in face_detect().       */
        g_detector = cv::FaceDetectorYN::create(
            yunet_onnx_path, "", cv::Size(320, 320), 0.7f, 0.3f, 5000);

        g_recognizer = cv::FaceRecognizerSF::create(sface_onnx_path, "");

        g_initialized = (g_detector && g_recognizer);
        return g_initialized ? 0 : -1;
    } catch (...) {
        return -1;
    }
}

int face_detect(const char *image_path, FaceResult *out_faces, int max_faces)
{
    if (!out_faces || max_faces <= 0)
        return -1;

    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_initialized)
        return -1;

    cv::Mat img = cv::imread(image_path, cv::IMREAD_COLOR);
    if (img.empty())
        return -1;

    const int img_w = img.cols;
    const int img_h = img.rows;

    /* Update detector input size to match this image. */
    g_detector->setInputSize(cv::Size(img_w, img_h));

    /* Detect faces — output is Nx15 float matrix:
       [x, y, w, h, x_re, y_re, x_le, y_le, x_nt, y_nt,
        x_rcm, y_rcm, x_lcm, y_lcm, score]                           */
    cv::Mat faces_mat;
    g_detector->detect(img, faces_mat);

    if (faces_mat.empty())
        return 0;

    const int n_faces = std::min(faces_mat.rows, max_faces);

    for (int i = 0; i < n_faces; ++i) {
        FaceResult &r = out_faces[i];

        /* Bounding box (clamp to image) */
        int bx = static_cast<int>(faces_mat.at<float>(i, 0));
        int by = static_cast<int>(faces_mat.at<float>(i, 1));
        int bw = static_cast<int>(faces_mat.at<float>(i, 2));
        int bh = static_cast<int>(faces_mat.at<float>(i, 3));

        bx = std::max(0, bx);
        by = std::max(0, by);
        bw = std::min(bw, img_w - bx);
        bh = std::min(bh, img_h - by);

        r.x = bx;
        r.y = by;
        r.w = bw;
        r.h = bh;
        r.image_width = img_w;
        r.image_height = img_h;
        r.score = faces_mat.at<float>(i, 14);

        /* Align face crop and extract 128-d embedding. */
        cv::Mat aligned;
        g_recognizer->alignCrop(img, faces_mat.row(i), aligned);

        cv::Mat feature;
        g_recognizer->feature(aligned, feature);

        /* Copy the 128 floats into the result struct. */
        if (feature.total() >= 128) {
            std::memcpy(r.embedding, feature.ptr<float>(), 128 * sizeof(float));
        } else {
            std::memset(r.embedding, 0, 128 * sizeof(float));
        }
    }

    return n_faces;
}

float face_cosine_similarity(const float *a, const float *b)
{
    double dot = 0.0, norm_a = 0.0, norm_b = 0.0;
    for (int i = 0; i < 128; ++i) {
        dot    += static_cast<double>(a[i]) * b[i];
        norm_a += static_cast<double>(a[i]) * a[i];
        norm_b += static_cast<double>(b[i]) * b[i];
    }
    double denom = std::sqrt(norm_a) * std::sqrt(norm_b);
    if (denom < 1e-12)
        return 0.0f;
    return static_cast<float>(dot / denom);
}
