"""
train.py

Trains TinyMLP on board-style MNIST + scikit-learn digits (+ board drawings if
drawings.npz exists), keeps the version that scores best on the validation
sets, and reports accuracy both in PyTorch and with the FPGA's whole-number maths.

Run:  python train.py                 (hidden size from model.py)
      python train.py --hidden 64     (try another size; must match Verilog)
Then: python export_weights.py
"""
import argparse
import os

import numpy as np
import torch
import torch.nn as nn

from data_setup import get_datasets, to_loader
from hw_model import hw_predict, quantize
from model import DEFAULT_HIDDEN, TinyMLP

HERE = os.path.dirname(os.path.abspath(__file__))


def accuracy(model, X, y):
    model.eval()
    with torch.no_grad():
        p = model(torch.tensor(X, dtype=torch.float32)).argmax(1).numpy()
    return (p == y).mean()


def confusion(pred, y):
    m = np.zeros((10, 10), dtype=int)
    for t, p in zip(y, pred):
        m[t, p] += 1
    return m


def print_confusion(m, title):
    print(f"\n{title}  (rows = true digit, columns = predicted)")
    print("      " + " ".join(f"{c:5d}" for c in range(10)) + "   correct")
    for r in range(10):
        print(f"  {r}:  " + " ".join(f"{v:5d}" for v in m[r]) +
              f"   {100 * m[r, r] / max(1, m[r].sum()):5.1f}%")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hidden", type=int, default=DEFAULT_HIDDEN)
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default=os.path.join(HERE, "tinyml_weights.pth"))
    a = ap.parse_args()

    torch.manual_seed(a.seed)
    sets = get_datasets(seed=a.seed)
    Xtr, ytr = sets["train"]
    val_names = [k for k in sets if k.startswith("val_")]
    print(f"training on {len(Xtr)} samples, hidden = {a.hidden}")

    model = TinyMLP(a.hidden)
    loader = to_loader(Xtr, ytr, a.batch)
    opt = torch.optim.Adam(model.parameters(), lr=a.lr, weight_decay=1e-5)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=a.epochs)
    loss_fn = nn.CrossEntropyLoss()

    best, best_state = -1.0, None
    for epoch in range(a.epochs):
        model.train()
        total = 0.0
        for xb, yb in loader:
            opt.zero_grad()
            loss = loss_fn(model(xb), yb)
            loss.backward()
            opt.step()
            total += loss.item() * len(xb)
        sched.step()
        vals = {k: accuracy(model, *sets[k]) for k in val_names}
        score = float(np.mean(list(vals.values())))   # each source counts equally
        mark = ""
        if score > best:
            best, best_state, mark = score, {k: v.clone() for k, v in model.state_dict().items()}, "  <- best"
        print(f"epoch {epoch + 1:3d}/{a.epochs}  loss {total / len(Xtr):.4f}  " +
              "  ".join(f"{k[4:]} {v:.4f}" for k, v in vals.items()) + mark)

    model.load_state_dict(best_state)
    torch.save(best_state, a.out)
    print(f"\nsaved best model to {a.out} (mean validation accuracy {best:.4f})")

    # final report: PyTorch vs the FPGA's whole-number maths
    q = [quantize(best_state[k].numpy()) for k in
         ("hidden_layer.weight", "hidden_layer.bias", "output_layer.weight", "output_layer.bias")]
    print(f"\n{'set':16s} {'pytorch':>8s} {'fpga':>8s}")
    for k, (X, y) in sets.items():
        if k == "train":
            continue
        fp = accuracy(model, X, y)
        hwacc = (hw_predict(X, *q) == y).mean()
        print(f"{k:16s} {fp:8.4f} {hwacc:8.4f}")
    X, y = sets["test_mnist_5x5"]
    print_confusion(confusion(hw_predict(X, *q), y), "MNIST test set, 5x5 brush, FPGA maths")


if __name__ == "__main__":
    main()
