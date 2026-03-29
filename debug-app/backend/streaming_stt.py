"""
Cervos Voice Service — Streaming STT (WhisperLive) + Streaming Diarization (pyannote components)

- WhisperLive: real-time transcript via ServeClientFasterWhisper
- SpeakerDiarizer: custom streaming diarization using pyannote segmentation + embedding
  models directly (no diart, no full Pipeline). 5s sliding window, 500ms step.
- SpeakerStore (Chroma): persistent speaker fingerprints across sessions
"""

import os
import json
import time
import queue
import logging
import threading
import numpy as np

from speaker_store import SpeakerStore

logger = logging.getLogger("cervos-voice")
SAMPLE_RATE = 16000


class WebSocketAdapter:
    """Adapts a queue to look like a websocket for WhisperLive."""
    def __init__(self):
        self.outbox = queue.Queue()

    def send(self, data: str):
        self.outbox.put_nowait(data)

    def close(self):
        pass


class RingBuffer:
    """Pre-allocated circular buffer for audio samples. O(1) append."""

    def __init__(self, capacity: int):
        self.buffer = np.zeros(capacity, dtype=np.float32)
        self.write_pos = 0
        self.available = 0
        self.capacity = capacity

    def write(self, data: np.ndarray):
        n = len(data)
        if n == 0:
            return
        if n >= self.capacity:
            self.buffer[:] = data[-self.capacity:]
            self.write_pos = 0
            self.available = self.capacity
            return
        end = self.write_pos + n
        if end <= self.capacity:
            self.buffer[self.write_pos:end] = data
        else:
            first = self.capacity - self.write_pos
            self.buffer[self.write_pos:] = data[:first]
            self.buffer[:n - first] = data[first:]
        self.write_pos = end % self.capacity
        self.available = min(self.available + n, self.capacity)

    def read_last(self, n: int) -> np.ndarray:
        """Read the last n samples as a contiguous array."""
        n = min(n, self.available)
        if n == 0:
            return np.array([], dtype=np.float32)
        start = (self.write_pos - n) % self.capacity
        if start + n <= self.capacity:
            return self.buffer[start:start + n].copy()
        else:
            return np.concatenate([
                self.buffer[start:],
                self.buffer[:n - (self.capacity - start)]
            ])

    def clear(self):
        self.write_pos = 0
        self.available = 0


class SpeakerDiarizer:
    """
    Streaming speaker diarization using pyannote components directly.

    Uses pyannote/segmentation-3.0 for per-speaker frame activations and
    pyannote/wespeaker-voxceleb-resnet34-LM for speaker embeddings.
    Matches embeddings against Chroma (SpeakerStore) for persistent IDs.

    No diart dependency. No full pyannote Pipeline. No agglomerative clustering.
    """

    WINDOW_S = 5.0       # sliding window duration
    STEP_S = 0.5         # step size
    TAU_ACTIVE = 0.5     # speaker activation threshold
    MIN_SPEECH_S = 0.5   # minimum speech per speaker to extract embedding

    def __init__(self, device: str, hf_token: str, speaker_store: SpeakerStore):
        self.ready = False
        self.speaker_store = speaker_store
        self._lock = threading.Lock()
        self._new_samples = 0
        self._time_offset = 0.0

        window_samples = int(self.WINDOW_S * SAMPLE_RATE)
        self._step_samples = int(self.STEP_S * SAMPLE_RATE)
        self._window_samples = window_samples
        self._ring = RingBuffer(window_samples)

        # Frame resolution (will be set after model loads)
        self._frame_step_s = 0.0
        self._to_multilabel = None

        try:
            import torch
            from pyannote.audio import Model

            dev = torch.device(device if torch.cuda.is_available() else "cpu")
            self._device = dev
            self._torch = torch

            # --- Segmentation model ---
            logger.info("Loading pyannote/segmentation-3.0...")
            self._seg_model = Model.from_pretrained(
                "pyannote/segmentation-3.0",
                use_auth_token=hf_token,
            ).to(dev).eval()

            # Compute frame resolution from model introspection
            specs = self._seg_model.specifications
            # segmentation-3.0: powerset with max_speakers_per_chunk=3, max_speakers_per_frame=2
            # Output is (batch, frames, num_powerset_classes)
            # We need the Powerset converter to go from powerset → multilabel
            from pyannote.audio.utils.powerset import Powerset
            powerset = Powerset(
                len(specs.classes),
                specs.powerset_max_classes,
            )
            # Move mapping tensor to same device as model to avoid CPU/CUDA mismatch
            powerset.mapping = powerset.mapping.to(dev)
            self._to_multilabel = powerset.to_multilabel

            # Frame step: run a dummy forward pass to get exact frame count
            dummy = torch.zeros(1, 1, window_samples, device=dev)
            with torch.no_grad():
                dummy_out = self._seg_model(dummy)
            num_frames = dummy_out.shape[1]
            self._frame_step_s = self.WINDOW_S / num_frames
            # Multilabel output tells us how many speakers the model can track per chunk
            dummy_ml = self._to_multilabel(dummy_out)
            self._max_speakers = dummy_ml.shape[2]
            logger.info(f"Segmentation model loaded: {num_frames} frames for {self.WINDOW_S}s "
                        f"(~{self._frame_step_s*1000:.1f}ms/frame), max {self._max_speakers} speakers")

            # --- Embedding model ---
            logger.info("Loading pyannote/wespeaker-voxceleb-resnet34-LM...")
            self._emb_model = Model.from_pretrained(
                "pyannote/wespeaker-voxceleb-resnet34-LM",
                use_auth_token=hf_token,
            ).to(dev).eval()
            logger.info("Embedding model loaded (256-dim)")

            self.ready = True
            logger.info(f"SpeakerDiarizer ready (device={dev}, window={self.WINDOW_S}s, step={self.STEP_S}s)")

        except Exception as e:
            logger.warning(f"SpeakerDiarizer not available: {e}", exc_info=True)

    def add_audio(self, pcm: np.ndarray):
        """Feed audio chunk. Non-blocking, thread-safe."""
        if not self.ready:
            return
        with self._lock:
            self._ring.write(pcm)
            self._new_samples += len(pcm)

    def process(self) -> list[dict] | None:
        """
        Process one sliding window step if enough new audio has arrived.
        Returns speaker turns with persistent IDs, or None.
        ~15-30ms on GPU.
        """
        if not self.ready:
            return None

        with self._lock:
            if self._new_samples < self._step_samples:
                return None
            if self._ring.available < self._window_samples:
                return None
            window_pcm = self._ring.read_last(self._window_samples)
            self._new_samples = max(0, self._new_samples - self._step_samples)

        try:
            return self._process_window(window_pcm)
        except Exception as e:
            logger.warning(f"Diarization error: {e}", exc_info=True)
            return None

    def _process_window(self, pcm: np.ndarray) -> list[dict] | None:
        """Run segmentation → embedding → Chroma match on one window."""
        torch = self._torch

        # Step 1: Segmentation — (1, 1, samples) → (1, frames, powerset_classes)
        waveform = torch.from_numpy(pcm).unsqueeze(0).unsqueeze(0).to(self._device)
        with torch.no_grad():
            powerset = self._seg_model(waveform)

        # Step 2: Powerset → multilabel — (1, frames, num_speakers)
        multilabel = self._to_multilabel(powerset)  # (1, frames, 3)
        activations = multilabel[0].cpu().numpy()    # (frames, 3)
        num_frames = activations.shape[0]

        # Step 3: Threshold → binary masks
        binary = activations > self.TAU_ACTIVE  # (frames, 3)

        # Compute time offset for this window
        window_start = self._time_offset
        self._time_offset += self.STEP_S

        turns = []
        min_speech_frames = int(self.MIN_SPEECH_S / self._frame_step_s)

        for spk_idx in range(binary.shape[1]):
            spk_mask = binary[:, spk_idx]
            active_frames = np.sum(spk_mask)
            if active_frames < min_speech_frames:
                continue

            # Find contiguous active regions for turn boundaries
            regions = self._mask_to_regions(spk_mask, window_start)
            if not regions:
                continue

            # Step 4: Extract masked audio for embedding
            # Upsample frame mask to sample rate
            samples_per_frame = len(pcm) / num_frames
            sample_mask = np.repeat(spk_mask, int(np.ceil(samples_per_frame)))[:len(pcm)]
            speaker_audio = pcm * sample_mask.astype(np.float32)

            # Only keep non-silent parts (concatenate active regions)
            active_samples = speaker_audio[sample_mask]
            if len(active_samples) < SAMPLE_RATE * 0.3:  # need at least 300ms of actual audio
                continue

            # Run embedding model
            emb_input = torch.from_numpy(active_samples).unsqueeze(0).unsqueeze(0).to(self._device)
            with torch.no_grad():
                embedding = self._emb_model(emb_input)

            emb_np = embedding.cpu().numpy().flatten()
            # Normalize to unit vector
            norm = np.linalg.norm(emb_np)
            if norm > 0:
                emb_np = emb_np / norm

            # Step 5: Match against Chroma speaker store
            speaker_id, is_new = self.speaker_store.match_or_create(emb_np)
            profile = self.speaker_store.get_profile(speaker_id)
            speaker_name = profile.get("name") if profile else None

            for region in regions:
                turns.append({
                    "start": round(region[0], 3),
                    "end": round(region[1], 3),
                    "speaker_id": speaker_id,
                    "speaker_name": speaker_name,
                })

        return turns if turns else None

    def _mask_to_regions(self, mask: np.ndarray, window_start: float) -> list[tuple[float, float]]:
        """Convert a boolean frame mask to a list of (start, end) time regions."""
        regions = []
        in_region = False
        start = 0
        for i, active in enumerate(mask):
            if active and not in_region:
                start = i
                in_region = True
            elif not active and in_region:
                regions.append((
                    window_start + start * self._frame_step_s,
                    window_start + i * self._frame_step_s,
                ))
                in_region = False
        if in_region:
            regions.append((
                window_start + start * self._frame_step_s,
                window_start + len(mask) * self._frame_step_s,
            ))
        return regions

    def reset(self):
        """Reset state for a new session."""
        with self._lock:
            self._ring.clear()
            self._new_samples = 0
            self._time_offset = 0.0


class StreamingSTT:
    """
    Real-time streaming STT (WhisperLive) + streaming diarization (pyannote components).
    """

    def __init__(self, model_size="large-v3", device="auto", compute_type="float16"):
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self._fw_client_class = None

        # Load faster-whisper model for diarized transcription passes
        from faster_whisper import WhisperModel
        logger.info(f"Loading faster-whisper '{model_size}'...")
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

        # Login to HuggingFace for gated model access
        hf_token = os.environ.get("HF_TOKEN", "")
        if hf_token:
            try:
                from huggingface_hub import login
                login(token=hf_token, add_to_git_credential=False)
            except Exception:
                pass

        # Speaker profile store (must init before diarizer — diarizer needs it)
        self.speaker_store = SpeakerStore()

        # Initialize custom streaming diarization (pyannote segmentation + embedding)
        self.diarizer = SpeakerDiarizer(
            device="cuda", hf_token=hf_token, speaker_store=self.speaker_store
        )

    def create_client(self, language=None) -> "WhisperLiveClient":
        """Create a new WhisperLive client session."""
        adapter = WebSocketAdapter()
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
