# Model Stack Rules

## Notion reference
- **Local Model Stack & Memory Budget**: `323c6ebc177f81ae9806c1882dbcb194`
- **Voice Commands & Device Tools**: `323c6ebc177f81a58a48d4b16c629443`

## 3-tier model cascade

| Tier | Engine | Location | Latency target | Use cases |
|------|--------|----------|---------------|-----------|
| 0 | Gemini Nano | S26 Ultra (AICore) | <50ms | Intent classification, quick replies, offline fallback |
| 1a | Llama 3.1 8B Q4 | Mac Studio (mlx-lm) | <300ms | Simple escalations, fast lane |
| 1b | Qwen 2.5 32B Q4 | Mac Studio (mlx-lm) | <800ms | Summarization, code, RAG |
| 2a | GPT-4o | Cloud (OpenAI) | <1500ms | General cloud escalation, vision |
| 2b | Claude | Cloud (Anthropic) | <2500ms | Complex coding, architecture, long-context |

## Model serving (Mac Studio, native)
- **mlx-lm** (port 8080): Primary — best tok/s on Apple Silicon, OpenAI-compatible API, native MLX format. Both Qwen 32B and Llama 8B served from same endpoint (model param in request).
- **lightning-whisper-mlx** (port 8081): STT — ~10x faster than whisper.cpp on Apple Silicon. `large-v3` for multilingual (FR/EN/DE), `distil-medium.en` for meeting captions.
- **pyannote** (port 8082): Speaker diarization — PyTorch CPU (keeps GPU free for LLM).
- **Ollama** (port 11434): Fallback for models not yet in MLX format.

## Cloud routing rules
- **Default cloud provider**: OpenAI (GPT-4o via ChatGPT CLI / Pro subscription)
- **Auto-route to Claude** when:
  - Task type is coding, architecture, or system design
  - Multi-file code generation
  - Input tokens exceed 100K
- Routing config: `server/openclaw/routing.yaml`

## Memory budget (96 GB recommended)
- macOS + system: ~8 GB
- Qwen 32B Q4: ~20 GB
- Llama 8B Q4: ~5 GB
- Whisper large-v3: ~3 GB
- pyannote + distil-whisper: ~3 GB
- Docker services: ~4 GB
- **Total baseline: ~43 GB** → 53 GB free for KV cache and hot-loading

## Conventions
- 70-80% of requests should be handled at tier 0 or 1 (no cloud round-trip)
- Nano handles ALL intent classification — every utterance goes through Nano first
- Cloud kill switch at `/var/run/cloud-enabled` — when disabled, system runs local-only
- Model badge colors: green (on-device), amber (local), blue (cloud)
- Every request logged with: model_id, tier, latency_ms, cost_usd
