/* media_prewarm.h — warms Qt Multimedia's FFmpeg backend off the GUI thread.
 *
 * The first MediaPlayer the app creates makes the backend probe every hardware
 * decoder (VDPAU, CUDA, VA-API, QSV, Vulkan) on the GUI thread; Vulkan alone takes
 * 1.3 s here (the device probe wakes the discrete GPU), and more when that GPU is
 * asleep: opening the first video froze the window. Asking the backend for its
 * formats (QMediaFormat is a value class, not a QObject) runs the same probe, so
 * doing that on a worker thread at start-up leaves the first player instant. */
#ifndef MEDIA_PREWARM_H
#define MEDIA_PREWARM_H

#ifdef __cplusplus
extern "C" {
#endif

/* Starts the probe on a worker thread (once; call after the QGuiApplication exists). */
void pw_media_prewarm(void);
/* 1 once the probe is done: the first MediaPlayer is then created at once (created while
   the probe still runs, it would wait for it on the GUI thread). */
int pw_media_ready(void);
/* Waits for that thread (call before the QGuiApplication goes away). */
void pw_media_prewarm_join(void);

#ifdef __cplusplus
}
#endif
#endif
