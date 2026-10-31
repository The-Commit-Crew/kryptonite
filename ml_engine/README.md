# ML Engine: TinyML Digit Classifier & FPGA Memory Exporter

The `ml_engine` directory contains the machine learning pipeline for **Kryptonite**, a hardware-accelerated TinyML deployment targeted for the **Digilent Basys 3 FPGA (Xilinx Artix-7)**.

It provides end-to-end tooling to prepare the dataset, define and train a lightweight Multi-Layer Perceptron (MLP) neural network, serialize trained weights, and quantize parameters into 16-bit fixed-point (Q8.8) hexadecimal memory (`.mem`) files ready for FPGA BRAM/ROM initialization via Verilog's `$readmemh`.

---

## Architecture & Hardware Pipeline Overview

```
 ┌──────────────────────┐
 │ Scikit-Learn Digits  │ (8x8 grayscale images, 64 features)
 └──────────┬───────────┘
            │
            ▼
 ┌──────────────────────┐
 │ data_setup.py        │ Flattens to (N, 64), creates PyTorch DataLoader
 └──────────┬───────────┘
            │
            ▼
 ┌──────────────────────┐
 │ model.py (TinyMLP)   │ Linear(64, 16) -> ReLU -> Linear(16, 10)
 └──────────┬───────────┘ [Total: 1,210 parameters]
            │
            ▼
 ┌──────────────────────┐
 │ train.py             │ 100 Epochs, Adam (lr=0.001), CrossEntropyLoss
 └──────────┬───────────┘ Generates: tinyml_weights.pth
            │
            ▼
 ┌──────────────────────┐
 │ export_weights.py    │ Q8.8 Quantization (scale * 256), 16-bit 2's complement
 └──────────┬───────────┘
            │
            ▼
 ┌──────────────────────┐
 │ mem_files/ (*.mem)   │ hw.mem, hb.mem, ow.mem, ob.mem
 └──────────┬───────────┘
            │
            ▼
 ┌──────────────────────┐
 │ Basys 3 FPGA (RTL)   │ Verilog $readmemh initialization into BRAM / ROM
 └──────────────────────┘
```

---

## Directory Structure

```
ml_engine/
├── data_setup.py          # Dataset loading, preprocessing, and DataLoader generator
├── model.py               # PyTorch neural network definition (TinyMLP)
├── train.py               # Model training script and checkpoint exporter
├── export_weights.py      # Fixed-point quantization & Verilog .mem file generator
├── requirements.txt       # Python dependencies (PyTorch, scikit-learn, etc.)
├── tinyml_weights.pth     # Serialized PyTorch model weights (1,210 parameters)
├── mem_files/             # Exported 16-bit hexadecimal memory initialization files
│   ├── hw.mem             # Hidden layer weights (1,024 words)
│   ├── hb.mem             # Hidden layer biases (16 words)
│   ├── ow.mem             # Output layer weights (160 words)
│   └── ob.mem             # Output layer biases (10 words)
└── README.md              # Documentation of the ML engine
```

---

## Detailed Components

### 1. Data Pipeline (`data_setup.py`)

- **Dataset:** Scikit-Learn `load_digits()` (1,797 samples of 8x8 pixel grayscale handwritten digits, values ranging 0–16).
- **Preprocessing:**
  - Flattens each 8x8 2D matrix into a 1D feature vector of length 64.
  - Converts pixel values to `torch.float32` tensors and target labels to `torch.long`.
- **Dataloader:** Wraps tensors into a `TensorDataset` and returns a batched, shuffled PyTorch `DataLoader` (default `batch_size=32`).
- **Standalone Execution:** Run `python3 data_setup.py` to inspect the batch shapes and raw pixel vectors.

### 2. Neural Network Architecture (`model.py`)

Defined as `TinyMLP(nn.Module)`, the model is architected specifically for low-latency, low-footprint hardware acceleration on an FPGA:

| Layer            | Type        | Input Dimensions | Output Dimensions       | Parameters                                  |
| :--------------- | :---------- | :--------------- | :---------------------- | :------------------------------------------ |
| **Hidden Layer** | `nn.Linear` | 64 features      | 16 neurons              | $16 \times 64 = 1,024$ weights, $16$ biases |
| **Activation**   | `nn.ReLU`   | 16               | 16                      | 0                                           |
| **Output Layer** | `nn.Linear` | 16 neurons       | 10 classes (digits 0–9) | $10 \times 16 = 160$ weights, $10$ biases   |
| **Total**        |             |                  |                         | **1,210 parameters**                        |

- **Standalone Execution:** Run `python3 model.py` to verify the parameter count and input/output tensor shapes with dummy data.

### 3. Model Training (`train.py`)

- **Loss Function:** `nn.CrossEntropyLoss()` (computes softmax internally for multi-class classification).
- **Optimizer:** `torch.optim.Adam` with learning rate $\alpha = 0.001$.
- **Training Epochs:** 100 epochs across the full digits dataset.
- **Output:** Saves the trained floating-point state dictionary to `tinyml_weights.pth`.

### 4. Quantization & Hardware Memory Export (`export_weights.py`)

Translates trained PyTorch floating-point tensors into fixed-point representations suitable for digital hardware:

- **Number Representation:** Signed 16-bit fixed-point in **Q8.8 format** (1 sign bit, 7 integer bits, 8 fractional bits).
- **Scaling Factor:** Multiplied by $2^8 = 256$ and rounded to nearest integer:
  $$\text{param}_{\text{scaled}} = \lfloor \text{param} \times 256 + 0.5 \rfloor$$
- **Two's Complement Encoding:** Formats negative and positive integers into 16-bit two's complement hexadecimal words using the bitmask `val & 0xFFFF`.
- **Target Output:** 4 separate `.mem` files in `mem_files/` formatted as 4-character hex strings per line (`04X`), directly loadable in Verilog/SystemVerilog using `$readmemh`:

| File               | Parameter Name        | PyTorch Shape | Format / Lines           |
| :----------------- | :-------------------- | :------------ | :----------------------- |
| `mem_files/hw.mem` | `hidden_layer.weight` | $(16, 64)$    | 1,024 lines (16-bit hex) |
| `mem_files/hb.mem` | `hidden_layer.bias`   | $(16,)$       | 16 lines (16-bit hex)    |
| `mem_files/ow.mem` | `output_layer.weight` | $(10, 16)$    | 160 lines (16-bit hex)   |
| `mem_files/ob.mem` | `output_layer.bias`   | $(10,)$       | 10 lines (16-bit hex)    |

---

## How to Run & Reproduce

### 1. Environment Setup

From the `ml_engine` directory, initialize a Python virtual environment and install requirements:

```bash
cd ml_engine
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. Train the Model

Train `TinyMLP` on the digits dataset and export `tinyml_weights.pth`:

```bash
python3 train.py
```

### 3. Export Hardware Memory Files

Generate the 16-bit hexadecimal `.mem` files for FPGA synthesis and simulation:

```bash
python3 export_weights.py
```

---

## Hardware RTL Integration Notes

- **Memory Loading:** In your Verilog/SystemVerilog RTL testbench or synthesis modules:
  ```verilog
  reg [15:0] hidden_weights [0:1023];
  initial begin
      $readmemh("hw.mem", hidden_weights);
  end
  ```
- **Arithmetic Alignment:** Because weights and biases are scaled by $256$ (Q8.8), multiplications with inputs scaled similarly will shift the fractional point by 16 bits ($Q8.8 \times Q8.8 = Q16.16$). Ensure the hardware MAC (Multiply-Accumulate) unit accounts for truncation/arithmetic right-shifts prior to ReLU and output classification.
