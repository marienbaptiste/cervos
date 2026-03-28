"""
Cervos Debug — Streaming STT engine (faster-whisper + VAD)

Accumulates PCM audio chunks and transcribes when speech is detected.
All in-memory, no files. Designed for sub-300ms latency on CUDA.
"""

import time
import numpy as np
from faster_whisper import WhisperModel

# Transcription config
SAMPLE_RATE = 16000
CHUNK_DURATION_S = 0.1  # 100ms chunks from frontend
MIN_SPEECH_S = 0.5      # minimum speech before transcribing
MAX_BUFFER_S = 30.0     # max buffer before forced transcribe
SILENCE_THRESHOLD_S = 0.6  # silence after speech triggers transcribe

# Simple energy-based VAD thresholds
ENERGY_SPEECH_THRESHOLD = 0.01  # RMS above this = speech
ENERGY_SILENCE_THRESHOLD = 0.005  # RMS below this = silence


class StreamingSTT:
    """
    Real-time streaming speech-to-text engine.

    Feed PCM chunks via add_audio(), get transcriptions back.
    Uses energy-based VAD to detect speech boundaries.
    """

    def __init__(self, model_size: str = "large-v3", device: str = "auto",
                 compute_type: str = "float16"):
        print(f"Loading faster-whisper model '{model_size}' on {device}...")
        t0 = time.perf_counter()
        self.model = WhisperModel(
            model_size,
            device=device,
            compute_type=compute_type,
        )
        print(f"Model loaded in {time.perf_counter() - t0:.1f}s")

        self.buffer = np.array([], dtype=np.float32)
        self.is_speaking = False
        self.silence_start = 0.0
        self.speech_start = 0.0

    def add_audio(self, pcm_chunk: np.ndarray) -> list[dict]:
        """
        Add a PCM chunk (float32, 16kHz mono) and return any completed
        transcriptions. Returns list of dicts with 'text', 'segments', 'latency_ms'.
        """
        self.buffer = np.concatenate([self.buffer, pcm_chunk])
        results = []

        # Compute RMS energy for this chunk
        rms = np.sqrt(np.mean(pcm_chunk ** 2)) if len(pcm_chunk) > 0 else 0.0
        now = time.perf_counter()
        buffer_duration = len(self.buffer) / SAMPLE_RATE

        if not self.is_speaking:
            if rms > ENERGY_SPEECH_THRESHOLD:
                self.is_speaking = True
                self.speech_start = now
                self.silence_start = 0.0
        else:
            if rms < ENERGY_SILENCE_THRESHOLD:
                if self.silence_start == 0.0:
                    self.silence_start = now
                elif now - self.silence_start > SILENCE_THRESHOLD_S:
                    # Silence after speech — transcribe
                    result = self._transcribe()
                    if result:
                        results.append(result)
                    self.is_speaking = False
                    self.silence_start = 0.0
            else:
                self.silence_start = 0.0

        # Force transcribe if buffer is too long
        if buffer_duration > MAX_BUFFER_S:
            result = self._transcribe()
            if result:
                results.append(result)
            self.is_speaking = False
            self.silence_start = 0.0

        return results

    def _transcribe(self) -> dict | None:
        """Run faster-whisper on the accumulated buffer."""
        if len(self.buffer) < int(MIN_SPEECH_S * SAMPLE_RATE):
            self.buffer = np.array([], dtype=np.float32)
            return None

        audio = self.buffer.copy()
        self.buffer = np.array([], dtype=np.float32)

        t0 = time.perf_counter()
        segments_iter, info = self.model.transcribe(
            audio,
            beam_size=1,
            language=None,  # auto-detect
            vad_filter=True,
            vad_parameters=dict(
                min_speech_duration_ms=250,
                min_silence_duration_ms=200,
            ),
        )

        segments = []
        full_text = []
        for seg in segments_iter:
            segments.append({
                "start": round(seg.start, 2),
                "end": round(seg.end, 2),
                "text": seg.text.strip(),
            })
            full_text.append(seg.text.strip())

        latency_ms = round((time.perf_counter() - t0) * 1000)
        text = " ".join(full_text)

        if not text.strip():
            return None

        return {
            "text": text,
            "segments": segments,
            "language": info.language,
            "language_probability": round(info.language_probability, 2),
            "audio_duration_s": round(len(audio) / SAMPLE_RATE, 2),
            "latency_ms": latency_ms,
        }

    def flush(self) -> dict | None:
        """Force-transcribe whatever is in the buffer."""
        if len(self.buffer) < int(0.3 * SAMPLE_RATE):
            self.buffer = np.array([], dtype=np.float32)
            return None
        result = self._transcribe()
        self.is_speaking = False
        self.silence_start = 0.0
        return result

    def reset(self):
        """Clear buffer and state."""
        self.buffer = np.array([], dtype=np.float32)
        self.is_speaking = False
        self.silence_start = 0.0
