// Cervos Voice Service — Real-time streaming STT frontend
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
let shownSegments = new Set();
let allSegments = {};    // keyed by start time — the full transcript
let speakerMap = {};     // start time → { id, name }
let speakerTurns = [];   // raw diarization timeline from backend

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
  els.speakersList = $('speakers-list');
  els.speakerCount = $('speaker-count');
  els.refreshSpeakers = $('refresh-speakers');

  els.simThreshold  = $('similarity-threshold');
  els.simValue      = $('similarity-value');
  els.minSpeech     = $('min-speech');
  els.minSpeechVal  = $('min-speech-value');

  els.streamBtn.addEventListener('click', toggleStream);
  els.clearBtn.addEventListener('click', clearTranscripts);
  els.refreshSpeakers.addEventListener('click', loadSpeakers);
  els.streamHint = $('stream-hint');

  // Diarization sliders — update display + send to backend live
  els.simThreshold.addEventListener('input', () => {
    els.simValue.textContent = els.simThreshold.value;
  });
  els.simThreshold.addEventListener('change', sendDiarizeConfig);
  els.minSpeech.addEventListener('input', () => {
    els.minSpeechVal.textContent = els.minSpeech.value;
  });
  els.minSpeech.addEventListener('change', sendDiarizeConfig);
  els.deviceSelect = $('device-select');
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

  // Show/hide device picker based on source mode
  document.querySelectorAll('input[name="audio-source"]').forEach(radio => {
    radio.addEventListener('change', () => {
      els.deviceSelect.classList.toggle('hidden', getAudioSource() === 'system');
    });
  });

  checkHealth();
  loadSpeakers();
  loadDiarizeConfig();
  enumerateAudioDevices();
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

function getAudioSource() {
  const sel = document.querySelector('input[name="audio-source"]:checked');
  return sel ? sel.value : 'mic';
}

async function enumerateAudioDevices() {
  try {
    // Need a brief getUserMedia call to get permission, then enumerate
    const tempStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    tempStream.getTracks().forEach(t => t.stop());

    const devices = await navigator.mediaDevices.enumerateDevices();
    const audioInputs = devices.filter(d => d.kind === 'audioinput');

    els.deviceSelect.innerHTML = '<option value="">Default mic</option>';
    for (const dev of audioInputs) {
      const opt = document.createElement('option');
      opt.value = dev.deviceId;
      opt.textContent = dev.label || `Mic ${els.deviceSelect.options.length}`;
      els.deviceSelect.appendChild(opt);
    }
  } catch {
    // Permission denied or no devices — leave default
  }
}

async function startStream() {
  const source_type = getAudioSource();

  try {
    // Ensure clean state
    if (audioContext) { audioContext.close().catch(() => {}); audioContext = null; }
    if (audioStream) { audioStream.getTracks().forEach(t => t.stop()); audioStream = null; }

    // Create AudioContext FIRST — must happen synchronously in the click handler
    // chain (before any await) so Chrome's autoplay policy treats it as user-initiated
    audioContext = new AudioContext();

    // Acquire audio stream based on selected source
    if (source_type === 'system') {
      // System audio capture via getDisplayMedia — Chrome/Edge only.
      // Firefox doesn't support audio in getDisplayMedia at all.
      // For Firefox/Safari, use Mic mode with a virtual audio device (VB-Cable, BlackHole).
      const isFirefox = navigator.userAgent.includes('Firefox');
      if (isFirefox) {
        throw new Error(
          'Firefox doesn\'t support system audio capture. ' +
          'Use Chrome/Edge, or switch to Mic mode with a virtual audio device (VB-Cable on Windows, BlackHole on Mac).'
        );
      }

      let displayStream;
      try {
        displayStream = await navigator.mediaDevices.getDisplayMedia({
          video: true,
          audio: true,
          systemAudio: 'include',
        });
      } catch {
        displayStream = await navigator.mediaDevices.getDisplayMedia({
          video: true,
          audio: true,
        });
      }

      // Drop the video track immediately — we only need audio
      displayStream.getVideoTracks().forEach(t => t.stop());
      const audioTrack = displayStream.getAudioTracks()[0];
      if (!audioTrack) {
        throw new Error(
          'No audio track received. Select "Entire Screen" and check "Share system audio". ' +
          'Or switch to Mic mode with a virtual audio device.'
        );
      }
      audioStream = new MediaStream([audioTrack]);
      audioTrack.addEventListener('ended', () => { if (isStreaming) stopStream(); });
    } else {
      // Mic mode — use selected device or default
      const deviceId = els.deviceSelect.value;
      const audioConstraints = {
        echoCancellation: true,
        noiseSuppression: true,
        sampleRate: SAMPLE_RATE,
      };
      if (deviceId) audioConstraints.deviceId = { exact: deviceId };
      audioStream = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints });
    }

    // Resume AudioContext after media prompt (Chrome sometimes suspends during dialog)
    if (audioContext.state === 'suspended') {
      await audioContext.resume();
    }

    // Open WebSocket and wait for it to be ready before piping audio
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(`${proto}//${location.host}/ws/stream`);
    ws.binaryType = 'arraybuffer';

    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = () => reject(new Error('WebSocket connection failed'));
      setTimeout(() => reject(new Error('WebSocket connection timeout')), 5000);
    });

    // Send config
    ws.send(JSON.stringify({
      action: 'config',
      simulate_ble: els.bleSim.checked,
      language: $('lang-select').value || null,
    }));

    ws.onmessage = e => {
      const data = JSON.parse(e.data);
      console.log('WS msg:', JSON.stringify(data).slice(0, 200));

      // Speaker turns — streaming diarization with persistent IDs, arrives every 500ms
      if (data.type === 'speaker_turns' && data.turns) {
        // Accumulate turns across all windows (don't replace)
        for (const turn of data.turns) {
          speakerTurns.push(turn);
        }
        // Cap to prevent unbounded growth in long sessions
        if (speakerTurns.length > 2000) {
          speakerTurns = speakerTurns.slice(-1000);
        }

        // Build a name lookup from all known speaker IDs
        const nameById = {};
        for (const turn of speakerTurns) {
          if (turn.speaker_name) nameById[turn.speaker_id] = turn.speaker_name;
        }

        // Match all completed segments against full turn history
        for (const key of Object.keys(allSegments)) {
          const seg = allSegments[key];
          if (!seg.completed) continue;
          const sStart = parseFloat(seg.start);
          const sEnd = parseFloat(seg.end);
          let bestTurn = null, bestOverlap = 0;
          for (const turn of speakerTurns) {
            const overlap = Math.max(0, Math.min(sEnd, turn.end) - Math.max(sStart, turn.start));
            if (overlap > bestOverlap) {
              bestOverlap = overlap;
              bestTurn = turn;
            }
          }
          if (bestTurn) {
            speakerMap[seg.start] = {
              id: bestTurn.speaker_id,
              name: nameById[bestTurn.speaker_id] || bestTurn.speaker_name,
            };
          }
        }

        // Propagate names to all previously mapped segments
        for (const key of Object.keys(speakerMap)) {
          const name = nameById[speakerMap[key].id];
          if (name) speakerMap[key].name = name;
        }

        renderTranscript();
        return;
      }

      // WhisperLive segment update
      const segments = data.segments;
      if (segments && segments.length > 0) {
        // Remove old pending segments — only keep completed ones + fresh pending
        for (const key of Object.keys(allSegments)) {
          if (!allSegments[key].completed) delete allSegments[key];
        }
        for (const seg of segments) {
          allSegments[seg.start] = seg;
        }
        renderTranscript();
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

    // Now wire up audio — WS is open, AudioContext is running, stream is active
    const audioSource = audioContext.createMediaStreamSource(audioStream);

    // VU meter
    analyserNode = audioContext.createAnalyser();
    analyserNode.fftSize = 256;
    audioSource.connect(analyserNode);
    startVuMeter();

    // PCM capture via ScriptProcessor → downmix to mono → resample → send as binary
    // System audio may be stereo, so we request 2 input channels and mix down
    const inputChannels = source_type === 'system' ? 2 : 1;
    const scriptNode = audioContext.createScriptProcessor(4096, inputChannels, 1);
    const nativeRate = audioContext.sampleRate;

    scriptNode.onaudioprocess = e => {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      let mono;
      if (inputChannels === 2) {
        const left = e.inputBuffer.getChannelData(0);
        const right = e.inputBuffer.numberOfChannels > 1 ? e.inputBuffer.getChannelData(1) : left;
        mono = new Float32Array(left.length);
        for (let i = 0; i < left.length; i++) mono[i] = (left[i] + right[i]) * 0.5;
      } else {
        mono = e.inputBuffer.getChannelData(0);
      }
      const pcm16k = resampleBuffer(mono, nativeRate, SAMPLE_RATE);
      ws.send(pcm16k.buffer);
    };

    audioSource.connect(scriptNode);
    scriptNode.connect(audioContext.destination);
    workletNode = scriptNode;

    isStreaming = true;
    els.streamBtn.classList.add('recording');
    els.streamLabel.textContent = 'Stop';
    els.streamHint.textContent = source_type === 'system' ? 'Capturing system audio' : 'Capturing microphone';
    els.liveText.textContent = 'Listening...';
    els.liveText.classList.remove('hidden');

  } catch (e) {
    // Clean up partial state on failure
    if (audioStream) { audioStream.getTracks().forEach(t => t.stop()); audioStream = null; }
    if (audioContext && audioContext.state !== 'closed') { audioContext.close().catch(() => {}); }
    audioContext = null;
    if (ws) { ws.close(); ws = null; }
    els.liveText.textContent = `Error: ${e.message}`;
    els.liveText.classList.remove('hidden');
  }
}

function stopStream() {
  // Flush remaining audio
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ action: 'flush' }));
    setTimeout(() => {
      if (ws) { ws.close(); ws = null; }
    }, 500);
  } else {
    ws = null;
  }

  // Cleanup audio in correct order: nodes → stream → context
  stopVuMeter();
  if (workletNode) { workletNode.onaudioprocess = null; workletNode.disconnect(); workletNode = null; }
  analyserNode = null;
  if (audioStream) { audioStream.getTracks().forEach(t => t.stop()); audioStream = null; }
  if (audioContext && audioContext.state !== 'closed') {
    audioContext.close().catch(() => {});
  }
  audioContext = null;

  isStreaming = false;
  els.streamBtn.classList.remove('recording');
  els.streamLabel.textContent = 'Stream';
  els.streamHint.textContent = 'Real-time audio → STT';
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

  // Add to transcript list
  const div = document.createElement('div');
  div.className = 'transcript-entry';
  // Tag with segment key so speaker updates can find it later
  if (data._segKey) div.dataset.segKey = data._segKey;

  const lang = data.language ? `[${data.language}]` : '';
  const latency = data.latency_ms ? `${data.latency_ms}ms` : '';
  const duration = data.audio_duration_s ? `${data.audio_duration_s}s` : '';
  const diarize = data.diarize_ms ? `diarize ${data.diarize_ms}ms` : '';
  const stt = data.transcribe_ms ? `stt ${data.transcribe_ms}ms` : '';

  div.innerHTML = `
    <span class="speaker-tag"></span>
    <div class="transcript-text">${escapeHtml(data.text)}</div>
    <div class="transcript-meta">
      ${lang ? `<span class="meta-tag">${lang}</span>` : ''}
      ${stt ? `<span class="meta-tag">${stt}</span>` : ''}
      ${diarize ? `<span class="meta-tag">${diarize}</span>` : ''}
      ${duration ? `<span class="meta-tag">${duration} audio</span>` : ''}
      ${latency ? `<span class="meta-tag">total ${latency}</span>` : ''}
    </div>
  `;
  els.transcripts.prepend(div);

  // Cap DOM nodes to prevent memory growth in long sessions
  const MAX_TRANSCRIPT_ENTRIES = 200;
  while (els.transcripts.children.length > MAX_TRANSCRIPT_ENTRIES) {
    els.transcripts.removeChild(els.transcripts.lastChild);
  }
  // Also cap the in-memory array
  if (transcripts.length > MAX_TRANSCRIPT_ENTRIES) {
    transcripts = transcripts.slice(-MAX_TRANSCRIPT_ENTRIES);
  }

  // Update stats bar
  if (data.latency_ms) {
    els.statsBar.textContent = `Last: ${stt} + ${diarize || 'no diarize'} = ${latency} total · ${duration} audio · ${lang}`;
  }
}

function clearTranscripts() {
  transcripts = [];
  shownSegments = new Set();
  allSegments = {};
  speakerMap = {};
  speakerTurns = [];
  els.transcripts.innerHTML = '';
  els.liveText.textContent = '';
  els.liveText.classList.add('hidden');
  els.statsBar.textContent = '';
}

function renderTranscript() {
  // Sort segments by start time
  const sorted = Object.values(allSegments)
    .sort((a, b) => parseFloat(a.start) - parseFloat(b.start));

  if (sorted.length === 0) return;

  // Split into completed and pending
  const completed = sorted.filter(s => s.completed);
  const pending = sorted.filter(s => !s.completed);

  // Show only truly new pending text (not yet in any completed segment)
  const completedTexts = new Set(completed.map(s => s.text.trim()));
  const newPending = pending.filter(s => !completedTexts.has(s.text.trim()));
  if (newPending.length > 0) {
    els.liveText.textContent = newPending.map(s => s.text).join(' ');
    els.liveText.classList.remove('hidden');
  } else {
    els.liveText.textContent = '';
    els.liveText.classList.add('hidden');
  }

  // Build grouped transcript — merge consecutive segments from same speaker
  const groups = [];
  let currentGroup = null;

  for (const seg of completed) {
    const speaker = speakerMap[seg.start];
    const speakerId = speaker?.id || null;

    if (currentGroup && speakerId !== null && currentGroup.speakerId === speakerId) {
      // Same known speaker — append to current group
      currentGroup.texts.push(seg.text);
      currentGroup.end = seg.end;
    } else {
      // New speaker or first segment
      currentGroup = {
        speakerId,
        speakerName: speaker?.name || null,
        texts: [seg.text],
        start: seg.start,
        end: seg.end,
      };
      groups.push(currentGroup);
    }
  }

  // Build new HTML and only update if changed (prevents blinking)
  let html = '';
  for (const group of groups) {
    const label = group.speakerName || (group.speakerId ? group.speakerId.slice(0, 12) : null);
    const labelHtml = label
      ? `<div class="speaker-tag visible"><span class="speaker-label clickable" onclick="promptRenameSpeaker('${group.speakerId}', this)">${escapeHtml(label)}</span></div>`
      : '';

    html += `<div class="transcript-entry">
      ${labelHtml}
      <div class="transcript-text">${escapeHtml(group.texts.join(' '))}</div>
    </div>`;
  }

  // Skip DOM updates if user is interacting with an input (e.g. renaming a speaker)
  const activeEl = document.activeElement;
  if (activeEl && (activeEl.tagName === 'INPUT' || activeEl.isContentEditable) &&
      els.transcripts.contains(activeEl)) {
    return;
  }

  const wasAtBottom = els.transcripts.scrollHeight - els.transcripts.scrollTop - els.transcripts.clientHeight < 50;
  const existing = els.transcripts.children;
  const hadGroups = existing.length;

  for (let i = 0; i < groups.length; i++) {
    const group = groups[i];
    const label = group.speakerName || (group.speakerId ? group.speakerId.slice(0, 12) : null);
    const text = group.texts.join(' ');

    if (i < existing.length) {
      // Update existing entry — only touch what changed
      const entry = existing[i];
      const textEl = entry.querySelector('.transcript-text');
      if (textEl && textEl.textContent !== text) {
        textEl.textContent = text;
      }
      // Update speaker label
      const tagEl = entry.querySelector('.speaker-tag');
      if (label) {
        if (!tagEl) {
          const tag = document.createElement('div');
          tag.className = 'speaker-tag visible';
          tag.innerHTML = `<span class="speaker-label clickable" onclick="promptRenameSpeaker('${group.speakerId}', this)">${escapeHtml(label)}</span>`;
          entry.insertBefore(tag, entry.firstChild);
        } else if (tagEl.textContent !== label) {
          tagEl.innerHTML = `<span class="speaker-label clickable" onclick="promptRenameSpeaker('${group.speakerId}', this)">${escapeHtml(label)}</span>`;
          tagEl.classList.add('visible');
        }
      }
    } else {
      // New group — append
      const entry = document.createElement('div');
      entry.className = 'transcript-entry';
      if (label) {
        const tag = document.createElement('div');
        tag.className = 'speaker-tag visible';
        tag.innerHTML = `<span class="speaker-label clickable" onclick="promptRenameSpeaker('${group.speakerId}', this)">${escapeHtml(label)}</span>`;
        entry.appendChild(tag);
      }
      const textEl = document.createElement('div');
      textEl.className = 'transcript-text';
      textEl.textContent = text;
      entry.appendChild(textEl);
      els.transcripts.appendChild(entry);
    }
  }
  // Remove extras
  while (els.transcripts.children.length > groups.length) {
    els.transcripts.removeChild(els.transcripts.lastChild);
  }

  if (wasAtBottom || hadGroups === 0) {
    els.transcripts.scrollTop = els.transcripts.scrollHeight;
  }
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


// ── Speaker Profiles ──────────────────────────────────────────────────────

async function loadDiarizeConfig() {
  try {
    const r = await fetch('/api/diarize-config');
    const data = await r.json();
    if (data.similarity_threshold != null) {
      els.simThreshold.value = data.similarity_threshold;
      els.simValue.textContent = data.similarity_threshold;
    }
    if (data.min_speech_s != null) {
      els.minSpeech.value = data.min_speech_s;
      els.minSpeechVal.textContent = data.min_speech_s;
    }
  } catch { /* backend not ready */ }
}

async function sendDiarizeConfig() {
  const config = {
    similarity_threshold: parseFloat(els.simThreshold.value),
    min_speech_s: parseFloat(els.minSpeech.value),
  };
  // Send via REST (works whether streaming or not)
  try {
    await fetch('/api/diarize-config', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(config),
    });
  } catch { /* backend not ready */ }
}

async function loadSpeakers() {
  try {
    const r = await fetch('/api/speakers');
    const data = await r.json();
    renderSpeakers(data.speakers || []);
  } catch {
    // Backend not ready yet
  }
}

function renderSpeakers(speakers) {
  els.speakerCount.textContent = speakers.length ? `${speakers.length} known` : '';

  if (!speakers.length) {
    els.speakersList.innerHTML = `
      <div style="color:var(--text-disabled);font-size:13px;padding:12px;text-align:center;">
        No speakers detected yet
      </div>`;
    return;
  }

  els.speakersList.innerHTML = speakers.map(s => {
    const name = s.name || '';
    const shortId = s.id.slice(0, 12);
    const samples = s.sample_count || 0;
    const lastSeen = s.last_seen ? new Date(s.last_seen).toLocaleString() : '';

    return `
      <div class="speaker-row" data-id="${s.id}">
        <div class="speaker-id">${shortId}</div>
        <input class="speaker-name-input" type="text" value="${escapeHtml(name)}"
               placeholder="Unknown — click to name"
               onchange="renameSpeaker('${s.id}', this.value)">
        <div class="speaker-meta">
          <span class="meta-tag">${samples} samples</span>
          <span class="meta-tag">${lastSeen}</span>
        </div>
        <button class="btn-icon" onclick="deleteSpeaker('${s.id}')" title="Delete">&#x2715;</button>
      </div>`;
  }).join('');
}

async function renameSpeaker(id, name) {
  await fetch(`/api/speakers/${id}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name }),
  });
  loadSpeakers();
}

async function deleteSpeaker(id) {
  await fetch(`/api/speakers/${id}`, { method: 'DELETE' });
  loadSpeakers();
}

function promptRenameSpeaker(id, el) {
  const current = el.textContent;
  const name = prompt(`Name for ${id}:`, current.startsWith('spk_') ? '' : current);
  if (name !== null) {
    renameSpeaker(id, name);
    // Update all instances of this speaker in the transcript view
    document.querySelectorAll(`.speaker-label[onclick*="${id}"]`).forEach(span => {
      span.textContent = name || id.slice(0, 12);
    });
  }
}

async function resetAllSpeakers() {
  if (!confirm('Delete all speaker profiles? This cannot be undone.')) return;
  const r = await fetch('/api/speakers');
  const data = await r.json();
  for (const s of (data.speakers || [])) {
    await fetch(`/api/speakers/${s.id}`, { method: 'DELETE' });
  }
  loadSpeakers();
}
