#!/usr/bin/env python3
# Validate the r100 TFLite conversion against the ONNX reference: feed the SAME random
# 112x112 RGB (0-255) to both, L2-normalise the 512-d output, compare cosine. ~1.0 = faithful.
import os, sys, glob, numpy as np, onnxruntime as ort, tensorflow as tf

ONNX = os.environ.get("R100_ONNX", "models/arcfaceresnet100-8.onnx")
tfl_glob = sys.argv[1] if len(sys.argv) > 1 else "models/tflite/r100/*float32*.tflite"
tfl_path = sorted(glob.glob(tfl_glob))[0]
print("tflite:", tfl_path)

rng = np.random.default_rng(0)
img = (rng.random((112, 112, 3)) * 255).astype("float32")   # RGB 0-255

# ONNX reference: NCHW
sess = ort.InferenceSession(ONNX, providers=["CPUExecutionProvider"])
iname = sess.get_inputs()[0].name
onnx_out = sess.run(None, {iname: np.transpose(img, (2, 0, 1))[None]})[0].reshape(-1)
onnx_out = onnx_out / np.linalg.norm(onnx_out)

# TFLite: NHWC
it = tf.lite.Interpreter(model_path=tfl_path); it.allocate_tensors()
inp, out = it.get_input_details()[0], it.get_output_details()[0]
x = img[None].astype(inp["dtype"]) if inp["dtype"] in (np.float32,) else img[None].astype("float32")
it.set_tensor(inp["index"], x); it.invoke()
tfl_out = it.get_tensor(out["index"]).reshape(-1)
tfl_out = tfl_out / np.linalg.norm(tfl_out)

cos = float(onnx_out @ tfl_out)
print(f"input shape onnx=NCHW(1,3,112,112) tflite={inp['shape'].tolist()} dtype={inp['dtype']}")
print(f"dim: onnx={onnx_out.shape[0]} tflite={tfl_out.shape[0]}")
print(f"COSINE onnx-vs-tflite = {cos:.6f}   {'PASS' if cos > 0.999 else 'CHECK'}")
sys.exit(0 if cos > 0.999 else 1)
