import { useEffect, useRef, useState } from 'react';
import { Icon } from '@ui';
import { formatAudioTime } from '../../utils/audioArtifact';
import { AudioWaveform } from './AudioWaveform';
import { AudioPlayer } from './AudioPlayer';
import type { PendingAttachment } from './useComposerAttachments';
import { useVoiceRecorder, type VoiceRecorder, type VoiceRecorderEnv } from './useVoiceRecorder';

/**
 * REQ-VOICE-4: the recorder strip above the composer card. Recording shows a timer with
 * Cancel and Stop; a stopped recording previews in the inline player with Discard and Send.
 * Errors (permission denied, no microphone) show inline until dismissed or retried.
 */
export function VoiceRecorderPanel({ recorder, debugPrefix: p, sendDisabled = false, onSend }: {
  recorder: VoiceRecorder;
  isMobile: boolean;
  debugPrefix: string;
  sendDisabled?: boolean;
  onSend: () => void;
}) {
  const { phase, error } = recorder;
  if (phase === 'idle' && !error) return null;
  const btn = `inline-flex min-h-11 px-3 items-center gap-1.5 rounded-[var(--radius-md)] text-sm`;
  const secondary = `${btn} border border-subtle text-primary hover:bg-neutral-soft disabled:opacity-45`;
  return (
    <div data-debug-id={`${p}-voice-recorder`} data-phase={phase}
      className="mb-2 rounded-2xl border border-subtle bg-surface-raised p-2 text-sm text-primary">
      {phase === 'idle' && error ? (
        <div className="flex min-w-0 items-center gap-2">
          <Icon name="alert" size="md" className="shrink-0 text-danger" />
          <span role="alert" data-debug-id={`${p}-voice-error`} className="min-w-0 flex-1 text-danger">{error}</span>
          <button type="button" data-debug-id={`${p}-voice-error-dismiss`} onClick={recorder.dismissError} className={secondary}>Dismiss</button>
        </div>
      ) : phase === 'requesting' ? (
        <div className="flex min-w-0 items-center gap-2">
          <Icon name="mic" size="md" className="shrink-0 text-muted" />
          <span data-debug-id={`${p}-voice-requesting`} role="status" className="min-w-0 flex-1 text-muted">Waiting for microphone access…</span>
          <button type="button" data-debug-id={`${p}-voice-cancel`} onClick={recorder.cancel} className={secondary}>Cancel</button>
        </div>
      ) : phase === 'recording' ? (

        <div className="flex min-w-0 flex-col gap-2">
          <div className="flex min-w-0 items-center gap-3 rounded-full bg-neutral-soft px-3">
            <span aria-hidden="true" className="h-2 w-2 shrink-0 rounded-full bg-danger" />
            <span data-debug-id={`${p}-voice-timer`} aria-label="Recording elapsed time" className="shrink-0 font-mono tabular-nums">{formatAudioTime(recorder.elapsedMs / 1000)}</span>
            <span className="sr-only" role="status">Recording</span>
            <div data-debug-id={`${p}-voice-waveform`} className="min-w-0 flex-1">
              {recorder.amplitudes.length ? <AudioWaveform live peaks={recorder.amplitudes} /> : <span className="flex h-11 items-center text-caption text-muted">Microphone level unavailable</span>}
            </div>
          </div>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <button type="button" data-debug-id={`${p}-voice-cancel`} onClick={recorder.cancel} className={secondary}><Icon name="trash" size="sm" />Cancel</button>
            <button type="button" data-debug-id={`${p}-voice-stop`} onClick={recorder.stop} aria-label="Stop recording" className={secondary}>
              <Icon name="stop" size="sm" />Stop
            </button>
          </div>
        </div>
      ) : recorder.recording ? (
        <div className="flex min-w-0 flex-col gap-2">
          <AudioPlayer src={recorder.recording.url} durationHintMs={recorder.recording.durationMs}
            debugId={`${p}-voice-preview`} label="Recording" />
          <div className="flex min-w-0 flex-wrap items-center justify-end gap-2">
            {recorder.limitReached ? <span data-debug-id={`${p}-voice-limit`} className="mr-auto min-w-0 text-caption text-muted">Stopped at the length limit.</span> : null}
            <button type="button" data-debug-id={`${p}-voice-discard`} onClick={recorder.discard} className={secondary}>
              <Icon name="trash" size="sm" />Discard
            </button>
            <button type="button" data-debug-id={`${p}-voice-send`} disabled={sendDisabled} onClick={onSend}
              className={`${btn} bg-accent font-semibold text-accent-fg disabled:opacity-45`}>
              <Icon name="arrow-up" size="sm" />Send
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

/**
 * Glue between the recorder and a composer's attachment flow: Send uploads the recording as
 * an `audio` artifact through the composer's own `uploadAttachment` and, once that upload
 * (and any other in flight) finishes, submits the message via `onReadyToSend`. If the upload
 * fails the recording stays in the attachment tray with Retry, and nothing is sent.
 */
export function useVoiceMessage({ attachments, uploadAttachment, onReadyToSend, env }: {
  attachments: PendingAttachment[];
  uploadAttachment: (file: File, localId?: string) => Promise<void> | void;
  onReadyToSend: () => void;
  env?: VoiceRecorderEnv;
}) {
  const recorder = useVoiceRecorder({ env });
  const [pendingId, setPendingId] = useState('');
  const sendRef = useRef(onReadyToSend);
  sendRef.current = onReadyToSend;

  useEffect(() => {
    if (!pendingId) return;
    const voice = attachments.find((a) => a.localId === pendingId);
    if (!voice || voice.status === 'error') { setPendingId(''); return; }
    if (voice.status !== 'uploaded' || attachments.some((a) => a.status === 'uploading')) return;
    setPendingId('');
    sendRef.current();
  }, [attachments, pendingId]);

  function send() {
    const file = recorder.take();
    if (!file) return;
    const localId = `voice_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    setPendingId(localId);
    void uploadAttachment(file, localId);
  }

  return {
    recorder,
    send,
    /** Recording, previewing or uploading-to-send: keeps a morphing composer open. */
    active: recorder.phase !== 'idle' || Boolean(pendingId),
  };
}
