/* Català ASR — subtítols catalans en directe al navegador.
 *
 * Motor: micròfon → AudioWorklet (/worklet.js: VAD + remostreig a 16 kHz) → WebSocket
 * Deepgram (nova-3, ca). Crèdits: només s'envien segons amb veu; en silenci s'envia
 * KeepAlive (gratuït) i passats 60 s sense veu la sessió es posa en pausa del tot.
 *
 * Presentació: la mateixa que Subtítol Live — text ancorat a baix, roll-up de 240 ms,
 * paraules noves amb 110 ms d'opacitat, cursor quiet i el camp de soroll taronja.
 */
'use strict';

(() => {

/* ------------------------------------------------------------------ *
 *  Configuració
 * ------------------------------------------------------------------ */

const DG_URL = 'wss://api.deepgram.com/v1/listen';
const DG_PARAMS = {
  model: 'nova-3',
  language: 'ca',
  encoding: 'linear16',
  sample_rate: 16000,
  channels: 1,
  interim_results: 'true',
  endpointing: 300,
  vad_events: 'true',
  utterance_end_ms: 1000,
};

const TOKEN_URL = '/.netlify/functions/dg-token';
const WORKLET_URL = '/worklet.js?v=6';
const IDLE_SLEEP_MS = 60_000;        // sense veu → pausa (0 crèdits, 0 bateria)
const KEEPALIVE_MS = 4_000;          // ping gratuït; Deepgram tanca als 10 s sense res
const SESSION_CAP_MS = 20 * 60_000;  // sostre de seguretat de la demo pública
const MAX_COMMITTED_CHARS = 2400;    // sostre de memòria del DOM
const MAX_PENDING = 60;              // ~6 s d'àudio mentre el socket s'obre
const RECONNECT_DELAYS = [300, 1000, 2500, 5000];

const PARAMS = new URLSearchParams(location.search);
const DEBUG = PARAMS.has('debug');

/* ------------------------------------------------------------------ *
 *  Textos (calcats de SubtitleController.displayText)
 * ------------------------------------------------------------------ */

const PILL = {
  idle: 'Toca per començar',
  connecting: 'Connectant…',
  live: 'Escoltant',
  sending: 'Escoltant',
  paused: 'En pausa',
  resume: 'Toca per activar l’àudio',
  error: 'Sense connexió',
  denied: 'Micròfon bloquejat',
  unsupported: 'No compatible',
};

const STATUS = {
  ready: 'Quan parlis, el text apareixerà aquí.',
  permission: 'Esperant permís per escoltar…',
  listening: 'T’escolto…',
  failed: 'No s’ha pogut iniciar la prova.',
  paused: 'En pausa. Toca per continuar.',
  cap: 'Pausa de la demostració. Toca per continuar.',
  denied: 'Cal permís per fer servir el micròfon. Toca per tornar-ho a provar.',
  noMic: 'No s’ha trobat cap micròfon.',
  network: 'No hi ha connexió amb el servei. Toca per tornar-ho a provar.',
  limited: 'Massa sessions seguides. Espera una estona i torna-ho a provar.',
  unsupported: 'Aquest navegador no pot fer servir el micròfon. Obre la pàgina amb Safari.',
  resume: 'Toca la pantalla per activar l’àudio.',
};

/* ------------------------------------------------------------------ *
 *  DOM
 * ------------------------------------------------------------------ */

const $ = (id) => document.getElementById(id);
const el = {
  app: $('app'),
  reader: $('reader'),
  lines: $('lines'),
  pill: $('pill'),
  pillLabel: $('pill-label'),
  theme: $('theme'),
  viz: $('viz'),
  deco: $('deco'),
  debug: $('debug'),
};

/* ------------------------------------------------------------------ *
 *  Estat
 * ------------------------------------------------------------------ */

let running = false;       // la sessió està activa (o arrencant)
let gateOpen = false;      // el VAD deixa passar veu ara mateix
let audioCtx = null;
let micStream = null;
let workletNode = null;
let ws = null;
let wsOpen = false;
let token = null;
let tokenExpMs = 0;
let pending = [];
let failures = 0;
let bytesSent = 0;
let level = 0;
let idleTimer = 0;
let capTimer = 0;
let keepAliveTimer = 0;
let reconnectTimer = 0;
let flushTailTimer = 0;
let lastAudioAt = 0;
let wakeLock = null;
let session = 0;           // invalida continuacions async d'una sessió anterior

const diag = {
  stage: 'init',
  lastError: '',
  closeCode: '',
  ctx: '',
  track: '',
};
window.__asrDiag = diag;

function setDiag(stage, e) {
  diag.stage = stage;
  if (e) diag.lastError = (e.name || 'Error') + ': ' + (e.message || e);
}

const KEEPALIVE_MSG = JSON.stringify({ type: 'KeepAlive' });
const FINALIZE_MSG = JSON.stringify({ type: 'Finalize' });
const CLOSE_MSG = JSON.stringify({ type: 'CloseStream' });

/* ------------------------------------------------------------------ *
 *  Píndola i tema
 * ------------------------------------------------------------------ */

function setPill(key) {
  el.pill.dataset.state = key;
  el.pillLabel.textContent = PILL[key] || key;
  el.pill.setAttribute('aria-label', (PILL[key] || key) + (running ? '. Toca per aturar' : ''));
}

function applyTheme(mode) {
  document.documentElement.dataset.theme = mode;
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.content = mode === 'dark' ? '#121212' : '#fafafa';
  el.theme.setAttribute('aria-label', mode === 'dark' ? 'Tema clar' : 'Tema fosc');
  try { localStorage.setItem('catala-asr.theme', mode); } catch (_) {}
}

function toggleTheme() {
  applyTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
}

/* ------------------------------------------------------------------ *
 *  Transcripció: text establert + cua viva + cursor quiet
 *
 *  Com FixedFocusTranscriptView: el bloc només es desplaça (240 ms) quan apareix
 *  una línia nova; si la cua es reescriu i perd una línia, aquesta queda reservada
 *  perquè el text ja llegit no salti avall.
 * ------------------------------------------------------------------ */

let committed = '';
let tailWords = [];
let committedNode = null;
let tailSpan = null;
let caret = null;
let highWater = 0;         // línies màximes vistes (per a la reserva i el roll-up)
let reserveLines = 0;
let resetLayout = true;

function showStatus(text) {
  committed = '';
  tailWords = [];
  committedNode = null;
  tailSpan = null;
  caret = null;
  el.lines.textContent = '';
  const s = document.createElement('span');
  s.className = 'status';
  s.textContent = text;
  el.lines.append(s);
  el.lines.style.paddingBottom = '0px';
  el.lines.classList.remove('rolling');
  el.lines.style.transform = '';
  highWater = 0;
  reserveLines = 0;
  resetLayout = true;
}

function hasTranscript() {
  return committedNode !== null && (committed.length > 0 || tailWords.length > 0);
}

function ensureTranscript() {
  if (committedNode) return;
  el.lines.textContent = '';
  committedNode = document.createTextNode('');
  tailSpan = document.createElement('span');
  caret = document.createElement('span');
  caret.className = 'caret';
  caret.textContent = '\u2060';
  caret.setAttribute('aria-hidden', 'true');
  el.lines.append(committedNode, tailSpan, caret);
  highWater = 0;
  reserveLines = 0;
  resetLayout = true;
}

function renderTail(words) {
  // les paraules que ja hi eren es queden quietes; només les noves fan fosa
  let same = 0;
  while (same < words.length && same < tailWords.length && words[same] === tailWords[same]) same++;
  const frag = document.createDocumentFragment();
  for (let i = 0; i < words.length; i++) {
    if (i > 0 || committed) frag.append(' ');
    if (i < same) {
      frag.append(words[i]);
    } else {
      const s = document.createElement('span');
      s.className = 'w-new';
      s.textContent = words[i];
      frag.append(s);
    }
  }
  tailSpan.textContent = '';
  tailSpan.append(frag);
  tailWords = words;
}

function commitText(text) {
  ensureTranscript();
  committed = committed ? committed + ' ' + text : text;
  if (committed.length > MAX_COMMITTED_CHARS) {
    let cut = committed.indexOf(' ', committed.length - MAX_COMMITTED_CHARS);
    if (cut < 0) cut = committed.length - MAX_COMMITTED_CHARS;
    committed = committed.slice(cut).trimStart();
    resetLayout = true; // el retall és invisible (queda per sobre): no és moviment
  }
  committedNode.nodeValue = committed;
  tailSpan.textContent = '';
  tailWords = [];
  updateCaret();
  layoutRoll();
}

function setTail(text) {
  ensureTranscript();
  renderTail(text ? text.split(/\s+/) : []);
  updateCaret();
  layoutRoll();
}

function updateCaret() {
  if (caret) caret.hidden = !(running && hasTranscript());
}

function linePitch() {
  const lh = parseFloat(getComputedStyle(el.lines).lineHeight);
  return Number.isFinite(lh) && lh > 0 ? lh : 40;
}

function layoutRoll() {
  if (!committedNode) return;
  const pitch = linePitch();
  const content = el.lines.offsetHeight - reserveLines * pitch;
  const n = Math.max(1, Math.round(content / pitch));
  if (resetLayout) {
    highWater = n;
    resetLayout = false;
  } else if (n > highWater) {
    const delta = n - highWater;
    highWater = n;
    if (running) {
      el.lines.classList.remove('rolling');
      el.lines.style.transform = `translate3d(0, ${delta * pitch}px, 0)`;
      void el.lines.offsetHeight;
      el.lines.classList.add('rolling');
      el.lines.style.transform = 'translate3d(0, 0, 0)';
    }
  }
  reserveLines = Math.max(0, highWater - n);
  el.lines.style.paddingBottom = reserveLines ? reserveLines * pitch + 'px' : '0px';
}

function flushTail() {
  if (tailWords.length) commitText(tailWords.join(' '));
}

/* ------------------------------------------------------------------ *
 *  Visualitzador: port fidel del ProceduralNoise.metal de l'app.
 *  Camp de soroll píxelat taronja; la veu només accelera la fase (×24),
 *  la paleta i l'escala no canvien mai.
 * ------------------------------------------------------------------ */

const VIZ_VERT = `#version 300 es
void main() {
  float x = (gl_VertexID == 1) ? 3.0 : -1.0;
  float y = (gl_VertexID == 2) ? 3.0 : -1.0;
  gl_Position = vec4(x, y, 0.0, 1.0);
}`;

const VIZ_FRAG = `#version 300 es
precision highp float;
precision highp int;
uniform vec2 viewportSize;
uniform float phase;
uniform float cellBasis;
uniform float cellPx;
out vec4 fragColor;

float hashValue(ivec2 point, uint seed) {
  uint value = uint(point.x) * 0x1F123BB5u;
  value ^= uint(point.y) * 0x5F356495u;
  value ^= seed * 0x9E3779B9u;
  value ^= value >> 16u;
  value *= 0x7FEB352Du;
  value ^= value >> 15u;
  value *= 0x846CA68Bu;
  value ^= value >> 16u;
  return float(value) / 4294967295.0;
}

float valueNoise(vec2 point, uint seed) {
  ivec2 cell = ivec2(floor(point));
  vec2 fraction = fract(point);
  fraction = fraction * fraction * (3.0 - 2.0 * fraction);
  float top = mix(hashValue(cell, seed), hashValue(cell + ivec2(1, 0), seed), fraction.x);
  float bottom = mix(hashValue(cell + ivec2(0, 1), seed), hashValue(cell + ivec2(1, 1), seed), fraction.x);
  return mix(top, bottom, fraction.y);
}

void main() {
  const uint broadSeed = 0x1F123BB5u;
  const uint detailSeed = 0xA53A9E31u;
  float cellSize = max(1.0, cellBasis * (70.0 / 410.0));
  // cellPx > 0 (mòbil): quadrats més petits; el soroll es mostreja en unitats de la
  // cel·la de l'app, així les taques són una mica més petites i hi ha molts més quadrats.
  bool fine = cellPx > 0.0;
  float drawCell = fine ? cellPx : cellSize;
  float zoom = fine ? 2.4 : 1.0;  // i taques una mica més petites, perquè hi càpiguen
  // gl_FragCoord té l'origen a baix-esquerra; Metal [[position]] a dalt-esquerra
  vec2 fc = vec2(gl_FragCoord.x, viewportSize.y - gl_FragCoord.y);
  vec2 cell = floor(fc / drawCell) * (drawCell / cellSize) * zoom;

  float broad = valueNoise(cell * 0.19 + vec2(17.3, -8.1) + phase * vec2(0.90, 0.35), broadSeed);
  float detail = valueNoise(cell * 0.43 + vec2(-5.2, 11.7) + phase * vec2(-1.40, 0.60), detailSeed);
  float tone = broad * 0.74 + detail * 0.26;
  float greenByte = clamp(128.655 + (tone - 0.5) * 195.0, 48.0, 194.0);

  ivec2 grainCell = ivec2(fc) & 63;
  float redDark = hashValue(grainCell, 0xD17E3A91u) < 0.5 ? hashValue(grainCell, 0x4C6B2F05u) * 10.0 : 0.0;
  float greenDark = hashValue(grainCell, 0x91D17E3Au) * 27.0;
  float greenLight = hashValue(grainCell, 0x2F054C6Bu) * 16.0;
  float blueLight = hashValue(grainCell, 0x3A9191D1u) < 0.5 ? hashValue(grainCell, 0x6B2F054Cu) * 10.0 : 0.0;

  vec3 color = vec3(1.0, greenByte / 255.0, 0.0);
  color *= vec3(1.0 - redDark / 255.0, 1.0 - greenDark / 255.0, 1.0);
  color += vec3(0.0, greenLight / 255.0, blueLight / 255.0);
  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}`;

// Dinàmica calcada de ShaderMotionDynamics.swift
const DYN = {
  idleSpeed: 0.16, maxMul: 40, gate: 0.03, gain: 1.5,
  attack: 0.045, release: 0.500, smooth: 0.100, maxDt: 1 / 12,
};

const VIZ_MOBILE_CELL = 22; // pt
const VIZ_FINE = window.matchMedia('(pointer: coarse) and (max-width: 1024px), (max-width: 600px)');

let vizGl = null;
let vizU = null;
let vizPhase = 0;
let vizEnv = 0;
let vizVoice = 0;
let vizPrevT = 0;
let vizRaf = 0;
let vizDemoLevel = NaN;

function vizInit() {
  const c = el.viz;
  let gl = null;
  try {
    gl = c.getContext('webgl2', {
      alpha: false, antialias: false, depth: false, stencil: false,
      premultipliedAlpha: false, preserveDrawingBuffer: false,
      powerPreference: 'low-power',
    });
  } catch (_) {}
  const fallback = (why) => {
    window.__vizStatus = 'fallback: ' + why;
    c.style.background = 'linear-gradient(160deg, #eb5a1e, #f08a2c 55%, #f3b83a)';
  };
  if (!gl) { fallback('no-webgl2'); return; }
  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  try {
    const prog = gl.createProgram();
    gl.attachShader(prog, compile(gl.VERTEX_SHADER, VIZ_VERT));
    gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, VIZ_FRAG));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    vizU = {
      viewport: gl.getUniformLocation(prog, 'viewportSize'),
      phase: gl.getUniformLocation(prog, 'phase'),
      basis: gl.getUniformLocation(prog, 'cellBasis'),
      cellPx: gl.getUniformLocation(prog, 'cellPx'),
    };
  } catch (e) {
    fallback(String(e.message || e));
    return;
  }
  window.__vizStatus = 'webgl2';
  vizGl = gl;
  c.addEventListener('webglcontextlost', (e) => { e.preventDefault(); vizGl = null; }, false);
  c.addEventListener('webglcontextrestored', () => { vizInit(); vizResize(); }, false);
  vizResize();
}

function vizDraw() {
  if (!vizGl) return;
  const w = el.viz.width;
  const h = el.viz.height;
  // Com l'app: cel·la = amplada del panell × 70/410. Al mòbil això dona quadrats de
  // ~65 pt; allà es dibuixen a VIZ_MOBILE_CELL pt perquè se'n vegin molts més.
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  vizGl.uniform2f(vizU.viewport, w, h);
  vizGl.uniform1f(vizU.phase, vizPhase);
  vizGl.uniform1f(vizU.basis, w);
  vizGl.uniform1f(vizU.cellPx, VIZ_FINE.matches ? Math.round(VIZ_MOBILE_CELL * dpr) : 0);
  vizGl.drawArrays(vizGl.TRIANGLES, 0, 3);
}

function vizResize() {
  const c = el.viz;
  const rect = c.getBoundingClientRect();
  if (rect.width < 1 || rect.height < 1) return;
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  const w = Math.max(1, Math.round(rect.width * dpr));
  const h = Math.max(1, Math.round(rect.height * dpr));
  if (c.width !== w || c.height !== h) {
    c.width = w;
    c.height = h;
    if (vizGl) {
      vizGl.viewport(0, 0, w, h);
      vizDraw(); // el canvas s'ha netejat: repinta ja per no ensenyar un frame buit
    }
  }
}

function vizAdvance(dt, lvl) {
  const elapsed = Math.min(Math.max(dt, 0), DYN.maxDt);
  let target = 0;
  if (lvl > DYN.gate) {
    const lin = Math.min(1, (lvl - DYN.gate) / (1 - DYN.gate));
    target = Math.min(1, Math.pow(lin, 0.4) * DYN.gain);
  }
  const tau = target > vizEnv ? DYN.attack : DYN.release;
  vizEnv += (target - vizEnv) * (1 - Math.exp(-elapsed / tau));
  vizEnv = Math.min(1, Math.max(0, vizEnv));
  vizVoice += (vizEnv - vizVoice) * (1 - Math.exp(-elapsed / DYN.smooth));
  vizVoice = Math.min(1, Math.max(0, vizVoice));
  vizPhase += DYN.idleSpeed * (1 + vizVoice * (DYN.maxMul - 1)) * elapsed;
}

let vizLastDraw = 0;
function vizLoop(t) {
  vizRaf = requestAnimationFrame(vizLoop);
  // 12 fps en repòs i 60 mentre escolta, com MetalNoiseView
  const interval = running || Number.isFinite(vizDemoLevel) ? 1000 / 60 : 1000 / 12;
  if (vizLastDraw && t - vizLastDraw < interval - 2) return;
  vizLastDraw = t;
  const dt = vizPrevT ? (t - vizPrevT) / 1000 : 0;
  vizPrevT = t;
  const lvl = Number.isFinite(vizDemoLevel) ? vizDemoLevel : (running ? level : 0);
  vizAdvance(dt, lvl);
  vizDraw();
  if (DEBUG) paintDebug();
}

/* ------------------------------------------------------------------ *
 *  Token efímer (la clau real viu a Netlify)
 * ------------------------------------------------------------------ */

function fetchWithTimeout(url, ms, opts) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  return fetch(url, { ...opts, signal: ctrl.signal }).finally(() => clearTimeout(t));
}

async function getToken(force) {
  if (!force && token && Date.now() < tokenExpMs - 20_000) return token;
  const res = await fetchWithTimeout(TOKEN_URL, 8000, { cache: 'no-store', credentials: 'same-origin' });
  if (!res.ok) {
    const err = new Error('token HTTP ' + res.status);
    err.status = res.status;
    throw err;
  }
  const data = await res.json();
  if (!data.access_token) throw new Error('token buit');
  token = data.access_token;
  tokenExpMs = Date.now() + (data.expires_in || 60) * 1000;
  return token;
}

/* ------------------------------------------------------------------ *
 *  WebSocket Deepgram
 * ------------------------------------------------------------------ */

function wsUrl() {
  return DG_URL + '?' + new URLSearchParams(DG_PARAMS).toString();
}

async function openSocket() {
  if (!running || ws) return;
  const mySession = session;
  if (!wsOpen) setPill('connecting');
  let tk;
  try {
    tk = await getToken(failures > 0);
  } catch (e) {
    setDiag('token', e);
    if (e.status === 429) { pause('limited'); return; }
    onSocketFailure();
    return;
  }
  if (!running || mySession !== session || ws) return;

  let sock;
  try {
    sock = new WebSocket(wsUrl(), ['bearer', tk]);
  } catch (e) {
    setDiag('socket', e);
    onSocketFailure();
    return;
  }
  ws = sock;
  sock.binaryType = 'arraybuffer';

  sock.onopen = () => {
    if (ws !== sock) return;
    wsOpen = true;
    failures = 0;
    setDiag('live');
    // el que s'ha dit mentre s'obria el socket surt de cop: Deepgram ho accepta
    for (const buf of pending) sendNow(buf);
    pending = [];
    setPill(gateOpen ? 'sending' : 'live');
    lastAudioAt = Date.now();
    armKeepAlive();
  };
  sock.onmessage = onMessage;
  sock.onerror = () => { diag.lastError = 'websocket error'; };
  sock.onclose = (e) => {
    diag.closeCode = e.code + (e.reason ? ' ' + e.reason : '');
    if (ws !== sock) return;
    ws = null;
    wsOpen = false;
    clearInterval(keepAliveTimer);
    if (!running) return;
    flushTail(); // una cua viva d'un socket mort no arribarà mai a final
    onSocketFailure();
  };
}

function onSocketFailure() {
  if (!running) return;
  if (failures >= RECONNECT_DELAYS.length) {
    pause('network');
    return;
  }
  setPill('connecting');
  clearTimeout(reconnectTimer);
  const delay = RECONNECT_DELAYS[Math.min(failures, RECONNECT_DELAYS.length - 1)];
  failures++;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = 0;
    if (running && !ws) openSocket();
  }, delay);
}

function sendNow(buf) {
  try {
    ws.send(buf);
    bytesSent += buf.byteLength;
    lastAudioAt = Date.now();
  } catch (_) {}
}

function sendPcm(buf) {
  if (wsOpen && ws && ws.readyState === 1) {
    sendNow(buf);
  } else if (running) {
    pending.push(buf);
    if (pending.length > MAX_PENDING) pending.shift();
  }
}

function sendControl(msg) {
  if (wsOpen && ws && ws.readyState === 1) {
    try { ws.send(msg); } catch (_) {}
  }
}

function armKeepAlive() {
  clearInterval(keepAliveTimer);
  keepAliveTimer = setInterval(() => {
    if (Date.now() - lastAudioAt > 3000) sendControl(KEEPALIVE_MSG);
  }, KEEPALIVE_MS);
}

function closeSocket() {
  clearInterval(keepAliveTimer);
  clearTimeout(reconnectTimer);
  reconnectTimer = 0;
  const dying = ws;
  ws = null;
  wsOpen = false;
  pending = [];
  if (!dying) return;
  dying.onclose = null;
  try {
    if (dying.readyState === 1) {
      // CloseStream fa que Deepgram enviï els darrers finals abans de tancar
      dying.send(CLOSE_MSG);
      setTimeout(() => { try { dying.close(); } catch (_) {} }, 1500);
    } else {
      dying.onmessage = null;
      dying.close();
    }
  } catch (_) {}
}

/* ------------------------------------------------------------------ *
 *  Missatges Deepgram → paraules
 * ------------------------------------------------------------------ */

function onMessage(ev) {
  if (typeof ev.data !== 'string') return;
  let msg;
  try { msg = JSON.parse(ev.data); } catch (_) { return; }
  if (msg.type !== 'Results') return;
  const alt = msg.channel && msg.channel.alternatives && msg.channel.alternatives[0];
  const text = alt && alt.transcript ? alt.transcript.trim() : '';
  if (msg.is_final) {
    if (text) commitText(text);
    else if (tailWords.length) setTail('');
  } else if (text) {
    setTail(text);
  }
}

/* ------------------------------------------------------------------ *
 *  Àudio
 * ------------------------------------------------------------------ */

function newAudioContext() {
  const AC = window.AudioContext || window.webkitAudioContext;
  const ctx = new AC({ latencyHint: 'interactive' });
  ctx.onstatechange = () => {
    diag.ctx = ctx.state + ' @' + ctx.sampleRate;
    if (ctx !== audioCtx || !running) return;
    // iOS: trucades, Siri o una altra app poden interrompre el context
    if (ctx.state === 'running') {
      if (el.pill.dataset.state === 'resume') setPill(wsOpen ? (gateOpen ? 'sending' : 'live') : 'connecting');
    } else {
      setPill('resume');
    }
  };
  diag.ctx = ctx.state + ' @' + ctx.sampleRate;
  return ctx;
}

function withTimeout(promise, ms) {
  return Promise.race([promise, new Promise((r) => setTimeout(r, ms))]);
}

function teardownAudio() {
  if (workletNode) {
    workletNode.port.onmessage = null;
    try { workletNode.disconnect(); } catch (_) {}
    workletNode = null;
  }
  if (micStream) {
    micStream.getTracks().forEach((t) => { t.onended = null; t.stop(); });
    micStream = null;
  }
  if (audioCtx) {
    const ctx = audioCtx;
    audioCtx = null;
    ctx.onstatechange = null;
    ctx.close().catch(() => {});
  }
  gateOpen = false;
  level = 0;
}

async function start() {
  if (running) return;
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia ||
      !(window.AudioContext || window.webkitAudioContext)) {
    setPill('unsupported');
    showStatus(STATUS.unsupported);
    return;
  }

  running = true;
  failures = 0;
  const mySession = ++session;
  clearTimeout(flushTailTimer);
  setPill('connecting');
  setDiag('mic');
  if (!hasTranscript()) showStatus(STATUS.permission);

  // Dins del gest de l'usuari: crear i reprendre el context (Chrome, Safari)
  // i escalfar el token en paral·lel amb el diàleg de permís.
  try {
    audioCtx = newAudioContext();
    audioCtx.resume().catch(() => {});
  } catch (e) {
    return failStart('context', e, STATUS.failed);
  }
  getToken(false).catch(() => {});

  try {
    micStream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: { ideal: 1 },
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });
  } catch (e) {
    const denied = e && (e.name === 'NotAllowedError' || e.name === 'SecurityError');
    const missing = e && (e.name === 'NotFoundError' || e.name === 'OverconstrainedError');
    failStart('getUserMedia', e, denied ? STATUS.denied : missing ? STATUS.noMic : STATUS.failed,
      denied ? 'denied' : 'error');
    return;
  }
  if (mySession !== session || !running) { teardownAudio(); return; }

  const track = micStream.getAudioTracks()[0];
  const settings = (track && track.getSettings && track.getSettings()) || {};
  diag.track = (settings.sampleRate || '?') + ' Hz ' + (track ? track.label : '');
  if (track) track.onended = () => { if (running) pause('paused'); };

  // iOS: un context creat abans d'obrir el micròfon pot quedar amb una freqüència
  // que ja no és la del maquinari i llavors el micròfon sona en silenci. Mentre es
  // captura, WebKit deixa crear-ne un de nou sense gest.
  if (settings.sampleRate && Math.abs(settings.sampleRate - audioCtx.sampleRate) > 1) {
    const old = audioCtx;
    old.onstatechange = null;
    old.close().catch(() => {});
    audioCtx = newAudioContext();
  }

  setDiag('worklet');
  try {
    if (!audioCtx.audioWorklet) throw new Error('AudioWorklet no disponible');
    await audioCtx.audioWorklet.addModule(WORKLET_URL);
    if (mySession !== session || !running) { teardownAudio(); return; }
    const src = audioCtx.createMediaStreamSource(micStream);
    workletNode = new AudioWorkletNode(audioCtx, 'gate', {
      numberOfInputs: 1,
      numberOfOutputs: 1,
      outputChannelCount: [1],
      processorOptions: { rate: audioCtx.sampleRate },
    });
    workletNode.port.onmessage = onWorklet;
    const mute = audioCtx.createGain();
    mute.gain.value = 0;
    src.connect(workletNode).connect(mute).connect(audioCtx.destination);
  } catch (e) {
    failStart('worklet', e, STATUS.failed);
    return;
  }

  await withTimeout(audioCtx.resume().catch(() => {}), 1200);
  if (mySession !== session || !running) return;
  diag.ctx = audioCtx.state + ' @' + audioCtx.sampleRate;

  if (!hasTranscript()) showStatus(audioCtx.state === 'running' ? STATUS.listening : STATUS.resume);
  if (audioCtx.state !== 'running') setPill('resume');

  setDiag('socket');
  openSocket();
  armIdleSleep();
  armSessionCap();
  requestWakeLock();
}

function failStart(stage, e, text, pill) {
  setDiag(stage, e);
  running = false;
  teardownAudio();
  closeSocket();
  setPill(pill || 'error');
  showStatus(text);
  if (DEBUG && e) showStatus(text + ' (' + diag.lastError + ')');
}

function onWorklet(ev) {
  const m = ev.data;
  if (m.t === 'pcm') {
    sendPcm(m.buf);
  } else if (m.t === 'level') {
    level = m.v;
  } else if (m.t === 'gate') {
    gateOpen = m.open;
    if (m.open) {
      clearTimeout(idleTimer);
      idleTimer = 0;
      if (wsOpen && el.pill.dataset.state !== 'resume') setPill('sending');
    } else {
      // tanca la frase ja: el final arriba sense esperar més àudio
      sendControl(FINALIZE_MSG);
      if (wsOpen && el.pill.dataset.state !== 'resume') setPill('live');
      armIdleSleep();
    }
  }
}

/* ------------------------------------------------------------------ *
 *  Vida de la sessió
 * ------------------------------------------------------------------ */

function armIdleSleep() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => pause('paused'), IDLE_SLEEP_MS);
}

function armSessionCap() {
  clearTimeout(capTimer);
  capTimer = setTimeout(() => pause('cap'), SESSION_CAP_MS);
}

function pause(reason) {
  if (!running) return;
  running = false;
  session++;
  clearTimeout(idleTimer);
  clearTimeout(capTimer);
  closeSocket();
  teardownAudio();
  releaseWakeLock();
  setDiag('paused:' + reason);

  const pill = { network: 'error', limited: 'error' }[reason] || 'paused';
  setPill(pill);
  const text = { network: STATUS.network, limited: STATUS.limited, cap: STATUS.cap }[reason];
  if (hasTranscript() && !text) {
    updateCaret();
    // si el darrer final no arriba, la cua es queda com a text establert
    clearTimeout(flushTailTimer);
    flushTailTimer = setTimeout(flushTail, 1600);
  } else {
    showStatus(text || STATUS.paused);
  }
}

function toggle() {
  if (running && audioCtx && audioCtx.state !== 'running') {
    // el context s'ha aturat (iOS): el toc el reprèn en lloc d'aturar la sessió
    audioCtx.resume().then(() => {
      if (audioCtx && audioCtx.state === 'running' && !hasTranscript()) showStatus(STATUS.listening);
    }).catch(() => {});
    return;
  }
  if (running) pause('paused');
  else start();
}

async function requestWakeLock() {
  try {
    if ('wakeLock' in navigator && !wakeLock) {
      wakeLock = await navigator.wakeLock.request('screen');
      wakeLock.addEventListener('release', () => { wakeLock = null; });
      if (!running) releaseWakeLock();
    }
  } catch (_) { wakeLock = null; }
}

function releaseWakeLock() {
  if (wakeLock) {
    wakeLock.release().catch(() => {});
    wakeLock = null;
  }
}

/* ------------------------------------------------------------------ *
 *  Diagnòstic (?debug)
 * ------------------------------------------------------------------ */

let debugLast = 0;
function paintDebug() {
  const now = performance.now();
  if (now - debugLast < 250) return;
  debugLast = now;
  const wsState = ws ? ['connecting', 'open', 'closing', 'closed'][ws.readyState] : 'none';
  el.debug.textContent = [
    'stage   ' + diag.stage,
    'ctx     ' + (audioCtx ? audioCtx.state + ' @' + audioCtx.sampleRate : '-') ,
    'track   ' + (diag.track || '-'),
    'ws      ' + wsState + (diag.closeCode ? '  close ' + diag.closeCode : ''),
    'gate    ' + (gateOpen ? 'open' : 'closed') + '  level ' + level.toFixed(3),
    'sent    ' + (bytesSent / 32000).toFixed(1) + ' s  pending ' + pending.length,
    'viz     ' + (window.__vizStatus || '-'),
    diag.lastError ? 'error   ' + diag.lastError : '',
  ].filter(Boolean).join('\n');
}

/* ------------------------------------------------------------------ *
 *  Esdeveniments
 * ------------------------------------------------------------------ */

el.app.addEventListener('click', (e) => {
  if (e.target.closest('#theme')) return;
  toggle();
});

el.theme.addEventListener('click', (e) => {
  e.stopPropagation();
  toggleTheme();
});

// zero crèdits en segon pla: la pestanya amagada o la pantalla bloquejada = pausa
document.addEventListener('visibilitychange', () => {
  if (document.hidden && running) pause('paused');
  if (!document.hidden) vizPrevT = 0; // com el resetClock() de l'app
});
window.addEventListener('pagehide', () => { if (running) pause('paused'); });

// teclat (escriptori): espai com a l'app nativa, D per al tema
window.addEventListener('keydown', (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.code === 'Space' && !e.repeat) {
    if (e.target && e.target.closest && e.target.closest('button')) return;
    e.preventDefault();
    toggle();
  } else if (e.key === 'd' || e.key === 'D') {
    toggleTheme();
  }
});

if (typeof ResizeObserver !== 'undefined') {
  new ResizeObserver(() => vizResize()).observe(el.deco);
  new ResizeObserver(() => { resetLayout = true; layoutRoll(); }).observe(el.reader);
} else {
  window.addEventListener('resize', () => { vizResize(); resetLayout = true; layoutRoll(); });
}
// canvis de densitat de píxels (zoom, pantalla externa)
window.matchMedia && (function watchDpr() {
  const mq = matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
  const onChange = () => { vizResize(); mq.removeEventListener('change', onChange); watchDpr(); };
  if (mq.addEventListener) mq.addEventListener('change', onChange);
})();

/* ------------------------------------------------------------------ *
 *  Arrencada
 * ------------------------------------------------------------------ */

(function init() {
  let mode = 'light';
  try { mode = localStorage.getItem('catala-asr.theme') || 'light'; } catch (_) {}
  applyTheme(mode);
  setPill('idle');
  if (DEBUG) el.debug.hidden = false;

  // ?lvl=0.8 → simula nivell de veu (proves visuals del shader)
  const demo = parseFloat(PARAMS.get('lvl'));
  if (Number.isFinite(demo)) vizDemoLevel = Math.min(1, Math.max(0, demo));

  vizInit();
  vizRaf = requestAnimationFrame(vizLoop);

  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    const hadController = !!navigator.serviceWorker.controller;
    let reloaded = false;
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      // un desplegament nou ha pres el control: recarrega si no s'està escoltant
      if (!hadController || reloaded || running) return;
      reloaded = true;
      location.reload();
    });
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  }
})();

})();
