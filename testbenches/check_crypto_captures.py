"""Check captured RTL ciphertext against Python, including the live LFSR noise."""

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from crypto.encrypt import FIXED_MESSAGE, decrypt, encrypt, load_keys


def read_capture(path):
    text = re.sub(r"//[^\n]*", "", path.read_text(encoding="ascii"))
    return [int(word, 16) for word in text.split() if not word.startswith("@")]


def live_noise(seed):
    mask = (1 << 64) - 1
    state = seed or 1

    def step():
        nonlocal state
        feedback = ((state >> 63) ^ (state >> 62) ^ (state >> 60) ^ (state >> 59)) & 1
        state = ((state << 1) & mask) | feedback

    for _ in range(64):
        step()
    samples = []
    for i in range(1280):
        eta = 3 if i < 512 else 2
        value = 0
        for j in range(2 * eta):
            value += (1 if j < eta else -1) * (state >> 63)
            step()
        samples.append(value % 3329)
    return samples


def verify(matrix, public, secret, message, noise, coefficients):
    assert len(noise) == 1280 and len(coefficients) == 768
    r = [noise[:256], noise[256:512]]
    e1 = [noise[512:768], noise[768:1024]]
    u, v = encrypt(matrix, public, message, r, e1, noise[1024:])
    assert coefficients == u[0] + u[1] + v, "RTL ciphertext differs from Python"
    assert decrypt(secret, u, v) == message, "Ciphertext did not decrypt"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--tests", nargs="+", required=True)
    args = parser.parse_args()
    matrix, public, secret = load_keys()
    if "tb_encrypt" in args.tests:
        verify(matrix, public, secret, FIXED_MESSAGE,
               read_capture(args.run_dir / "live_noise.mem"),
               read_capture(args.run_dir / "live_ciphertext.mem"))
        print("PASS: live encryption RTL matches Python and decrypts to the original message")
    if "tb_board1_top_live" in args.tests:
        messages = ["379", "15", "2", " Ee  2026A", "0123456789012345"]
        for number, text in enumerate(messages, 1):
            paths = list(args.run_dir.glob(f"top_0_{number}_*.mem"))
            assert len(paths) == 1, f"Expected one capture for live Board 1 message {number}"
            path = paths[0]
            seed = int(path.stem.rsplit("_", 1)[1])
            data = read_capture(path)
            assert len(data) == 1536
            coefficients = [lo | (hi << 8) for lo, hi in zip(data[::2], data[1::2])]
            verify(matrix, public, secret, text.encode("ascii").ljust(32, b" "),
                   live_noise(seed), coefficients)
        print("PASS: all five live Board 1 UART captures match Python and decrypt correctly")


if __name__ == "__main__":
    main()
