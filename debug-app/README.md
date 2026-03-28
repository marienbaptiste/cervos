# Cervos Debug — Whisper.cpp STT Tester

Cross-platform debug app for testing the Whisper.cpp STT integration end-to-end,
including the full BLE audio pipeline simulation (LC3 encode/decode).

## Quick start

```bash
cd debug-app
docker compose up --build
```

Open **http://localhost:8090** in any browser.

> First build downloads the `large-v3` model (~3GB) and compiles whisper.cpp
> from source. This takes a while — subsequent builds use Docker cache.

## Architecture

```
Browser (mic / WAV file)
  │
  ▼
Backend (FastAPI, port 8090)
  ├─ Resample to 24kHz mono (firmware rate)
  ├─ LC3 encode → 60-byte frames (matching nRF52840 dongle)
  ├─ BLE packet framing [seq:u16][ts:u32][count:u8][LC3...]
  ├─ LC3 decode (simulates phone-side decoding)
  ├─ Resample to 16kHz mono (whisper input rate)
  │
  ▼
whisper.cpp server (Docker, port 8081)
  ├─ Transcription
  ├─ Tinydiarize speaker turns
  │
  ▼
Results → Browser
```

## Services

| Service | Container | Port | Description |
|---------|-----------|------|-------------|
| whisper-cpp | cervos-whisper-cpp | 8081 | whisper.cpp HTTP server with large-v3 + tinydiarize |
| debug-backend | cervos-debug-backend | 8090 | FastAPI backend + static frontend |

## API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/transcribe` | Full pipeline: audio → LC3 sim → whisper → text |
| `POST` | `/api/simulate-ble` | LC3 pipeline only (no whisper), returns stats + audio |
| `GET` | `/api/health` | Backend + whisper.cpp reachability check |
| `PUT` | `/api/settings` | Update whisper URL at runtime |
| `GET` | `/` | Static frontend |

### POST /api/transcribe

Query parameters:
- `simulate_ble` (bool, default `true`) — run LC3 encode/decode pipeline
- `diarize` (bool, default `true`) — enable tinydiarize speaker turns

Body: `multipart/form-data` with `file` field (WAV, WebM, or raw PCM).

## Using with a remote whisper instance (Tailscale)

1. Run whisper.cpp on a remote machine (e.g., Mac Studio):
   ```bash
   docker compose up whisper-cpp
   ```
2. On the debug machine, point the backend at the remote:
   ```bash
   WHISPER_URL=http://<tailscale-ip>:8081 docker compose up debug-backend
   ```
3. Or change the URL in the browser settings panel at runtime.

## LC3 constants (matching firmware)

These match `firmware/src/lc3_encoder.h` exactly:

| Constant | Value | Source |
|----------|-------|--------|
| Sample rate | 24000 Hz | `LC3_SAMPLE_RATE` |
| Frame duration | 10 ms | `LC3_FRAME_US` |
| Frame samples | 240 | `LC3_FRAME_SAMPLES` |
| Bitrate | 48 kbps | `LC3_BITRATE` |
| Frame bytes | 60 | `LC3_FRAME_BYTES` |

## Switching whisper model

To use a smaller model for faster testing:

```yaml
# docker-compose.yml
whisper-cpp:
  build:
    args:
      MODEL: base.en    # ~150MB, English-only, fast on CPU
```

Available models: `tiny`, `base`, `small`, `medium`, `large-v3`

## File structure

```
debug-app/
├── docker-compose.yml
├── whisper/
│   ├── Dockerfile           # Multi-stage: compile whisper.cpp + download model
│   └── entrypoint.sh        # Finds model, starts server with --tdrz
├── backend/
│   ├── Dockerfile           # Python 3.12 + liblc3 (built from source) + FastAPI
│   ├── requirements.txt
│   ├── app.py               # FastAPI routes
│   ├── audio_utils.py       # WAV loading, resampling
│   └── lc3_pipeline.py      # LC3 encode/decode + BLE packet simulation
└── frontend/
    ├── index.html           # Single-page UI
    ├── style.css            # Cervos dark elevation theme
    └── app.js               # Mic recording, file upload, API calls
```
