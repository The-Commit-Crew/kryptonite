"""
capture_grids.py  (Khushi)

Collects real drawings from the board for training. Every time you press
submit on the board, the grid (8x8, values 0..16) is sent over the USB cable. This script
shows it, asks what character it is, and saves it.

    pip install pyserial numpy
    python capture_grids.py COM8          (8x8 greyscale, the default build)
    python capture_grids.py COM8 16       (if the board is built with GRID = 16)
Find your port with:  py -m serial.tools.list_ports -v  (look for "USB Serial Port")

Output: drawings.npz with X (N x GRID x GRID) and y (N labels as strings).
Give this file to Divyansh to add to the training set.
"""
import os, sys
import numpy as np
import serial

port = sys.argv[1] if len(sys.argv) > 1 else "COM5"
GRID = int(sys.argv[2]) if len(sys.argv) > 2 else 8
GREY = (GRID == 8)          # 8x8 build sends one byte per cell (0..16)
out = "drawings.npz"
ser = serial.Serial(port, 115200, timeout=None)

X, y = [], []
if os.path.exists(out):
    d = np.load(out)
    X, y = list(d["X"]), list(d["y"])
    print(f"loaded {len(X)} existing drawings")

print("Draw on the board and press submit. Ctrl+C to stop.")
try:
    while True:
        # wait for the 0xA5 0x5A header
        if ser.read(1) != b"\xA5":
            continue
        if ser.read(1) != b"\x5A":
            continue
        if GREY:
            data = ser.read(GRID * GRID)
            grid = np.frombuffer(data, dtype=np.uint8).reshape(GRID, GRID).copy()
            print("\n".join(" ".join(f"{v:2d}" for v in row) for row in grid))
        else:
            data = ser.read(GRID * GRID // 8)
            bits = 0
            for i, b in enumerate(data):
                bits |= b << (8 * i)
            grid = np.array([[(bits >> (r * GRID + c)) & 1 for c in range(GRID)] for r in range(GRID)],
                            dtype=np.uint8)
            print("\n".join("".join("#" if v else "." for v in row) for row in grid))
        label = input("label (Enter = skip): ").strip()
        if label:
            X.append(grid)
            y.append(label)
            np.savez(out, X=np.array(X), y=np.array(y))
            print(f"saved, {len(X)} total")
except KeyboardInterrupt:
    print(f"\nstopped, {len(X)} drawings in {out}")
