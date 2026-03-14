# Server Rules (Mac Studio)

## Notion reference
- **Layer-by-Layer Design** (server sections): `323c6ebc177f813da534f0a211958b8d`
- **Local Model Stack & Memory Budget**: `323c6ebc177f81ae9806c1882dbcb194`
- **Repo Structure**: `323c6ebc177f81ff8ae0e19b651a609c`

## Architecture: native vs Docker

### Native on macOS (bare-metal) — for GPU/Metal access
- **mlx-lm** (port 8080): Qwen 2.5 32B Q4, Llama 3.1 8B Q4 — OpenAI-compatible API
- **lightning-whisper-mlx** (port 8081): Whisper large-v3, distil-medium.en
- **pyannote** (port 8082): Speaker diarization, PyTorch CPU
- **Ollama** (port 11434): Fallback for non-MLX models
- **meeting_stt.py** (port 8083): Dual-stream meeting STT + diarization

### Docker (OrbStack/Colima)
- **nginx** (port 443): mTLS reverse proxy + rate limiting + kill switch
- **OpenClaw** (port 8000): Agent orchestrator + MCP tool registry
- **SearXNG** (port 8888): Local web search
- **Chroma** (port 8500): Vector database for RAG
- **Console** (port 9090): Observability web app

## Tech stack
- **Orchestrator**: OpenClaw (Docker)
- **Database**: SQLite (conversations, prefs, devices, permissions, templates)
- **Vector DB**: Chroma (RAG, long-term memory)
- **Audit log**: JSON Lines, append-only, HMAC-SHA256 signed, Ed25519 archive signing
- **Search**: SearXNG (self-hosted)
- **Reverse proxy**: nginx with mTLS
- **Container runtime**: OrbStack or Colima (NOT Docker Desktop)

## Cloud routing
- **Default cloud**: OpenAI (GPT-4o via ChatGPT CLI)
- **Specialist**: Anthropic (Claude) for coding, architecture, long-context (100K+)
- Routing rules defined in `server/openclaw/routing.yaml`

## Conventions
- OpenClaw can append to the audit log but CANNOT read, modify, or delete it
- Kill switch at `/var/run/cloud-enabled` — when absent, all cloud API requests blocked
- nginx rate limit: 100 req/min per client
- All model backends expose OpenAI-compatible API — model selection via request parameter
- SQLite migrations in `server/persistence/migrations/` — numbered sequentially

## Meeting STT (`server/meeting_stt.py`)
- Receives two tagged audio streams from the phone via Tailscale
- "Remote" channel (dongle): runs Whisper STT + pyannote diarization
- "You" channel (G2 mic): runs Whisper STT only (single speaker)
- Merges and pushes labeled captions back to phone → glasses

## Security
- No secrets in Docker images or committed config
- nginx mTLS: only registered Flutter app client cert accepted
- Audit log: `root:audit` ownership, mode 0640, HMAC per entry
- Daily log rotation with Ed25519 archive signing
