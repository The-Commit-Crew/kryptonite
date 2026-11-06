# Ciphertext transmission

`ciphertext_uart_tx` reads the synchronous ciphertext port of `board1_send` and
feeds the existing `uart_link` send interface. It requires exclusive access to
that interface while `busy` is high.

The proposed receiver contract uses twelve packets per ciphertext. Every packet
has 128 payload bytes. Packet type `0x10 + index` identifies index 0 through 11.
The existing UART layer adds the start marker, sequence number, length and
checksum, and handles packet acknowledgements and retransmissions.

| Packet types | Coefficients |
| --- | --- |
| `0x10` through `0x13` | `u0[0]` through `u0[255]` |
| `0x14` through `0x17` | `u1[0]` through `u1[255]` |
| `0x18` through `0x1B` | `v[0]` through `v[255]` |

Each coefficient occupies two bytes, low byte first. The high byte's upper four
bits are zero. Packet index `i` carries bytes `128*i` through `128*i+127` of the
1536-byte ciphertext. The payload consists entirely of ciphertext bytes.

Board 2 should begin or restart assembly on a valid type-`0x10` packet. Accept
successive types in order, require length 128, and decrypt after type `0x1B`.
Discard an incomplete assembly when a new type-`0x10` packet arrives. The UART
link suppresses duplicate deliveries caused by a lost packet acknowledgement.
This packet layout needs coordination with the Board 2 receiver.

Pulse `start` after `board1_send.ciphertext_ready`. Keep its ciphertext available
until the adapter signals a result. `done` pulses after all twelve packets have
been acknowledged, at which point the source may be released. `fail` pulses
after the UART link exhausts its retries for a packet. The adapter stops the
serializer and retains source ownership for the caller to retry with another
`start` pulse or explicitly abandon the ciphertext. The caller controls source
release in both cases.

The adapter holds the packet buffer unchanged while the UART link is sending or
retrying. It backpressures the serializer between packets. A retry of the whole
ciphertext restarts at packet type `0x10` and source coefficient zero.

## Board 1 integration

`My_Top_Module` enables the encrypted sender through `top_fsm.ENCRYPT_SEND`.
Centre on the mouse MESSAGE screen snapshots and encrypts the current digits.
Enter on the keyboard board snapshots the editor's ASCII bytes. Both paths
preserve the first character in byte 0 and pad the 32-byte plaintext with spaces.
The busy LED covers encryption and transmission. OK appears after all packets
are acknowledged. After FAIL, Left retries the retained ciphertext, and Centre
(mouse) or Enter (keyboard) encrypts a new snapshot. Edits and extra Send presses during an active operation
leave the in-flight message intact. The source is released after success or
when a new message replaces a failed operation.

The FPGA configuration defaults to `SIM_MULTIPLIER=0` and uses
`shared_poly_multiplier.v`. It runs two writable `ntt_core` instances in
parallel, multiplies adjacent NTT coefficient pairs modulo `X^2 - gamma`, and
uses `intt_core` to return the normal-form product modulo `X^256 + 1` and 3329.
The pair arithmetic shares one pipelined variable multiplier and Barrett
reducer. It does not use the secret-key ROMs in the decryption-specific
`basemul_core`.

Load all 256 operand pairs before each `mul_start` pulse. Writes and starts are
ignored while the multiplier is running. `mul_done` pulses for one clock; the
result remains available through the one-clock synchronous read port until the
next operation. Reset aborts an active operation, after which both operands must
be loaded again. The encryption controller already follows this contract for
its six products per message.

Include `shared_poly_multiplier.v`, `ntt_core.v`, `intt_core.v`, `butterfly.v`,
`butterfly_inv.v`, `barrett_reduce.v` and `mod_mult_pipeline.v` in the Vivado
sources, and include `zetas.mem` and `gammas.mem` from
`sources_1/imports/mem_files` as memory files.
Both tables use canonical residues, without Montgomery scaling. Their filenames
can be overridden through the multiplier's `ZETAS_FILE` and `GAMMAS_FILE`
parameters. The transform cores also accept `ZETAS_FILE`, defaulting to the
original `zetas.mem` name. Encryption enables their `PIPELINED` mode, inserting
five registered modular-multiplication stages for the 100 MHz clock. The default
transform mode retains the existing decryption timing and implementation.

`SIM_MULTIPLIER=1` still selects `testbenches/poly_mult_model.sv` for quick UI
simulations. The encryption and Board 1 integration regressions now default to
the real multiplier. `ENCRYPT_SEND=0` selects the existing plaintext send path
for the earlier UI/UART demonstrations.

The existing short-plaintext receive display remains available. Ciphertext
fragment reassembly and decryption belong to the Board 2 receive integration.

## Hardware multiplier verification

From the repository root, run the Vivado Simulator regressions with PowerShell:

```powershell
./testbenches/run_crypto.ps1 -VivadoBin 'C:/AMD/2025.2/Vivado/bin'
```

Set `-VivadoBin` to your installation's `bin` directory. The runner stages inputs
and writes logs under the ignored `.crypto.sim` directory. It checks ten
polynomial products against the schoolbook reference (including negacyclic
wraparound, dense/random inputs, busy protection and reset recovery), fixed and
live encryption, the existing NTT decryption regression, and Board 1 UI/UART
retries with the hardware multiplier. Keyboard tests follow the digits-only UI.
Python also compares live-noise ciphertext with the reference and decrypts it
using the existing local `crypto/keys/board2` key set. No keys are regenerated.

For a Basys 3 synthesis/resource/timing check:

```powershell
& 'C:/AMD/2025.2/Vivado/bin/vivado.bat' -mode batch -source testbenches/synth_crypto.tcl
```

Append `-tclargs My_Top_Module` to synthesize the complete board top. The script
uses the `xc7a35tcpg236-1` part and a 10 ns clock, and writes reports under
`.crypto.sim`. Synthesis timing is an estimate; routed timing and physical-board
verification are separate checks.

Verified with Vivado 2025.2: the multiplier alone synthesizes to 715 LUTs,
369 registers, 15 DSPs and nine RAMB18 blocks. Its out-of-context synthesis
setup slack is +1.805 ns at 100 MHz. All six simulation regressions pass,
including five live-noise Board 1 UART captures checked against Python and
decrypted with the matching local secret key.

The complete board top also synthesizes with zero errors and zero critical
warnings, and fits the device. Its synthesis setup slack is -5.506 ns: the worst
path is from `u_vml/u_ml/pixel_idx_reg` to `u_vml/u_ml/accumulator_reg` in the
existing TinyML logic. That board-level timing issue still needs attention
before implementation and physical-board sign-off; the standalone multiplier's
100 MHz synthesis timing passes.
