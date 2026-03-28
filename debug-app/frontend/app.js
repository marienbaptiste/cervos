// Cervos Debug — Frontend logic
// Handles mic recording, file upload, API calls, and result display.

const API = '';  // Same origin (backend serves frontend)

// ── State ──────────────────────────────────────────────────────────────────

let audioContext = null;
let audioStream = null;
let scriptNode = null;
let recordedBuffers = [];
let isRecording = false;
let vuMeterNode = null;
let vuAnimFrame = null;

// ── DOM refs ───────────────────────────────────────────────────────────────

const els = {};
function $(id) { return document.getElementById(id); }

document.addEventListener('DOMContentLoaded', () => {
  els.statusDot      = $('status-dot');
  els.statusText     = $('status-text');
  els.whisperUrl     = $('whisper-url');
  els.urlSave        = $('url-save');
  els.bleSim         = $('ble-sim');
  els.diarize        = $('diarize');
  els.recordBtn      = $('record-btn');
  els.recordLabel     = $('record-label');
  els.dropZone       = $('drop-zone');
  els.fileInput      = $('file-input');
  els.fileName       = $('file-name');
  els.transcribeBtn  = $('transcribe-btn');
  els.resultSection  = $('result-section');
  els.resultText     = $('result-text');
  els.segmentsList   = $('segments-list');
  els.pipelineViz    = $('pipeline-viz');
  els.statsGrid      = $('stats-grid');
  els.bleSection     = $('ble-section');
  els.hexDump        = $('hex-dump');
  els.audioCompare   = $('audio-compare');
  els.audioOriginal  = $('audio-original');
  els.audioDecoded   = $('audio-decoded');
  els.errorMsg       = $('error-msg');
  els.spinner        = $('spinner');

  setupEventListeners();
  checkHealth();
});


// ── Event listeners ────────────────────────────────────────────────────────

function setupEventListeners() {
  // Settings
  els.urlSave.addEventListener('click', saveSettings);

  // Recording
  els.recordBtn.addEventListener('click', toggleRecording);

  // File upload
  els.dropZone.addEventListener('click', () => els.fileInput.click());
  els.fileInput.addEventListener('change', handleFileSelect);
  els.dropZone.addEventListener('dragover', e => {
    e.preventDefault();
    els.dropZone.classList.add('dragover');
  });
  els.dropZone.addEventListener('dragleave', () => {
    els.dropZone.classList.remove('dragover');
  });
  els.dropZone.addEventListener('drop', e => {
    e.preventDefault();
    els.dropZone.classList.remove('dragover');
    if (e.dataTransfer.files.length) {
      els.fileInput.files = e.dataTransfer.files;
      handleFileSelect();
    }
  });

  // Transcribe
  els.transcribeBtn.addEventListener('click', transcribe);
}


// ── Health check ───────────────────────────────────────────────────────────

async function checkHealth() {
  try {
    const r = await fetch(`${API}/api/health`);
    const data = await r.json();
    if (data.whisper_reachable) {
      els.statusDot.className = 'status-dot ok';
      els.statusText.textContent = 'whisper.cpp connected';
    } else {
      els.statusDot.className = 'status-dot err';
      els.statusText.textContent = `whisper.cpp unreachable: ${data.whisper_error || 'unknown'}`;
    }
  } catch (e) {
    els.statusDot.className = 'status-dot err';
    els.statusText.textContent = 'Backend unreachable';
  }
}


// ── Settings ───────────────────────────────────────────────────────────────

async function saveSettings() {
  const url = els.whisperUrl.value.trim();
  if (!url) return;
  try {
    await fetch(`${API}/api/settings`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ whisper_url: url }),
    });
    checkHealth();
  } catch (e) {
    showError(`Failed to save settings: ${e.message}`);
  }
}


// ── Recording ──────────────────────────────────────────────────────────────

async function toggleRecording() {
  if (isRecording) {
    stopRecording();
  } else {
    await startRecording();
  }
}

async function startRecording() {
  try {
    audioStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    // Use browser's native sample rate for compatibility
    audioContext = new AudioContext();
    const source = audioContext.createMediaStreamSource(audioStream);

    // VU meter via AnalyserNode
    vuMeterNode = audioContext.createAnalyser();
    vuMeterNode.fftSize = 256;
    source.connect(vuMeterNode);
    startVuMeter();

    // Capture raw PCM via ScriptProcessor (4096 buffer, mono)
    scriptNode = audioContext.createScriptProcessor(4096, 1, 1);
    recordedBuffers = [];

    scriptNode.onaudioprocess = e => {
      const data = e.inputBuffer.getChannelData(0);
      recordedBuffers.push(new Float32Array(data));
    };

    source.connect(scriptNode);
    scriptNode.connect(audioContext.destination);

    isRecording = true;
    els.recordBtn.classList.add('recording');
    els.recordLabel.textContent = 'Stop';
  } catch (e) {
    showError(`Microphone access denied: ${e.message}`);
  }
}

function stopRecording() {
  if (scriptNode) {
    scriptNode.disconnect();
    scriptNode = null;
  }
  stopVuMeter();
  if (audioStream) {
    audioStream.getTracks().forEach(t => t.stop());
    audioStream = null;
  }

  // Build WAV from captured PCM buffers
  const totalSamples = recordedBuffers.reduce((n, b) => n + b.length, 0);
  const pcm = new Float32Array(totalSamples);
  let offset = 0;
  for (const buf of recordedBuffers) {
    pcm.set(buf, offset);
    offset += buf.length;
  }
  recordedBuffers = [];

  const wavBlob = encodeWav(pcm, audioContext ? audioContext.sampleRate : 16000);
  if (audioContext) {
    audioContext.close();
    audioContext = null;
  }

  setAudioFile(wavBlob, 'recording.wav');
  isRecording = false;
  els.recordBtn.classList.remove('recording');
  els.recordLabel.textContent = 'Record';
}

function encodeWav(pcm, sampleRate) {
  const numSamples = pcm.length;
  const buffer = new ArrayBuffer(44 + numSamples * 2);
  const view = new DataView(buffer);

  // WAV header
  writeString(view, 0, 'RIFF');
  view.setUint32(4, 36 + numSamples * 2, true);
  writeString(view, 8, 'WAVE');
  writeString(view, 12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);       // PCM
  view.setUint16(22, 1, true);       // mono
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);       // block align
  view.setUint16(34, 16, true);      // bits per sample
  writeString(view, 36, 'data');
  view.setUint32(40, numSamples * 2, true);

  // Convert float32 to int16
  for (let i = 0; i < numSamples; i++) {
    const s = Math.max(-1, Math.min(1, pcm[i]));
    view.setInt16(44 + i * 2, s * 0x7FFF, true);
  }

  return new Blob([buffer], { type: 'audio/wav' });
}

function writeString(view, offset, str) {
  for (let i = 0; i < str.length; i++) {
    view.setUint8(offset + i, str.charCodeAt(i));
  }
}

// ── VU Meter ─────────────────────────────────────────────────────────────

function startVuMeter() {
  const canvas = document.getElementById('vu-meter');
  if (!canvas || !vuMeterNode) return;
  canvas.classList.remove('hidden');
  const ctx = canvas.getContext('2d');
  const bufLen = vuMeterNode.frequencyBinCount;
  const dataArray = new Uint8Array(bufLen);

  function draw() {
    vuAnimFrame = requestAnimationFrame(draw);
    vuMeterNode.getByteTimeDomainData(dataArray);

    // Compute RMS
    let sum = 0;
    for (let i = 0; i < bufLen; i++) {
      const v = (dataArray[i] - 128) / 128;
      sum += v * v;
    }
    const rms = Math.sqrt(sum / bufLen);
    const level = Math.min(1, rms * 3);  // scale up for visibility

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
  if (vuAnimFrame) {
    cancelAnimationFrame(vuAnimFrame);
    vuAnimFrame = null;
  }
  const canvas = document.getElementById('vu-meter');
  if (canvas) {
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#1E1F22';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    canvas.classList.add('hidden');
  }
}


// ── File handling ──────────────────────────────────────────────────────────

let currentFile = null;

function handleFileSelect() {
  const file = els.fileInput.files[0];
  if (file) setAudioFile(file, file.name);
}

function setAudioFile(blob, name) {
  currentFile = new File([blob], name, { type: blob.type || 'audio/wav' });
  els.fileName.textContent = `${name} (${formatSize(blob.size)})`;
  els.transcribeBtn.disabled = false;
  hideError();
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1048576).toFixed(1)} MB`;
}


// ── Transcribe ─────────────────────────────────────────────────────────────

async function transcribe() {
  if (!currentFile) return;

  const simulateBle = els.bleSim.checked;
  const diarize = els.diarize.checked;

  // Show loading state
  els.transcribeBtn.disabled = true;
  els.spinner.classList.remove('hidden');
  els.resultSection.classList.remove('hidden');
  els.resultText.textContent = '';
  els.segmentsList.innerHTML = '';
  els.statsGrid.innerHTML = '';
  els.bleSection.classList.add('hidden');
  hideError();

  const formData = new FormData();
  formData.append('file', currentFile);

  const params = new URLSearchParams({
    simulate_ble: simulateBle,
    diarize: diarize,
  });

  try {
    const r = await fetch(`${API}/api/transcribe?${params}`, {
      method: 'POST',
      body: formData,
    });

    const data = await r.json();

    if (!r.ok) {
      showError(data.error || `Request failed (${r.status})`);
      if (data.pipeline_info) renderStats(data.pipeline_info);
      return;
    }

    // Render results
    renderTranscription(data.text, data.segments);
    renderStats(data.pipeline_info);
    renderPipeline(data.pipeline_info);

    // If BLE sim was on, also fetch the BLE details
    if (simulateBle) {
      await fetchBleDetails();
    }
  } catch (e) {
    showError(`Request failed: ${e.message}`);
  } finally {
    els.transcribeBtn.disabled = false;
    els.spinner.classList.add('hidden');
  }
}

async function fetchBleDetails() {
  if (!currentFile) return;

  const formData = new FormData();
  formData.append('file', currentFile);

  try {
    const r = await fetch(`${API}/api/simulate-ble`, {
      method: 'POST',
      body: formData,
    });
    const data = await r.json();

    els.bleSection.classList.remove('hidden');

    // Hex dump
    if (data.ble_packet_samples) {
      els.hexDump.textContent = data.ble_packet_samples.join('\n');
    }

    // Audio comparison
    if (data.original_audio_b64 && data.decoded_audio_b64) {
      els.audioCompare.classList.remove('hidden');
      els.audioOriginal.src = `data:audio/wav;base64,${data.original_audio_b64}`;
      els.audioDecoded.src = `data:audio/wav;base64,${data.decoded_audio_b64}`;
    }
  } catch (e) {
    // Non-critical, don't show error
    console.warn('BLE details fetch failed:', e);
  }
}


// ── Rendering ──────────────────────────────────────────────────────────────

function renderTranscription(text, segments) {
  // Check for speaker turn markers [SPEAKER_TURN] from tinydiarize
  const formatted = text.replace(/\[SPEAKER_TURN\]/g, '\n---\n');
  els.resultText.textContent = formatted.trim() || '(no speech detected)';

  els.segmentsList.innerHTML = '';
  if (segments && segments.length) {
    for (const seg of segments) {
      const div = document.createElement('div');
      div.className = 'segment';
      const t0 = formatTimestamp(seg.t0 ?? seg.start ?? 0);
      const t1 = formatTimestamp(seg.t1 ?? seg.end ?? 0);
      div.innerHTML = `
        <span class="segment-time">${t0} - ${t1}</span>
        <span>${escapeHtml(seg.text || '')}</span>
      `;
      els.segmentsList.appendChild(div);
    }
  }
}

function renderStats(info) {
  if (!info) return;

  const stats = [
    { label: 'Duration', value: `${info.original_duration_s || 0}s` },
    { label: 'Whisper time', value: `${info.whisper_processing_ms || '—'}ms` },
    { label: 'Total pipeline', value: `${info.total_pipeline_ms || '—'}ms` },
  ];

  if (info.simulate_ble) {
    stats.push(
      { label: 'LC3 frames', value: info.lc3_frames_encoded || 0 },
      { label: 'Compression', value: `${info.compression_ratio || 0}x` },
      { label: 'LC3 bytes', value: formatSize(info.total_lc3_bytes || 0) },
    );
  }

  els.statsGrid.innerHTML = stats.map(s => `
    <div class="stat-card">
      <div class="stat-value">${s.value}</div>
      <div class="stat-label">${s.label}</div>
    </div>
  `).join('');
}

function renderPipeline(info) {
  if (!info) return;

  const steps = ['Input audio'];
  if (info.simulate_ble) {
    steps.push('24kHz resample', `LC3 encode (${info.lc3_frames_encoded}×60B)`,
               'BLE packets', 'LC3 decode', '16kHz resample');
  } else {
    steps.push('16kHz resample');
  }
  steps.push('whisper.cpp');

  els.pipelineViz.innerHTML = steps.map((s, i) => {
    const arrow = i < steps.length - 1 ? '<span class="pipeline-arrow">&rarr;</span>' : '';
    return `<span class="pipeline-step">${s}</span>${arrow}`;
  }).join('');
}


// ── Helpers ────────────────────────────────────────────────────────────────

function formatTimestamp(ms) {
  // whisper.cpp returns timestamps in various formats; normalize
  const totalSec = typeof ms === 'number' ? ms / 1000 : 0;
  const min = Math.floor(totalSec / 60);
  const sec = (totalSec % 60).toFixed(1);
  return `${min}:${sec.padStart(4, '0')}`;
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

function showError(msg) {
  els.errorMsg.textContent = msg;
  els.errorMsg.classList.remove('hidden');
}

function hideError() {
  els.errorMsg.classList.add('hidden');
}
