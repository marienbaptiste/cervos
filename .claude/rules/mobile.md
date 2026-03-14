# Mobile App Rules (Flutter)

## Notion reference
- **Layer-by-Layer Design** (mobile section): `323c6ebc177f813da534f0a211958b8d`
- **Voice Commands & Device Tools**: `323c6ebc177f81a58a48d4b16c629443`
- **Permission & Security Model**: `323c6ebc177f81b8a55afa5378182fa3`
- **Observability & Journal Security**: `323c6ebc177f8104b936d82ab3769a63`

## Tech stack
- **Language**: Dart (Flutter)
- **State management**: Riverpod or Bloc (decide during Phase 2)
- **BLE**: `flutter_reactive_ble`
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
