/* ocr_tesseract.cpp — see ocr_tesseract.h. */
#include "ocr_tesseract.h"

#include <cstdlib>
#include <cstring>
#include <mutex>

#include <tesseract/baseapi.h>
#include <leptonica/allheaders.h>

static std::mutex g_mutex;
static tesseract::TessBaseAPI *g_api = nullptr;

int pw_ocr_init(const char *langs)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_api)
        return 0;
    const char *l = (langs && *langs) ? langs : "por";
    tesseract::TessBaseAPI *api = new tesseract::TessBaseAPI();
    /* datapath NULL uses the compiled TESSDATA_PREFIX; fall back to the usual path. */
    if (api->Init(nullptr, l) != 0 && api->Init("/usr/share/tessdata", l) != 0) {
        delete api;
        return -1;
    }
    g_api = api;
    return 0;
}

void pw_ocr_release(void)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_api) {
        g_api->End();
        delete g_api;
        g_api = nullptr;
    }
}

char *pw_ocr_image(const char *path, int *out_conf)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (out_conf)
        *out_conf = 0;
    if (!g_api || !path)
        return nullptr;
    Pix *image = pixRead(path); /* leptonica reads JPEG/PNG/… and honours orientation */
    if (!image)
        return nullptr;
    char *result = nullptr;
    g_api->SetImage(image);
    char *text = g_api->GetUTF8Text(); /* Tesseract-allocated, freed with delete[] */
    if (text) {
        if (out_conf)
            *out_conf = g_api->MeanTextConf();
        result = strdup(text); /* hand back a malloc'd copy the C side owns */
        delete[] text;
    }
    g_api->Clear();
    pixDestroy(&image);
    return result;
}

void pw_ocr_free(char *s)
{
    free(s);
}
