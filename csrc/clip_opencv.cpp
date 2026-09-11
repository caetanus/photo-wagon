/* clip_opencv.cpp — see clip_opencv.h. */
#include "clip_opencv.h"

#include <cmath>
#include <mutex>

#include <opencv2/core/utility.hpp>
#include <opencv2/dnn.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

static std::mutex g_mutex;
static cv::dnn::Net g_net;
static bool g_loaded = false;

int pw_clip_init(const char *vision_onnx_path)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_loaded)
        return 0;
    try {
        cv::setNumThreads(2); /* the UI shares these cores */
        g_net = cv::dnn::readNetFromONNX(vision_onnx_path);
        g_net.setPreferableBackend(cv::dnn::DNN_BACKEND_OPENCV);
        g_net.setPreferableTarget(cv::dnn::DNN_TARGET_CPU);
        g_loaded = !g_net.empty();
        return g_loaded ? 0 : -1;
    } catch (...) {
        g_loaded = false;
        return -1;
    }
}

void pw_clip_release(void)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_net = cv::dnn::Net();
    g_loaded = false;
}

int pw_clip_encode(const char *image_path, float *out512)
{
    if (!out512)
        return -1;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_loaded)
        return -1;
    try {
        cv::Mat img = cv::imread(image_path, cv::IMREAD_COLOR); /* honours EXIF orientation */
        if (img.empty())
            return -1;
        /* CLIP preprocessing: shortest side to 224 (bicubic), centre crop 224x224,
           RGB, [0,1], then (x - mean) / std per channel */
        const int side = 224;
        const double s = static_cast<double>(side) / std::min(img.cols, img.rows);
        cv::Mat resized;
        /* INTER_AREA when shrinking (antialiased, like PIL's bicubic), cubic when growing */
        cv::resize(img, resized, cv::Size(std::max(side, static_cast<int>(std::lround(img.cols * s))),
                                          std::max(side, static_cast<int>(std::lround(img.rows * s)))),
                   0, 0, s < 1.0 ? cv::INTER_AREA : cv::INTER_CUBIC);
        const int x0 = (resized.cols - side) / 2, y0 = (resized.rows - side) / 2;
        cv::Mat crop = resized(cv::Rect(x0, y0, side, side));
        cv::Mat rgb;
        cv::cvtColor(crop, rgb, cv::COLOR_BGR2RGB);
        rgb.convertTo(rgb, CV_32FC3, 1.0 / 255.0);
        const cv::Scalar mean(0.48145466, 0.4578275, 0.40821073);
        const cv::Scalar stdv(0.26862954, 0.26130258, 0.27577711);
        cv::Mat channels[3];
        cv::split(rgb, channels);
        for (int c = 0; c < 3; ++c)
            channels[c] = (channels[c] - mean[c]) / stdv[c];
        cv::Mat norm;
        cv::merge(channels, 3, norm);
        cv::Mat blob = cv::dnn::blobFromImage(norm, 1.0, cv::Size(side, side), cv::Scalar(), false, false, CV_32F);
        g_net.setInput(blob);
        /* the export has two outputs (last_hidden_state, image_embeds); take the 512 one */
        std::vector<cv::Mat> outs;
        g_net.forward(outs, g_net.getUnconnectedOutLayersNames());
        const cv::Mat *emb = nullptr;
        for (const auto &o : outs)
            if (o.total() == 512)
                emb = &o;
        if (!emb)
            return -1;
        const float *p = emb->ptr<float>();
        double n = 0;
        for (int i = 0; i < 512; ++i)
            n += static_cast<double>(p[i]) * p[i];
        n = std::sqrt(n);
        if (n < 1e-12)
            return -1;
        for (int i = 0; i < 512; ++i)
            out512[i] = static_cast<float>(p[i] / n);
        return 0;
    } catch (...) {
        return -1;
    }
}
