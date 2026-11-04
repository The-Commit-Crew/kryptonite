"""Generate one K-PKE key set in normal coefficient order for the two boards."""

import argparse
import hashlib
import secrets
from pathlib import Path
from tempfile import TemporaryDirectory


N = 256
Q = 3329
K = 2
ETA1 = 3
KEY_DIR = Path(__file__).resolve().parent / "keys"

# FIPS 203 Algorithm 10 uses powers of 17 indexed by seven-bit reversal.
ZETAS = [pow(17, int(f"{i:07b}"[::-1], 2), Q) for i in range(N // 2)]


def sample_ntt(rho, row, column):
    """Expand one matrix entry using FIPS 203 SampleNTT."""
    shake = hashlib.shake_128(rho + bytes([column, row]))
    block_size = 168  # SHAKE128 rate in bytes, also a multiple of three.
    data = shake.digest(3 * block_size)
    offset = 0
    coefficients = []
    while len(coefficients) < N:
        if offset == len(data):
            # digest() returns the entire prefix. Resume at the previous offset.
            data = shake.digest(len(data) + block_size)
        b0, b1, b2 = data[offset:offset + 3]
        offset += 3
        for candidate in (b0 | ((b1 & 0xF) << 8), (b1 >> 4) | (b2 << 4)):
            if candidate < Q:
                coefficients.append(candidate)
                if len(coefficients) == N:
                    return coefficients


def inverse_ntt(coefficients):
    """Convert an NTT polynomial to normal coefficient order."""
    result = list(coefficients)
    zeta_index = N // 2 - 1
    for stage in range(1, 8):
        width = 1 << stage
        for start in range(0, N, 2 * width):
            zeta = ZETAS[zeta_index]
            zeta_index -= 1
            for j in range(start, start + width):
                low, high = result[j], result[j + width]
                result[j] = (low + high) % Q
                result[j + width] = (zeta * (high - low)) % Q
    return [(coefficient * 3303) % Q for coefficient in result]


def sample_cbd(seed, nonce, eta):
    """Sample 256 CBD coefficients from the SHAKE256 PRF, LSB first."""
    data = hashlib.shake_256(seed + bytes([nonce])).digest(64 * eta)
    bits = int.from_bytes(data, "little")
    mask = (1 << eta) - 1
    coefficients = []
    for _ in range(N):
        positive = bits & mask
        negative = (bits >> eta) & mask
        coefficients.append((positive.bit_count() - negative.bit_count()) % Q)
        bits >>= 2 * eta
    return coefficients


def negacyclic_multiply(left, right):
    """Multiply normal-form polynomials modulo q and X^256 + 1."""
    convolution = [0] * (2 * N)
    for i, a in enumerate(left):
        for j, b in enumerate(right):
            convolution[i + j] += a * b
    return [(convolution[i] - convolution[i + N]) % Q for i in range(N)]


def keygen(d):
    """Return (A, t, s) in normal form from a 32-byte seed."""
    if len(d) != 32:
        raise ValueError("key generation requires a 32-byte seed")
    expanded = hashlib.sha3_512(d + bytes([K])).digest()
    rho, sigma = expanded[:32], expanded[32:]

    matrix = [
        [inverse_ntt(sample_ntt(rho, i, j)) for j in range(K)]
        for i in range(K)
    ]
    secret = [sample_cbd(sigma, i, ETA1) for i in range(K)]
    error = [sample_cbd(sigma, K + i, ETA1) for i in range(K)]
    public = []
    for row, noise in zip(matrix, error):
        products = [negacyclic_multiply(a, s) for a, s in zip(row, secret)]
        public.append([
            (sum(terms) + error_coefficient) % Q
            for terms, error_coefficient in zip(zip(*products), noise)
        ])
    return matrix, public, secret


def write_mem(path, polynomial):
    contents = "".join(f"{value:03X}\n" for value in polynomial)
    path.write_text(contents, encoding="ascii", newline="\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if KEY_DIR.exists():
        parser.exit(1, f"Key set already exists at {KEY_DIR}. Reuse it for both boards.\n")

    matrix, public, secret = keygen(secrets.token_bytes(32))
    # Publish both boards' files together after every write succeeds.
    with TemporaryDirectory(prefix=".keygen-", dir=KEY_DIR.parent) as temporary:
        staging = Path(temporary) / KEY_DIR.name
        staging.mkdir(mode=0o700)
        board1, board2 = staging / "board1", staging / "board2"
        board1.mkdir()
        board2.mkdir()
        for i in range(K):
            for j in range(K):
                write_mem(board1 / f"A{i}{j}.mem", matrix[i][j])
            write_mem(board1 / f"t{i}.mem", public[i])
            write_mem(board2 / f"s{i}.mem", secret[i])
        try:
            staging.rename(KEY_DIR)
        except FileExistsError:
            parser.exit(1, f"Key set already exists at {KEY_DIR}. Reuse it for both boards.\n")

    print(f"Generated matching key files in {KEY_DIR}")


if __name__ == "__main__":
    main()
