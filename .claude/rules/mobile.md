# Mobile App Rules (Flutter)

## Notion reference
- **Layer-by-Layer Design** (mobile section): `323c6ebc177f813da534f0a211958b8d`
- **Voice Commands & Device Tools**: `323c6ebc177f81a58a48d4b16c629443`
- **Permission & Security Model**: `323c6ebc177f81b8a55afa5378182fa3`
- **Observability & Journal Security**: `323c6ebc177f8104b936d82ab3769a63`

## Tech stack
- **Language**: Dart (Flutter)
- **State management**: Riverpod
- **BLE GATT**: `flutter_reactive_ble` (config characteristics: capture, name, power mode)
- **BLE L2CAP**: Native Android plugin (`L2capAudioPlugin`) for CoC audio streaming
- **LC3 decoder**: Android NDK via platform channel (`Lc3DecoderPlugin`, google/liblc3)
- **Audio output**: Oboe/AAudio via `flutter_pcm_sound` (48kHz stereo)
- **Database**: SQLCipher (AES-256-CBC, 256K PBKDF2 iterations)
- **Key storage**: Android Keystore (hardware TEE / StrongBox)
- **Biometrics**: `local_auth` package
- **On-device AI**: Gemini Nano via Android AICore API
- **HTTP**: mTLS client certificates over Tailscale

## Directory structure
```
mobile/lib/
├── ble/           # GlassesService, RingInputMapper, BLE manager
├── audio/         # AudioRouter (meeting mode, voice commands, TTS)
├── mcp_server/    # Dart isolate MCP server (device tools)
├── ui/            # UIRenderer, adaptive UI shell, design system widgets
├── nano/          # Gemini Nano integration, intent classifier
├── journal/       # Action journal, SQLCipher, biometric gating
└── core/          # Config, Tailscale, HTTP client, models
```

## Audio architecture
- Dongle streams LC3 over BLE L2CAP CoC (not GATT notifications)
- Packet format: `[seq_num:u16][timestamp:u32][frame_count:u8][LC3 frames...]`
- Duplicate-frame resilience: packets carry current + previous frame; receiver deduplicates by seq_num
- LC3 decode happens in NDK (C via JNI), exposed to Dart via platform channel
- Decoded 48kHz stereo PCM plays through Oboe/AAudio to BLE earbuds
- Same decoded PCM forwarded to Mac Studio via Tailscale for STT

## Power modes
Three modes configurable from Settings, written to dongle via `0xCF02` GATT characteristic:
- **Battery Saver**: 30ms CI, 50ms buffer, ~80ms latency, ~25mW
- **Balanced** (default): 15ms CI, 30ms buffer, ~55ms latency, ~35mW
- **Low Latency**: 7.5ms CI, 10ms buffer, ~35ms latency, ~50mW

## Conventions
- The Flutter app is a **thin gateway** — it does NOT make AI decisions, only routes
- BLE manager handles 4 simultaneous connections: G2, R1, earbuds, dongle
- Audio streams are always tagged with source metadata (`channel: "you"` / `"remote"`)
- Journal writes NEVER block on biometrics — use write-ahead buffer
- Permission enforcement happens in the MCP server, not in OpenClaw
- All device tools follow the naming pattern `device.<category>.<action>`

## Permission tiers
- **Always allowed** (green): clock, weather, battery, clipboard read, notifications list, sensors
- **Confirm on glasses** (amber): camera, location, reply, screen capture
- **Require unlock** (red): payments, delete data, send to unfamiliar contacts, social posts

## Security
- No API keys in Dart code — loaded from config at runtime
- Journal encryption: Android Keystore → AES-256 master key → DEK → SQLCipher
- 5-min biometric timeout, 5 failed attempts → backoff, 15 → device PIN required
- Sync uses ephemeral X25519 + XChaCha20-Poly1305 (libsodium) on top of Tailscale
