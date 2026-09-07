#!/usr/bin/env python3

import argparse
import json
import sys

import cv2
import numpy as np


def empty_payload():
    return {"faces": []}


def clamp_box(x: float, y: float, w: float, h: float, image_w: int, image_h: int):
    left = max(0, int(round(x)))
    top = max(0, int(round(y)))
    width = max(1, int(round(w)))
    height = max(1, int(round(h)))

    if left + width > image_w:
        width = max(1, image_w - left)
    if top + height > image_h:
        height = max(1, image_h - top)

    return left, top, width, height


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract face boxes + embeddings using OpenCV YuNet + SFace")
    parser.add_argument("--image", required=True)
    parser.add_argument("--detector", required=True)
    parser.add_argument("--recognizer", required=True)
    args = parser.parse_args()

    image = cv2.imread(args.image)
    if image is None:
        print(json.dumps(empty_payload()))
        return 0

    image_h, image_w = image.shape[:2]

    try:
        detector = cv2.FaceDetectorYN.create(
            args.detector,
            "",
            (image_w, image_h),
            score_threshold=0.82,
            nms_threshold=0.3,
            top_k=5000,
        )
        recognizer = cv2.FaceRecognizerSF.create(args.recognizer, "")
    except Exception:
        print(json.dumps(empty_payload()))
        return 0

    try:
        _, detections = detector.detect(image)
    except Exception:
        print(json.dumps(empty_payload()))
        return 0

    if detections is None or len(detections) == 0:
        print(json.dumps(empty_payload()))
        return 0

    faces = []
    for row in detections:
        try:
            x, y, w, h = row[0], row[1], row[2], row[3]
            left, top, width, height = clamp_box(x, y, w, h, image_w, image_h)

            aligned = recognizer.alignCrop(image, row)
            embedding = recognizer.feature(aligned).reshape(-1).astype(np.float32)
            fingerprint_hex = embedding.tobytes().hex()

            faces.append(
                {
                    "x": left,
                    "y": top,
                    "w": width,
                    "h": height,
                    "imageWidth": image_w,
                    "imageHeight": image_h,
                    "fingerprint": fingerprint_hex,
                }
            )
        except Exception:
            continue

    print(json.dumps({"faces": faces}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
