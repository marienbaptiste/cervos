"""
Cervos Debug — FastAPI backend

Routes:
  POST /api/transcribe      Full pipeline: audio → LC3 sim → whisper → text
  POST /api/simulate-ble    LC3 pipeline only, returns stats + audio comparison
  GET  /api/health           Backend + whisper.cpp health
  PUT  /api/settings         Update whisper URL at runtime
  GET  /                     Serves static frontend
"""

import os
import time
import base64
from pathlib import Path

import httpx
import numpy as np
from fastapi import FastAPI, File, UploadFile, Query
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from audio_utils import load_audio, resample, pcm_to_wav_bytes
from lc3_pipeline import lc3_encode_decode_pipeline, ble_packet_hex_sample

app = FastAPI(title="Cervos Debug — Whisper STT")

# Runtime settings (WHISPER_URL from env, fallback to docker-compose service name)
settings = {
    "whisper_url": os.environ.get("WHISPER_URL", "http://whisper-cpp:8080"),
}

STATIC_DIR = Path(__file__).parent / "static"


# ── Health ──────────────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    whisper_ok = False
    whisper_err = None
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(f"{settings['whisper_url']}/health")
            whisper_ok = r.status_code == 200
    except Exception as e:
        whisper_err = str(e)

    return {
        "backend": "ok",
        "whisper_url": settings["whisper_url"],
        "whisper_reachable": whisper_ok,
        "whisper_error": whisper_err,
    }


# ── Settings ────────────────────────────────────────────────────────────────

@app.put("/api/settings")
async def update_settings(body: dict):
    if "whisper_url" in body:
        settings["whisper_url"] = body["whisper_url"].rstrip("/")
    return {"settings": settings}


# ── Transcribe ──────────────────────────────────────────────────────────────

@app.post("/api/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    simulate_ble: bool = Query(True),
    diarize: bool = Query(True),
):
    t_start = time.perf_counter()
    raw_bytes = await file.read()

    # Load and normalize to float32 mono
    pcm, sr = load_audio(raw_bytes, file.filename or "audio.wav")

    pipeline_info = {
        "original_sample_rate": sr,
        "original_duration_s": round(len(pcm) / sr, 3),
        "original_samples": len(pcm),
        "simulate_ble": simulate_ble,
    }

    if simulate_ble:
        # Resample to 24kHz (firmware rate) → LC3 encode/decode → back to PCM
        pcm_24k = resample(pcm, sr, 24000)
        lc3_result = lc3_encode_decode_pipeline(pcm_24k)
        decoded_pcm = lc3_result["decoded_pcm"]

        pipeline_info.update({
            "lc3_frames_encoded": lc3_result["frame_count"],
            "lc3_frame_bytes": 60,
            "total_lc3_bytes": lc3_result["total_encoded_bytes"],
            "compression_ratio": round(lc3_result["compression_ratio"], 2),
            "ble_packets_simulated": lc3_result["frame_count"],
        })

        # Resample decoded 24kHz → 16kHz for whisper
        pcm_16k = resample(decoded_pcm, 24000, 16000)
    else:
        # Direct resample to 16kHz
        pcm_16k = resample(pcm, sr, 16000)

    # Convert to 16-bit WAV for whisper.cpp /inference endpoint
    wav_bytes = pcm_to_wav_bytes(pcm_16k, 16000)

    # Send to whisper.cpp
    t_whisper_start = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            files_payload = {"file": ("audio.wav", wav_bytes, "audio/wav")}
            data_payload = {
                "response_format": "json",
                "temperature": "0.0",
            }
            if diarize:
                data_payload["tdrz"] = "true"

            r = await client.post(
                f"{settings['whisper_url']}/inference",
                files=files_payload,
                data=data_payload,
            )
            r.raise_for_status()
            whisper_result = r.json()
    except Exception as e:
        return JSONResponse(status_code=502, content={
            "error": f"whisper.cpp request failed: {e}",
            "pipeline_info": pipeline_info,
        })

    t_end = time.perf_counter()

    pipeline_info.update({
        "whisper_processing_ms": round((t_end - t_whisper_start) * 1000),
        "total_pipeline_ms": round((t_end - t_start) * 1000),
    })

    return {
        "text": whisper_result.get("text", ""),
        "segments": whisper_result.get("segments", []),
        "pipeline_info": pipeline_info,
    }


# ── BLE Simulation Only ────────────────────────────────────────────────────

@app.post("/api/simulate-ble")
async def simulate_ble_only(file: UploadFile = File(...)):
    raw_bytes = await file.read()
    pcm, sr = load_audio(raw_bytes, file.filename or "audio.wav")

    # Resample to 24kHz
    pcm_24k = resample(pcm, sr, 24000)

    # LC3 encode/decode
    lc3_result = lc3_encode_decode_pipeline(pcm_24k)
    decoded_pcm = lc3_result["decoded_pcm"]

    # Generate WAV bytes for before/after comparison
    original_wav = pcm_to_wav_bytes(pcm_24k, 24000)
    decoded_wav = pcm_to_wav_bytes(decoded_pcm, 24000)

    # Sample BLE packet hex dump (first 3 packets)
    packet_hex = ble_packet_hex_sample(lc3_result["encoded_frames"], count=3)

    return {
        "frame_count": lc3_result["frame_count"],
        "lc3_frame_bytes": 60,
        "total_encoded_bytes": lc3_result["total_encoded_bytes"],
        "compression_ratio": round(lc3_result["compression_ratio"], 2),
        "original_pcm_bytes": len(pcm_24k) * 2,
        "ble_packet_samples": packet_hex,
        "original_audio_b64": base64.b64encode(original_wav).decode(),
        "decoded_audio_b64": base64.b64encode(decoded_wav).decode(),
    }


# ── Static frontend ────────────────────────────────────────────────────────

if STATIC_DIR.exists():
    app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")
