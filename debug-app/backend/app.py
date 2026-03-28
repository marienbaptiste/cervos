"""
Cervos Debug — FastAPI backend (streaming STT)

Endpoints:
  WS   /ws/stream          Real-time: PCM chunks in → transcription text out
  POST /api/transcribe      Batch: upload file → transcription (kept for testing)
  GET  /api/health          Health check
  GET  /                    Static frontend
"""

import os
import sys
import time
import json
import asyncio
import logging
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from fastapi import FastAPI, File, UploadFile, Query, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.websockets import WebSocketState

from audio_utils import load_audio, resample, pcm_to_wav_bytes
from lc3_pipeline import lc3_encode_decode_pipeline, ble_packet_hex_sample
from streaming_stt import StreamingSTT

logging.basicConfig(level=logging.INFO, stream=sys.stdout)
logger = logging.getLogger("cervos-debug")

app = FastAPI(title="Cervos Debug — Streaming STT")

STATIC_DIR = Path(__file__).parent / "static"

# Model config from environment
MODEL_SIZE = os.environ.get("WHISPER_MODEL", "large-v3")
DEVICE = os.environ.get("WHISPER_DEVICE", "auto")
COMPUTE_TYPE = os.environ.get("WHISPER_COMPUTE_TYPE", "float16")

# Thread pool for blocking STT calls
_executor = ThreadPoolExecutor(max_workers=2)

# Model instance — loaded at startup
_stt_engine: StreamingSTT | None = None


@app.on_event("startup")
async def startup_load_model():
    """Load model at startup so WebSocket connections don't have to wait."""
    global _stt_engine
    loop = asyncio.get_event_loop()
    logger.info(f"Pre-loading model '{MODEL_SIZE}' on {DEVICE}...")
    _stt_engine = await loop.run_in_executor(
        _executor,
        lambda: StreamingSTT(model_size=MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE),
    )
    logger.info("Model ready")


def get_stt() -> StreamingSTT:
    return _stt_engine


# ── Health ──────────────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    return {
        "backend": "ok",
        "engine": "faster-whisper",
        "model": MODEL_SIZE,
        "device": DEVICE,
        "model_loaded": _stt_engine is not None,
    }


# ── WebSocket streaming STT ────────────────────────────────────────────────

@app.websocket("/ws/stream")
async def ws_stream(ws: WebSocket):
    await ws.accept()
    logger.info("WebSocket connected")

    # Load model in thread to avoid blocking event loop
    loop = asyncio.get_event_loop()
    stt = await loop.run_in_executor(_executor, get_stt)

    if stt is None:
        await ws.send_json({"error": "Model still loading, try again"})
        await ws.close()
        return

    stt.reset()
    simulate_ble = False

    try:
        while True:
            msg = await ws.receive()

            if "text" in msg:
                try:
                    ctrl = json.loads(msg["text"])
                except json.JSONDecodeError:
                    continue

                action = ctrl.get("action", "")
                if action == "flush":
                    result = await loop.run_in_executor(_executor, stt.flush)
                    if result:
                        await ws.send_json(result)
                elif action == "reset":
                    stt.reset()
                    await ws.send_json({"status": "reset"})
                elif action == "config":
                    simulate_ble = ctrl.get("simulate_ble", False)
                    await ws.send_json({"status": "configured", "simulate_ble": simulate_ble})
                continue

            if "bytes" in msg:
                raw = msg["bytes"]
                if len(raw) == 0:
                    continue

                # Detect format: float32 or int16
                if len(raw) % 4 == 0:
                    pcm = np.frombuffer(raw, dtype=np.float32).copy()
                else:
                    pcm = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0

                # Optional BLE pipeline simulation
                if simulate_ble and len(pcm) > 0:
                    pcm_24k = resample(pcm, 16000, 24000)
                    lc3_result = lc3_encode_decode_pipeline(pcm_24k)
                    pcm = resample(lc3_result["decoded_pcm"], 24000, 16000)

                # Feed to STT in thread (transcribe is blocking)
                results = await loop.run_in_executor(_executor, stt.add_audio, pcm)
                for result in results:
                    result["simulate_ble"] = simulate_ble
                    logger.info(f"Transcription: {result['text'][:80]}... ({result['latency_ms']}ms)")
                    if ws.client_state == WebSocketState.CONNECTED:
                        await ws.send_json(result)

    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")
    except RuntimeError as e:
        if "disconnect" in str(e).lower():
            logger.info("WebSocket disconnected (runtime)")
        else:
            logger.error(f"WebSocket error: {e}")
    finally:
        stt.reset()


# ── Batch transcribe (file upload) ─────────────────────────────────────────

@app.post("/api/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    simulate_ble: bool = Query(False),
):
    t_start = time.perf_counter()
    raw_bytes = await file.read()

    pcm, sr = load_audio(raw_bytes, file.filename or "audio.wav")

    pipeline_info = {
        "original_sample_rate": sr,
        "original_duration_s": round(len(pcm) / sr, 3),
        "simulate_ble": simulate_ble,
    }

    if simulate_ble:
        pcm_24k = resample(pcm, sr, 24000)
        lc3_result = lc3_encode_decode_pipeline(pcm_24k)
        pcm_16k = resample(lc3_result["decoded_pcm"], 24000, 16000)
        pipeline_info["compression_ratio"] = round(lc3_result["compression_ratio"], 2)
    else:
        pcm_16k = resample(pcm, sr, 16000)

    loop = asyncio.get_event_loop()
    stt = await loop.run_in_executor(_executor, get_stt)
    if stt is None:
        return JSONResponse(status_code=503, content={"error": "Model loading"})

    t_stt = time.perf_counter()

    def do_transcribe():
        segments_iter, info = stt.model.transcribe(pcm_16k, beam_size=1, vad_filter=True)
        segs = []
        texts = []
        for seg in segments_iter:
            segs.append({"start": round(seg.start, 2), "end": round(seg.end, 2), "text": seg.text.strip()})
            texts.append(seg.text.strip())
        return segs, texts, info

    segs, texts, info = await loop.run_in_executor(_executor, do_transcribe)

    pipeline_info.update({
        "language": info.language,
        "stt_ms": round((time.perf_counter() - t_stt) * 1000),
        "total_ms": round((time.perf_counter() - t_start) * 1000),
    })

    return {"text": " ".join(texts), "segments": segs, "pipeline_info": pipeline_info}


# ── Static frontend ────────────────────────────────────────────────────────

if STATIC_DIR.exists():
    app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")
