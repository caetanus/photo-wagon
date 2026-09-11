# Scenes and moods

Zero-shot tags from CLIP (ViT-B/32): the image encoder runs in the core (models/clip_vision.onnx,
fetched separately like the face models), the text side is precomputed here.

- `labels.tsv` — the tag vocabulary: group (`scene` / `mood`), label, and the phrases that
  describe it. `None` / `Neutral` are the "nothing in particular" classes.
- `prompts.tsv` — one row per label: group, label, then the mean text embedding of its phrases
  over a few templates ("a photo of {}", …), unit length, 512 floats. Compiled into the binary.
- `make-prompts.py` — regenerates `prompts.tsv` from `labels.tsv` with the CLIP text model
  (onnxruntime + tokenizers; see the script for the model files).

Scoring (core/library/scenes.d): cosine of the image embedding with each label of a group, softmax
with CLIP's logit scale (100), the top label wins unless it is the "nothing" class or too weak.
Bump `tagsVersion` there after changing this vocabulary: the stored image embeddings stay, only
the labels are recomputed.
