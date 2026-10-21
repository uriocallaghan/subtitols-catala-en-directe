/* Català ASR — AudioWorklet: detector de veu + remostreig a 16 kHz.
 * Tot passa dins del fil d'àudio; el fil principal només rep PCM ja retallat,
 * l'estat de la comporta i el nivell per al visualitzador. */
'use strict';

const VOICE_GAIN = 6; // mateix guany que AudioCapture.voiceGain de l'app

class Gate extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const o = (options && options.processorOptions) || {};
    this.inRate = o.rate || sampleRate || 48000;
    this.outRate = 16000;
    this.step = this.inRate / this.outRate;
    this.phase = 0;
    this.prev = 0;
    this.out = new Float32Array(1600); // 100 ms
    this.outN = 0;

    // VAD: llindar adaptatiu sobre el soroll de fons
    this.floor = 0.001;
    this.open = false;
    this.above = 0;
    this.below = 0;
    const blockMs = 128 / this.inRate * 1000;
    this.attackBlocks = Math.ceil(24 / blockMs);   // ~24 ms per confirmar veu
    this.hangBlocks = Math.ceil(800 / blockMs);    // ~800 ms de cua després de la veu
    this.minRms = 0.0035;

    // anell de pre-roll: ~320 ms per no tallar l'inici de cada paraula
    this.ringCap = Math.ceil(0.32 * this.inRate / 128);
    this.ring = Array.from({ length: this.ringCap }, () => new Float32Array(128));
    this.ringIdx = 0;
    this.ringLen = 0;

    this.tick = 0;
    this.pendingLevel = 0;
  }

  pushResampled(s) {
    this.out[this.outN++] = s;
    if (this.outN >= this.out.length) this.flushPcm();
  }

  flushPcm() {
    if (this.outN === 0) return;
    const int16 = new Int16Array(this.outN);
    for (let i = 0; i < this.outN; i++) {
      const s = Math.max(-1, Math.min(1, this.out[i]));
      int16[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
    }
    this.outN = 0;
    this.port.postMessage({ t: 'pcm', buf: int16.buffer }, [int16.buffer]);
  }

  resample(input) {
    const N = input.length;
    let pos = this.phase;
    while (pos < N) {
      const i = Math.floor(pos);
      const f = pos - i;
      const s0 = i === 0 ? this.prev : input[i - 1];
      const s1 = input[i];
      this.pushResampled(s0 + (s1 - s0) * f);
      pos += this.step;
    }
    this.phase = pos - N;
    this.prev = input[N - 1];
  }

  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!ch || ch.length === 0) return true;

    let sum = 0;
    for (let i = 0; i < ch.length; i++) sum += ch[i] * ch[i];
    const rms = Math.sqrt(sum / ch.length);

    // sostre de soroll adaptatiu (només mentre la comporta és tancada)
    if (!this.open) {
      this.floor = rms < this.floor ? rms : this.floor + (rms - this.floor) * 0.002;
    }
    const thr = Math.max(this.floor * 4, this.minRms);

    if (rms > thr) {
      this.above++;
      this.below = 0;
    } else {
      this.below++;
      this.above = 0;
    }

    if (!this.open && this.above >= this.attackBlocks) {
      this.open = true;
      this.below = 0;
      this.port.postMessage({ t: 'gate', open: true });
      // aboca el pre-roll en ordre perquè no es perdi l'atac de la paraula
      const oldest = this.ringLen < this.ringCap ? 0 : this.ringIdx;
      for (let k = 0; k < this.ringLen; k++) {
        this.resample(this.ring[(oldest + k) % this.ringCap]);
      }
      this.ringLen = 0;
      this.ringIdx = 0;
    }
    if (this.open && this.below >= this.hangBlocks) {
      this.open = false;
      this.above = 0;
      this.flushPcm();
      this.port.postMessage({ t: 'gate', open: false });
    }

    if (this.open) {
      this.resample(ch);
    } else {
      let slot = this.ring[this.ringIdx];
      if (slot.length !== ch.length) {
        slot = new Float32Array(ch.length);
        this.ring[this.ringIdx] = slot;
      }
      slot.set(ch);
      this.ringIdx = (this.ringIdx + 1) % this.ringCap;
      if (this.ringLen < this.ringCap) this.ringLen++;
    }

    // nivell per al visualitzador: pic de la finestra, ~30 Hz
    const level = Math.min(1, rms * VOICE_GAIN);
    if (level > this.pendingLevel) this.pendingLevel = level;
    if (++this.tick % 12 === 0) {
      this.port.postMessage({ t: 'level', v: this.pendingLevel });
      this.pendingLevel = 0;
    }
    return true;
  }
}

registerProcessor('gate', Gate);
