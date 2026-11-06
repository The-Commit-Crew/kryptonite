# ML Engine: TinyML Digit Classifier & FPGA Memory Exporter

The `ml_engine` folder trains the handwritten digit classifier for **Kryptonite** and exports its weights as `.mem` files for `tinyml_core.v` on the **Basys 3 (Artix-7)**.

The model is a small neural network: 64 inputs (the 8x8 grid from the board), one hidden layer of 64 neurons with ReLU, and 10 outputs (digits 0 to 9).

## What changed (Nov 2026)

| | Before | Now |
| :-- | :-- | :-- |
| Training data | scikit-learn digits only (1,797 digits, 43 writers) | MNIST converted to board-style grids (120k) + scikit-learn digits (+ board drawings if `drawings.npz` exists) |
| Hidden neurons | 16 | 64 (a 32-neuron backup is in `mem_files_h32/`) |
| Testing | none (trained and tested on the same data) | separate validation and test sets, confusion matrix |
| Accuracy on board-style MNIST test digits (5x5 brush, FPGA maths) | 53% (0s: 24%, 6s: 42%) | 97.2% (0s: 98.4%, 6s: 97.4%, 8s: 94.4%) |
| Output bias in hardware | added without the needed `<< 8` | `verify_hw.py` models the fixed Verilog |

## Pipeline

```
MNIST (28x28)  --prepare_mnist.py-->  board-style 8x8 grids (values 0..16)
                                              |
scikit-learn digits (8x8, 0..16) -------------+---- data_setup.py
board drawings (drawings.npz, optional) ------+
                                              |
                                          train.py   -> tinyml_weights.pth
                                              |
                                     export_weights.py -> mem_files/*.mem
                                              |
                                        verify_hw.py  -> checks + testbench vectors
```

## Files

| File | What it does |
| :-- | :-- |
| `preprocess.py` | Exact Python copy of `stroke_engine.v` + `downsampler.v` (unchanged) |
| `prepare_mnist.py` | Makes MNIST look like board drawings, saves `mnist_board.npz` |
| `data_setup.py` | Combines all data sources, holds back validation sets |
| `model.py` | `TinyMLP`; `DEFAULT_HIDDEN` must match `HIDDEN_NODES` in `tinyml_core.v` |
| `train.py` | Trains, keeps the best epoch, reports PyTorch and FPGA accuracy |
| `hw_model.py` | The FPGA's whole-number maths in Python |
| `export_weights.py` | Writes the four `.mem` files (Q8.8, 16-bit) into `mem_files/` |
| `verify_hw.py` | Checks `.mem` files against the model, writes testbench vectors |
| `capture_grids.py` | Saves real board drawings to `drawings.npz` (used automatically if present) |

## How MNIST is made to look like the board

For each MNIST digit, `prepare_mnist.py`:

1. applies small random changes: tilt (up to 12 degrees), slant, wider or narrower, and a random height of 26 to 60 pixels (the OLED is 64 tall)
2. makes it black and white (pixel >= 128 is ink, same as `mnist_to_grid`)
3. thins the strokes to a 1-pixel line
4. redraws the line with a square brush like `stroke_engine.v` (5x5 most of the time, some 3x3 and 7x7)
5. downsamples with the same maths as `downsampler.v` (checked bit for bit against `preprocess.image_to_grid`)

Inputs stay as whole numbers 0 to 16, exactly what the board sends. Do not divide or normalise them (no `ToTensor()` / `Normalize()`), or the model will expect different numbers from what the hardware gives it.

## How to run

```bash
cd ml_engine
python -m venv venv
venv\Scripts\activate            # Windows  (source venv/bin/activate on Linux/macOS)
pip install -r requirements.txt

python prepare_mnist.py          # about 1-3 min, downloads MNIST the first time
python train.py                  # about 1-2 min, saves tinyml_weights.pth
python export_weights.py         # writes mem_files/*.mem
python verify_hw.py              # checks the .mem files, writes testbench vectors
```

Then copy `mem_files/hw.mem`, `hb.mem`, `ow.mem`, `ob.mem` into `kryptonite/kryptonite.srcs/sources_1/imports/mem_files/`.

Options: `python train.py --hidden 32` trains a smaller model; `python export_weights.py --weights tinyml_weights_h32.pth --out-dir mem_files_h32` exports it.

## Results (seed 0)

| Hidden neurons | MNIST test, 3x3 brush | 5x5 brush | 7x7 brush | sklearn validation |
| :-- | :-- | :-- | :-- | :-- |
| 16 | 94.3% | 94.7% | 94.4% | 95.0% |
| 32 | 96.3% | 96.5% | 96.2% | 97.8% |
| **64 (chosen)** | **96.7%** | **97.2%** | **96.8%** | **98.9%** |
| 128 | 97.0% | 97.3% | 97.2% | 98.3% |

All numbers use the FPGA's whole-number maths. 128 neurons doubles the hardware for about 0.1 to 0.3% more, so 64 was chosen.

## Hardware notes

- **Number format:** every weight and bias is multiplied by 256 and stored as a signed 16-bit word (Q8.8).
- **Scaling through the network:** pixels are whole numbers 0 to 16, so the hidden layer sums come out x256. The output layer multiplies x256 hidden values by x256 weights, so its sums come out x65536. The output bias is only x256, so the Verilog must shift it left by 8 before adding (`ob << 8`). `hw_model.py` shows the exact maths.
- **Memory size:** with 64 hidden neurons, `hw.mem` has 4,096 words, `hb.mem` 64, `ow.mem` 640 and `ob.mem` 10. `HIDDEN_NODES` in `tinyml_core.v` must match.
- **Testbench vectors:** `mem_files/tb_grids.mem` holds 50 grids, one 320-bit hex word per line (cell 0 in bits [4:0], same as the downsampler). `tb_expected.mem` holds the digit `tinyml_core` should output for each one.
