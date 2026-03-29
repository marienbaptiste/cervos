# Cervos Voice Service + Debug Frontend

Real-time streaming STT with speaker diarization and persistent voice profiles.

## Architecture

```
Browser mic (debug frontend)
  │  WebSocket (16kHz float32 PCM)
  ▼
cervos-voice-service (Docker, CUDA GPU)
  ├── faster-whisper: transcription (GPU, large-v3)
  ├── pyannote: diarization + speaker embeddings (CPU)
  ├── Speaker store: Chroma DB for persistent voice profiles
  │   ├── Known speaker (similarity > 0.35) → reuse UUID
  │   └── Unknown speaker → create new profile
  └── Returns: named transcript with persistent speaker IDs
```

## Quick start

```bash
# 1. Set your HuggingFace token (for pyannote models)
echo "HF_TOKEN=hf_your_token_here" > .env

# 2. Build and run
docker compose up --build

# 3. Open debug frontend
open http://localhost:8090
```

First start downloads models (~4GB total). Cached in Docker volumes after that.

## Prerequisites

- Docker with NVIDIA GPU support (nvidia-container-toolkit)
- HuggingFace account with access to:
  - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
  - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
  - [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)

## Interface

### WebSocket — `/ws/stream` (real-time)

```
Client → Server: binary frames (16kHz float32 PCM)
Client → Server: {"action": "flush"}     force-transcribe buffer
Client → Server: {"action": "reset"}     clear state
Client → Server: {"action": "config", "simulate_ble": true/false}

Server → Client: {
  "text": "[Baptiste] Hello...",
  "segments": [{"speaker_id": "spk_a1b2c3d4", "speaker_name": "Baptiste", ...}],
  "language": "fr",
  "latency_ms": 1050,
  "transcribe_ms": 400,
  "diarize_ms": 650
}
```

### REST — speaker management

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/speakers` | List all speaker profiles |
| `PUT` | `/api/speakers/{id}` | Name a speaker: `{"name": "Alice"}` |
| `DELETE` | `/api/speakers/{id}` | Delete a speaker profile |
| `POST` | `/api/transcribe` | Batch file upload (fallback) |
| `GET` | `/api/health` | Service status |

## Speaker identification flow

1. **During meeting**: pyannote diarizes + extracts voice embeddings per speaker
2. **Match against Chroma**: cosine similarity → reuse existing UUID or create new
3. **Persistent IDs**: same voice = same `spk_xxxxxxxx` across sessions
4. **Naming**: click speaker label in UI → type name → stored in Chroma
5. **At summarization**: OpenClaw gets transcript with named speaker IDs + profile DB

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HF_TOKEN` | (required) | HuggingFace token for pyannote models |
| `WHISPER_MODEL` | `large-v3` | faster-whisper model size |
| `WHISPER_DEVICE` | `auto` | `auto`, `cuda`, or `cpu` |
| `WHISPER_COMPUTE_TYPE` | `float16` | `float16`, `int8`, or `float32` |

## Docker volumes

| Volume | Purpose |
|--------|---------|
| `cervos_model-cache` | HuggingFace model weights (persists across rebuilds) |
| `cervos_speaker-data` | Chroma speaker profiles (voice fingerprints) |

## File structure

```
debug-app/
├── docker-compose.yml          # cervos-voice-service (single GPU container)
├── .env                        # HF_TOKEN (gitignored)
├── backend/
│   ├── Dockerfile              # CUDA + faster-whisper + pyannote + chromadb
│   ├── requirements.txt
│   ├── app.py                  # FastAPI + WebSocket streaming
│   ├── streaming_stt.py        # faster-whisper + pyannote + speaker ID
│   ├── speaker_store.py        # Chroma-backed persistent voice profiles
│   ├── lc3_pipeline.py         # LC3 BLE simulation (optional)
│   └── audio_utils.py          # WAV loading, resampling
└── frontend/
    ├── index.html              # Debug UI
    ├── style.css               # Cervos dark elevation theme
    └── app.js                  # WebSocket streaming + speaker management
```
