"""
hw_model.py

Python copy of the maths tinyml_core.v does, using whole numbers only, so we can
check what the FPGA will predict before going to the board.

  hidden = ReLU( sum(pixel * hw) + hb )          pixels 0..16, hw/hb are x256
  score  = sum(hidden * ow) + (ob << 8)          hidden x256, ow x256 -> x65536
  prediction = index of the largest score (lowest index wins a tie)

bias_fix=False reproduces the old Verilog (ob added without << 8).
"""
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MEM_DIR = os.path.join(HERE, "mem_files")


def quantize(t):
    """float -> Q8.8 integer (x256, rounded), same as export_weights.py."""
    q = np.round(np.asarray(t, dtype=np.float64) * 256).astype(np.int64)
    if q.min() < -32768 or q.max() > 32767:
        raise ValueError("value does not fit in 16 bits (|x| >= 128)")
    return q


def read_mem(name, mem_dir=MEM_DIR):
    with open(os.path.join(mem_dir, name)) as f:
        v = np.array([int(line, 16) for line in f.read().split()], dtype=np.int64)
    return np.where(v >= 32768, v - 65536, v)


def load_mem_weights(mem_dir=MEM_DIR):
    hw, hb = read_mem("hw.mem", mem_dir), read_mem("hb.mem", mem_dir)
    ow, ob = read_mem("ow.mem", mem_dir), read_mem("ob.mem", mem_dir)
    hidden = len(hb)
    return hw.reshape(hidden, 64), hb, ow.reshape(10, hidden), ob


def hw_scores(X, hw, hb, ow, ob, bias_fix=True):
    X = np.asarray(X, dtype=np.int64)
    hidden = np.maximum(X @ hw.T + hb, 0)
    return hidden @ ow.T + (ob * 256 if bias_fix else ob)


def hw_predict(X, hw, hb, ow, ob, bias_fix=True):
    # np.argmax returns the first (lowest) index on ties, same as the Verilog
    return hw_scores(X, hw, hb, ow, ob, bias_fix).argmax(1)
