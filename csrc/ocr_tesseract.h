/* ocr_tesseract.h — a C surface over Tesseract for reading the text in an image
 * (screenshots, memes, documents). Mirrors clip_opencv.h: init once, then one call
 * per image and the recognised text crosses the boundary. The vision worker
 * (core/vision/worker.d) is the one caller, so a single global engine is enough.
 */
#ifndef OCR_TESSERACT_H
#define OCR_TESSERACT_H

#ifdef __cplusplus
extern "C" {
#endif

/* Loads Tesseract for `langs` (e.g. "por" or "por+eng"). 0 on success, -1 otherwise.
   A no-op once loaded. */
int pw_ocr_init(const char *langs);

/* Frees the engine; pw_ocr_init loads it again. */
void pw_ocr_release(void);

/* Reads the text in the image file. Returns a malloc'd UTF-8 string (freed with
   pw_ocr_free), or NULL when the image cannot be read or the engine is not loaded.
   *out_conf receives the mean word confidence, 0..100. */
char *pw_ocr_image(const char *path, int *out_conf);

/* Frees a string returned by pw_ocr_image. */
void pw_ocr_free(char *s);

#ifdef __cplusplus
}
#endif
#endif
