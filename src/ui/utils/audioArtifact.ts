// REQ-VOICE-3/4: audio artifacts in Ninjy chat — detection, playback helpers and the
// voice-recorder state machine. Pure module (no React, no DOM) so it is unit-testable.

/** Artifact kinds that mean "play this inline". `voice` is what agents send for spoken replies. */
export const AUDIO_ARTIFACT_KINDS = ['audio', 'voice'] as const;

/** The kind the composer gives a recording (and any uploaded audio file). */
export const AUDIO_ARTIFACT_KIND = 'audio';

/** Extensions that are unambiguously audio. `.webm`/`.mp4` are left out: they are usually video. */
const AUDIO_EXT_MIME: Record<string, string> = {
  mp3: 'audio/mpeg',
  wav: 'audio/wav',
  ogg: 'audio/ogg',
  oga: 'audio/ogg',
  opus: 'audio/ogg',
  m4a: 'audio/mp4',
  aac: 'audio/aac',
  flac: 'audio/flac',
  weba: 'audio/webm',
};

/** Hub artifact cap (MAX_UPLOAD_BYTES in ArtifactUpload.tsx); mirrored to keep this module pure. */
export const VOICE_MAX_BYTES = 15 * 1024 * 1024;
/** 10 minutes of 64 kbit/s Opus is ~4.8 MB, well under the 15 MiB cap even with container overhead. */
export const VOICE_MAX_DURATION_MS = 10 * 60 * 1000;
export const VOICE_BITS_PER_SECOND = 64_000;
/** Stop early when the recorded bytes reach this share of the cap (a codec ignoring the bitrate hint). */
export const VOICE_BYTES_SAFETY = 0.9;

export type AudioArtifactMeta = {
  kind?: string;
  type?: string;
  mime?: string;
  content_type?: string;
  contentType?: string;
  ext?: string;
  extension?: string;
  name?: string;
};

function lower(value: unknown): string {
  return String(value ?? '').trim().toLowerCase();
}

/** The base media type without parameters: `audio/webm;codecs=opus` → `audio/webm`. */
export function baseMimeType(mime: string): string {
  return lower(mime).split(';')[0].trim();
}

function metaMime(meta: AudioArtifactMeta | null | undefined): string {
  return baseMimeType(String(meta?.mime || meta?.content_type || meta?.contentType || ''));
}

function metaExt(meta: AudioArtifactMeta | null | undefined): string {
  const explicit = lower(meta?.ext || meta?.extension).replace(/^\./, '');
  if (explicit) return explicit;
  const name = lower(meta?.name);
  const dot = name.lastIndexOf('.');
  return dot >= 0 ? name.slice(dot + 1) : '';
}

/** True for kind `audio`/`voice`, any `audio/*` mime, or an unambiguous audio extension. */
export function isAudioArtifact(meta: AudioArtifactMeta | null | undefined): boolean {
  if (!meta) return false;
  const kind = lower(meta.kind || meta.type);
  if ((AUDIO_ARTIFACT_KINDS as readonly string[]).includes(kind)) return true;
  const mime = metaMime(meta);
  if (mime.startsWith('audio/')) return true;
  // An explicit non-audio mime wins over the name (e.g. `notes.ogg` stored as text/plain).
  if (mime && mime !== 'application/octet-stream') return false;
  return Boolean(AUDIO_EXT_MIME[metaExt(meta)]);
}

/** The media type to give the decrypted blob so <audio> can sniff it; '' when unknown. */
export function audioMimeForArtifact(meta: AudioArtifactMeta | null | undefined): string {
  const mime = metaMime(meta);
  if (mime.startsWith('audio/')) return mime;
  return AUDIO_EXT_MIME[metaExt(meta)] || (isAudioArtifact(meta) ? 'audio/webm' : '');
}

/** `m:ss` (or `h:mm:ss`) for a duration in seconds; `--:--` when it is not known yet. */
export function formatAudioTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '--:--';
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const ss = String(s).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}

/**
 * The playable duration in seconds. Chromium's MediaRecorder writes WebM without a
 * duration, so `<audio>.duration` is `Infinity` until the whole file is scanned; the
 * recorder's own measurement (`hintMs`) fills that gap.
 */
export function resolveAudioDuration(raw: number, hintMs = 0): number {
  if (Number.isFinite(raw) && raw > 0) return raw;
  return hintMs > 0 ? hintMs / 1000 : NaN;
}

/** Recorder container preference: Opus in WebM (Chromium/Firefox), Ogg, then MP4/AAC (Safari). */
export const RECORDER_MIME_CANDIDATES = [
  'audio/webm;codecs=opus',
  'audio/webm',
  'audio/ogg;codecs=opus',
  'audio/mp4',
] as const;

export function pickRecorderMimeType(isTypeSupported: ((mime: string) => boolean) | undefined): string {
  if (!isTypeSupported) return '';
  for (const mime of RECORDER_MIME_CANDIDATES) {
    try {
      if (isTypeSupported(mime)) return mime;
    } catch {}
  }
  return '';
}

export function extensionForAudioMime(mime: string): string {
  switch (baseMimeType(mime)) {
    case 'audio/webm': return '.webm';
    case 'audio/ogg': return '.ogg';
    case 'audio/mp4': return '.m4a';
    case 'audio/mpeg': return '.mp3';
    case 'audio/wav': return '.wav';
    case 'audio/aac': return '.aac';
    case 'audio/flac': return '.flac';
    default: return '';
  }
}

/** `voice-message-2026-11-21T16-40-03-120Z.webm` */
export function voiceRecordingName(mime: string, now: Date = new Date()): string {
  const stamp = now.toISOString().replace(/[:.]/g, '-');
  return `voice-message-${stamp}${extensionForAudioMime(mime) || '.webm'}`;
}

/** A plain-language reason for a getUserMedia/MediaRecorder failure. */
export function describeMicError(error: unknown): string {
  const name = String((error as any)?.name || '');
  switch (name) {
    case 'NotAllowedError':
    case 'PermissionDeniedError':
    case 'SecurityError':
      return 'Microphone access was denied. Allow Ninjy to use the microphone, then try again.';
    case 'NotFoundError':
    case 'DevicesNotFoundError':
    case 'OverconstrainedError':
      return 'No microphone was found. Connect one and try again.';
    case 'NotReadableError':
    case 'TrackStartError':
    case 'AbortError':
      return 'The microphone could not be started. It may be in use by another app.';
    case 'NotSupportedError':
      return 'Recording is not available here. Use a current browser or the desktop app.';
    default:
      return 'Recording failed. Try again.';
  }
}

export const MIC_UNAVAILABLE_ERROR = 'Recording is not available here. Use a current browser or the desktop app.';

// ---------------------------------------------------------------------------
// Recorder state machine:
//   idle --start--> requesting --granted--> recording --stopped--> preview --sent|discard--> idle
//   requesting --denied--> idle(error); recording --cancel--> idle; any --failed--> idle(error)
// ---------------------------------------------------------------------------

export type VoiceRecording = { blob: Blob; url: string; mime: string; durationMs: number };

export type VoiceRecorderPhase = 'idle' | 'requesting' | 'recording' | 'preview';

export type VoiceRecorderState = {
  phase: VoiceRecorderPhase;
  elapsedMs: number;
  error: string;
  /** The recording stopped by itself at the duration or size cap. */
  limitReached: boolean;
  recording: VoiceRecording | null;
};

export type VoiceRecorderAction =
  | { type: 'start' }
  | { type: 'granted' }
  | { type: 'denied'; error: string }
  | { type: 'tick'; elapsedMs: number }
  | { type: 'limit' }
  | { type: 'stopped'; recording: VoiceRecording }
  | { type: 'cancel' }
  | { type: 'discard' }
  | { type: 'sent' }
  | { type: 'failed'; error: string }
  | { type: 'dismiss_error' };

export const INITIAL_VOICE_RECORDER_STATE: VoiceRecorderState = {
  phase: 'idle', elapsedMs: 0, error: '', limitReached: false, recording: null,
};

export function voiceRecorderReducer(state: VoiceRecorderState, action: VoiceRecorderAction): VoiceRecorderState {
  switch (action.type) {
    case 'start':
      return state.phase === 'idle' ? { ...INITIAL_VOICE_RECORDER_STATE, phase: 'requesting' } : state;
    case 'granted':
      return state.phase === 'requesting' ? { ...state, phase: 'recording', elapsedMs: 0 } : state;
    case 'denied':
      return state.phase === 'requesting' ? { ...INITIAL_VOICE_RECORDER_STATE, error: action.error } : state;
    case 'tick':
      return state.phase === 'recording' ? { ...state, elapsedMs: Math.max(state.elapsedMs, action.elapsedMs) } : state;
    case 'limit':
      return state.phase === 'recording' ? { ...state, limitReached: true } : state;
    case 'stopped':
      return state.phase === 'recording'
        ? { ...state, phase: 'preview', recording: action.recording, elapsedMs: action.recording.durationMs }
        : state;
    case 'cancel':
      return state.phase === 'requesting' || state.phase === 'recording' ? INITIAL_VOICE_RECORDER_STATE : state;
    case 'discard':
    case 'sent':
      return state.phase === 'preview' ? INITIAL_VOICE_RECORDER_STATE : state;
    case 'failed':
      return { ...INITIAL_VOICE_RECORDER_STATE, error: action.error };
    case 'dismiss_error':
      return state.error ? { ...state, error: '' } : state;
    default:
      return state;
  }
}
