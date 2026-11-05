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
Centre on the sender MESSAGE screen snapshots and encrypts the current digits.
The busy LED covers encryption and transmission. OK appears after all packets
are acknowledged. After FAIL, Left retries the retained ciphertext, and Centre
encrypts a new snapshot. Edits and extra Send presses during an active operation
leave the in-flight message intact. The source is released after success or
when a new message replaces a failed operation.

Simulation sets `SIM_MULTIPLIER=1` and includes `testbenches/poly_mult_model.sv`.
The FPGA configuration uses `SIM_MULTIPLIER=0` and requires a
`shared_poly_multiplier` module, or an adapter with that name, implementing the
normal-form operand and synchronous result ports shown in `My_Top_Module`.
That hardware module is still a dependency. `ENCRYPT_SEND=0` selects the existing
plaintext send path for the earlier UI/UART demonstrations.

The existing short-plaintext receive display remains available. Ciphertext
fragment reassembly and decryption belong to the Board 2 receive integration.
