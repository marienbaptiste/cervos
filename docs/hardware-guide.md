# Hardware Guide

## Bill of Materials

| Component | Role | Connection |
|-----------|------|------------|
| Even Realities G2 | Display (text/simple UI) + microphone | BLE to phone |
| R1 ring | Gesture input (tap, swipe, hold) + haptic feedback | BLE to phone |
| Samsung Galaxy S26 Ultra | Mobile gateway, on-device SLM, camera, GPS, audio | BLE + Tailscale |
| Mac Studio (M-series, 96GB+) | AI server: STT, local LLMs, orchestration, persistence | Tailscale mesh |
| nRF52840 dongle | BLE audio bridge for meetings, protocol dev sniffer | USB-C OTG to phone |
| BLE earbuds | Audio return channel (TTS output, meeting audio) | BLE to phone |

## Memory Budget (Mac Studio)

| Component | Memory |
|-----------|--------|
| macOS + system | ~8 GB |
| Qwen 2.5 32B Q4 | ~20 GB |
| Llama 3.1 8B Q4 | ~5 GB |
| Whisper Large-v3 | ~3 GB |
| pyannote + distil-whisper | ~3 GB |
| Docker services | ~4 GB |
| **Total baseline** | **~43 GB** |

**96 GB recommended** — leaves 53 GB free for KV cache, concurrent requests, and hot-loading larger models.
