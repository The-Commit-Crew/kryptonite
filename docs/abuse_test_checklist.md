# Robustness Abuse-Test Checklist

| Action | Expected result | Pass/Fail | Notes |
|---|---|---|---|
| Send with no receiver; connect receiver; retry | Initial attempt fails cleanly; retry succeeds after connection |  |  |
| Unplug the link mid-send | Retries finish and the UI returns to a usable state |  |  |
| Reset either board mid-send | Both boards recover to their startup state without a stuck busy condition |  |  |
| Reset either board mid-decrypt | Receiver returns to a usable RX state without stale decrypt output |  |  |
| Mash all buttons on every screen | No illegal transition, lock-up, or unintended repeated action |  |  |
| Flip sw4 mid-transfer | Transfer behavior remains deterministic; no stuck link state |  |  |
| Flip sw6 mid-transfer | Normal/test mode remains deterministic; no stuck link state |  |  |
| Board type change (expect return to the first screen) | Changing the board type resets only the UI controller and returns the UI to its first screen; link/decrypt operations are not promised to abort |  |  |
| Flip sw3 mid-transfer | Display remains usable; transfer/decrypt state is unaffected |  |  |
| Power-cycle a board | A board with the bitstream programmed in flash restarts into the design; a volatile-only configuration loses the design and must be reprogrammed |  |  |
| Send 20 messages in a row | Every accepted message completes or fails cleanly; no stale state accumulates |  |  |
| Repeated btnU corruption | Each requested corruption is handled by the existing retry behavior |  |  |
| Configure both boards as SENDER, attempt send, then press BACK | Send fails cleanly after retries; BACK recovers to a usable screen |  |  |
| Hold btnL during a send | After about 1 s the startup/menu screen is requested; the send may continue and must complete or fail without a stuck link |  |  |
| Hold btnL during a reveal | After about 1 s the startup/menu screen is requested; the reveal may continue and the UI must remain recoverable |  |  |
| Press sw15 reset on every screen | The design resets to its startup/menu state and clears transient UI, link, and decrypt state |  |  |
| Repeated Enter on keyboard-board sender | Only the accepted idle send starts; repeated Enter while sending does not create duplicate sends |  |  |
| Repeated Enter on a LISTEN receiver | Enter only performs the receiver action when a ciphertext is shown; repeated presses while busy do not start duplicate decrypts |  |  |
| New ciphertext arrives mid-reveal | The new ciphertext replaces the displayed receive result and starts the normal check/decrypt path without a stuck reveal state |  |  |
| Self test end to end, including CLR and BACK on RX | The message loops back, decrypt/reveal completes, CLR clears the RX result, and BACK returns to the preceding screen |  |  |

## Finding notes

- Verified behavior: `uart_link` ACKs every good data packet without checking board role, and the receive path remains active on a SENDER board; therefore two SENDER boards can deliver a one-way packet.
- Verified behavior: the sender MSG toolbar has SEND, CLR, and DRAW/RX/PLAIN; it has no BACK button.
- Verified behavior: after ciphertext assembly and checking, decrypt starts automatically. `rx_decrypt.v` documents about 34,000 clocks (0.34 ms); the button controls the displayed reveal, not decrypt start.
- Hardware caveat: a power cycle preserves the design only when the bitstream is programmed in nonvolatile flash; RTL cannot make a volatile-only FPGA configuration survive power loss.
- Finding 5: screen can change mid-operation, the operation still completes.
