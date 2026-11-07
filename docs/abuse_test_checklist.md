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
| Flip sw13 mid-transfer | Role change does not create an unsafe or stuck UI state |  |  |
| Flip sw3 mid-transfer | Display remains usable; transfer/decrypt state is unaffected |  |  |
| Power-cycle a board | Board restarts cleanly and can send or receive again |  |  |
| Send 20 messages in a row | Every accepted message completes or fails cleanly; no stale state accumulates |  |  |
| Repeated btnU corruption | Each requested corruption is handled by the existing retry behavior |  |  |
| Configure both boards as SENDER, attempt send, then press BACK | Send fails cleanly after retries; BACK recovers to a usable screen |  |  |

## Finding notes

- Finding 5: `ui_ctrl` allows `p_next` to leave `S_MSG` or `S_RX` without checking transfer/decrypt busy state. This can change the displayed screen while an operation is still active; it was not changed in this robustness pass.
