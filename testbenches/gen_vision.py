"""Generate random stroke tests for tb_vision.v and the expected results."""
import json, os, random, sys
GRID = int(os.environ.get('GRID', '8'))   # 8 or 16, must match the testbench
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "ml_engine"))   # repo layout
import numpy as np
from preprocess import run_strokes, image_to_grid

random.seed(2026)
lines, expected = [], []
canvas = np.zeros((64, 96), dtype=np.uint8)


def ev(x, y, p, e, b, s=0, c=0):
    lines.append(f"{x} {y} {p} {e} {b} {s} {c}")


def submit():
    ev(0, 0, 0, 0, 0, s=1)
    g = image_to_grid(canvas, GRID)
    expected.append({"canvas": canvas.flatten().tolist(), "grid": g.flatten().tolist()})


def clear():
    global canvas
    ev(0, 0, 0, 0, 0, c=1)
    canvas = np.zeros((64, 96), dtype=np.uint8)


def stroke(points, b, erase=False):
    """points: list of (x,y); pen down for all, then pen up."""
    global canvas
    evs = []
    for (x, y) in points:
        ev(x, y, 0 if erase else 1, 1 if erase else 0, b)
        evs.append((x, y, 0 if erase else 1, 1 if erase else 0, b))
    ev(points[-1][0], points[-1][1], 0, 0, b)
    evs.append((points[-1][0], points[-1][1], 0, 0, b))
    canvas = run_strokes(evs, canvas)


# 0. empty canvas
submit()

# 1. tall thin "1" (tests aspect ratio / centring)
stroke([(48, 8), (48, 56)], 1)
submit(); clear()

# 2. a "7" with a 5x5 brush, fast jumps (tests Bresenham in all directions)
stroke([(30, 10), (65, 10), (42, 58)], 2)
submit(); clear()

# 3. tiny drawing (S < 12, tests the 'at least one pixel per cell' rule)
stroke([(10, 10), (14, 13)], 0)
submit(); clear()

# 4. strokes touching the edges (tests clipping / padding)
stroke([(0, 0), (95, 63)], 2)
stroke([(95, 0), (0, 63)], 1)
submit(); clear()

# 5. draw then erase part of it (tests exact re-scan of the bounding box)
stroke([(20, 30), (80, 30)], 2)
stroke([(60, 25), (85, 25), (85, 35), (60, 35)], 2, erase=True)
stroke([(60, 30), (85, 30)], 2, erase=True)
submit(); clear()

# 6-25. random scribbles
for t in range(20):
    for _ in range(random.randint(1, 3)):
        pts = [(random.randint(0, 95), random.randint(0, 63)) for _ in range(random.randint(1, 6))]
        stroke(pts, random.randint(0, 2))
    submit(); clear()

here = os.path.dirname(__file__)
open(os.path.join(here, "stim_vision.txt"), "w").write("\n".join(lines) + "\n")
json.dump(expected, open(os.path.join(here, "expected_vision.json"), "w"))
print(f"{len(lines)} events, {len(expected)} submits")
