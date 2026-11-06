"""
export_weights.py

Turns tinyml_weights.pth into the four .mem files tinyml_core.v loads with
$readmemh. Each value is multiplied by 256, rounded, and written as a 16-bit
two's complement hex word (Q8.8), one per line.

Files go into ml_engine/mem_files/. Copy them into
kryptonite/kryptonite.srcs/sources_1/imports/mem_files/ for Vivado.
"""
import argparse
import os

import torch

from hw_model import quantize

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "mem_files")


def write_mem(out_dir, name, q):
    with open(os.path.join(out_dir, name), "w") as f:
        for v in q.reshape(-1).tolist():
            f.write(f"{v & 0xFFFF:04X}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default=os.path.join(HERE, "tinyml_weights.pth"))
    ap.add_argument("--out-dir", default=OUT_DIR)
    a = ap.parse_args()
    sd = torch.load(a.weights, map_location="cpu")
    os.makedirs(a.out_dir, exist_ok=True)
    names = {"hw.mem": "hidden_layer.weight", "hb.mem": "hidden_layer.bias",
             "ow.mem": "output_layer.weight", "ob.mem": "output_layer.bias"}
    for fname, key in names.items():
        t = sd[key].numpy()
        q = quantize(t)          # raises if anything does not fit in 16 bits
        write_mem(a.out_dir, fname, q)
        print(f"{fname}: {q.size:5d} words  (float range {t.min():+.3f} .. {t.max():+.3f})")
    hidden = sd["hidden_layer.bias"].shape[0]
    print(f"\nHidden layer size: {hidden}. Set HIDDEN_NODES = {hidden} in tinyml_core.v.")
    print(f"Written to {a.out_dir}")


if __name__ == "__main__":
    main()
