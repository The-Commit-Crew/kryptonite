"""fx_frames.py (Khushi) - turn tb_fx.v's PPM frames into one contact sheet.
    py testbenches/fx_frames.py path/to/frames
needs: pip install pillow
"""
import glob, os, sys
from PIL import Image, ImageDraw

folder = sys.argv[1] if len(sys.argv) > 1 else "frames"
files = sorted(glob.glob(os.path.join(folder, "*.ppm")))
if not files:
    sys.exit(f"no .ppm files in {folder}")
S, cols, pad = 3, 4, 18
W, H = 96 * S, 64 * S
rows = (len(files) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (W + 8) + 8, rows * (H + pad + 8) + 8), (40, 40, 40))
d = ImageDraw.Draw(sheet)
for i, fn in enumerate(files):
    im = Image.open(fn).convert("RGB").resize((W, H), Image.NEAREST)
    x, y = 8 + (i % cols) * (W + 8), 8 + (i // cols) * (H + pad + 8)
    d.text((x, y), os.path.basename(fn)[:-4], fill=(220, 220, 220))
    sheet.paste(im, (x, y + pad))
out = os.path.join(folder, "contact_sheet.png")
sheet.save(out)
print("saved", out)
