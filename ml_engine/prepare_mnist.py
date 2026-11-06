"""
prepare_mnist.py

Turns MNIST into "board-style" 8x8 grids, so the model trains on digits that
look like what the FPGA actually sends to tinyml_core.

For every MNIST digit:
  1. small random changes: tilt, slant, wider/narrower, different sizes
  2. black and white (pixel >= 128 is ink, same threshold as mnist_to_grid)
  3. thin the strokes to a 1-pixel line (skeletonize)
  4. redraw that line with a square brush, like stroke_engine does
     (mostly the 5x5 brush, some 3x3 and 7x7)
  5. downsample with exactly the same maths as downsampler.v (image_to_grid)

Output: mnist_board.npz (about 10 MB) with
  X_train, y_train, idx_train   training grids (64 values 0..16), labels, and
                                which original MNIST image each one came from
  X_test_b1/b2/b3, y_test       the 10k MNIST test digits, no random changes,
                                drawn with brush radius 1/2/3 (3x3, 5x5, 7x7)

Run:  python prepare_mnist.py            (downloads MNIST the first time)
      python prepare_mnist.py --copies 3 (more augmented copies per digit)
"""
import argparse
import gzip
import os
import urllib.request
from multiprocessing import Pool

import numpy as np
from scipy import ndimage
from skimage.morphology import skeletonize

from preprocess import image_to_grid

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "mnist_raw")
OUT = os.path.join(HERE, "mnist_board.npz")
MIRROR = "https://raw.githubusercontent.com/fgnt/mnist/master/"
FILES = ["train-images-idx3-ubyte.gz", "train-labels-idx1-ubyte.gz",
         "t10k-images-idx3-ubyte.gz", "t10k-labels-idx1-ubyte.gz"]

# brush radius -> chance of being picked for a training copy.
# radius 2 = the 5x5 brush we plan to use on the board.
BRUSH_P = {1: 0.2, 2: 0.6, 3: 0.2}
HEIGHT_RANGE = (26, 60)   # how tall people draw on the 64-pixel-high OLED


# ----------------------------------------------------------------------------
# MNIST loading
# ----------------------------------------------------------------------------
def download():
    os.makedirs(RAW, exist_ok=True)
    for f in FILES:
        path = os.path.join(RAW, f)
        if not os.path.exists(path):
            print("downloading", f)
            urllib.request.urlretrieve(MIRROR + f, path)


def read_idx(name):
    with gzip.open(os.path.join(RAW, name), "rb") as f:
        data = f.read()
    if data[2] != 8:
        raise ValueError("unexpected idx type")
    ndim = data[3]
    shape = [int.from_bytes(data[4 + 4 * i: 8 + 4 * i], "big") for i in range(ndim)]
    return np.frombuffer(data, dtype=np.uint8, offset=4 + 4 * ndim).reshape(shape)


def load_mnist():
    download()
    return (read_idx(FILES[0]), read_idx(FILES[1]),
            read_idx(FILES[2]), read_idx(FILES[3]))


# ----------------------------------------------------------------------------
# Fast version of preprocess.image_to_grid (8x8 greyscale). Same answer, bit
# for bit (checked against the slow one in main()), but uses a running-sum
# table instead of looping over every pixel.
# ----------------------------------------------------------------------------
def fast_grid8(img):
    img = np.asarray(img).astype(bool)
    H, W = img.shape
    grid = np.zeros((8, 8), dtype=np.uint8)
    ys, xs = np.nonzero(img)
    if len(xs) == 0:
        return grid
    xmin, xmax, ymin, ymax = xs.min(), xs.max(), ys.min(), ys.max()
    w, h = xmax - xmin + 1, ymax - ymin + 1
    S = max(w, h)
    x0 = xmin - (S - w) // 2
    y0 = ymin - (S - h) // 2
    ii = np.zeros((H + 1, W + 1), dtype=np.int64)
    ii[1:, 1:] = img.cumsum(0).cumsum(1)

    def box(a, b, c, d):          # ink in rows [a, b), cols [c, d), clipped
        a, b = max(a, 0), min(b, H)
        c, d = max(c, 0), min(d, W)
        if a >= b or c >= d:
            return 0
        return ii[b, d] - ii[a, d] - ii[b, c] + ii[a, c]

    for cy in range(8):
        ys_, ye = y0 + (cy * S * 32 >> 8), y0 + ((cy + 1) * S * 32 >> 8)
        if ye == ys_:
            ye = ys_ + 1
        for cx in range(8):
            xs_, xe = x0 + (cx * S * 32 >> 8), x0 + ((cx + 1) * S * 32 >> 8)
            if xe == xs_:
                xe = xs_ + 1
            area = (xe - xs_) * (ye - ys_)
            count = box(ys_, ye, xs_, xe)
            grid[cy, cx] = (count * 16 + area // 2) // area
    return grid


# ----------------------------------------------------------------------------
# One MNIST digit -> one board-style drawing
# ----------------------------------------------------------------------------
def board_drawing(img28, height, radius, angle=0.0, shear=0.0, xscale=1.0):
    """Returns a binary image that looks like the digit drawn on the OLED."""
    f = img28.astype(np.float32) / 255.0
    k = height / 20.0                     # MNIST digits are about 20 px tall
    t = np.deg2rad(angle)
    rot = np.array([[np.cos(t), -np.sin(t)], [np.sin(t), np.cos(t)]])
    shr = np.array([[1.0, 0.0], [shear, 1.0]])          # (row, col) order
    scl = np.diag([k, k * xscale])
    A = rot @ shr @ scl                   # input -> output, in (row, col)
    size = 110
    Ainv = np.linalg.inv(A)
    centre_in = np.array([13.5, 13.5])
    centre_out = np.array([size / 2, size / 2])
    offset = centre_in - Ainv @ centre_out
    big = ndimage.affine_transform(f, Ainv, offset=offset,
                                   output_shape=(size, size), order=1)
    ink = big >= 0.5                      # same as pixel >= 128
    if not ink.any():
        return None
    line = skeletonize(ink)
    if radius > 0:
        line = ndimage.binary_dilation(line, structure=np.ones((2 * radius + 1,) * 2, bool))
    return line


def _train_job(args):
    img, seed = args
    rng = np.random.default_rng(seed)
    radius = rng.choice(list(BRUSH_P), p=list(BRUSH_P.values()))
    d = board_drawing(img,
                      height=rng.uniform(*HEIGHT_RANGE),
                      radius=int(radius),
                      angle=rng.uniform(-12, 12),
                      shear=rng.uniform(-0.25, 0.25),
                      xscale=rng.uniform(0.75, 1.3))
    if d is None:
        d = board_drawing(img, height=45, radius=2)
    return fast_grid8(d).reshape(-1)


def _test_job(args):
    img, radius, seed = args
    rng = np.random.default_rng(seed)
    d = board_drawing(img, height=rng.uniform(36, 58), radius=radius)
    return fast_grid8(d).reshape(-1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--copies", type=int, default=2,
                    help="augmented copies per MNIST training digit")
    ap.add_argument("--workers", type=int, default=os.cpu_count())
    a = ap.parse_args()

    Xtr, ytr, Xte, yte = load_mnist()
    print(f"MNIST: {len(Xtr)} train, {len(Xte)} test")

    # sanity check: the fast downsampler must match preprocess.py exactly
    rng = np.random.default_rng(0)
    for i in rng.choice(len(Xtr), 200, replace=False):
        d = board_drawing(Xtr[i], height=rng.uniform(*HEIGHT_RANGE), radius=2,
                          angle=rng.uniform(-12, 12))
        assert np.array_equal(fast_grid8(d), image_to_grid(d, 8)), "fast_grid8 mismatch"
    print("fast downsampler matches preprocess.image_to_grid on 200 samples")

    jobs = [(Xtr[i], 1000003 * c + i) for c in range(a.copies) for i in range(len(Xtr))]
    with Pool(a.workers) as p:
        print(f"converting {len(jobs)} training drawings ...")
        X_train = np.array(p.map(_train_job, jobs, chunksize=500), dtype=np.uint8)
        out = {}
        for r in (1, 2, 3):
            print(f"converting test set, brush radius {r} ...")
            out[f"X_test_b{r}"] = np.array(
                p.map(_test_job, [(Xte[i], r, 7 * i + r) for i in range(len(Xte))],
                      chunksize=500), dtype=np.uint8)
    y_train = np.tile(ytr, a.copies).astype(np.int64)
    idx_train = np.tile(np.arange(len(Xtr)), a.copies)
    np.savez_compressed(OUT, X_train=X_train, y_train=y_train, idx_train=idx_train,
                        y_test=yte.astype(np.int64), **out)
    print(f"saved {OUT}: {len(X_train)} training grids, mean value {X_train.mean():.2f}")


if __name__ == "__main__":
    main()
