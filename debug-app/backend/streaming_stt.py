"""
Cervos Debug — Streaming STT engine (faster-whisper + pyannote diarization)

Accumulates PCM audio chunks and transcribes when speech is detected.
Runs pyannote speaker diarization on transcribed segments.
All in-memory, no files.
"""

import os
import time
import logging
import numpy as np
from faster_whisper import WhisperModel

logger = logging.getLogger("cervos-debug")

# Config
SAMPLE_RATE = 16000
MIN_SPEECH_S = 0.5
MAX_BUFFER_S = 30.0
SILENCE_THRESHOLD_S = 0.6
ENERGY_SPEECH_THRESHOLD = 0.01
ENERGY_SILENCE_THRESHOLD = 0.005


class StreamingSTT:
    """
    Real-time streaming STT with speaker diarization.

    Feed PCM chunks via add_audio(), get transcriptions with speaker labels back.
    """

    def __init__(self, model_size: str = "large-v3", device: str = "auto",
                 compute_type: str = "float16"):
        # Load whisper model
        logger.info(f"Loading faster-whisper model '{model_size}' on {device}...")
        t0 = time.perf_counter()
        self.model = WhisperModel(
            model_size,
            device=device,
            compute_type=compute_type,
        )
        logger.info(f"Whisper model loaded in {time.perf_counter() - t0:.1f}s")

        # Load pyannote diarization pipeline
        self.diarize_pipeline = None
        hf_token = os.environ.get("HF_TOKEN", "")
        if hf_token and hf_token != "paste_your_token_here":
            try:
                from pyannote.audio import Pipeline
                logger.info("Loading pyannote diarization pipeline...")
                t0 = time.perf_counter()
                self.diarize_pipeline = Pipeline.from_pretrained(
                    "pyannote/speaker-diarization-3.1",
                    token=hf_token,
                )
                # Keep pyannote on CPU (GPU is for whisper)
                import torch
                self.diarize_pipeline.to(torch.device("cpu"))
                logger.info(f"Pyannote loaded in {time.perf_counter() - t0:.1f}s")
            except Exception as e:
                logger.warning(f"Pyannote not available: {e}")
        else:
            logger.info("No HF_TOKEN set — diarization disabled")

        self.buffer = np.array([], dtype=np.float32)
        self.is_speaking = False
        self.silence_start = 0.0

    def add_audio(self, pcm_chunk: np.ndarray) -> list[dict]:
        """
        Add a PCM chunk (float32, 16kHz mono) and return completed transcriptions.
        Returns list of dicts with 'text', 'segments', 'speakers', 'latency_ms'.
        """
        self.buffer = np.concatenate([self.buffer, pcm_chunk])
        results = []

        rms = np.sqrt(np.mean(pcm_chunk ** 2)) if len(pcm_chunk) > 0 else 0.0
        now = time.perf_counter()
        buffer_duration = len(self.buffer) / SAMPLE_RATE

        if not self.is_speaking:
            if rms > ENERGY_SPEECH_THRESHOLD:
                self.is_speaking = True
                self.silence_start = 0.0
        else:
            if rms < ENERGY_SILENCE_THRESHOLD:
                if self.silence_start == 0.0:
                    self.silence_start = now
                elif now - self.silence_start > SILENCE_THRESHOLD_S:
                    result = self._transcribe()
                    if result:
                        results.append(result)
                    self.is_speaking = False
                    self.silence_start = 0.0
            else:
                self.silence_start = 0.0

        if buffer_duration > MAX_BUFFER_S:
            result = self._transcribe()
            if result:
                results.append(result)
            self.is_speaking = False
            self.silence_start = 0.0

        return results

    def _transcribe(self) -> dict | None:
        """Run faster-whisper + optional pyannote diarization on buffer."""
        if len(self.buffer) < int(MIN_SPEECH_S * SAMPLE_RATE):
            self.buffer = np.array([], dtype=np.float32)
            return None

        audio = self.buffer.copy()
        self.buffer = np.array([], dtype=np.float32)

        t0 = time.perf_counter()

        # Transcribe
        segments_iter, info = self.model.transcribe(
            audio,
            beam_size=1,
            language=None,
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
                "speaker": None,
            })
            full_text.append(seg.text.strip())

        transcribe_ms = round((time.perf_counter() - t0) * 1000)

        text = " ".join(full_text)
        if not text.strip():
            return None

        # Diarize (assign speakers to segments)
        diarize_ms = 0
        if self.diarize_pipeline and len(segments) > 0:
            t1 = time.perf_counter()
            try:
                segments = self._assign_speakers(audio, segments)
            except Exception as e:
                logger.warning(f"Diarization failed: {e}")
            diarize_ms = round((time.perf_counter() - t1) * 1000)

        total_ms = round((time.perf_counter() - t0) * 1000)

        # Build display text with speaker labels
        display_parts = []
        current_speaker = None
        for seg in segments:
            speaker = seg.get("speaker")
            if speaker and speaker != current_speaker:
                display_parts.append(f"\n[{speaker}] ")
                current_speaker = speaker
            display_parts.append(seg["text"])
        display_text = " ".join(display_parts).strip()

        return {
            "text": display_text,
            "segments": segments,
            "language": info.language,
            "language_probability": round(info.language_probability, 2),
            "audio_duration_s": round(len(audio) / SAMPLE_RATE, 2),
            "latency_ms": total_ms,
            "transcribe_ms": transcribe_ms,
            "diarize_ms": diarize_ms,
            "diarization": self.diarize_pipeline is not None,
        }

    def _assign_speakers(self, audio: np.ndarray, segments: list[dict]) -> list[dict]:
        """Run pyannote on audio and assign speaker labels to segments."""
        import torch

        # pyannote expects a dict with "waveform" and "sample_rate"
        waveform = torch.from_numpy(audio).unsqueeze(0).float()
        audio_input = {"waveform": waveform, "sample_rate": SAMPLE_RATE}

        result = self.diarize_pipeline(audio_input)
        diarization = result.speaker_diarization

        # Build speaker timeline: list of (start, end, speaker)
        speaker_turns = []
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            speaker_turns.append((turn.start, turn.end, speaker))

        # Assign speaker to each whisper segment by overlap
        for seg in segments:
            seg_start = seg["start"]
            seg_end = seg["end"]
            best_speaker = None
            best_overlap = 0.0

            for turn_start, turn_end, speaker in speaker_turns:
                overlap_start = max(seg_start, turn_start)
                overlap_end = min(seg_end, turn_end)
                overlap = max(0, overlap_end - overlap_start)
                if overlap > best_overlap:
                    best_overlap = overlap
                    best_speaker = speaker

            seg["speaker"] = best_speaker

        return segments

    def flush(self) -> dict | None:
        if len(self.buffer) < int(0.3 * SAMPLE_RATE):
            self.buffer = np.array([], dtype=np.float32)
            return None
        result = self._transcribe()
        self.is_speaking = False
        self.silence_start = 0.0
        return result

    def reset(self):
        self.buffer = np.array([], dtype=np.float32)
        self.is_speaking = False
        self.silence_start = 0.0
