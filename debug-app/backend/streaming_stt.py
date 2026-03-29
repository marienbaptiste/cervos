"""
Cervos Debug — Streaming STT powered by WhisperLive + pyannote speaker ID

Uses WhisperLive's battle-tested ServeClientFasterWhisper for real-time
streaming transcription. Adds pyannote diarization + persistent speaker
profiles on top.
"""

import os
import json
import time
import queue
import logging
import threading
import numpy as np

from speaker_store import SpeakerStore

logger = logging.getLogger("cervos-debug")
SAMPLE_RATE = 16000


class WebSocketAdapter:
    """
    Adapts a queue to look like a websocket for WhisperLive's ServeClientFasterWhisper.
    WhisperLive sends JSON strings via websocket.send() — we capture them in a queue.
    """
    def __init__(self):
        self.outbox = queue.Queue()

    def send(self, data: str):
        self.outbox.put_nowait(data)

    def close(self):
        pass


class StreamingSTT:
    """
    Real-time streaming STT backed by WhisperLive + pyannote speaker ID.

    Usage:
        stt = StreamingSTT(...)
        client = stt.create_client()   # starts WhisperLive transcription thread
        client.add_frames(pcm_chunk)   # feed audio (float32, 16kHz)
        msg = client.adapter.outbox.get_nowait()  # get JSON segment messages
        client.cleanup()               # stop
    """

    def __init__(self, model_size="large-v3", device="auto", compute_type="float16"):
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self._fw_client_class = None

        # Load faster-whisper model for diarization transcription pass
        from faster_whisper import WhisperModel
        logger.info(f"Loading faster-whisper '{model_size}' for diarization...")
        self.model = WhisperModel(model_size, device=device, compute_type=compute_type)
        logger.info("Whisper model loaded")

        # Load WhisperLive backend
        logger.info("Importing WhisperLive ServeClientFasterWhisper...")
        try:
            from whisper_live.backend.faster_whisper_backend import ServeClientFasterWhisper
            self._fw_client_class = ServeClientFasterWhisper
            logger.info("WhisperLive backend loaded")
        except ImportError as e:
            logger.error(f"WhisperLive not installed: {e}")
            raise

        # Load pyannote for diarization
        self.diarize_pipeline = None
        self._speaker_encoder = None
        hf_token = os.environ.get("HF_TOKEN", "")
        if hf_token and hf_token != "paste_your_token_here":
            try:
                from pyannote.audio import Pipeline, Inference, Model
                import torch
                logger.info("Loading pyannote...")
                t0 = time.perf_counter()
                self.diarize_pipeline = Pipeline.from_pretrained(
                    "pyannote/speaker-diarization-3.1", use_auth_token=hf_token)
                self.diarize_pipeline.to(torch.device("cpu"))
                embedding_model = Model.from_pretrained(
                    "pyannote/wespeaker-voxceleb-resnet34-LM", use_auth_token=hf_token)
                self._speaker_encoder = Inference(
                    embedding_model, window="whole", device=torch.device("cpu"))
                logger.info(f"Pyannote loaded in {time.perf_counter() - t0:.1f}s")
            except Exception as e:
                logger.warning(f"Pyannote not available: {e}")
        else:
            logger.info("No HF_TOKEN — diarization disabled")

        self.speaker_store = SpeakerStore()

    def create_client(self, language=None) -> "WhisperLiveClient":
        """Create a new WhisperLive client session. Each WS connection gets one."""
        adapter = WebSocketAdapter()

        # Create WhisperLive client — single_model=True shares the model across clients
        # so clicking Stream doesn't reload the model every time
        client = self._fw_client_class(
            websocket=adapter,
            task="transcribe",
            language=language,
            client_uid=f"cervos-{time.time_ns()}",
            model=self.model_size,
            use_vad=True,
            single_model=True,
            send_last_n_segments=10,
            no_speech_thresh=0.45,
            clip_audio=True,
            same_output_threshold=7,
        )

        return WhisperLiveClient(client, adapter, self)

    # ── Diarization ───────────────────────────────────────────────────────

    def transcribe_and_diarize(self, audio: np.ndarray) -> list[dict]:
        """Transcribe + diarize the same audio. Timestamps always aligned. Blocking."""
        import torch

        # Transcribe
        segments_iter, info = self.model.transcribe(
            audio, beam_size=1, language=None, vad_filter=True,
            vad_parameters=dict(min_speech_duration_ms=250, min_silence_duration_ms=200),
        )
        segments = []
        for seg in segments_iter:
            segments.append({
                "start": round(seg.start, 3),
                "end": round(seg.end, 3),
                "text": seg.text.strip(),
                "speaker_id": None,
                "speaker_name": None,
            })
        if not segments:
            return []

        # Diarize the same audio
        if self.diarize_pipeline:
            waveform = torch.from_numpy(audio).unsqueeze(0).float()
            result = self.diarize_pipeline({"waveform": waveform, "sample_rate": SAMPLE_RATE})
            raw_turns = [(t.start, t.end, s) for t, _, s in result.itertracks(yield_label=True)]

            if raw_turns:
                # Map labels to persistent IDs
                label_map = {}
                for label in set(s for _, _, s in raw_turns):
                    emb = self._extract_embedding(audio, raw_turns, label)
                    if emb is not None:
                        sid, _ = self.speaker_store.match_or_create(emb)
                        label_map[label] = sid

                # Assign speaker to each segment by best overlap
                for seg in segments:
                    best_label, best_ov = None, 0.0
                    for ts, te, label in raw_turns:
                        ov = max(0, min(seg["end"], te) - max(seg["start"], ts))
                        if ov > best_ov:
                            best_ov, best_label = ov, label
                    if best_label and best_label in label_map:
                        sid = label_map[best_label]
                        seg["speaker_id"] = sid
                        profile = self.speaker_store.get_profile(sid)
                        if profile and profile.get("name"):
                            seg["speaker_name"] = profile["name"]

        return segments

    def get_speaker_turns(self, audio: np.ndarray) -> list[dict]:
        """Run pyannote diarization on audio, return speaker turns with persistent IDs."""
        if not self.diarize_pipeline:
            return []

        import torch
        waveform = torch.from_numpy(audio).unsqueeze(0).float()
        result = self.diarize_pipeline({"waveform": waveform, "sample_rate": SAMPLE_RATE})
        raw_turns = [(t.start, t.end, s) for t, _, s in result.itertracks(yield_label=True)]
        if not raw_turns:
            return []

        # Map pyannote labels to persistent speaker IDs
        label_map = {}
        for label in set(s for _, _, s in raw_turns):
            emb = self._extract_embedding(audio, raw_turns, label)
            if emb is not None:
                sid, _ = self.speaker_store.match_or_create(emb)
                label_map[label] = sid

        turns = []
        for start, end, label in raw_turns:
            sid = label_map.get(label)
            if sid:
                profile = self.speaker_store.get_profile(sid)
                name = profile.get("name") if profile else None
                turns.append({
                    "start": round(start, 3),
                    "end": round(end, 3),
                    "speaker_id": sid,
                    "speaker_name": name,
                })
        return turns

    def diarize(self, audio: np.ndarray, segments: list[dict]) -> list[dict]:
        """Run pyannote diarization + speaker ID on audio. Blocking."""
        if not self.diarize_pipeline or len(segments) == 0:
            return segments

        import torch
        waveform = torch.from_numpy(audio).unsqueeze(0).float()
        result = self.diarize_pipeline({"waveform": waveform, "sample_rate": SAMPLE_RATE})
        turns = [(t.start, t.end, s) for t, _, s in result.itertracks(yield_label=True)]
        if not turns:
            return segments

        label_map = {}
        for label in set(s for _, _, s in turns):
            emb = self._extract_embedding(audio, turns, label)
            if emb is not None:
                sid, is_new = self.speaker_store.match_or_create(emb)
                label_map[label] = sid

        for seg in segments:
            start = float(seg.get("start", 0))
            end = float(seg.get("end", 0))
            best_label, best_ov = None, 0.0
            for ts, te, label in turns:
                ov = max(0, min(end, te) - max(start, ts))
                if ov > best_ov:
                    best_ov, best_label = ov, label
            if best_label and best_label in label_map:
                seg["speaker_id"] = label_map[best_label]
                profile = self.speaker_store.get_profile(label_map[best_label])
                if profile and profile.get("name"):
                    seg["speaker_name"] = profile["name"]
        return segments

    def _extract_embedding(self, audio, turns, target_label):
        if not self._speaker_encoder:
            return None
        import torch
        chunks = []
        for ts, te, label in turns:
            if label != target_label:
                continue
            chunk = audio[int(ts * SAMPLE_RATE):int(te * SAMPLE_RATE)]
            if len(chunk) > 0:
                chunks.append(chunk)
        if not chunks:
            return None
        speaker_audio = np.concatenate(chunks)
        if len(speaker_audio) < int(0.5 * SAMPLE_RATE):
            return None
        waveform = torch.from_numpy(speaker_audio).unsqueeze(0).float()
        emb = self._speaker_encoder({"waveform": waveform, "sample_rate": SAMPLE_RATE})
        if hasattr(emb, 'numpy'):
            emb = emb.numpy()
        emb = np.array(emb).flatten().astype(np.float32)
        if np.any(np.isnan(emb)) or np.all(emb == 0):
            return None
        norm = np.linalg.norm(emb)
        return emb / norm if norm > 0 else None


class WhisperLiveClient:
    """Wraps a WhisperLive ServeClientFasterWhisper with our adapter."""

    def __init__(self, wl_client, adapter: WebSocketAdapter, stt: StreamingSTT):
        self.wl_client = wl_client
        self.adapter = adapter
        self.stt = stt

    def add_frames(self, pcm: np.ndarray):
        """Feed audio to WhisperLive. Float32, 16kHz."""
        self.wl_client.add_frames(pcm)

    def get_messages(self) -> list[dict]:
        """Non-blocking: drain all pending messages from WhisperLive."""
        messages = []
        while True:
            try:
                raw = self.adapter.outbox.get_nowait()
                msg = json.loads(raw) if isinstance(raw, str) else raw
                messages.append(msg)
            except queue.Empty:
                break
        return messages

    def cleanup(self):
        self.wl_client.cleanup()
