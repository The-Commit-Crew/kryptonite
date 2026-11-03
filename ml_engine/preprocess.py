"""
preprocess.py  (Khushi)

Bit-exact Python copy of the hardware in rtl/stroke_engine.v and
rtl/downsampler.v.

Two uses:
  1. Testing: the simulation output must match this exactly.
  2. Training (give this to Divyansh): image_to_grid() turns any drawing into
     exactly what the FPGA sends the classifier. 8x8 (default): 64 values
     0..16, laid out like scikit-learn's load_digits() (no border, digit
     scaled to fill the frame). Use it to turn board drawings saved by
     capture_grids.py into extra training data.

Grid layout: grid[row][col], row 0 = top. Hardware cell index = row*GRID + col.
"""
import numpy as np

# grid size -> (PAD, RECIP, SHIFT, TSH, GREY); CELLS = grid - 2*PAD. Same as
# the Verilog defaults in vision_top.v.
#   8x8 : no border, greyscale 0..16 per cell (matches scikit-learn's digits)
#   16x16: 2-cell border, 1 bit per cell (1 if count * 2^TSH >= area)
SETTINGS = {8: (0, 32, 8, 3, True), 16: (2, 683, 13, 2, False)}


def divc(n, recip, shift):
    """Hardware divide-by-CELLS: (n * RECIP) >> SHIFT (exact for our range)."""
    return (n * recip) >> shift


def image_to_grid(img, grid_size=8):
    """8x8: values 0..16 (round(count*16/area)). 16x16: values 0/1."""
    """img: 2-D array (any size), nonzero = ink. Returns grid_size^2 uint8 grid."""
    PAD, RECIP, SHIFT, TSH, GREY = SETTINGS[grid_size]
    CELLS = grid_size - 2 * PAD
    div12 = lambda n: divc(n, RECIP, SHIFT)
    img = np.asarray(img).astype(bool)
    H, W = img.shape
    grid = np.zeros((grid_size, grid_size), dtype=np.uint8)
    ys, xs = np.nonzero(img)
    if len(xs) == 0:
        return grid
    xmin, xmax, ymin, ymax = xs.min(), xs.max(), ys.min(), ys.max()
    w, h = xmax - xmin + 1, ymax - ymin + 1
    S = max(w, h)
    x0 = xmin - (S - w) // 2
    y0 = ymin - (S - h) // 2
    for cy in range(CELLS):
        for cx in range(CELLS):
            xs_, xe = x0 + div12(cx * S), x0 + div12((cx + 1) * S)
            ys_, ye = y0 + div12(cy * S), y0 + div12((cy + 1) * S)
            if xe == xs_:
                xe = xs_ + 1
            if ye == ys_:
                ye = ys_ + 1
            area = (xe - xs_) * (ye - ys_)
            count = 0
            for py in range(ys_, ye):
                for px in range(xs_, xe):
                    if 0 <= px < W and 0 <= py < H and img[py, px]:
                        count += 1
            if GREY:
                # same as the hardware long division: (count*16 + area//2) // area
                grid[cy + PAD, cx + PAD] = (count * 16 + area // 2) // area
            else:
                grid[cy + PAD, cx + PAD] = 1 if (count << TSH) >= area else 0
    return grid


def mnist_to_grid(img28, threshold=128, grid_size=8):
    """MNIST (28x28, 0..255 greyscale) -> binary -> same grid as the board."""
    return image_to_grid(np.asarray(img28) >= threshold, grid_size)


def grid_to_bits(grid):
    """NxN grid -> integer, bit (row*N + col), as in hardware."""
    n = grid.shape[0]
    v = 0
    for r in range(n):
        for c in range(n):
            if grid[r, c]:
                v |= 1 << (r * n + c)
    return v


# ----------------------------------------------------------------------
# Stroke engine model (Bresenham + square brush), for testing
# ----------------------------------------------------------------------
def bresenham(x0, y0, x1, y1):
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x1 >= x0 else -1), (1 if y1 >= y0 else -1)
    err = dx + dy
    pts = []
    while True:
        pts.append((x0, y0))
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy
    return pts


def stamp(canvas, x, y, r, ink):
    for by in range(-r, r + 1):
        for bx in range(-r, r + 1):
            px, py = x + bx, y + by
            if 0 <= px < 96 and 0 <= py < 64:
                canvas[py, px] = ink


def run_strokes(events, canvas=None):
    """events: list of (x, y, paint, erase, brush_sel). Mirrors stroke_engine."""
    if canvas is None:
        canvas = np.zeros((64, 96), dtype=np.uint8)
    was_down, last = False, (0, 0)
    for (x, y, paint, erase, bsel) in events:
        r = [0, 1, 2, 2][bsel]
        if paint or erase:
            ink = 1 if paint else 0
            if not was_down:
                stamp(canvas, x, y, r, ink)
            elif (x, y) != last:
                for (px, py) in bresenham(last[0], last[1], x, y):
                    stamp(canvas, px, py, r, ink)
            last, was_down = (x, y), True
        else:
            was_down = False
    return canvas


def show(grid):
    """Text picture of a grid: '.' empty, then darker characters for more ink."""
    chars = " .:-=+*#%@"
    mx = 16 if grid.max() > 1 else 1
    return "\n".join("".join(chars[min(9, int(v) * 9 // mx)] if v else "." for v in row) for row in grid)


if __name__ == "__main__":
    # quick demo: a hand-made "7"
    ev = [(30, 10, 1, 0, 1), (60, 10, 1, 0, 1), (40, 55, 1, 0, 1), (40, 55, 0, 0, 1)]
    c = run_strokes(ev)
    print(show(image_to_grid(c)))
