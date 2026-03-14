# Architecture

> See the full architecture specification in the project's Notion workspace:
> **Ambient AI Assistant — Architecture & Implementation Plan**

## Overview

Cervos is a privacy-first, open-source ambient AI assistant spanning:
- **Wearable layer**: Even Realities G2 glasses, R1 ring, nRF52840 dongle, BLE earbuds
- **Mobile gateway**: Flutter app on Samsung Galaxy S26 Ultra
- **Secure transport**: nginx with mTLS over Tailscale mesh
- **Orchestration**: OpenClaw (Docker) with MCP tool registry
- **Persistence**: SQLite, Chroma (RAG), append-only audit log
- **Observability**: Action journal (Flutter) + server console

## Model Cascade (3-tier)

| Tier | Engine | Location | Latency |
|------|--------|----------|---------|
| 0 | Gemini Nano | S26 Ultra | <50ms |
| 1 | Qwen 2.5 32B / Llama 3.1 8B | Mac Studio | <300ms |
| 2a | GPT-4o | Cloud (OpenAI) | <1500ms |
| 2b | Claude | Cloud (Anthropic) | <2000ms |
