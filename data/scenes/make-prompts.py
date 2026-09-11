#!/usr/bin/env python3
"""labels.tsv → prompts.tsv with the CLIP ViT-B/32 text encoder.

usage: make-prompts.py <dir with text_model.onnx and tokenizer.json>   (Xenova/clip-vit-base-patch32)
Needs: pip install onnxruntime tokenizers numpy
"""
import sys, os, numpy as np
from tokenizers import Tokenizer
import onnxruntime as ort

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)
TEMPLATES = ["a photo of {}.", "a picture of {}.", "{}", "a snapshot of {}."]

tok = Tokenizer.from_file(os.path.join(MODELS, "tokenizer.json"))
tok.enable_padding(pad_id=49407, pad_token="<|endoftext|>", length=77)
tok.enable_truncation(77)
sess = ort.InferenceSession(os.path.join(MODELS, "text_model.onnx"), providers=["CPUExecutionProvider"])
names = [i.name for i in sess.get_inputs()]

def embed(texts):
    enc = tok.encode_batch(texts)
    ids = np.array([e.ids for e in enc], dtype=np.int64)
    mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
    feed = {"input_ids": ids}
    if "attention_mask" in names:
        feed["attention_mask"] = mask
    out = sess.run(None, feed)
    # Xenova's export: [last_hidden_state, pooler_output]; the projection is the second (512)
    emb = [o for o in out if o.ndim == 2 and o.shape[1] == 512][0]
    return emb / np.linalg.norm(emb, axis=1, keepdims=True)

rows = []
for line in open(os.path.join(HERE, "labels.tsv"), encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    group, label, phrases = line.rstrip("\n").split("\t")
    texts = [t.format(p) for p in phrases.split("|") for t in TEMPLATES]
    e = embed(texts).mean(axis=0)
    e /= np.linalg.norm(e)
    rows.append((group, label, e))
    print(group, label, len(texts), "phrases")
with open(os.path.join(HERE, "prompts.tsv"), "w", encoding="utf-8") as f:
    for group, label, e in rows:
        f.write(group + "\t" + label + "\t" + " ".join("%.5f" % v for v in e) + "\n")
print(len(rows), "labels →", os.path.join(HERE, "prompts.tsv"))
