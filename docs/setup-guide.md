# Setup Guide

## Prerequisites

- Mac Studio (Apple Silicon, 96GB+) — powered on, macOS up to date
- Samsung Galaxy S26 Ultra (Android 15+)
- Even Realities G2 glasses — charged, pairing mode
- R1 ring — charged, pairing mode
- Tailscale account (free tier)
- API keys: OpenAI and/or Anthropic

## Step 1 — Clone and configure (~5 min)

```bash
git clone https://github.com/yourname/cervos.git
cd cervos
cp config.example.yaml config.yaml
nano config.yaml   # fill in Tailscale auth key + API keys
```

## Step 2 — Run server setup (~10 min)

```bash
./scripts/setup.sh
```

This script:
1. Installs mlx-lm, lightning-whisper-mlx, Ollama via Homebrew/pip
2. Starts Docker services (nginx, OpenClaw, SearXNG, Chroma, console)
3. Joins your Tailnet
4. Generates mTLS certs, displays QR code for phone pairing
5. Pulls default models (Qwen 2.5 32B Q4, Llama 3.1 8B Q4, Whisper large-v3)
6. Runs self-test (all services reachable, inference works)

## Step 3 — Install and pair the phone (~10 min)

Install Flutter app from source or GitHub Releases APK.

Onboarding wizard:
1. Welcome screen
2. Scan QR code → auto-configures Tailscale + mTLS + server endpoint
3. Pair G2 glasses, R1 ring, earbuds via BLE
4. Set up journal biometrics (fingerprint enrollment, SQLCipher init)
5. Ready screen: `Ambient AI ready` on glasses

## Step 4 — First message (~1 min)

Tap the ring. Say: "What's the weather today?"
