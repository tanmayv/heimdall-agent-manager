/** Explicit analysis budgets. No PCM or decrypted-URL cache is retained. */
export const WAVEFORM_BINS = 128;
export const LIVE_BINS = 64;
export const MAX_WAVEFORM_BYTES = 8 * 1024 * 1024;
export const MAX_WAVEFORM_SECONDS = 60;
export const WAVEFORM_SAMPLE_RATE = 16000;
export type AudioContextConstructor = new (options?: AudioContextOptions) => AudioContext;
export function audioContextConstructor(): AudioContextConstructor | undefined {
  const g = globalThis as typeof globalThis & { webkitAudioContext?: AudioContextConstructor };
  return g.AudioContext || g.webkitAudioContext;
}

/** Maximum absolute amplitude across every channel: silence stays zero. */
export function audioPeaks(buffer: Pick<AudioBuffer, 'length' | 'numberOfChannels' | 'getChannelData'>, bins = WAVEFORM_BINS): number[] {
  const count = Math.min(WAVEFORM_BINS, Math.max(1, Math.floor(bins)));
  const peaks = Array<number>(count).fill(0);
  for (let channel = 0; channel < buffer.numberOfChannels; channel++) {
    const samples = buffer.getChannelData(channel);
    for (let i = 0; i < buffer.length; i++) {
      const bin = Math.min(count - 1, Math.floor(i * count / buffer.length));
      peaks[bin] = Math.min(1, Math.max(peaks[bin], Math.abs(samples[i]) || 0));
    }
  }
  return peaks;
}
export function sampleAmplitude(samples: Float32Array): number {
  let peak = 0;
  for (const sample of samples) peak = Math.max(peak, Math.abs(sample) || 0);
  return Math.min(1, peak);
}

// One active decoder and no queue: a visible player retries when the slot is released.
let decoding = false;
const slotListeners = new Set<() => void>();
export function onWaveformSlot(callback: () => void): () => void {
  slotListeners.add(callback);
  return () => { slotListeners.delete(callback); };
}
export function waveformAdmitted(duration: number): boolean {
  return Number.isFinite(duration) && duration > 0 && duration <= MAX_WAVEFORM_SECONDS;
}

/** Only existing decrypted blob URLs are accepted; no authenticated/remote fetch path. */
export async function decodeWaveform(src: string, duration: number, signal: AbortSignal): Promise<number[] | null | 'busy'> {
  const Context = audioContextConstructor();
  if (!Context || !src.startsWith('blob:') || !waveformAdmitted(duration) || signal.aborted) return null;
  if (decoding) return 'busy';
  decoding = true;
  let context: AudioContext | undefined;
  let closing: Promise<void> | undefined;
  const closeContext = () => {
    const owned = context;
    context = undefined;
    if (owned) { try { closing = owned.close().catch(() => {}); } catch {} }
  };
  signal.addEventListener('abort', closeContext, { once: true });
  try {
    const response = await fetch(src, { signal });
    if (!response.ok || !response.body) return null;
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > MAX_WAVEFORM_BYTES || signal.aborted) { await reader.cancel(); return null; }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
    if (signal.aborted || !size) return null;
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    chunks.length = 0;
    // decodeAudioData resamples to this rate. With <=32 Web Audio channels and <=60s,
    // admitted output PCM is <=123 MiB. Browser decoder internals are not hard-capped.
    context = new Context({ sampleRate: WAVEFORM_SAMPLE_RATE });
    const buffer = await context.decodeAudioData(bytes.buffer);
    if (signal.aborted || buffer.duration > MAX_WAVEFORM_SECONDS || buffer.numberOfChannels > 32 || buffer.sampleRate > WAVEFORM_SAMPLE_RATE) return null;
    return audioPeaks(buffer);
  } catch { return null; }
  finally {
    signal.removeEventListener('abort', closeContext);
    closeContext();
    await closing;
    decoding = false;
    // Notify after the caller can commit its result; cancelled players unsubscribe.
    setTimeout(() => { for (const callback of slotListeners) callback(); }, 0);
  }
}

/** Owns only analysis resources, never the stream tracks; never connects to speakers. */
export function analyseMicrophone(stream: MediaStream, update: (peaks: number[]) => void, Context = audioContextConstructor()): () => void {
  if (!Context) return () => {};
  let context: AudioContext | undefined;
  let source: MediaStreamAudioSourceNode | undefined;
  let analyser: AnalyserNode | undefined;
  let frame = 0;
  let stopped = false;
  const cleanup = () => {
    if (stopped) return;
    stopped = true;
    cancelAnimationFrame(frame);
    try { source?.disconnect(); } catch {}
    try { analyser?.disconnect(); } catch {}
    if (context) { try { void context.close().catch(() => {}); } catch {} }
    context = undefined;
  };
  try {
    context = new Context();
    source = context.createMediaStreamSource(stream);
    analyser = context.createAnalyser();
    analyser.fftSize = 256;
    source.connect(analyser);
    const samples = new Float32Array(analyser.fftSize);
    const history: number[] = [];
    let last = -Infinity;
    const tick = (time: number) => {
      if (stopped) return;
      if (time - last >= 50 && typeof document !== 'undefined' && !document.hidden && context?.state === 'running') {
        try {
          analyser!.getFloatTimeDomainData(samples);
          history.push(sampleAmplitude(samples));
          if (history.length > LIVE_BINS) history.shift();
          update([...history]);
          last = time;
        } catch { cleanup(); update([]); return; }
      }
      frame = requestAnimationFrame(tick);
    };
    void context.resume().catch(() => { if (!stopped) { cleanup(); update([]); } });
    frame = requestAnimationFrame(tick);
  } catch { cleanup(); }
  return cleanup;
}
