/* face_opencv.cpp — see face_opencv.h for why this file exists. */
#include "face_opencv.h"

#include <algorithm>
#include <cstring>
#include <mutex>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/objdetect.hpp>

/* One detector and one recognizer for the process; neither is thread-safe,
   so every call holds the mutex. Callers run on worker threads and simply
   queue behind each other. */
static std::mutex g_mutex;
static cv::Ptr<cv::FaceDetectorYN> g_detector;
static cv::Ptr<cv::FaceRecognizerSF> g_recognizer;

int pw_face_init(const char *yunet_onnx_path, const char *sface_onnx_path)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_detector && g_recognizer)
        return 0;
    try {
        /* score 0.7, NMS 0.3, top_k 5000; the input size is set per image */
        g_detector = cv::FaceDetectorYN::create(yunet_onnx_path, "", cv::Size(320, 320), 0.7f, 0.3f, 5000);
        g_recognizer = cv::FaceRecognizerSF::create(sface_onnx_path, "");
        return (g_detector && g_recognizer) ? 0 : -1;
    } catch (...) {
        g_detector.release();
        g_recognizer.release();
        return -1;
    }
}

int pw_face_detect(const char *image_path, int max_edge, PwFace *out, int max_faces)
{
    if (!out || max_faces <= 0)
        return -1;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_detector || !g_recognizer)
        return -1;
    try {
        cv::Mat img = cv::imread(image_path, cv::IMREAD_COLOR); /* honours EXIF orientation */
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

            cv::Mat aligned, feature;
            g_recognizer->alignCrop(img, faces.row(i), aligned);
            g_recognizer->feature(aligned, feature);
            if (feature.total() >= 128)
                std::memcpy(r.embedding, feature.ptr<float>(), 128 * sizeof(float));
            else
                std::memset(r.embedding, 0, sizeof r.embedding);
        }
        return n;
    } catch (...) {
        return -1;
    }
}
