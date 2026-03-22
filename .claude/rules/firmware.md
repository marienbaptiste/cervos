# Firmware Rules (nRF52840 Dongle)

## Notion reference
- **Layer-by-Layer Design** (wearable + meeting sections): `323c6ebc177f813da534f0a211958b8d`
- **Implementation Roadmap** (Phase 6): `323c6ebc177f811db478fe421d1311e5`

## Tech stack
- **Platform**: nRF52840 (Nordic Semiconductor)
- **RTOS**: Zephyr RTOS
- **Language**: C
- **Build**: west (Zephyr meta-tool)
- **Codec**: LC3 (google/liblc3, fixed-point, ARM Cortex-M4F DSP intrinsics)
- **Flash format**: UF2 binary (pre-built in GitHub releases)

## Dongle operation modes

### Meeting mode (primary)
The dongle operates as two devices simultaneously:
- **USB side**: USB Audio Class output device (speaker) at 48kHz / 16-bit stereo
- **BLE side**: LC3 codec over BLE L2CAP CoC (2M PHY) — streams compressed audio to phone

Audio spec:
- USB input: 48kHz, 16-bit, stereo (from work PC)
- LC3 encode: 48kHz stereo, 10ms frames, ~160kbps (~80kbps per channel)
- BLE transport: L2CAP Connection-Oriented Channels with 2M PHY

### Dev mode
BLE sniffer for reverse-engineering G2/R1 GATT protocols.

## Source files
```
firmware/src/
├── main.c               # Main loop: USB → LC3 encode → BLE L2CAP
├── audio_buffer.c/h     # Ring buffer: 48kHz stereo, 10ms frames (960 samples)
├── usb_audio_capture.c  # USB Audio Class speaker endpoint (48kHz stereo passthrough)
├── lc3_encoder.c/h      # LC3 encoder wrapper (stereo + mono fallback)
├── ble_l2cap_stream.c   # L2CAP CoC transport, GATT config service, RSSI monitor
└── ble_sniffer.c        # Dev-mode BLE protocol sniffer
```

## Packet format
Each BLE L2CAP packet: `[seq_num: u16][timestamp: u32][frame_count: u8][LC3 frames...]`
- Duplicate-frame resilience: each packet carries current + previous frame
- Sequence number enables reordering and PLC triggering on receiver

## Resilience
- **Duplicate frames**: current + previous frame in each packet (~320kbps within 2M PHY budget)
- **LC3 built-in PLC**: conceals 1-2 consecutive lost frames
- **Adaptive bitrate**: RSSI monitoring with hysteresis; falls back to mono under poor conditions

## Power modes
Three phone power modes, selectable from Flutter Settings, stored in NVS:
- **Battery Saver**: 30ms CI, 50ms buffer, ~80ms latency
- **Balanced** (default): 15ms CI, 30ms buffer, ~55ms latency
- **Low Latency**: 7.5ms CI, 10ms buffer, ~35ms latency

## GATT config service (0xCE57:0001)
- `0xCE57:0003` — Capture control (read/write): 0x00=off, 0x01=on
- `0xCE57:CF01` — Dongle name (read/write): max 32 chars, NVS-persisted, triggers soft-reset
- `0xCE57:CF02` — Power mode (read/write): 0/1/2, NVS-persisted, applies CI immediately

## Conventions
- Default device name: `"Cervos Meeting Bridge"` (configurable via Flutter app)
- Zero install on work PC — the dongle is just a USB speaker to the OS
- USB mic on work PC stays as Zoom input — dongle only replaces audio OUTPUT
- BLE and USB run simultaneously on the same chip
- LC3 encode must complete 10ms stereo frame in <7ms CPU budget
- Settings subsystem (NVS) persists name and power mode across reboots

## Key constraint
The work PC is NOT under our control. We cannot install software on it. The dongle must appear as a standard USB audio device with no drivers needed.

## Dependencies
- `firmware/lib/liblc3/` — clone google/liblc3 here (not committed, added to .gitignore)
