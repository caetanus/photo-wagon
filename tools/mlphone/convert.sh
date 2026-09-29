#!/bin/sh
# Regenerates the phone's face models (TFLite, float16) from the desktop's ONNX originals:
#
#   tools/mlphone/convert.sh <onnx-dir> <out-dir>
#
# <onnx-dir> holds face_detection_yunet_2023mar.onnx and arcfaceresnet100-8.onnx (as fetched by
# packaging/fetch-models.sh); <out-dir> gets yunet.tflite and r100.tflite, the names the APK
# carries in assets/models. The converter is pinned to the environment the shipped models were
# made and validated with (python 3.11, onnx2tf 1.29.24, TensorFlow 2.19). onnx2tf rewrites its
# input in place (onnxsim), so it works on copies.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <onnx-dir> <out-dir>" >&2; exit 2; }
IN=$(cd "$1" && pwd)
mkdir -p "$2"
OUT=$(cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 -m pip install --quiet --no-cache-dir \
    onnx2tf==1.29.24 tensorflow==2.19.0 onnx==1.19.1 onnxruntime==1.23.0 onnxsim==0.4.36 \
    onnx-graphsurgeon==0.5.8 sng4onnx==2.0.1 ai-edge-litert==2.1.0 numpy==1.26.4 psutil==5.9.5 \
    tf_keras opencv-python-headless
cp "$IN/face_detection_yunet_2023mar.onnx" "$IN/arcfaceresnet100-8.onnx" "$WORK/"
cd "$WORK"
# onnx2tf downloads a calibration sample for int8 quantization from a release asset that no
# longer exists; float16 does not use it, so a valid placeholder lets it proceed.
python3 - <<'EOF'
import numpy as np
np.save("calibration_image_sample_data_20x128x128x3_float32.npy",
        np.random.rand(20, 128, 128, 3).astype("float32"), allow_pickle=False)
import onnx2tf
onnx2tf.convert(input_onnx_file_path="face_detection_yunet_2023mar.onnx", output_folder_path="yunet",
                copy_onnx_input_output_names_to_tflite=True, disable_strict_mode=True, non_verbose=True)
onnx2tf.convert(input_onnx_file_path="arcfaceresnet100-8.onnx", output_folder_path="r100",
                copy_onnx_input_output_names_to_tflite=True, non_verbose=True)
EOF
cp yunet/face_detection_yunet_2023mar_float16.tflite "$OUT/yunet.tflite"
cp r100/arcfaceresnet100-8_float16.tflite "$OUT/r100.tflite"
# r100 must still embed like the desktop ONNX: validate_r100.py feeds both the same input
R100_ONNX="$IN/arcfaceresnet100-8.onnx" python3 "$HERE/validate_r100.py" "$OUT/r100.tflite"
ls -l "$OUT"
