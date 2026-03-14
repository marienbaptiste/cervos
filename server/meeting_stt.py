"""
Cervos — Meeting STT Server

Receives dual-stream audio from the phone via Tailscale:
  - "Remote" channel: meeting audio from nRF52840 dongle (other participants)
  - "You" channel: G2 glasses mic (your voice)

Runs Whisper STT on both streams independently.
Runs pyannote diarization on the "Remote" stream to identify individual speakers.
Merges labeled transcripts and pushes formatted captions back to the phone → glasses.

Usage:
    python meeting_stt.py --host 0.0.0.0 --port 8083
"""

import asyncio
import argparse
import json
import logging
from dataclasses import dataclass, field
from typing import Optional

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("meeting_stt")


@dataclass
class AudioStream:
    """A tagged audio stream from the phone."""
    channel: str  # "remote" or "you"
    sample_rate: int = 16000
    buffer: bytearray = field(default_factory=bytearray)


@dataclass
class Caption:
    """A labeled caption segment."""
    speaker: str       # "You", "Alice", "Bob", etc.
    text: str
    timestamp_ms: int
    channel: str       # "remote" or "you"


class MeetingSTTServer:
    """
    Receives dual audio streams, runs STT + diarization, produces labeled captions.
    """

    def __init__(self, whisper_url: str = "http://localhost:8081",
                 pyannote_url: str = "http://localhost:8082"):
        self.whisper_url = whisper_url
        self.pyannote_url = pyannote_url
        self.active_streams: dict[str, AudioStream] = {}
        self.is_active = False

    async def start_session(self) -> str:
        """Start a new meeting capture session."""
        session_id = f"meeting_{int(asyncio.get_event_loop().time())}"
        self.active_streams = {
            "remote": AudioStream(channel="remote"),
            "you": AudioStream(channel="you"),
        }
        self.is_active = True
        logger.info(f"Meeting session started: {session_id}")
        return session_id

    async def receive_audio_chunk(self, channel: str, pcm_data: bytes) -> None:
        """
        Receive a PCM audio chunk from the phone.
        channel: "remote" (dongle stream) or "you" (G2 mic stream)
        """
        if channel not in self.active_streams:
            logger.warning(f"Unknown channel: {channel}")
            return
        self.active_streams[channel].buffer.extend(pcm_data)

    async def process_chunk(self, channel: str) -> Optional[Caption]:
        """
        Process buffered audio for a channel through STT.
        For "remote" channel, also run diarization.
        """
        stream = self.active_streams.get(channel)
        if not stream or len(stream.buffer) == 0:
            return None

        # TODO: Send audio to Whisper STT (lightning-whisper-mlx)
        # TODO: For "remote" channel, run pyannote diarization to identify speakers
        # TODO: Return labeled Caption

        return None

    async def stop_session(self) -> dict:
        """Stop the meeting session and return summary."""
        self.is_active = False
        self.active_streams.clear()
        logger.info("Meeting session stopped")
        return {"status": "stopped"}


async def handle_client(reader: asyncio.StreamReader,
                        writer: asyncio.StreamWriter,
                        server: MeetingSTTServer) -> None:
    """Handle incoming audio stream connection from phone."""
    addr = writer.get_extra_info("peername")
    logger.info(f"Connection from {addr}")

    try:
        # Read header: channel tag + metadata
        header = await reader.readline()
        meta = json.loads(header.decode())
        channel = meta.get("channel", "remote")
        logger.info(f"Stream started: channel={channel}")

        while True:
            # Read 20ms PCM frames (640 bytes at 16kHz 16-bit mono)
            data = await reader.read(640)
            if not data:
                break
            await server.receive_audio_chunk(channel, data)

            # Process in chunks
            caption = await server.process_chunk(channel)
            if caption:
                response = json.dumps({
                    "speaker": caption.speaker,
                    "text": caption.text,
                    "timestamp_ms": caption.timestamp_ms,
                }) + "\n"
                writer.write(response.encode())
                await writer.drain()

    except asyncio.CancelledError:
        pass
    except Exception as e:
        logger.error(f"Stream error: {e}")
    finally:
        writer.close()
        await writer.wait_closed()
        logger.info(f"Connection closed: {addr}")


async def main(host: str, port: int) -> None:
    server = MeetingSTTServer()

    async def client_handler(r, w):
        await handle_client(r, w, server)

    tcp_server = await asyncio.start_server(client_handler, host, port)
    addrs = ", ".join(str(s.getsockname()) for s in tcp_server.sockets)
    logger.info(f"Meeting STT server listening on {addrs}")

    async with tcp_server:
        await tcp_server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Cervos Meeting STT Server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8083)
    args = parser.parse_args()

    asyncio.run(main(args.host, args.port))
