/* face_opencv.cpp — see face_opencv.h for why this file exists. */
#include "face_opencv.h"

#include <algorithm>
#include <cstring>
#include <mutex>

#include <opencv2/core/utility.hpp>
#include <opencv2/dnn.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>

/* One detector/aligner/embedder for the process; none is thread-safe, so every
   call holds the mutex. g_recognizer (SFace) is kept ONLY for alignCrop — the
   112x112 warp is model-independent; the feature is ArcFace r100 (g_embedder). */
static std::mutex g_mutex;
static cv::Ptr<cv::FaceDetectorYN> g_detector;
static cv::Ptr<cv::FaceRecognizerSF> g_recognizer;
static cv::dnn::Net g_embedder;
static bool g_embedder_ok = false;

int pw_face_init(const char *yunet_onnx_path, const char *sface_onnx_path, const char *embed_onnx_path)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_detector && g_recognizer && g_embedder_ok)
        return 0;
    try {
        cv::setNumThreads(2); /* the UI shares these cores */
        /* score 0.7, NMS 0.3, top_k 5000; the input size is set per image */
        g_detector = cv::FaceDetectorYN::create(yunet_onnx_path, "", cv::Size(320, 320), 0.7f, 0.3f, 5000);
        g_recognizer = cv::FaceRecognizerSF::create(sface_onnx_path, "");
        g_embedder = cv::dnn::readNetFromONNX(embed_onnx_path);
        g_embedder_ok = !g_embedder.empty();
        return (g_detector && g_recognizer && g_embedder_ok) ? 0 : -1;
    } catch (...) {
        g_detector.release();
        g_recognizer.release();
        g_embedder = cv::dnn::Net();
        g_embedder_ok = false;
        return -1;
    }
}

int pw_face_detect(const char *image_path, int max_edge, int edge_hint, PwFace *out, int max_faces)
{
    if (!out || max_faces <= 0)
        return -1;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_detector || !g_recognizer || !g_embedder_ok)
        return -1;
    try {
        /* decode reduced when the picture is far bigger than the detector needs (EXIF
           orientation is still applied by imread in these modes) */
        int flags = cv::IMREAD_COLOR;
        if (max_edge > 0 && edge_hint > 0) {
            if (edge_hint >= 8 * max_edge) flags = cv::IMREAD_REDUCED_COLOR_8;
            else if (edge_hint >= 4 * max_edge) flags = cv::IMREAD_REDUCED_COLOR_4;
            else if (edge_hint >= 2 * max_edge) flags = cv::IMREAD_REDUCED_COLOR_2;
        }
        cv::Mat img = cv::imread(image_path, flags);
        if (img.empty())
            return -1;
        if (max_edge > 0 && std::max(img.cols, img.rows) > max_edge) {
            const double s = static_cast<double>(max_edge) / std::max(img.cols, img.rows);
            cv::Mat small;
            cv::resize(img, small, cv::Size(), s, s, cv::INTER_AREA);
            img = small;
        }
        const float W = static_cast<float>(img.cols);
        const float H = static_cast<float>(img.rows);
        g_detector->setInputSize(cv::Size(img.cols, img.rows));

        /* N x 15: x, y, w, h, 5 landmark pairs, score */
        cv::Mat faces;
        g_detector->detect(img, faces);
        if (faces.empty())
            return 0;

        const int n = std::min(faces.rows, max_faces);
        for (int i = 0; i < n; ++i) {
            PwFace &r = out[i];
            const float bx = std::max(0.f, faces.at<float>(i, 0));
            const float by = std::max(0.f, faces.at<float>(i, 1));
            const float bw = std::min(faces.at<float>(i, 2), W - bx);
            const float bh = std::min(faces.at<float>(i, 3), H - by);
            r.x = bx / W;
            r.y = by / H;
            r.w = bw / W;
            r.h = bh / H;
            r.score = faces.at<float>(i, 14);

            /* align to the canonical 112x112 (SFace's warp), then embed with
               ArcFace r100. Its ONNX normalises internally (Sub/Mul on "data"),
               so feed RAW pixels, RGB; L2-normalise so "same" is a cosine. */
            cv::Mat aligned;
            g_recognizer->alignCrop(img, faces.row(i), aligned);
            cv::Mat blob = cv::dnn::blobFromImage(aligned, 1.0, cv::Size(112, 112),
                                                  cv::Scalar(0, 0, 0), /*swapRB*/ true, /*crop*/ false);
            g_embedder.setInput(blob);
            cv::Mat feature = g_embedder.forward();
            feature = feature.reshape(1, 1);
            if (feature.total() >= PW_FACE_EMB_DIM) {
                cv::normalize(feature, feature, 1.0, 0.0, cv::NORM_L2);
                std::memcpy(r.embedding, feature.ptr<float>(), PW_FACE_EMB_DIM * sizeof(float));
            } else {
                std::memset(r.embedding, 0, sizeof r.embedding);
            }
        }
        return n;
    } catch (...) {
        return -1;
    }
}
