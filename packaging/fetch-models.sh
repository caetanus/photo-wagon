#!/bin/sh
# Downloads the local AI models Photo Wagon uses (faces, CLIP scenes and search) into
# ${XDG_DATA_HOME:-~/.local/share}/photowagon/models, where the app looks for them. Each file
# is checked against its published sha256; one that is already there and matches is kept.
#
#   photo-wagon-fetch-models [DIR]
#
# About 870 MB in total. Without them the library, editing and text search still work.
set -eu
DIR=${1:-${XDG_DATA_HOME:-$HOME/.local/share}/photowagon/models}
mkdir -p "$DIR"

fetch() {   # <file> <sha256> <url>
    f="$DIR/$1"
    if [ -f "$f" ] && echo "$2  $f" | sha256sum -c --status 2>/dev/null; then
        echo "  ok      $1"
        return
    fi
    echo "  fetch   $1"
    curl -fL --retry 3 --progress-bar -o "$f.part" "$3"
    if ! echo "$2  $f.part" | sha256sum -c --status; then
        rm -f "$f.part"
        echo "photo-wagon-fetch-models: $1 does not match its sha256; not installed" >&2
        exit 1
    fi
    mv "$f.part" "$f"
}

echo "Photo Wagon models → $DIR"
fetch face_detection_yunet_2023mar.onnx 8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4 \
    https://github.com/opencv/opencv_zoo/raw/f12e12798e8314f7c074a6656816c048dcc95b7a/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
fetch face_recognition_sface_2021dec.onnx 0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79 \
    https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
fetch arcfaceresnet100-8.onnx f3a6bc281e72f88862f5748b53be3d76b3b48f8f1ab1f4a537941bdc4e1b01da \
    https://github.com/onnx/models/raw/main/validated/vision/body_analysis/arcface/model/arcfaceresnet100-8.onnx
fetch clip_vision.onnx fd6e1402a588279d1723c7534d4bcba5bc0b14b47dfab0e46f8c47b8270d7d40 \
    https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main/onnx/vision_model.onnx
fetch clip_text.onnx 3f6571f5bad13a97c469c1622e1cfc4d9aef78b79fdbfcff804ca357bfada8cc \
    https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main/onnx/text_model.onnx
echo "Done. Restart Photo Wagon to pick them up."
