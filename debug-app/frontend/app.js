// Cervos Debug — Real-time streaming STT frontend
// WebSocket streams PCM chunks from mic → backend → live transcription

const SAMPLE_RATE = 16000;
const CHUNK_MS = 100;  // send audio every 100ms
const CHUNK_SAMPLES = SAMPLE_RATE * CHUNK_MS / 1000;  // 1600 samples

// ── State ──────────────────────────────────────────────────────────────────

let ws = null;
let audioContext = null;
let audioStream = null;
let workletNode = null;
let analyserNode = null;
let vuAnimFrame = null;
let isStreaming = false;
let transcripts = [];

// ── DOM refs ───────────────────────────────────────────────────────────────

const els = {};
function $(id) { return document.getElementById(id); }

document.addEventListener('DOMContentLoaded', () => {
  els.statusDot    = $('status-dot');
  els.statusText   = $('status-text');
  els.bleSim       = $('ble-sim');
  els.streamBtn    = $('stream-btn');
  els.streamLabel  = $('stream-label');
  els.vuMeter      = $('vu-meter');
  els.liveText     = $('live-text');
  els.transcripts  = $('transcripts');
  els.statsBar     = $('stats-bar');
  els.clearBtn     = $('clear-btn');
  els.fileInput    = $('file-input');
  els.dropZone     = $('drop-zone');
  els.fileName     = $('file-name');
  els.uploadBtn    = $('upload-btn');

  els.streamBtn.addEventListener('click', toggleStream);
  els.clearBtn.addEventListener('click', clearTranscripts);
  els.dropZone.addEventListener('click', () => els.fileInput.click());
  els.fileInput.addEventListener('change', handleFileSelect);
  els.uploadBtn.addEventListener('click', uploadFile);
  els.dropZone.addEventListener('dragover', e => { e.preventDefault(); els.dropZone.classList.add('dragover'); });
  els.dropZone.addEventListener('dragleave', () => els.dropZone.classList.remove('dragover'));
  els.dropZone.addEventListener('drop', e => {
    e.preventDefault();
    els.dropZone.classList.remove('dragover');
    if (e.dataTransfer.files.length) { els.fileInput.files = e.dataTransfer.files; handleFileSelect(); }
  });

  checkHealth();
});


// ── Health ─────────────────────────────────────────────────────────────────

async function checkHealth() {
  try {
    const r = await fetch('/api/health');
    const data = await r.json();
    els.statusDot.className = 'status-dot ok';
    els.statusText.textContent = `${data.engine} / ${data.model} / ${data.device}`;
  } catch {
    els.statusDot.className = 'status-dot err';
    els.statusText.textContent = 'Backend unreachable';
  }
}


// ── Streaming ──────────────────────────────────────────────────────────────

async function toggleStream() {
  if (isStreaming) {
    stopStream();
  } else {
    await startStream();
  }
}

async function startStream() {
  try {
    // Open WebSocket
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(`${proto}//${location.host}/ws/stream`);
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => {
      // Send config
      ws.send(JSON.stringify({
        action: 'config',
        simulate_ble: els.bleSim.checked,
      }));
    };

    ws.onmessage = e => {
      const data = JSON.parse(e.data);
      if (data.text) {
        addTranscript(data);
      }
    };

    ws.onerror = () => {
      stopStream();
      els.statusDot.className = 'status-dot err';
      els.statusText.textContent = 'WebSocket error';
    };

    ws.onclose = () => {
      if (isStreaming) stopStream();
    };

    // Open mic at native rate, resample to 16kHz in worklet
    audioStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    audioContext = new AudioContext();
    const source = audioContext.createMediaStreamSource(audioStream);

    // VU meter
    analyserNode = audioContext.createAnalyser();
    analyserNode.fftSize = 256;
    source.connect(analyserNode);
    startVuMeter();

    // PCM capture via ScriptProcessor → resample → send as binary
    const scriptNode = audioContext.createScriptProcessor(4096, 1, 1);
    const nativeRate = audioContext.sampleRate;

    scriptNode.onaudioprocess = e => {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      const input = e.inputBuffer.getChannelData(0);

      // Resample from native rate to 16kHz
      const pcm16k = resampleBuffer(input, nativeRate, SAMPLE_RATE);

      // Send as float32 binary
      ws.send(pcm16k.buffer);
    };

    source.connect(scriptNode);
    scriptNode.connect(audioContext.destination);
    workletNode = scriptNode;

    isStreaming = true;
    els.streamBtn.classList.add('recording');
    els.streamLabel.textContent = 'Stop';
    els.liveText.textContent = 'Listening...';
    els.liveText.classList.remove('hidden');

  } catch (e) {
    els.liveText.textContent = `Error: ${e.message}`;
    els.liveText.classList.remove('hidden');
  }
}

function stopStream() {
  // Flush remaining audio
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ action: 'flush' }));
    // Give a moment for flush response, then close
    setTimeout(() => {
      if (ws) ws.close();
      ws = null;
    }, 500);
  }

  if (workletNode) { workletNode.disconnect(); workletNode = null; }
  stopVuMeter();
  if (audioStream) { audioStream.getTracks().forEach(t => t.stop()); audioStream = null; }
  if (audioContext) { audioContext.close(); audioContext = null; }

  isStreaming = false;
  els.streamBtn.classList.remove('recording');
  els.streamLabel.textContent = 'Stream';
  els.liveText.textContent = '';
  els.liveText.classList.add('hidden');
}


// ── Resampling ─────────────────────────────────────────────────────────────

function resampleBuffer(input, fromRate, toRate) {
  if (fromRate === toRate) return new Float32Array(input);
  const ratio = fromRate / toRate;
  const outLen = Math.round(input.length / ratio);
  const output = new Float32Array(outLen);
  for (let i = 0; i < outLen; i++) {
    const srcIdx = i * ratio;
    const idx = Math.floor(srcIdx);
    const frac = srcIdx - idx;
    output[i] = idx + 1 < input.length
      ? input[idx] * (1 - frac) + input[idx + 1] * frac
      : input[idx] || 0;
  }
  return output;
}


// ── Transcripts ────────────────────────────────────────────────────────────

function addTranscript(data) {
  transcripts.push(data);

  // Update live text
  els.liveText.textContent = data.text;

  // Add to transcript list
  const div = document.createElement('div');
  div.className = 'transcript-entry';

  const lang = data.language ? `[${data.language}]` : '';
  const latency = data.latency_ms ? `${data.latency_ms}ms` : '';
  const duration = data.audio_duration_s ? `${data.audio_duration_s}s` : '';
  const diarize = data.diarize_ms ? `diarize ${data.diarize_ms}ms` : '';
  const stt = data.transcribe_ms ? `stt ${data.transcribe_ms}ms` : '';

  // Format text with speaker labels highlighted
  const formattedText = escapeHtml(data.text)
    .replace(/\[SPEAKER_(\d+)\]/g, '<span class="speaker-label">Speaker $1</span>');

  div.innerHTML = `
    <div class="transcript-text">${formattedText}</div>
    <div class="transcript-meta">
      <span class="meta-tag">${lang}</span>
      <span class="meta-tag">${stt}</span>
      ${diarize ? `<span class="meta-tag">${diarize}</span>` : ''}
      <span class="meta-tag">${duration} audio</span>
      <span class="meta-tag">total ${latency}</span>
    </div>
  `;
  els.transcripts.prepend(div);

  // Update stats bar
  if (data.latency_ms) {
    els.statsBar.textContent = `Last: ${stt} + ${diarize || 'no diarize'} = ${latency} total · ${duration} audio · ${lang}`;
  }
}

function clearTranscripts() {
  transcripts = [];
  els.transcripts.innerHTML = '';
  els.statsBar.textContent = '';
}


// ── File upload (batch mode) ───────────────────────────────────────────────

let currentFile = null;

function handleFileSelect() {
  const file = els.fileInput.files[0];
  if (file) {
    currentFile = file;
    els.fileName.textContent = `${file.name} (${formatSize(file.size)})`;
    els.uploadBtn.disabled = false;
  }
}

async function uploadFile() {
  if (!currentFile) return;
  els.uploadBtn.disabled = true;
  els.uploadBtn.textContent = 'Processing...';

  const formData = new FormData();
  formData.append('file', currentFile);
  const params = new URLSearchParams({ simulate_ble: els.bleSim.checked });

  try {
    const r = await fetch(`/api/transcribe?${params}`, { method: 'POST', body: formData });
    const data = await r.json();
    if (data.text) {
      addTranscript({
        text: data.text,
        segments: data.segments,
        language: data.pipeline_info?.language,
        latency_ms: data.pipeline_info?.stt_ms,
        audio_duration_s: data.pipeline_info?.original_duration_s,
      });
    }
  } catch (e) {
    els.liveText.textContent = `Upload failed: ${e.message}`;
    els.liveText.classList.remove('hidden');
  } finally {
    els.uploadBtn.disabled = false;
    els.uploadBtn.textContent = 'Transcribe';
  }
}


// ── VU Meter ───────────────────────────────────────────────────────────────

function startVuMeter() {
  const canvas = els.vuMeter;
  if (!canvas || !analyserNode) return;
  canvas.classList.remove('hidden');
  const ctx = canvas.getContext('2d');
  const bufLen = analyserNode.frequencyBinCount;
  const dataArray = new Uint8Array(bufLen);

  function draw() {
    vuAnimFrame = requestAnimationFrame(draw);
    analyserNode.getByteTimeDomainData(dataArray);

    let sum = 0;
    for (let i = 0; i < bufLen; i++) {
      const v = (dataArray[i] - 128) / 128;
      sum += v * v;
    }
    const rms = Math.sqrt(sum / bufLen);
    const level = Math.min(1, rms * 3);

    ctx.fillStyle = '#1E1F22';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    const barWidth = level * canvas.width;
    const gradient = ctx.createLinearGradient(0, 0, canvas.width, 0);
    gradient.addColorStop(0, '#34A853');
    gradient.addColorStop(0.6, '#FBBC04');
    gradient.addColorStop(1, '#EA4335');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, barWidth, canvas.height);
  }
  draw();
}

function stopVuMeter() {
  if (vuAnimFrame) { cancelAnimationFrame(vuAnimFrame); vuAnimFrame = null; }
  const canvas = els.vuMeter;
  if (canvas) {
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#1E1F22';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    canvas.classList.add('hidden');
  }
}


// ── Helpers ────────────────────────────────────────────────────────────────

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1048576).toFixed(1)} MB`;
}
