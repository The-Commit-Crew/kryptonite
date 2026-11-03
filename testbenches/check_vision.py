"""Compare tb_vision.v output with the Python reference."""
import json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))
import numpy as np
GRID = int(os.environ.get('GRID', '8'))
from preprocess import show

here = os.path.dirname(__file__)
exp = json.load(open(os.path.join(here, "expected_vision.json")))
out = open(os.path.join(here, "out_vision.txt")).read().split("\n")
out = [l for l in out if l.strip()]
got = [(out[i], out[i + 1]) for i in range(0, len(out), 2)]

ok = True
if len(got) != len(exp):
    print(f"FAIL: expected {len(exp)} results, got {len(got)}")
    ok = False
for i, (e, (cline, gline)) in enumerate(zip(exp, got)):
    canvas_hw = [int(ch) for ch in cline.strip()]
    grid_hw = [int(ch) for ch in gline.split()[0]]
    c_ok = canvas_hw == e["canvas"]
    g_ok = grid_hw == e["grid"]
    print(f"test {i:2d}: canvas {'PASS' if c_ok else 'FAIL'}  grid {'PASS' if g_ok else 'FAIL'}")
    if not (c_ok and g_ok):
        ok = False
        print("expected grid:\n" + show(np.array(e["grid"]).reshape(GRID, GRID)))
        print("hardware grid:\n" + show(np.array(grid_hw).reshape(GRID, GRID)))
    if i in (1, 2):
        print(show(np.array(grid_hw).reshape(GRID, GRID)))
print("ALL PASS" if ok else "SOME FAILED")
