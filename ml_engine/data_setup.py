"""
data_setup.py

Builds the training data for TinyMLP. Every sample is 64 values from 0 to 16,
exactly what the board's downsampler sends (no dividing, no normalising).

Sources:
  1. MNIST converted to board-style 8x8 grids   (mnist_board.npz, made by
     prepare_mnist.py; created automatically if missing)
  2. scikit-learn's 8x8 digits                  (already in board format)
  3. drawings.npz from capture_grids.py         (optional: real board drawings,
     used automatically if the file exists)

A validation set is held back from each source. For MNIST the split is done by
original image, so augmented copies of one digit never sit on both sides.
"""
import os

import numpy as np
import torch
from sklearn.datasets import load_digits
from torch.utils.data import DataLoader, TensorDataset

HERE = os.path.dirname(os.path.abspath(__file__))
MNIST_NPZ = os.path.join(HERE, "mnist_board.npz")
DRAWINGS_NPZ = os.path.join(HERE, "drawings.npz")
VAL_FRACTION = 0.1
SKLEARN_REPEAT = 3     # sklearn is small, so show it a few times per epoch
DRAWINGS_REPEAT = 20   # real board drawings are the most valuable, if any


def _load_mnist():
    if not os.path.exists(MNIST_NPZ):
        print("mnist_board.npz not found, running prepare_mnist.py first ...")
        import prepare_mnist
        prepare_mnist.main()
    return np.load(MNIST_NPZ)


def _load_drawings():
    """Board drawings saved by capture_grids.py (labels are strings there)."""
    if not os.path.exists(DRAWINGS_NPZ):
        return None, None
    d = np.load(DRAWINGS_NPZ)
    X, y = [], []
    for g, lab in zip(d["X"], d["y"]):
        lab = str(lab).strip()
        if lab.isdigit() and len(lab) == 1 and g.shape == (8, 8):
            X.append(g.reshape(-1))
            y.append(int(lab))
    if not X:
        return None, None
    return np.array(X, dtype=np.uint8), np.array(y, dtype=np.int64)


def _split(n, rng):
    perm = rng.permutation(n)
    k = int(round(n * VAL_FRACTION))
    return perm[k:], perm[:k]


def get_datasets(seed=0):
    """Returns dict of numpy arrays: train, and named validation/test sets."""
    rng = np.random.default_rng(seed)
    m = _load_mnist()

    # MNIST: split by original image index
    orig = np.unique(m["idx_train"])
    tr_ids, va_ids = _split(len(orig), rng)
    va_mask = np.isin(m["idx_train"], orig[va_ids])
    Xm_tr, ym_tr = m["X_train"][~va_mask], m["y_train"][~va_mask]
    Xm_va, ym_va = m["X_train"][va_mask], m["y_train"][va_mask]

    # scikit-learn digits
    sk = load_digits()
    Xs = sk.images.reshape(len(sk.images), -1).astype(np.uint8)
    ys = sk.target.astype(np.int64)
    s_tr, s_va = _split(len(Xs), rng)

    parts_X = [Xm_tr] + [Xs[s_tr]] * SKLEARN_REPEAT
    parts_y = [ym_tr] + [ys[s_tr]] * SKLEARN_REPEAT

    sets = {
        "val_mnist": (Xm_va, ym_va),
        "val_sklearn": (Xs[s_va], ys[s_va]),
        "test_mnist_3x3": (m["X_test_b1"], m["y_test"]),
        "test_mnist_5x5": (m["X_test_b2"], m["y_test"]),
        "test_mnist_7x7": (m["X_test_b3"], m["y_test"]),
    }

    Xd, yd = _load_drawings()
    if Xd is not None:
        d_tr, d_va = _split(len(Xd), rng)
        parts_X += [Xd[d_tr]] * DRAWINGS_REPEAT
        parts_y += [yd[d_tr]] * DRAWINGS_REPEAT
        sets["val_board"] = (Xd[d_va], yd[d_va])
        print(f"using {len(Xd)} board drawings from drawings.npz")

    sets["train"] = (np.concatenate(parts_X), np.concatenate(parts_y))
    return sets


def to_loader(X, y, batch_size=128, shuffle=True):
    ds = TensorDataset(torch.tensor(X, dtype=torch.float32),
                       torch.tensor(y, dtype=torch.long))
    return DataLoader(ds, batch_size=batch_size, shuffle=shuffle)


def get_dataloader(batch_size=32):
    """Old behaviour (scikit-learn digits only), kept for compatibility."""
    digits = load_digits()
    X = digits.images.reshape(digits.images.shape[0], -1)
    return to_loader(X, digits.target, batch_size)


if __name__ == "__main__":
    sets = get_datasets()
    for name, (X, y) in sets.items():
        print(f"{name:16s} {len(X):7d} samples, mean value {X.mean():.2f}, "
              f"range {X.min()}..{X.max()}")
