import { useCallback, useEffect, useReducer, useRef } from 'react';
import {
  INITIAL_VOICE_RECORDER_STATE,
  MIC_UNAVAILABLE_ERROR,
  VOICE_BITS_PER_SECOND,
  VOICE_BYTES_SAFETY,
  VOICE_MAX_BYTES,
  VOICE_MAX_DURATION_MS,
  baseMimeType,
  describeMicError,
  pickRecorderMimeType,
  voiceRecorderReducer,
  voiceRecordingName,
  type VoiceRecorderState,
} from '../../utils/audioArtifact';

type RecorderCtor = {
  new (stream: MediaStream, options?: MediaRecorderOptions): MediaRecorder;
  isTypeSupported?: (mime: string) => boolean;
};

/** Browser seams, injectable so the state machine can be driven by fakes in tests. */
export type VoiceRecorderEnv = {
  getUserMedia?: (constraints: MediaStreamConstraints) => Promise<MediaStream>;
  MediaRecorder?: RecorderCtor;
  now?: () => number;
};

function browserEnv(): VoiceRecorderEnv {
  const g: any = typeof globalThis === 'undefined' ? {} : globalThis;
  const devices = g.navigator?.mediaDevices;
  return {
    getUserMedia: devices?.getUserMedia ? (c) => devices.getUserMedia(c) : undefined,
    MediaRecorder: g.MediaRecorder,
    now: () => Date.now(),
  };
}

export type VoiceRecorder = VoiceRecorderState & {
  supported: boolean;
  start: () => Promise<void>;
  /** Finish recording and move to preview. */
  stop: () => void;
  /** Abandon an in-progress recording (or a pending permission prompt). */
  cancel: () => void;
  /** Throw away the previewed recording. */
  discard: () => void;
  /** Hand the previewed recording over as a File and reset; null when there is none. */
  take: () => File | null;
  dismissError: () => void;
};

/**
 * REQ-VOICE-4: microphone recording for the chat composer. One recording at a time; the
 * stream's tracks are released as soon as recording stops, on cancel, and on unmount (so
 * navigating away never leaves the mic indicator on). Recording stops by itself at
 * `maxDurationMs` or when the data nears the 15 MiB artifact cap.
 */
export function useVoiceRecorder({ maxDurationMs = VOICE_MAX_DURATION_MS, maxBytes = VOICE_MAX_BYTES, env }: {
  maxDurationMs?: number;
  maxBytes?: number;
  env?: VoiceRecorderEnv;
} = {}): VoiceRecorder {
  const [state, dispatch] = useReducer(voiceRecorderReducer, INITIAL_VOICE_RECORDER_STATE);
  const envRef = useRef<VoiceRecorderEnv>(env || browserEnv());
  if (env) envRef.current = env;
  const streamRef = useRef<MediaStream | null>(null);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | undefined>(undefined);
  const startedAtRef = useRef(0);
  const sessionRef = useRef(0);
  const discardRef = useRef(false);
  const previewUrlRef = useRef('');
  const stateRef = useRef(state);
  stateRef.current = state;
  const mountedRef = useRef(true);
  const now = () => (envRef.current.now || Date.now)();

  const supported = Boolean(envRef.current.getUserMedia && envRef.current.MediaRecorder);

  const releaseStream = useCallback(() => {
    clearInterval(timerRef.current);
    timerRef.current = undefined;
    streamRef.current?.getTracks().forEach((track) => { try { track.stop(); } catch {} });
    streamRef.current = null;
  }, []);

  const revokePreview = useCallback(() => {
    if (previewUrlRef.current) URL.revokeObjectURL(previewUrlRef.current);
    previewUrlRef.current = '';
  }, []);

  const stop = useCallback(() => {
    const recorder = recorderRef.current;
    if (recorder && recorder.state !== 'inactive') {
      try { recorder.stop(); } catch {}
    }
    releaseStream();
  }, [releaseStream]);

  const cancel = useCallback(() => {
    sessionRef.current += 1; // a pending getUserMedia resolves into a dead session
    discardRef.current = true;
    stop();
    recorderRef.current = null;
    dispatch({ type: 'cancel' });
  }, [stop]);

  const start = useCallback(async () => {
    if (stateRef.current.phase !== 'idle') return;
    const { getUserMedia, MediaRecorder: Recorder } = envRef.current;
    revokePreview();
    if (!getUserMedia || !Recorder) {
      dispatch({ type: 'failed', error: MIC_UNAVAILABLE_ERROR });
      return;
    }
    const session = ++sessionRef.current;
    dispatch({ type: 'start' });
    let stream: MediaStream;
    try {
      stream = await getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true }, video: false });
    } catch (err) {
      if (session === sessionRef.current && mountedRef.current) dispatch({ type: 'denied', error: describeMicError(err) });
      return;
    }
    if (session !== sessionRef.current || !mountedRef.current) {
      stream.getTracks().forEach((track) => { try { track.stop(); } catch {} });
      return;
    }
    streamRef.current = stream;
    const mimeType = pickRecorderMimeType(Recorder.isTypeSupported?.bind(Recorder));
    let recorder: MediaRecorder;
    try {
      recorder = new Recorder(stream, { ...(mimeType ? { mimeType } : {}), audioBitsPerSecond: VOICE_BITS_PER_SECOND });
    } catch (err) {
      releaseStream();
      dispatch({ type: 'failed', error: describeMicError(err) });
      return;
    }
    const chunks: Blob[] = [];
    let bytes = 0;
    discardRef.current = false;
    recorder.ondataavailable = (event: BlobEvent) => {
      if (!event.data || event.data.size === 0) return;
      chunks.push(event.data);
      bytes += event.data.size;
      if (bytes >= maxBytes * VOICE_BYTES_SAFETY && recorder.state === 'recording') {
        dispatch({ type: 'limit' });
        stop();
      }
    };
    recorder.onerror = (event: any) => {
      if (session !== sessionRef.current) return;
      discardRef.current = true;
      stop();
      dispatch({ type: 'failed', error: describeMicError(event?.error) });
    };
    recorder.onstop = () => {
      releaseStream();
      if (recorderRef.current === recorder) recorderRef.current = null;
      if (discardRef.current || session !== sessionRef.current || !mountedRef.current) return;
      const mime = baseMimeType(recorder.mimeType || mimeType || 'audio/webm') || 'audio/webm';
      const blob = new Blob(chunks, { type: mime });
      if (blob.size === 0) {
        dispatch({ type: 'failed', error: 'Nothing was recorded. Check the microphone and try again.' });
        return;
      }
      const durationMs = Math.min(maxDurationMs, Math.max(0, now() - startedAtRef.current));
      const url = URL.createObjectURL(blob);
      previewUrlRef.current = url;
      dispatch({ type: 'stopped', recording: { blob, url, mime, durationMs } });
    };
    recorderRef.current = recorder;
    try {
      // A timeslice delivers data while recording, so the size guard can act in time.
      recorder.start(1000);
    } catch (err) {
      recorderRef.current = null;
      releaseStream();
      dispatch({ type: 'failed', error: describeMicError(err) });
      return;
    }
    startedAtRef.current = now();
    dispatch({ type: 'granted' });
    timerRef.current = setInterval(() => {
      const elapsedMs = now() - startedAtRef.current;
      dispatch({ type: 'tick', elapsedMs: Math.min(elapsedMs, maxDurationMs) });
      if (elapsedMs >= maxDurationMs) {
        dispatch({ type: 'limit' });
        stop();
      }
    }, 250);
  }, [maxBytes, maxDurationMs, releaseStream, revokePreview, stop]);

  const discard = useCallback(() => {
    revokePreview();
    dispatch({ type: 'discard' });
  }, [revokePreview]);

  const take = useCallback((): File | null => {
    const recording = stateRef.current.phase === 'preview' ? stateRef.current.recording : null;
    if (!recording) return null;
    const file = new File([recording.blob], voiceRecordingName(recording.mime), { type: recording.mime });
    revokePreview();
    dispatch({ type: 'sent' });
    return file;
  }, [revokePreview]);

  const dismissError = useCallback(() => dispatch({ type: 'dismiss_error' }), []);

  // Unmount (navigation, conversation switch): stop the mic and drop any recording.
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      sessionRef.current += 1;
      discardRef.current = true;
      const recorder = recorderRef.current;
      if (recorder && recorder.state !== 'inactive') { try { recorder.stop(); } catch {} }
      recorderRef.current = null;
      releaseStream();
      revokePreview();
    };
  }, [releaseStream, revokePreview]);

  return { ...state, supported, start, stop, cancel, discard, take, dismissError };
}
