// videothumb.c — a representative frame of a video, saved as a JPEG, using the
// Android platform (MediaMetadataRetriever) via JNI. There is no ffmpeg on the
// phone, so this is how the phone makes its own video thumbnails.
//
// Called from D (phoneindex) with a JNIEnv* obtained from
// QJniEnvironment.getJniEnv(). Runs on the Qt thread — MediaMetadataRetriever is
// plain Android/Java, so the only thread requirement is a JNIEnv attached to the
// caller, which getJniEnv() guarantees.
//
// All calls go through the C JNI interface (CallObjectMethod &c.), whose varargs
// are ordinary C varargs — none of the C++ QJniObject variadic-ABI hazards.

#include <jni.h>
#include <android/log.h>
#include <stdlib.h>

#define TAG "pwvid"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// A local ref that we always want released; keeps the cleanup readable.
#define DEL(r) do { if (r) (*env)->DeleteLocalRef(env, (jobject)(r)); } while (0)

static int failed(JNIEnv* env) {
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return 1;
    }
    return 0;
}

// Extract a representative frame of `videoPath`, scale it to fit `maxSize` on its
// long edge, and save it as a JPEG at `outPath`. Returns the video duration in
// milliseconds (>= 0) on success, or -1 on any failure.
long pw_video_thumb(void* env_, const char* videoPath, const char* outPath, int maxSize) {
    JNIEnv* env = (JNIEnv*)env_;
    long result = -1;

    jclass cMMR = NULL, cBitmap = NULL, cFOS = NULL, cCompress = NULL;
    jobject mmr = NULL, frame = NULL, scaled = NULL, fos = NULL, jfmt = NULL, durStr = NULL;
    jstring jPath = NULL, jOut = NULL;

    cMMR = (*env)->FindClass(env, "android/media/MediaMetadataRetriever");
    if (!cMMR || failed(env)) goto done;

    jmethodID mInit = (*env)->GetMethodID(env, cMMR, "<init>", "()V");
    jmethodID mSetSrc = (*env)->GetMethodID(env, cMMR, "setDataSource", "(Ljava/lang/String;)V");
    jmethodID mFrame = (*env)->GetMethodID(env, cMMR, "getFrameAtTime", "()Landroid/graphics/Bitmap;");
    jmethodID mMeta = (*env)->GetMethodID(env, cMMR, "extractMetadata", "(I)Ljava/lang/String;");
    jmethodID mRelease = (*env)->GetMethodID(env, cMMR, "release", "()V");
    if (!mInit || !mSetSrc || !mFrame || !mMeta || !mRelease) goto done;

    mmr = (*env)->NewObject(env, cMMR, mInit);
    if (!mmr || failed(env)) goto done;

    jPath = (*env)->NewStringUTF(env, videoPath);
    (*env)->CallVoidMethod(env, mmr, mSetSrc, jPath);
    if (failed(env)) goto release;   // unreadable / not a media file

    frame = (*env)->CallObjectMethod(env, mmr, mFrame);
    if (!frame || failed(env)) goto release;

    // Native frame dimensions, to decide the scale (Bitmap.getWidth/getHeight).
    cBitmap = (*env)->GetObjectClass(env, frame);
    jmethodID mW = (*env)->GetMethodID(env, cBitmap, "getWidth", "()I");
    jmethodID mH = (*env)->GetMethodID(env, cBitmap, "getHeight", "()I");
    jint w = (*env)->CallIntMethod(env, frame, mW);
    jint h = (*env)->CallIntMethod(env, frame, mH);
    if (w <= 0 || h <= 0) goto release;

    jobject toSave = frame;
    int longEdge = w > h ? w : h;
    if (maxSize > 0 && longEdge > maxSize) {
        double s = (double)maxSize / (double)longEdge;
        jint sw = (jint)(w * s + 0.5), sh = (jint)(h * s + 0.5);
        if (sw < 1) sw = 1;
        if (sh < 1) sh = 1;
        jmethodID mScaled = (*env)->GetStaticMethodID(env, cBitmap, "createScaledBitmap",
            "(Landroid/graphics/Bitmap;IIZ)Landroid/graphics/Bitmap;");
        if (mScaled) {
            scaled = (*env)->CallStaticObjectMethod(env, cBitmap, mScaled, frame, sw, sh, JNI_TRUE);
            if (scaled && !failed(env)) toSave = scaled;
        }
    }

    // new FileOutputStream(outPath)
    cFOS = (*env)->FindClass(env, "java/io/FileOutputStream");
    jmethodID mFosInit = (*env)->GetMethodID(env, cFOS, "<init>", "(Ljava/lang/String;)V");
    jmethodID mFosClose = (*env)->GetMethodID(env, cFOS, "close", "()V");
    jOut = (*env)->NewStringUTF(env, outPath);
    fos = (*env)->NewObject(env, cFOS, mFosInit, jOut);
    if (!fos || failed(env)) goto release;

    // Bitmap.CompressFormat.JPEG
    cCompress = (*env)->FindClass(env, "android/graphics/Bitmap$CompressFormat");
    jfieldID fJpeg = (*env)->GetStaticFieldID(env, cCompress, "JPEG", "Landroid/graphics/Bitmap$CompressFormat;");
    jfmt = (*env)->GetStaticObjectField(env, cCompress, fJpeg);

    // toSave.compress(JPEG, 82, fos)
    jmethodID mCompress = (*env)->GetMethodID(env, cBitmap, "compress",
        "(Landroid/graphics/Bitmap$CompressFormat;ILjava/io/OutputStream;)Z");
    jboolean ok = (*env)->CallBooleanMethod(env, toSave, mCompress, jfmt, 82, fos);
    (*env)->CallVoidMethod(env, fos, mFosClose);
    if (!ok || failed(env)) goto release;

    // Duration (METADATA_KEY_DURATION == 9), best-effort.
    long durMs = 0;
    durStr = (*env)->CallObjectMethod(env, mmr, mMeta, 9);
    if (durStr && !failed(env)) {
        const char* s = (*env)->GetStringUTFChars(env, (jstring)durStr, NULL);
        if (s) { durMs = atol(s); (*env)->ReleaseStringUTFChars(env, (jstring)durStr, s); }
    }
    result = durMs < 0 ? 0 : durMs;

release:
    if (mmr) { (*env)->CallVoidMethod(env, mmr, mRelease); if (failed(env)) {} }
done:
    if (failed(env)) {}   // swallow any pending exception before returning to D
    DEL(durStr); DEL(jfmt); DEL(cCompress); DEL(fos); DEL(jOut); DEL(cFOS);
    DEL(scaled); DEL(cBitmap); DEL(frame); DEL(jPath); DEL(mmr); DEL(cMMR);
    return result;
}

/* pw_share_image — hand a file path to Android's share sheet (ACTION_SEND) by calling the
   static MainActivity.shareImage(String, String). `env` is a JNIEnv* from
   QJniEnvironment.getJniEnv(), exactly like pw_video_thumb above. Returns 0 once
   dispatched (MainActivity posts the intent to the UI thread), -1 if the class/method is
   missing. */
int pw_share_image(void* env_, const char* path, const char* mime) {
    JNIEnv* env = (JNIEnv*) env_;
    jclass cls = (*env)->FindClass(env, "org/photowagon/mobile/MainActivity");
    if (!cls) { failed(env); return -1; }
    jmethodID mid = (*env)->GetStaticMethodID(env, cls, "shareImage",
        "(Ljava/lang/String;Ljava/lang/String;)V");
    if (!mid) { failed(env); DEL(cls); return -1; }
    jstring jpath = (*env)->NewStringUTF(env, path ? path : "");
    jstring jmime = (*env)->NewStringUTF(env, mime ? mime : "image/*");
    (*env)->CallStaticVoidMethod(env, cls, mid, jpath, jmime);
    if (failed(env)) {}   /* swallow any pending exception before returning to D */
    DEL(jmime); DEL(jpath); DEL(cls);
    return 0;
}

/* pw_delete_media — ask Android to delete these files (paths one per line) by calling the
   static MainActivity.deleteMedia(String): it finds them in the MediaStore and shows the
   system's own confirmation (MediaStore.createDeleteRequest). Returns 0 once dispatched, -1
   if the class/method is missing. */
int pw_delete_media(void* env_, const char* paths) {
    JNIEnv* env = (JNIEnv*) env_;
    jclass cls = (*env)->FindClass(env, "org/photowagon/mobile/MainActivity");
    if (!cls) { failed(env); return -1; }
    jmethodID mid = (*env)->GetStaticMethodID(env, cls, "deleteMedia", "(Ljava/lang/String;)V");
    if (!mid) { failed(env); DEL(cls); return -1; }
    jstring jpaths = (*env)->NewStringUTF(env, paths ? paths : "");
    (*env)->CallStaticVoidMethod(env, cls, mid, jpaths);
    if (failed(env)) {}   /* swallow any pending exception before returning to D */
    DEL(jpaths); DEL(cls);
    return 0;
}
