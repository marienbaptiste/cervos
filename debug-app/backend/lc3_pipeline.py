"""
Cervos Debug — LC3 BLE pipeline simulation

Simulates the firmware→phone audio path:
  1. Split PCM into 10ms frames (240 samples at 24kHz)
  2. LC3 encode each frame to 60 bytes
  3. Wrap in BLE L2CAP packet format [seq:u16][ts:u32][count:u8][LC3...]
  4. LC3 decode back to PCM

Constants match firmware/src/lc3_encoder.h exactly.
"""

import struct
import numpy as np

# LC3 constants — must match firmware/src/lc3_encoder.h
LC3_SAMPLE_RATE = 24000
LC3_CHANNELS = 1
LC3_FRAME_US = 10000       # 10ms
LC3_FRAME_SAMPLES = 240    # LC3_SAMPLE_RATE / 100
LC3_BITRATE = 48000        # 48kbps mono
LC3_FRAME_BYTES = 60       # LC3_BITRATE / 8 / 100

# BLE packet header: [seq_num:u16][timestamp:u32][frame_count:u8]
BLE_HEADER_FORMAT = "<HIB"  # little-endian: H=u16 seq, I=u32 timestamp, B=u8 count
BLE_HEADER_SIZE = 7         # 2 + 4 + 1

# Try to import lc3 Python bindings (built from google/liblc3)
_lc3_available = False
try:
    import lc3
    _lc3_available = True
except ImportError:
    pass


def lc3_encode_decode_pipeline(pcm_24k: np.ndarray) -> dict:
    """
    Run the full LC3 BLE simulation pipeline on 24kHz mono float32 PCM.

    Returns dict with:
      - decoded_pcm: float32 numpy array of decoded audio
      - encoded_frames: list of bytes (raw LC3 frames)
      - frame_count: number of frames processed
      - total_encoded_bytes: total LC3 compressed size
      - compression_ratio: original_size / compressed_size
    """
    if _lc3_available:
        return _pipeline_with_lc3(pcm_24k)
    else:
        return _pipeline_passthrough(pcm_24k)


def _pipeline_with_lc3(pcm_24k: np.ndarray) -> dict:
    """Pipeline using real LC3 codec."""
    encoder = lc3.Encoder(LC3_FRAME_US, LC3_SAMPLE_RATE, LC3_CHANNELS)
    decoder = lc3.Decoder(LC3_FRAME_US, LC3_SAMPLE_RATE, LC3_CHANNELS)

    # Pad PCM to exact frame boundary
    n_frames = max(1, len(pcm_24k) // LC3_FRAME_SAMPLES)
    padded_len = n_frames * LC3_FRAME_SAMPLES
    pcm_padded = np.zeros(padded_len, dtype=np.float32)
    pcm_padded[:len(pcm_24k)] = pcm_24k[:padded_len]

    encoded_frames = []
    decoded_chunks = []

    for i in range(n_frames):
        frame_pcm = pcm_padded[i * LC3_FRAME_SAMPLES:(i + 1) * LC3_FRAME_SAMPLES]

        # Encode: float [-1,1] input, returns bytes
        frame_clipped = np.clip(frame_pcm, -1.0, 1.0).tolist()
        encoded = encoder.encode(frame_clipped, LC3_FRAME_BYTES)
        encoded_frames.append(bytes(encoded))

        # Decode: returns float array [-1,1] when no bit_depth
        decoded_floats = decoder.decode(bytes(encoded))
        decoded_chunks.append(np.array(decoded_floats, dtype=np.float32))

    decoded_pcm = np.concatenate(decoded_chunks) if decoded_chunks else np.array([], dtype=np.float32)
    total_encoded = sum(len(f) for f in encoded_frames)
    original_bytes = len(pcm_padded) * 2  # int16 = 2 bytes

    return {
        "decoded_pcm": decoded_pcm,
        "encoded_frames": encoded_frames,
        "frame_count": n_frames,
        "total_encoded_bytes": total_encoded,
        "compression_ratio": original_bytes / total_encoded if total_encoded > 0 else 0,
    }


def _pipeline_passthrough(pcm_24k: np.ndarray) -> dict:
    """
    Fallback when liblc3 is not available.
    Simulates the pipeline without actual LC3 encode/decode — just computes
    what the sizes would be and passes audio through unchanged.
    """
    n_frames = max(1, len(pcm_24k) // LC3_FRAME_SAMPLES)
    padded_len = n_frames * LC3_FRAME_SAMPLES
    pcm_padded = np.zeros(padded_len, dtype=np.float32)
    pcm_padded[:min(len(pcm_24k), padded_len)] = pcm_24k[:padded_len]

    total_encoded = n_frames * LC3_FRAME_BYTES
    original_bytes = padded_len * 2

    # Generate fake encoded frames (for hex dump display)
    encoded_frames = [b"\x00" * LC3_FRAME_BYTES for _ in range(min(n_frames, 10))]

    return {
        "decoded_pcm": pcm_padded,
        "encoded_frames": encoded_frames,
        "frame_count": n_frames,
        "total_encoded_bytes": total_encoded,
        "compression_ratio": original_bytes / total_encoded if total_encoded > 0 else 0,
        "_lc3_fallback": True,
    }


def ble_packet_hex_sample(encoded_frames: list[bytes], count: int = 3) -> list[str]:
    """
    Build BLE L2CAP packet headers for the first N frames and return hex dumps.
    Packet format matches firmware/src/ble_l2cap_stream.c:
      [seq_num:u16][timestamp:u32][frame_count:u8][LC3 frame data]
    """
    packets = []
    for i, frame_data in enumerate(encoded_frames[:count]):
        seq_num = i & 0xFFFF
        timestamp_us = i * LC3_FRAME_US
        frame_count = 1

        header = struct.pack("<HIB", seq_num, timestamp_us, frame_count)
        packet = header + frame_data
        hex_str = packet.hex(" ", 1)
        packets.append(f"Packet {i}: [{len(packet)} bytes] {hex_str}")

    return packets
