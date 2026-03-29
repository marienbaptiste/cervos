"""
Cervos Debug — FastAPI backend (WhisperLive streaming STT + pyannote speaker ID)

Endpoints:
  WS   /ws/stream          Real-time: PCM chunks in → transcription segments out
  POST /api/transcribe      Batch: upload file → transcription
  GET  /api/health          Health check
  GET  /api/speakers        Speaker profiles CRUD
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

MODEL_SIZE = os.environ.get("WHISPER_MODEL", "large-v3")
DEVICE = os.environ.get("WHISPER_DEVICE", "auto")
COMPUTE_TYPE = os.environ.get("WHISPER_COMPUTE_TYPE", "float16")

_executor = ThreadPoolExecutor(max_workers=4)
_stt_engine: StreamingSTT | None = None


@app.on_event("startup")
async def startup_load_model():
    global _stt_engine
    loop = asyncio.get_event_loop()
    logger.info(f"Pre-loading StreamingSTT (WhisperLive + pyannote)...")
    _stt_engine = await loop.run_in_executor(
        _executor,
        lambda: StreamingSTT(model_size=MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE),
    )
    logger.info("StreamingSTT ready")


def get_stt() -> StreamingSTT:
    return _stt_engine


# ── Health ──────────────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    return {
        "backend": "ok",
        "engine": "whisper-live + faster-whisper",
        "model": MODEL_SIZE,
        "device": DEVICE,
        "model_loaded": _stt_engine is not None,
    }


# ── WebSocket streaming STT ────────────────────────────────────────────────

@app.websocket("/ws/stream")
async def ws_stream(ws: WebSocket):
    await ws.accept()
    logger.info("WebSocket connected")

    stt = get_stt()
    if stt is None:
        await ws.send_json({"error": "Model still loading, try again"})
        await ws.close()
        return

    loop = asyncio.get_event_loop()
    client = None
    simulate_ble = False
    language = None
    alive = True

    # Audio accumulator for diarization — keeps raw PCM alongside timestamps
    diarize_lock = asyncio.Lock()
    diarize_audio = np.array([], dtype=np.float32)
    diarize_offset = 0.0  # seconds of audio already diarized and discarded
    pending_diarize: set[asyncio.Task] = set()

    total_audio_s = 0.0
    diarize_trim_s = 0.0
    last_diarize_time = 0.0
    diarize_running = False
    DIARIZE_INTERVAL_S = 10.0  # only run diarization every 10s
    DIARIZE_MIN_AUDIO_S = 5.0  # need at least 5s of audio

    def append_diarize_audio(pcm: np.ndarray):
        nonlocal diarize_audio, total_audio_s, diarize_trim_s
        diarize_audio = np.concatenate([diarize_audio, pcm])
        total_audio_s += len(pcm) / 16000
        max_samples = 60 * 16000
        if len(diarize_audio) > max_samples:
            trim = len(diarize_audio) - max_samples
            diarize_trim_s += trim / 16000
            diarize_audio = diarize_audio[trim:]

    async def run_diarization():
        """Transcribe + diarize our own audio buffer, send full attributed transcript."""
        nonlocal diarize_running
        if not stt.diarize_pipeline:
            return
        audio = diarize_audio.copy()
        buf_s = len(audio) / 16000
        if buf_s < DIARIZE_MIN_AUDIO_S:
            return

        diarize_running = True
        try:
            # Limit to last 15s — pyannote on CPU needs to finish within ~5s
            max_samples = 15 * 16000
            if len(audio) > max_samples:
                audio = audio[-max_samples:]
            buf_s = len(audio) / 16000
            logger.info(f"Running diarization on {buf_s:.1f}s of audio...")
            result = await loop.run_in_executor(
                _executor, stt.transcribe_and_diarize, audio
            )
            if result and ws.client_state == WebSocketState.CONNECTED:
                speakers = set(s.get("speaker_id") for s in result if s.get("speaker_id"))
                logger.info(f"Diarized: {len(result)} segments, {len(speakers)} speakers")
                await ws.send_json({
                    "type": "diarized_transcript",
                    "segments": result,
                })
        except Exception as e:
            logger.warning(f"Diarization failed: {e}")
        finally:
            diarize_running = False

    def fire_diarize():
        task = asyncio.create_task(run_diarization())
        pending_diarize.add(task)
        task.add_done_callback(pending_diarize.discard)

    # Poller: reads WhisperLive output queue and forwards to browser
    async def poll_results():
        nonlocal last_diarize_time, diarize_running
        while alive:
            await asyncio.sleep(0.1)  # 100ms poll
            if not alive:
                break
            try:
                if client is None:
                    continue
                messages = client.get_messages()
                for msg in messages:
                    if ws.client_state != WebSocketState.CONNECTED:
                        break

                    # WhisperLive sends: {"uid": ..., "segments": [...]} or status messages
                    if "segments" in msg:
                        segments = msg["segments"]
                        for seg in segments:
                            seg["simulate_ble"] = simulate_ble

                        # Send segments immediately (text appears instantly)
                        await ws.send_json({
                            "segments": segments,
                            "partial": not all(s.get("completed", False) for s in segments),
                        })

                        # Fire diarization periodically (not on every segment)
                        now = time.perf_counter()
                        buf_s = len(diarize_audio) / 16000
                        if (not diarize_running
                                and buf_s >= DIARIZE_MIN_AUDIO_S
                                and now - last_diarize_time >= DIARIZE_INTERVAL_S):
                            last_diarize_time = now
                            fire_diarize()

                    elif "message" in msg:
                        if msg["message"] == "SERVER_READY":
                            logger.info("WhisperLive client ready")
                        elif "language" in msg:
                            logger.info(f"Language detected: {msg.get('language')}")
            except Exception as e:
                if alive:
                    logger.error(f"Poll error: {e}")

    poll_task = asyncio.create_task(poll_results())

    try:
        while True:
            msg = await ws.receive()

            if "text" in msg:
                try:
                    ctrl = json.loads(msg["text"])
                except json.JSONDecodeError:
                    continue

                action = ctrl.get("action", "")
                if action == "reset":
                    await ws.send_json({"status": "reset"})
                elif action == "config":
                    simulate_ble = ctrl.get("simulate_ble", False)
                    language = ctrl.get("language")  # null = auto-detect
                    # Create WhisperLive client now that we know the language
                    if client is None:
                        client = await loop.run_in_executor(
                            _executor, lambda: stt.create_client(language=language))
                        logger.info(f"Client created, language={language or 'auto'}")
                    await ws.send_json({"status": "configured", "simulate_ble": simulate_ble})
                elif action == "flush":
                    # WhisperLive handles flushing internally
                    pass
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

                # Feed audio to WhisperLive — non-blocking (just appends to buffer)
                if client:
                    client.add_frames(pcm)
                # Also accumulate for diarization
                append_diarize_audio(pcm)

    except WebSocketDisconnect:
        logger.info("WebSocket disconnected")
    except RuntimeError as e:
        if "disconnect" in str(e).lower():
            logger.info("WebSocket disconnected (runtime)")
        else:
            logger.error(f"WebSocket error: {e}")
    finally:
        alive = False
        poll_task.cancel()
        for task in list(pending_diarize):
            task.cancel()
        if client:
            client.cleanup()


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

    stt = get_stt()
    if stt is None:
        return JSONResponse(status_code=503, content={"error": "Model loading"})

    # For batch, use faster-whisper directly (WhisperLive is for streaming)
    loop = asyncio.get_event_loop()
    t_stt = time.perf_counter()

    # Import and use the WhisperLive client's transcriber directly
    def do_transcribe():
        client = stt.create_client()
        segments_iter, info = client.wl_client.transcriber.transcribe(
            pcm_16k, beam_size=1, vad_filter=True)
        segs = []
        texts = []
        for seg in segments_iter:
            segs.append({"start": round(seg.start, 2), "end": round(seg.end, 2), "text": seg.text.strip()})
            texts.append(seg.text.strip())
        if client:
            client.cleanup()
        return segs, texts, info

    segs, texts, info = await loop.run_in_executor(_executor, do_transcribe)

    pipeline_info.update({
        "language": info.language,
        "stt_ms": round((time.perf_counter() - t_stt) * 1000),
        "total_ms": round((time.perf_counter() - t_start) * 1000),
    })

    return {"text": " ".join(texts), "segments": segs, "pipeline_info": pipeline_info}


# ── Speaker profiles ────────────────────────────────────────────────────────

@app.get("/api/speakers")
async def list_speakers():
    stt = get_stt()
    if stt is None:
        return JSONResponse(status_code=503, content={"error": "Model loading"})
    return {"speakers": stt.speaker_store.get_all_profiles()}


@app.put("/api/speakers/{speaker_id}")
async def update_speaker(speaker_id: str, body: dict):
    stt = get_stt()
    if stt is None:
        return JSONResponse(status_code=503, content={"error": "Model loading"})
    name = body.get("name", "")
    if stt.speaker_store.set_name(speaker_id, name):
        return {"ok": True, "speaker": stt.speaker_store.get_profile(speaker_id)}
    return JSONResponse(status_code=404, content={"error": "Speaker not found"})


@app.delete("/api/speakers/{speaker_id}")
async def delete_speaker(speaker_id: str):
    stt = get_stt()
    if stt is None:
        return JSONResponse(status_code=503, content={"error": "Model loading"})
    if stt.speaker_store.delete_profile(speaker_id):
        return {"ok": True}
    return JSONResponse(status_code=404, content={"error": "Speaker not found"})


# ── Static frontend ────────────────────────────────────────────────────────

if STATIC_DIR.exists():
    app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")
