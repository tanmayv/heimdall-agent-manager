import { useEffect, useRef, useState, type CSSProperties } from 'react';
import { Icon } from '@ui';
import { formatAudioTime, resolveAudioDuration } from '../../utils/audioArtifact';

/** Far past any real duration: seeking here makes Chromium scan a duration-less WebM to the end. */
const DURATION_PROBE_SECONDS = 1e9;

/**
 * REQ-VOICE-3: the inline audio player (play/pause, seek, elapsed / duration) used in chat
 * transcripts, the artifact viewer and the composer's recording preview. `src` is a blob: URL
 * of already-decrypted content; this component never fetches.
 */
export function AudioPlayer({ src, debugId, label = 'Audio', durationHintMs = 0, className = '' }: {
  src: string;
  debugId: string;
  /** Accessible name prefix for the controls ("Play voice message"). */
  label?: string;
  /** A known length (the recorder's measurement) for files whose header has none. */
  durationHintMs?: number;
  className?: string;
}) {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const probing = useRef(false);
  const [playing, setPlaying] = useState(false);
  const [current, setCurrent] = useState(0);
  const [rawDuration, setRawDuration] = useState(NaN);
  const [error, setError] = useState('');
  const duration = resolveAudioDuration(rawDuration, durationHintMs);
  const seekable = Number.isFinite(duration) && duration > 0;

  useEffect(() => {
    setPlaying(false);
    setCurrent(0);
    setRawDuration(NaN);
    setError('');
    probing.current = false;
  }, [src]);

  // Pause when the player leaves the page (message list virtualisation, closing a viewer).
  useEffect(() => () => { audioRef.current?.pause(); }, []);

  function syncDuration(audio: HTMLAudioElement) {
    const value = audio.duration;
    if (value === Infinity && !probing.current) {
      probing.current = true;
      try { audio.currentTime = DURATION_PROBE_SECONDS; } catch { probing.current = false; }
      return;
    }
    if (Number.isFinite(value) && value > 0) {
      setRawDuration(value);
      if (probing.current) {
        probing.current = false;
        try { audio.currentTime = 0; } catch {}
        setCurrent(0);
      }
    }
  }

  async function toggle() {
    const audio = audioRef.current;
    if (!audio || !src) return;
    if (!audio.paused) { audio.pause(); return; }
    setError('');
    try {
      if (seekable && audio.currentTime >= duration - 0.05) audio.currentTime = 0;
      await audio.play();
    } catch (err: any) {
      if (err?.name !== 'AbortError') setError('This audio could not be played.');
    }
  }

  function seek(value: number) {
    const audio = audioRef.current;
    if (!audio || !seekable) return;
    const next = Math.min(Math.max(0, value), duration);
    try { audio.currentTime = next; } catch {}
    setCurrent(next);
  }

  return (
    <div data-debug-id={debugId} data-playing={playing ? 'true' : 'false'}
      className={`flex min-w-0 items-center gap-2 ${className}`}>
      <audio
        ref={audioRef}
        data-debug-id={`${debugId}-audio`}
        src={src || undefined}
        preload="metadata"
        onLoadedMetadata={(event) => syncDuration(event.currentTarget)}
        onDurationChange={(event) => syncDuration(event.currentTarget)}
        onTimeUpdate={(event) => { if (!probing.current) setCurrent(event.currentTarget.currentTime); }}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onError={() => { if (src) setError('This audio could not be played.'); setPlaying(false); }}
        className="hidden"
      />
      <button
        type="button"
        data-debug-id={`${debugId}-toggle`}
        aria-label={playing ? `Pause ${label.toLowerCase()}` : `Play ${label.toLowerCase()}`}
        disabled={!src}
        onClick={() => void toggle()}
        className="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-neutral-soft text-primary hover:bg-strong disabled:opacity-45"
      >
        <Icon name={playing ? 'pause' : 'play'} size="sm" />
      </button>
      <input
        type="range"
        data-debug-id={`${debugId}-seek`}
        aria-label={`Seek ${label.toLowerCase()}`}
        aria-valuetext={`${formatAudioTime(current)} of ${formatAudioTime(duration)}`}
        min={0}
        max={seekable ? duration : 0}
        step="any"
        value={seekable ? Math.min(current, duration) : 0}
        disabled={!seekable}
        onChange={(event) => seek(Number(event.currentTarget.value))}
        style={{ accentColor: 'var(--color-accent)' } as CSSProperties}
        className="h-1.5 min-w-[64px] flex-1 cursor-pointer disabled:cursor-default disabled:opacity-45"
      />
      <span data-debug-id={`${debugId}-time`} className="shrink-0 font-mono text-caption tabular-nums text-muted">
        {formatAudioTime(current)} / {formatAudioTime(duration)}
      </span>
      {error ? <span role="alert" data-debug-id={`${debugId}-error`} className="shrink-0 text-caption text-danger">{error}</span> : null}
    </div>
  );
}
