# BLE Protocol Notes

## Even Realities G2

The G2 BLE GATT protocol is implemented directly in the Flutter app via a `GlassesService` abstraction (reverse-engineered from the decompiled official app).

### Key Methods

- `displayText(lines)` — send text lines to the G2 display (~15 chars wide)
- `displayNotification(title, body)` — push notification overlay
- `showConfirmPrompt(message)` — permission confirmation prompt
- `streamCaptions(text)` — live caption streaming (meeting mode)

### Display Constraints

- ~15 characters wide
- Text-forward — all content targeting glasses passes through a text-downgrade formatter

## R1 Ring

Gesture vocabulary mapped to semantic actions via `RingInputMapper`:

| Gesture | Action |
|---------|--------|
| Single tap | Select / confirm |
| Double tap | Confirm (permission prompt) |
| Long press | Cancel / dismiss |
| Swipe forward | Next page / next item |
| Swipe back | Previous |

## nRF52840 Dongle

Dual-purpose device:

- **Development mode**: BLE sniffer for protocol reverse-engineering
- **Meeting mode**: BLE audio bridge — captures room audio, streams PCM frames over USB serial to the Flutter app's `AudioRouter`

Firmware: Zephyr RTOS with 20ms audio frames.
