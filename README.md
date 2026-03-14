<p align="center">
  <h1 align="center">Cervos</h1>
  <p align="center">
    A privacy-first, open-source ambient AI assistant spanning wearable glasses, a mobile gateway, and a local AI server.
    <br />
    <em>Low latency. Resilient. Adaptive. Fully observable.</em>
  </p>
</p>

<p align="center">
  <a href="docs/setup-guide.md">Setup Guide</a> &middot;
  <a href="docs/architecture.md">Architecture</a> &middot;
  <a href="docs/hardware-guide.md">Hardware</a> &middot;
  <a href="docs/contributing.md">Contributing</a>
</p>

---

## What is Cervos?

Cervos turns a pair of smart glasses, a ring, a phone, and a home server into a seamless ambient AI assistant. Most processing happens locally — data only leaves your network when you explicitly need frontier model capabilities, and even then it travels over an encrypted Tailscale mesh.

**70–80% of requests never touch the cloud.**

```
  Wearable (G2 glasses + R1 ring + earbuds)
      ↕ BLE
  Phone (Flutter on S26 Ultra · Gemini Nano)
      ↕ Tailscale (WireGuard)
  Mac Studio (mlx-lm · Whisper · OpenClaw)
      ↕ Cloud (only when needed)
  GPT-4o / Claude
```

## Principles

| # | Principle | What it means |
|---|-----------|--------------|
| 1 | **Privacy first** | Voice, intent classification, and most inference run locally. No telemetry. No cloud dependency for core function. |
| 2 | **Low latency** | Common interactions complete in <500ms via a 3-tier model cascade. |
| 3 | **Resilience** | Every component has a fallback. Mac Studio down? Nano handles it. Cloud down? Local models take over. |
| 4 | **Adaptive UI** | Generates the best interface per response — text on glasses, rich cards on phone, or both. |
| 5 | **Extensibility** | New tools, models, and devices plug in via MCP without rewiring the core. |
| 6 | **Full observability** | Every request logged: which model, latency, cost, tools invoked. |

## Hardware

| Component | Role | Connection |
|-----------|------|------------|
| Even Realities G2 | Display (~15 chars) + microphone | BLE to phone |
| R1 ring | Gesture input (tap, swipe, hold) + haptic | BLE to phone |
| Samsung Galaxy S26 Ultra | Mobile gateway, on-device SLM, camera, GPS | BLE + Tailscale |
| Mac Studio (M-series, 96GB+) | AI server: STT, LLMs, orchestration, persistence | Tailscale mesh |
| nRF52840 dongle | Meeting audio capture (USB audio → BLE) | USB to work PC, BLE to phone |
| BLE earbuds | Audio return (TTS, meeting audio) | BLE to phone |

## Model Cascade

| Tier | Engine | Location | Latency | Use cases |
|------|--------|----------|---------|-----------|
| 0 | Gemini Nano | S26 Ultra | <50ms | Intent classification, quick replies, offline |
| 1 | Qwen 2.5 32B / Llama 3.1 8B | Mac Studio (mlx-lm) | <300ms | Summarization, code, RAG |
| 2a | GPT-4o | Cloud (OpenAI) | <1500ms | General escalation, vision |
| 2b | Claude | Cloud (Anthropic) | <2500ms | Complex coding, architecture, long-context |

## Meeting Capture

The nRF52840 dongle plugs into your work PC as a USB speaker — zero software install. Meeting audio flows through the dongle over BLE to your phone, which plays it through earbuds (you hear the meeting) and forwards it to the Mac Studio for STT + speaker diarization. Your G2 glasses mic captures your voice as a separate channel. Live captions with speaker labels appear on your glasses in real-time.

## Getting Started

### Prerequisites

- Mac Studio (Apple Silicon, 96GB+)
- Samsung Galaxy S26 Ultra (Android 15+)
- Even Realities G2 + R1 ring
- Tailscale account (free tier)
- API keys: OpenAI and/or Anthropic

### Quick Start

```bash
git clone https://github.com/yourname/cervos.git
cd cervos
cp config.example.yaml config.yaml
# Fill in Tailscale auth key + API keys

./scripts/setup.sh
```

The setup script installs native inference (mlx-lm, Whisper, Ollama), starts Docker services (nginx, OpenClaw, SearXNG, Chroma, console), joins your Tailnet, generates mTLS certificates, and runs a self-test. See the full [Setup Guide](docs/setup-guide.md).

## Project Structure

```
cervos/
├── config.example.yaml            # Configuration template (no secrets)
├── docs/                          # Architecture, setup, hardware, protocol notes
├── design-system/                 # Dark UI tokens, component library, icons
│   ├── tokens.yaml                # Elevation palette, colors, typography, spacing
│   └── components.yaml            # 13 UI primitives (Card, Badge, CaptionStream, etc.)
├── mobile/                        # Flutter app — thin gateway
│   └── lib/
│       ├── ble/                   # GlassesService, RingInputMapper, BLE manager
│       ├── audio/                 # AudioRouter (meeting mode, voice, TTS)
│       ├── mcp_server/            # Device tools (camera, location, contacts, etc.)
│       ├── ui/                    # Adaptive UI renderer + design system widgets
│       ├── nano/                  # Gemini Nano integration, intent classifier
│       ├── journal/               # Action journal (SQLCipher + biometric gating)
│       └── core/                  # Config, Tailscale, HTTP, models
├── server/                        # Mac Studio
│   ├── docker-compose.yml         # nginx, OpenClaw, SearXNG, Chroma, console
│   ├── nginx/                     # mTLS reverse proxy + rate limiting + kill switch
│   ├── openclaw/                  # Agent orchestrator + cloud routing rules
│   ├── meeting_stt.py             # Dual-stream meeting STT + diarization
│   ├── models/                    # mlx, ollama, stt model storage
│   ├── search/searxng/            # Local web search
│   └── persistence/               # SQLite migrations, Chroma vector DB
├── console/                       # Observability web app (latency, cost, health)
├── firmware/                      # nRF52840 Zephyr RTOS
│   └── src/                       # USB audio capture, BLE streaming, BLE sniffer
├── scripts/                       # setup, certs, tailscale, e2e tests
└── .github/workflows/             # CI (lint, validate, build checks)
```

## Security

- All traffic encrypted end-to-end via Tailscale (WireGuard). No ports exposed to the public internet.
- nginx enforces mTLS — only the registered Flutter app client certificate is accepted.
- Journal encrypted with SQLCipher (AES-256-CBC), key bound to Android hardware TEE.
- Audit log is append-only, HMAC-signed, outside the agent's control.
- Cloud kill switch: disable all cloud API calls instantly.
- Three-tier permission system: always allowed / confirm on glasses / require phone unlock.

## Day-to-Day

- **Morning:** Glasses show briefing at 7:00 AM — calendar, priority emails, weather.
- **Commute:** "Navigate to Zurich HB" — turn-by-turn text on glasses, map on phone.
- **Meeting:** Dongle captures audio, live captions on glasses with speaker labels.
- **Coding:** "Help me debug the BLE reconnection logic" — Claude, context-aware.
- **Evening:** "What is this?" at a spice jar — Nano recognizes locally, instant answer.

## Contributing

See [CONTRIBUTING](docs/contributing.md). All UI changes must pass `design-lint` validation.

## License

See [LICENSE](LICENSE).
