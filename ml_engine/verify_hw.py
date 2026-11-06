"""
verify_hw.py

Checks the exported .mem files before they go to the FPGA:
  1. the .mem files match tinyml_weights.pth exactly
  2. accuracy with the FPGA's whole-number maths matches PyTorch
  3. shows how much the old output-bias bug would cost
  4. writes test vectors for a Vivado testbench of tinyml_core:
       mem_files/tb_grids.mem     one 320-bit grid per line (cell 0 in bits [4:0])
       mem_files/tb_expected.mem  the digit the FPGA should predict for each grid

Run after export_weights.py:  python verify_hw.py
"""
import os

import numpy as np
import torch

from data_setup import get_datasets
from hw_model import MEM_DIR, hw_predict, load_mem_weights, quantize
from model import TinyMLP

HERE = os.path.dirname(os.path.abspath(__file__))
N_VECTORS = 50


def grid_to_hex(g):
    v = 0
    for i, val in enumerate(np.asarray(g).reshape(-1)):
        v |= int(val) << (5 * i)
    return f"{v:080X}"


def main():
    hw, hb, ow, ob = load_mem_weights()
    hidden = len(hb)
    sd = torch.load(os.path.join(HERE, "tinyml_weights.pth"), map_location="cpu")
    keys = ("hidden_layer.weight", "hidden_layer.bias", "output_layer.weight", "output_layer.bias")
    same = all(np.array_equal(quantize(sd[k].numpy()), m) for k, m in zip(keys, (hw, hb, ow, ob)))
    print(f"hidden size {hidden}; .mem files match tinyml_weights.pth: {same}")
    if not same:
        print("  -> run export_weights.py again")

    model = TinyMLP(hidden)
    model.load_state_dict(sd)
    model.eval()

    sets = get_datasets()
    print(f"\n{'set':16s} {'pytorch':>8s} {'fpga':>8s} {'old bug':>8s}")
    for k, (X, y) in sets.items():
        if k == "train":
            continue
        with torch.no_grad():
            fp = (model(torch.tensor(X, dtype=torch.float32)).argmax(1).numpy() == y).mean()
        fixed = (hw_predict(X, hw, hb, ow, ob, bias_fix=True) == y).mean()
        old = (hw_predict(X, hw, hb, ow, ob, bias_fix=False) == y).mean()
        print(f"{k:16s} {fp:8.4f} {fixed:8.4f} {old:8.4f}")

    # test vectors: a few of every digit from the 5x5-brush MNIST test set
    X, y = sets["test_mnist_5x5"]
    rng = np.random.default_rng(0)
    pick = np.concatenate([rng.choice(np.where(y == d)[0], N_VECTORS // 10, replace=False)
                           for d in range(10)])
    pred = hw_predict(X[pick], hw, hb, ow, ob)
    with open(os.path.join(MEM_DIR, "tb_grids.mem"), "w") as f:
        f.writelines(grid_to_hex(g) + "\n" for g in X[pick])
    with open(os.path.join(MEM_DIR, "tb_expected.mem"), "w") as f:
        f.writelines(f"{p:X}\n" for p in pred)
    print(f"\nwrote {len(pick)} test vectors to mem_files/tb_grids.mem and tb_expected.mem")
    print("(expected = what the fixed FPGA maths predicts, not the true label, so the "
          "testbench should match it 100%)")


if __name__ == "__main__":
    main()
