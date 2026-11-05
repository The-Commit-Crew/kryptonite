"""Verify the existing board keys and export an uncompressed K-PKE test vector."""

import argparse
import re
import secrets
from pathlib import Path

from .keygen import ETA1, K, KEY_DIR, N, Q, negacyclic_multiply, sample_cbd, write_mem


ETA2 = 2
MESSAGE_BYTES = N // 8
ENCODED_ONE = (Q + 1) // 2
FIXED_MESSAGE = b"Kryptonite FPGA encryption demo!"
FIXED_NOISE_SEED = bytes(range(32))  # Public seed for this test vector only.
VECTOR_DIR = Path(__file__).resolve().parent / "test_vectors"
ROUND_TRIPS = 1000


def read_mem(path):
    lines = path.read_text(encoding="ascii").splitlines()
    if len(lines) != N or any(re.fullmatch(r"[0-9A-Fa-f]{3}", line) is None for line in lines):
        raise ValueError(f"{path} must contain {N} three-digit hex coefficients")
    coefficients = [int(line, 16) for line in lines]
    if any(value >= Q for value in coefficients):
        raise ValueError(f"{path} contains a coefficient outside 0..{Q - 1}")
    return coefficients


def load_keys():
    board1, board2 = KEY_DIR / "board1", KEY_DIR / "board2"
    matrix = [[read_mem(board1 / f"A{i}{j}.mem") for j in range(K)] for i in range(K)]
    public = [read_mem(board1 / f"t{i}.mem") for i in range(K)]
    secret = [read_mem(board2 / f"s{i}.mem") for i in range(K)]
    return matrix, public, secret


def sample_noise(seed):
    if len(seed) != 32:
        raise ValueError("encryption noise requires a 32-byte seed")
    r = [sample_cbd(seed, i, ETA1) for i in range(K)]
    e1 = [sample_cbd(seed, K + i, ETA2) for i in range(K)]
    e2 = sample_cbd(seed, 2 * K, ETA2)
    return r, e1, e2


def poly_dot(left, right):
    products = [negacyclic_multiply(a, b) for a, b in zip(left, right)]
    return [sum(terms) % Q for terms in zip(*products)]


def encrypt(matrix, public, message, r, e1, e2):
    """Return (u, v) in coefficient form for the supplied message and noise."""
    if len(message) != MESSAGE_BYTES:
        raise ValueError(f"encryption requires exactly {MESSAGE_BYTES} message bytes")
    encoded = [ENCODED_ONE * ((byte >> bit) & 1) for byte in message for bit in range(8)]

    u = []
    for column, noise in zip(zip(*matrix), e1):
        product = poly_dot(column, r)
        u.append([(value + error) % Q for value, error in zip(product, noise)])

    product = poly_dot(public, r)
    v = [(value + error + bit) % Q for value, error, bit in zip(product, e2, encoded)]
    return u, v


def decrypt(secret, u, v):
    """Recover the 32-byte message from normal-form ciphertext coefficients."""
    product = poly_dot(secret, u)
    message = bytearray(MESSAGE_BYTES)
    for i, (coefficient, mask) in enumerate(zip(v, product)):
        w = (coefficient - mask) % Q
        if 833 <= w <= 2496:
            message[i // 8] |= 1 << (i % 8)
    return bytes(message)


def export_vector(message, r, e1, e2, u, v):
    noise_dir = VECTOR_DIR / "noise"
    ciphertext_dir = VECTOR_DIR / "ciphertext"
    noise_dir.mkdir(parents=True, exist_ok=True)
    ciphertext_dir.mkdir(parents=True, exist_ok=True)

    for i in range(K):
        write_mem(noise_dir / f"r{i}.mem", r[i])
        write_mem(noise_dir / f"e1_{i}.mem", e1[i])
        write_mem(ciphertext_dir / f"u{i}.mem", u[i])
    write_mem(noise_dir / "e2.mem", e2)
    write_mem(ciphertext_dir / "v.mem", v)
    (ciphertext_dir / "message.txt").write_bytes(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    try:
        matrix, public, secret = load_keys()
        r, e1, e2 = sample_noise(FIXED_NOISE_SEED)
        u, v = encrypt(matrix, public, FIXED_MESSAGE, r, e1, e2)
        if decrypt(secret, u, v) != FIXED_MESSAGE:
            raise ValueError("Fixed vector failed to decrypt. Check that both boards use the same key set.")

        for trial in range(1, ROUND_TRIPS + 1):
            message = secrets.token_bytes(MESSAGE_BYTES)
            noise = sample_noise(secrets.token_bytes(32))
            if decrypt(secret, *encrypt(matrix, public, message, *noise)) != message:
                raise ValueError(f"Random round trip {trial} failed")

        export_vector(FIXED_MESSAGE, r, e1, e2, u, v)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")

    print(f"Fixed vector and {ROUND_TRIPS} random encrypt/decrypt round trips passed.")
    print(f"Exported test vector to {VECTOR_DIR}")


if __name__ == "__main__":
    main()
