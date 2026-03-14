# Firmware Rules (nRF52840 Dongle)

## Notion reference
- **Layer-by-Layer Design** (wearable + meeting sections): `323c6ebc177f813da534f0a211958b8d`
- **Implementation Roadmap** (Phase 6): `323c6ebc177f811db478fe421d1311e5`

## Tech stack
- **Platform**: nRF52840 (Nordic Semiconductor)
- **RTOS**: Zephyr RTOS
- **Language**: C
- **Build**: west (Zephyr meta-tool)
- **Flash format**: UF2 binary (pre-built in GitHub releases)

## Dongle operation modes

### Meeting mode (primary)
The dongle operates as two devices simultaneously:
- **USB side**: USB Audio Class output device (speaker) — work PC sends meeting audio
- **BLE side**: Custom GATT audio service — streams PCM to phone

Audio spec: 16kHz, 16-bit PCM, mono, 20ms frames (640 bytes per frame)

### Dev mode
BLE sniffer for reverse-engineering G2/R1 GATT protocols.

## Source files
```
firmware/src/
├── usb_audio_capture.c   # USB Audio Class speaker endpoint
├── ble_audio_stream.c    # BLE GATT audio streaming to phone
└── ble_sniffer.c         # Dev-mode BLE protocol sniffer
```

## Conventions
- Device name is configurable in firmware ("Meeting Audio", "Conference Speaker", etc.)
- Zero install on work PC — the dongle is just a USB speaker to the OS
- USB mic on work PC stays as Zoom input — dongle only replaces audio OUTPUT
- BLE and USB run simultaneously on the same chip
- Frame timing is critical — 20ms intervals, no jitter

## Key constraint
The work PC is NOT under our control. We cannot install software on it. The dongle must appear as a standard USB audio device with no drivers needed.
