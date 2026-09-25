// tflite_c_api.h — a minimal, hand-written declaration of the *classic* TensorFlow Lite
// C API, enough for facelite.c. The phone links libLiteRt.so (Google's LiteRT runtime),
// which exports these stable TfLite* symbols alongside its newer LiteRt* API — so we build
// against this small header instead of pulling in TF's whole header tree. Only the ~18
// functions the face pipeline uses are declared. Symbols verified present in
// mobile/android/libs/<abi>/libLiteRt.so (nm -D).
#ifndef PW_TFLITE_C_API_H
#define PW_TFLITE_C_API_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TfLiteModel TfLiteModel;
typedef struct TfLiteInterpreterOptions TfLiteInterpreterOptions;
typedef struct TfLiteInterpreter TfLiteInterpreter;
typedef struct TfLiteTensor TfLiteTensor;
typedef struct TfLiteDelegate TfLiteDelegate;

typedef enum { kTfLiteOk = 0, kTfLiteError = 1 } TfLiteStatus;
// Only the types we touch; the enum's numeric values are ABI-stable.
typedef enum { kTfLiteNoType = 0, kTfLiteFloat32 = 1, kTfLiteFloat16 = 10 } TfLiteType;

// Model: its flatbuffer must OUTLIVE every interpreter created from it.
TfLiteModel* TfLiteModelCreateFromFile(const char* model_path);
void         TfLiteModelDelete(TfLiteModel* model);

TfLiteInterpreterOptions* TfLiteInterpreterOptionsCreate(void);
void TfLiteInterpreterOptionsDelete(TfLiteInterpreterOptions* options);
void TfLiteInterpreterOptionsSetNumThreads(TfLiteInterpreterOptions* options, int32_t num_threads);
void TfLiteInterpreterOptionsAddDelegate(TfLiteInterpreterOptions* options, TfLiteDelegate* delegate);

TfLiteInterpreter* TfLiteInterpreterCreate(const TfLiteModel* model, const TfLiteInterpreterOptions* options);
void         TfLiteInterpreterDelete(TfLiteInterpreter* interpreter);
TfLiteStatus TfLiteInterpreterAllocateTensors(TfLiteInterpreter* interpreter);
TfLiteStatus TfLiteInterpreterInvoke(TfLiteInterpreter* interpreter);

int32_t            TfLiteInterpreterGetInputTensorCount(const TfLiteInterpreter* interpreter);
TfLiteTensor*      TfLiteInterpreterGetInputTensor(const TfLiteInterpreter* interpreter, int32_t input_index);
int32_t            TfLiteInterpreterGetOutputTensorCount(const TfLiteInterpreter* interpreter);
const TfLiteTensor* TfLiteInterpreterGetOutputTensor(const TfLiteInterpreter* interpreter, int32_t output_index);

void*      TfLiteTensorData(const TfLiteTensor* tensor);
int32_t    TfLiteTensorNumDims(const TfLiteTensor* tensor);
int32_t    TfLiteTensorDim(const TfLiteTensor* tensor, int32_t dim_index);
size_t     TfLiteTensorByteSize(const TfLiteTensor* tensor);
TfLiteType TfLiteTensorType(const TfLiteTensor* tensor);

// XNNPACK: the portable CPU delegate (big speedup over the reference kernels).
// Pass NULL for default options.
TfLiteDelegate* TfLiteXNNPackDelegateCreate(const void* options);
void            TfLiteXNNPackDelegateDelete(TfLiteDelegate* delegate);

#ifdef __cplusplus
}
#endif
#endif
