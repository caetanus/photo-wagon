/* media_prewarm.cpp — see media_prewarm.h. */
#include "media_prewarm.h"

#include <QtCore/QList>
#include <QtMultimedia/QMediaFormat>
#include <atomic>
#include <thread>

static std::thread warm;
static std::atomic<int> ready{0};

void pw_media_prewarm(void)
{
    if (warm.joinable())
        return;
    warm = std::thread([] {
        QMediaFormat f;
        (void) f.supportedFileFormats(QMediaFormat::Decode);
        ready.store(1);
    });
}

int pw_media_ready(void)
{
    return ready.load();
}

void pw_media_prewarm_join(void)
{
    if (warm.joinable())
        warm.join();
}
