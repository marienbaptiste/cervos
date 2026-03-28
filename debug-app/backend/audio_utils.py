"""
Cervos Debug — Audio utilities

Handles loading audio from various formats and resampling between rates.
"""

import io
import struct
import numpy as np
from scipy.signal import resample_poly
from math import gcd


def load_audio(raw_bytes: bytes, filename: str) -> tuple[np.ndarray, int]:
    """
    Load audio bytes into a float32 mono numpy array + sample rate.
    Supports WAV (PCM 16-bit or float32). For other formats, assumes
    16kHz 16-bit mono PCM.
    """
    if filename.lower().endswith(".wav") or raw_bytes[:4] == b"RIFF":
        return _load_wav(raw_bytes)

    # Fallback: treat as raw 16-bit mono PCM at 16kHz
    samples = np.frombuffer(raw_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    return samples, 16000


def _load_wav(raw_bytes: bytes) -> tuple[np.ndarray, int]:
    """Parse WAV file (PCM 16-bit or 32-bit float, mono or stereo)."""
    import scipy.io.wavfile as wavfile

    sr, data = wavfile.read(io.BytesIO(raw_bytes))

    # Convert to float32
    if data.dtype == np.int16:
        audio = data.astype(np.float32) / 32768.0
    elif data.dtype == np.int32:
        audio = data.astype(np.float32) / 2147483648.0
    elif data.dtype == np.float32:
        audio = data
    else:
        audio = data.astype(np.float32)

    # Stereo → mono
    if audio.ndim == 2:
        audio = audio.mean(axis=1)

    return audio, sr


def resample(pcm: np.ndarray, from_rate: int, to_rate: int) -> np.ndarray:
    """Resample audio using polyphase filtering. Returns float32 array."""
    if from_rate == to_rate:
        return pcm

    divisor = gcd(from_rate, to_rate)
    up = to_rate // divisor
    down = from_rate // divisor
    return resample_poly(pcm, up, down).astype(np.float32)


def pcm_to_wav_bytes(pcm: np.ndarray, sample_rate: int) -> bytes:
    """Convert float32 PCM array to 16-bit WAV bytes."""
    # Clip and convert to int16
    pcm_clipped = np.clip(pcm, -1.0, 1.0)
    pcm_int16 = (pcm_clipped * 32767).astype(np.int16)

    buf = io.BytesIO()
    num_samples = len(pcm_int16)
    data_size = num_samples * 2  # 16-bit = 2 bytes per sample

    # WAV header (44 bytes)
    buf.write(b"RIFF")
    buf.write(struct.pack("<I", 36 + data_size))
    buf.write(b"WAVE")
    buf.write(b"fmt ")
    buf.write(struct.pack("<I", 16))          # fmt chunk size
    buf.write(struct.pack("<H", 1))           # PCM format
    buf.write(struct.pack("<H", 1))           # mono
    buf.write(struct.pack("<I", sample_rate))
    buf.write(struct.pack("<I", sample_rate * 2))  # byte rate
    buf.write(struct.pack("<H", 2))           # block align
    buf.write(struct.pack("<H", 16))          # bits per sample
    buf.write(b"data")
    buf.write(struct.pack("<I", data_size))
    buf.write(pcm_int16.tobytes())

    return buf.getvalue()
